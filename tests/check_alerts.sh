#!/usr/bin/env bash
# Prove the alerting rules fire, not just that promtool parses them.
#
# An alert nobody has ever watched fire is a comment with a `for:` clause. This
# brings the stack up twice: once on a healthy synthetic box, where the hardware
# alerts must all stay quiet, and once with the exporters serving the EC USB-PD
# safety mode, where the two that watch for it must reach `firing`.
#
# Needs no Spark. Docker is the only requirement.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/harness"

read_var() {
    python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))[sys.argv[2]])' \
        "${HARNESS_DIR}/vars.yml" "$1"
}
PROMETHEUS_URL="http://$(read_var prometheus_bind_address):$(read_var prometheus_port)"

# `for:` is 2m on the cap alert and 10m on the clock one. Waiting that out twice
# would make this unusable, so the rules are evaluated here through Prometheus's
# own API on the state it has: `pending` proves the expression matched, which is
# the thing under test. The `for:` durations are promtool's business, not this
# script's.
alert_state() {
    curl -fsS "${PROMETHEUS_URL}/api/v1/alerts" |
        python3 -c '
import json, sys
name = sys.argv[1]
alerts = json.load(sys.stdin)["data"]["alerts"]
states = sorted({a["state"] for a in alerts if a["labels"]["alertname"] == name})
print(",".join(states) if states else "inactive")' "$1"
}

rules_loaded() {
    curl -fsS "${PROMETHEUS_URL}/api/v1/rules" |
        python3 -c '
import json, sys
groups = json.load(sys.stdin)["data"]["groups"]
names = [r["name"] for g in groups for r in g["rules"]]
sys.exit(0 if "SparkPowerCapCollapsed" in names else 1)'
}

# Every series the two hardware rules read, across both synthetic exporters.
# Until all of them exist, an evaluation can only conclude `inactive`, which is
# indistinguishable from the alert being broken.
metrics_scraped() {
    curl -fsS --get "${PROMETHEUS_URL}/api/v1/query" \
        --data-urlencode 'query=count(node_hwmon_power_cap_watt)
          and count(node_hwmon_sensor_label)
          and count(nvidia_smi_clocks_current_sm_clock_hz)
          and count(nvidia_smi_utilization_gpu_ratio)' |
        python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["data"]["result"] else 1)'
}

# Prometheus stamps each group with the time it last ran.
group_stamp() {
    curl -fsS "${PROMETHEUS_URL}/api/v1/rules" |
        python3 -c '
import json, sys
groups = json.load(sys.stdin)["data"]["groups"]
print(next((g["lastEvaluation"] for g in groups if g["name"] == "spark"), ""))'
}

stamp_moved_from() { [ "$(group_stamp)" != "$1" ]; }

# Poll the condition rather than guess how long it takes. Every arbitrary sleep
# here was a race: on a loaded runner the container start, the first scrape and
# the group evaluation interleave any way they like, and whichever rule's series
# landed after the last evaluation read `inactive`. Both of these alerts have
# failed CI that way in turn, each while the other passed, and both pass locally
# every time.
wait_for() {
    local what="$1" deadline
    shift
    deadline=$(( $(date +%s) + 120 ))
    until "$@"; do
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            echo "    timed out waiting for ${what}" >&2
            exit 1
        fi
        sleep 1
    done
}

failures=0
check() {
    local label="$1" want="$2" got="$3"
    if [ "${got}" = "${want}" ]; then
        echo "    OK    ${label}: ${got}"
    else
        echo "    FAIL  ${label}: expected ${want}, got ${got}"
        failures=$((failures + 1))
    fi
}

LOG="$(mktemp)"
trap 'rm -f "${LOG}"' EXIT

# Compose narrates every container it touches on stderr, which drowns four lines
# of result. Captured, and shown only when something actually fails.
quietly() {
    if ! "$@" >"${LOG}" 2>&1; then
        echo "    command failed: $*" >&2
        tail -20 "${LOG}" >&2
        exit 1
    fi
}

run_phase() {
    local phase="$1" stamp
    echo
    echo "==> ${phase} box"
    SPARKUP_HARNESS_OPEN=0 quietly "${REPO_ROOT}/tests/harness-up.sh"
    wait_for "the alerting rules to load into Prometheus" rules_loaded
    wait_for "the synthetic exporters to be scraped" metrics_scraped
    # Two evaluations, not one: the evaluation in flight when the scrape landed
    # may have read the series as still absent, so only the second is guaranteed
    # to have seen this phase's data. This is what makes `inactive` on the
    # healthy box a result rather than a race the assertion happened to win.
    stamp="$(group_stamp)"
    wait_for "a rule evaluation after that scrape" stamp_moved_from "${stamp}"
    stamp="$(group_stamp)"
    wait_for "a second rule evaluation" stamp_moved_from "${stamp}"
}

echo "==> Alerting rules, against a synthetic box"

run_phase "healthy"
check "SparkPowerCapCollapsed quiet"  inactive "$(alert_state SparkPowerCapCollapsed)"
check "SparkGpuClockStuckLow quiet"   inactive "$(alert_state SparkGpuClockStuckLow)"
check "SparkFirmwarePowerSilent quiet" inactive "$(alert_state SparkFirmwarePowerSilent)"
check "SparkExporterDown quiet"       inactive "$(alert_state SparkExporterDown)"
quietly "${REPO_ROOT}/tests/harness-down.sh"

SPARKUP_HARNESS_SAFETY_MODE=1
export SPARKUP_HARNESS_SAFETY_MODE
run_phase "USB-PD safety mode"
# pending or firing both prove the expression matched; which one depends only on
# how long the phase has been up against the rule's `for:`.
cap="$(alert_state SparkPowerCapCollapsed)"
clock="$(alert_state SparkGpuClockStuckLow)"
case "${cap}" in
    pending|firing|pending,firing) echo "    OK    SparkPowerCapCollapsed: ${cap}" ;;
    *) echo "    FAIL  SparkPowerCapCollapsed: expected pending or firing, got ${cap}"
       failures=$((failures + 1)) ;;
esac
case "${clock}" in
    pending|firing|pending,firing) echo "    OK    SparkGpuClockStuckLow: ${clock}" ;;
    *) echo "    FAIL  SparkGpuClockStuckLow: expected pending or firing, got ${clock}"
       failures=$((failures + 1)) ;;
esac
quietly "${REPO_ROOT}/tests/harness-down.sh"

echo
if [ "${failures}" -gt 0 ]; then
    echo "FAIL: ${failures} alert(s) did not behave as documented"
    exit 1
fi
echo "PASS: the hardware alerts stay quiet on a healthy box and fire on the safety mode"
