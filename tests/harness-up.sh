#!/usr/bin/env bash
# Bring the monitoring stack up on this machine, fed by synthetic metrics.
#
# The point is to make the dashboard editable without a DGX Spark: the role's
# own templates are rendered, Prometheus and Grafana come up on ports that are
# not 80, two fake exporters serve numbers shaped like the real box, and the
# board is opened with data in it.
#
# Nothing here touches a real host. Everything it creates is removed by
# tests/harness-down.sh, volumes included.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/harness"
RENDERED_DIR="${HARNESS_DIR}/rendered"
PID_FILE="${RENDERED_DIR}/fake-exporters.pid"
PROJECT="sparkup-harness"
READY_TIMEOUT=120

read_var() {
    python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))[sys.argv[2]])' \
        "${HARNESS_DIR}/vars.yml" "$1"
}

# Every port and name comes from tests/harness/vars.yml, which is also what
# ansible renders the stack with. One source of truth, so a port changed in one
# place cannot leave the other pointing at nothing.
GRAFANA_PORT="$(read_var grafana_port)"
PROMETHEUS_PORT="$(read_var prometheus_port)"
PROMETHEUS_BIND="$(read_var prometheus_bind_address)"
NODE_PORT="$(read_var node_exporter_port)"
GPU_PORT="$(read_var nvidia_gpu_exporter_port)"
PROMETHEUS_URL="http://${PROMETHEUS_BIND}:${PROMETHEUS_PORT}"

if ! docker info >/dev/null 2>&1; then
    echo "docker is not running; the harness needs it for Prometheus and Grafana" >&2
    exit 1
fi

# compose.yml.j2 pins container_name: prometheus and container_name: grafana,
# which overrides the per-project naming the project name would otherwise give.
# Two stacks on one machine therefore collide. Refuse rather than adopt or
# clobber somebody else's containers.
for name in prometheus grafana; do
    existing="$(docker ps -aq --filter "name=^${name}$")"
    if [ -n "${existing}" ]; then
        owner="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' \
            "${existing}")"
        if [ "${owner}" != "${PROJECT}" ]; then
            echo "a container named '${name}' already exists and belongs to" >&2
            echo "'${owner:-no compose project}', not ${PROJECT}. The monitoring role's" >&2
            echo "compose template pins container_name, so the harness cannot run" >&2
            echo "alongside it. Stop that container first." >&2
            exit 1
        fi
    fi
done

echo "==> Rendering the monitoring role's templates"
ansible-playbook "${HARNESS_DIR}/render.yml"

echo "==> Starting the synthetic exporters on :${NODE_PORT} and :${GPU_PORT}"
if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "    already running as pid $(cat "${PID_FILE}")"
else
    python3 "${REPO_ROOT}/tests/fake_exporters.py" \
        --node-port "${NODE_PORT}" --gpu-port "${GPU_PORT}" \
        >"${RENDERED_DIR}/fake-exporters.log" 2>&1 &
    echo $! >"${PID_FILE}"
    echo "    pid $(cat "${PID_FILE}"), log ${RENDERED_DIR}/fake-exporters.log"
fi

echo "==> Bringing up ${PROJECT}"
docker compose --project-directory "${RENDERED_DIR}" --project-name "${PROJECT}" up -d

wait_for() {
    local description="$1" deadline
    shift
    deadline=$(( $(date +%s) + READY_TIMEOUT ))
    until "$@" >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            echo "timed out after ${READY_TIMEOUT}s waiting for ${description}" >&2
            return 1
        fi
        sleep 1
    done
    echo "    ${description}"
}

prometheus_ready() {
    curl -fsS "${PROMETHEUS_URL}/-/ready"
}

# Asking Prometheus is the only honest way to check an exporter: this repo's
# rule is never to verify one by curling it.
promql() {
    curl -fsS --get --data-urlencode "query=$1" "${PROMETHEUS_URL}/api/v1/query" |
        python3 -c 'import json, sys
result = json.load(sys.stdin)["data"]["result"]
print(int(float(result[0]["value"][1])) if result else 0)'
}

targets_up() {
    [ "$(promql 'count(up{job=~"node|gpu"} == 1)')" = "2" ]
}

# A panel built on rate() has no data until a target has been scraped twice,
# so the dashboard check would race the first scrape and report an empty panel
# that is only early. Wait for the second sample instead of sleeping and
# hoping.
scraped_twice() {
    [ "$(promql 'min(count_over_time(up{job=~"node|gpu"}[5m]))')" -ge 2 ]
}

echo "==> Waiting for the stack"
wait_for "Prometheus is ready" prometheus_ready
wait_for "both exporter targets are up" targets_up
wait_for "both targets scraped twice, so rate() has slope" scraped_twice

echo "==> Checking every panel query returns data"
python3 "${REPO_ROOT}/tests/check_dashboard.py" --prometheus-url "${PROMETHEUS_URL}"

DASHBOARD_URL="http://localhost:${GRAFANA_PORT}/d/spark-overview/spark-overview"
echo
echo "Grafana:    ${DASHBOARD_URL}  (anonymous, no login)"
echo "Prometheus: ${PROMETHEUS_URL}"
echo "Tear down:  make harness-down"

if [ "${SPARKUP_HARNESS_OPEN:-1}" = "1" ]; then
    if command -v open >/dev/null 2>&1; then
        open "${DASHBOARD_URL}"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "${DASHBOARD_URL}"
    fi
fi
