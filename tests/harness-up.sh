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

# compose.yml.j2 no longer pins container_name, so this harness and a real
# monitoring stack get distinct per-project container names and can coexist.
# A container literally named `prometheus` or `grafana` can still exist though,
# from an older stack that did pin it, and it would hold the ports. Refuse
# rather than clobber somebody else's containers.
for name in prometheus grafana; do
    existing="$(docker ps -aq --filter "name=^${name}$")"
    if [ -n "${existing}" ]; then
        owner="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' \
            "${existing}")"
        if [ "${owner}" != "${PROJECT}" ]; then
            echo "a container named '${name}' already exists and belongs to" >&2
            echo "'${owner:-no compose project}', not ${PROJECT}. It predates the" >&2
            echo "removal of container_name from the compose template. Stop it first." >&2
            exit 1
        fi
    fi
done

echo "==> Rendering the monitoring role's templates"
ansible-playbook "${HARNESS_DIR}/render.yml"

EXPORTER_LOG="${RENDERED_DIR}/fake-exporters.log"

exporters_answer() {
    curl -fsS "http://127.0.0.1:${NODE_PORT}/metrics" >/dev/null &&
        curl -fsS "http://127.0.0.1:${GPU_PORT}/metrics" >/dev/null
}

port_in_use() {
    python3 -c 'import socket, sys
probe = socket.socket()
probe.settimeout(1)
sys.exit(0 if probe.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$1"
}

echo "==> Starting the synthetic exporters on :${NODE_PORT} and :${GPU_PORT}"
if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "    already running as pid $(cat "${PID_FILE}")"
else
    # Refuse before starting rather than after. A process that loses the bind
    # dies on EADDRINUSE in milliseconds, but the port keeps answering,
    # because whatever already held it is still there, so a check that only asks
    # "does :19100 respond" passes while Prometheus scrapes a stranger. That
    # is not a hypothetical: it happened while this harness was being written,
    # and every panel went green off someone else's process.
    for port in "${NODE_PORT}" "${GPU_PORT}"; do
        if port_in_use "${port}"; then
            echo "something is already listening on 127.0.0.1:${port}." >&2
            echo "The harness will not feed Prometheus from a process it did not" >&2
            echo "start. Free the port, or change it in tests/harness/vars.yml:" >&2
            echo "  lsof -nP -iTCP:${port} -sTCP:LISTEN" >&2
            exit 1
        fi
    done
    # SPARKUP_HARNESS_SAFETY_MODE=1 serves the collapsed 20/30 W caps and a
    # 495 MHz clock, which is how tests/check_alerts.sh gets the alerts to fire.
    safety_flag=()
    [ "${SPARKUP_HARNESS_SAFETY_MODE:-0}" = "1" ] && safety_flag=(--safety-mode)
    python3 "${REPO_ROOT}/tests/fake_exporters.py" \
        --node-port "${NODE_PORT}" --gpu-port "${GPU_PORT}" "${safety_flag[@]}" \
        >"${EXPORTER_LOG}" 2>&1 &
    echo $! >"${PID_FILE}"
    echo "    pid $(cat "${PID_FILE}"), log ${EXPORTER_LOG}"
fi

exporter_deadline=$(( $(date +%s) + 15 ))
until exporters_answer; do
    if [ "$(date +%s)" -ge "${exporter_deadline}" ]; then
        echo "the synthetic exporters never answered on :${NODE_PORT} and :${GPU_PORT}:" >&2
        cat "${EXPORTER_LOG}" >&2
        rm -f "${PID_FILE}"
        exit 1
    fi
    sleep 1
done
echo "    both endpoints answering"

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

# The energy panel sums its gauge at a fixed 15 s subquery step, so two samples
# ten seconds apart leave every step outside the data and the panel is empty for a
# reason that has nothing to do with the query. Wait for a window wider than the
# step instead of racing it.
enough_for_subqueries() {
    [ "$(promql 'min(count_over_time(up{job=~"node|gpu"}[5m]))')" -ge 6 ]
}

echo "==> Waiting for the stack"
wait_for "Prometheus is ready" prometheus_ready
wait_for "both exporter targets are up" targets_up
wait_for "both targets scraped twice, so rate() has slope" scraped_twice
wait_for "a window wider than the dashboard's 15s subquery step" enough_for_subqueries

echo "==> Checking every panel query returns data"
python3 "${REPO_ROOT}/tests/check_dashboard.py" --prometheus-url "${PROMETHEUS_URL}"

DASHBOARD_URL="http://localhost:${GRAFANA_PORT}/d/box-overview/box-overview"
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
