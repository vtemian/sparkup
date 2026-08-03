#!/usr/bin/env bash
# Converge a role in a container, then converge it again and require the second
# run to report changed=0 — the project's stated acceptance test, run against
# the only substrate available without a DGX Spark.
#
# Two roles are covered and four are not. The uncovered ones are named on
# stdout every time this runs, because a test suite that quietly omits most of
# the system reads as broader coverage than it has.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${REPO_ROOT}/tests/roles"
IMAGE="sparkup-role-test"
CONTAINERS=(sparkup-test-base sparkup-test-users)
LOG_DIR="${TMPDIR:-/tmp}/sparkup-role-idempotence"
BOOT_TIMEOUT=60

cat <<'SCOPE'
=============================================================================
What this covers, and what it does not

  base    tested. Needs systemd for avahi, hostnamectl and service_facts, so
          the container boots a real init.
  users   tested. Accounts, groups and the shared tree. The GitHub key import
          is not exercised: it needs the network and a real account.

  docker      NOT tested. Installing docker-ce inside a container and starting
              a second daemon is docker-in-docker, and the daemon.json this
              role writes names the nvidia runtime, which is not present.
  gpu         NOT tested. Needs a GB10, driver 580, nvidia-ctk and a CDI spec.
              Nothing about it can be faked without inventing the answer.
  exporters   NOT tested. Downloads linux-arm64 release archives, installs two
              systemd units and verifies them through Prometheus. The unit
              templates render offline (make lint), but nothing here proves
              they start.
  monitoring  NOT tested here. Its templates and dashboard are covered by
              `make harness-up` and `make dashboard`, which run the real
              Prometheus and Grafana against synthetic metrics; what stays
              unproven is the role's own tasks against a real host.

Only a converge against the box itself covers the rest. `make idempotence`.
=============================================================================

SCOPE

if ! docker info >/dev/null 2>&1; then
    echo "docker is not running; this test has nowhere to converge" >&2
    exit 1
fi

cleanup() {
    if [ "${SPARKUP_KEEP_CONTAINERS:-0}" = "1" ]; then
        echo "Leaving ${CONTAINERS[*]} running (SPARKUP_KEEP_CONTAINERS=1)"
        return
    fi
    docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "${LOG_DIR}"

echo "==> Building ${IMAGE}"
docker build --quiet --tag "${IMAGE}" "${TESTS_DIR}" >/dev/null

for container in "${CONTAINERS[@]}"; do
    docker rm -f "${container}" >/dev/null 2>&1 || true
    echo "==> Starting ${container}"
    # --privileged and the cgroup mount are what let systemd run as pid 1.
    docker run --detach --name "${container}" \
        --privileged --cgroupns=host \
        --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock \
        "${IMAGE}" >/dev/null

    deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
    until docker exec "${container}" systemctl is-system-running 2>/dev/null |
        grep -qE '^(running|degraded)$'; do
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            echo "systemd never finished booting in ${container}" >&2
            docker exec "${container}" systemctl --failed || true
            exit 1
        fi
        sleep 1
    done

    # Docker bind-mounts /etc/hosts, /etc/hostname and /etc/resolv.conf from
    # outside the container, so any write that renames a temp file over them
    # fails with EBUSY — which is what ansible's lineinfile and hostnamectl
    # both do. Replacing the mounts with ordinary files of the same content
    # removes a container artifact; it does not change what the role does.
    docker exec "${container}" bash -c '
        set -euo pipefail
        for injected in /etc/hosts /etc/hostname /etc/resolv.conf; do
            cp "${injected}" "/tmp/detached"
            umount "${injected}"
            cat /tmp/detached > "${injected}"
        done
        rm -f /tmp/detached'
done

run_converge() {
    local pass="$1"
    echo "==> Converge, pass ${pass}"
    ansible-playbook \
        --inventory "${TESTS_DIR}/inventory.yml" \
        "${TESTS_DIR}/converge.yml" \
        2>&1 | tee "${LOG_DIR}/pass-${pass}.log"
}

run_converge 1 >/dev/null
run_converge 2

echo
echo "==> Second-run recap"
recap="$(sed -n '/PLAY RECAP/,$p' "${LOG_DIR}/pass-2.log" | grep -E 'changed=[0-9]+' || true)"
if [ -z "${recap}" ]; then
    echo "no PLAY RECAP in the second run; see ${LOG_DIR}/pass-2.log" >&2
    exit 1
fi
echo "${recap}"

if echo "${recap}" | grep -qvE 'changed=0 '; then
    echo
    echo "NOT IDEMPOTENT: a second converge changed something" >&2
    exit 1
fi
if echo "${recap}" | grep -qvE 'failed=0'; then
    echo
    echo "FAILED: a task failed on the second converge" >&2
    exit 1
fi
# A host ansible could not reach still prints changed=0 and failed=0, so those
# two checks pass on a run that did nothing at all. Only set -e aborting earlier
# saves this, and relying on that indirection is how a suite starts passing
# vacuously.
if echo "${recap}" | grep -qvE 'unreachable=0'; then
    echo
    echo "UNREACHABLE: a container did not answer, so nothing was proved" >&2
    exit 1
fi

echo
echo "IDEMPOTENT: base and users both reported changed=0 on the second run"
