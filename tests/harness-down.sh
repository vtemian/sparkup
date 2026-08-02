#!/usr/bin/env bash
# Remove everything tests/harness-up.sh created: both containers, both named
# volumes, and the synthetic exporter process.
#
# The volumes matter. Grafana keeps provisioned-dashboard state and Prometheus
# keeps a TSDB in them, so leaving them behind means the next run starts with
# yesterday's synthetic history and a dashboard that may not be the file on
# disk. `down` without --volumes is how a harness stops being reproducible.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDERED_DIR="${REPO_ROOT}/tests/harness/rendered"
PID_FILE="${RENDERED_DIR}/fake-exporters.pid"
PROJECT="sparkup-harness"

if [ -f "${PID_FILE}" ]; then
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
        echo "==> Stopping the synthetic exporters (pid ${pid})"
        kill "${pid}"
    fi
    rm -f "${PID_FILE}"
fi

if ! docker info >/dev/null 2>&1; then
    echo "docker is not running; nothing container-shaped to remove"
    exit 0
fi

echo "==> Removing ${PROJECT} containers and volumes"
if [ -f "${RENDERED_DIR}/compose.yml" ]; then
    docker compose --project-directory "${RENDERED_DIR}" --project-name "${PROJECT}" \
        down --volumes --remove-orphans
else
    # The rendered tree is gone but the stack may not be. Compose can still act
    # on a project it labelled, without a file to read.
    docker compose --project-name "${PROJECT}" down --volumes --remove-orphans
fi

remaining="$(docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}")"
if [ -n "${remaining}" ]; then
    echo "==> Removing volumes compose left behind"
    echo "${remaining}" | xargs docker volume rm
fi

echo "Down. The rendered stack is still in ${RENDERED_DIR} if you want to read it."
