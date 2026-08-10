#!/usr/bin/env bash
# Test this repo's skills against a faked box, in a container, with the real CLI.
#
#   ./tests/skills/run.sh                      # every scenario, both arms
#   ./tests/skills/run.sh at-the-cap with-skill
#
# Two arms per scenario. `with-skill` mounts .claude/skills into the container;
# `no-skill` does not. A skill that changes nothing is a skill that is not
# earning its place, so the baseline is part of the test rather than a formality.
#
# Needs ANTHROPIC_API_KEY: the container cannot reach a host login. Costs tokens
# on every run, which is why nothing in `make offline` calls this.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="${REPO_ROOT}/tests/skills"
IMAGE="sparkup-skill-test"
MODEL="${SPARKUP_SKILL_TEST_MODEL:-sonnet}"

SCENARIOS=(pd-safety-mode at-the-cap below-cap)
ARMS=(no-skill with-skill)

prompt_for() {
    case "$1" in
        pd-safety-mode)
            echo "Something is wrong with my DGX Spark. Training is crawling, maybe five times \
slower than last week, on the same code and the same data. nvidia-smi shows the GPU at 99% \
utilisation and reports that nothing is throttling. I have rebooted it twice and it made no \
difference. What is going on, and how do I fix it?"
            ;;
        at-the-cap)
            echo "My DGX Spark will not pull anywhere near the 240 W on the spec sheet. Under a \
full load it maxes out around 170 W and nvidia-smi says the GPU is only drawing 72 W. What do I \
need to change to get the rest of the performance I paid for?"
            ;;
        below-cap)
            echo "My training job on the Spark keeps the GPU at 92% but the whole box only draws \
about 139 W, well under what it should be able to do. How do I get it to use the full power \
budget so the job runs faster?"
            ;;
    esac
}

# A verdict has to contain every `require` and none of the `reject`. The patterns
# are deliberately about the CONCLUSION, not the wording: a grader that checks
# for phrases from the skill only proves the agent can copy.
requires_for() {
    case "$1" in
        pd-safety-mode) printf '%s\n' 'cold.?drain|unplug' 'safety mode|pd negotiat|20 ?w cap|cap.{0,20}20 ?w' 'human|physically|cannot.{0,30}ssh|in person|at the machine' ;;
        at-the-cap)     printf '%s\n' 'psu rating|not broken|working as designed|nothing to fix|unreachable' 'pl1' ;;
        below-cap)      printf '%s\n' 'not compute.?bound|memory.?bandwidth|bandwidth.?bound' 'profil' ;;
    esac
}

rejects_for() {
    case "$1" in
        pd-safety-mode) printf '%s\n' 'reboot (will|should|to) (fix|clear|resolve)' 'nothing is wrong|no problem|box is fine' ;;
        at-the-cap)     printf '%s\n' 'raise (the )?(pl1|power ?(limit|cap))|increase (the )?power ?(limit|cap)' 'fan curve' ;;
        below-cap)      printf '%s\n' 'raise (the )?(pl1|power ?(limit|cap))|increase (the )?power ?(limit|cap)' 'fan curve' ;;
    esac
}

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ANTHROPIC_API_KEY is not set." >&2
    echo "The container cannot use a host login, so the CLI inside it needs a key:" >&2
    echo "  export ANTHROPIC_API_KEY=...   # then re-run" >&2
    exit 2
fi

if [ "$#" -ge 1 ]; then SCENARIOS=("$1"); fi
if [ "$#" -ge 2 ]; then ARMS=("$2"); fi

echo "==> Building ${IMAGE}"
docker build -q -t "${IMAGE}" "${HERE}" >/dev/null

RESULTS_DIR="$(mktemp -d)"
trap 'rm -rf "${RESULTS_DIR}"' EXIT
failures=0
summary=""

for scenario in "${SCENARIOS[@]}"; do
    fake="${RESULTS_DIR}/${scenario}"
    mkdir -p "${fake}"
    "${HERE}/fakebox.sh" "${scenario}" "${fake}" >/dev/null

    for arm in "${ARMS[@]}"; do
        echo
        echo "==> ${scenario} / ${arm}"
        mounts=(
            -v "${fake}/bin:/fakebox/bin:ro"
            -v "${fake}/hwmon:/sys/class/hwmon:ro"
            -v "${fake}/Makefile:/work/Makefile:ro"
            -v "${fake}/report.sh:/work/report.sh:ro"
        )
        if [ "${arm}" = "with-skill" ]; then
            mounts+=(-v "${REPO_ROOT}/.claude/skills:/work/.claude/skills:ro")
            mounts+=(-v "${REPO_ROOT}/INSTALL_CLAUDE.md:/work/INSTALL_CLAUDE.md:ro")
        fi

        log="${RESULTS_DIR}/${scenario}.${arm}.log"
        # --dangerously-skip-permissions is safe here and nowhere else: the
        # container is disposable, holds no repo checkout and no credentials
        # beyond the key, and the alternative is an agent that cannot run the
        # very commands the skill tells it to run.
        if ! docker run --rm "${mounts[@]}" \
            -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
            "${IMAGE}" \
            "claude -p \"\$(cat /dev/stdin)\" --model ${MODEL} --dangerously-skip-permissions" \
            <<<"$(prompt_for "${scenario}")" >"${log}" 2>&1; then
            echo "    CLI FAILED, see below"
            tail -20 "${log}" | sed 's/^/    | /'
            summary+="${scenario} ${arm}: ERROR"$'\n'
            failures=$((failures + 1))
            continue
        fi

        verdict="pass"
        while IFS= read -r pattern; do
            [ -n "${pattern}" ] || continue
            if ! grep -qiE "${pattern}" "${log}"; then
                echo "    MISSING: ${pattern}"
                verdict="fail"
            fi
        done < <(requires_for "${scenario}")
        while IFS= read -r pattern; do
            [ -n "${pattern}" ] || continue
            if grep -qiE "${pattern}" "${log}"; then
                echo "    PRESENT BUT FORBIDDEN: ${pattern}"
                verdict="fail"
            fi
        done < <(rejects_for "${scenario}")

        echo "    ${verdict}"
        summary+="${scenario} ${arm}: ${verdict}"$'\n'
        # The no-skill arm is expected to fail. It is the control, not a defect.
        if [ "${verdict}" = "fail" ] && [ "${arm}" = "with-skill" ]; then
            failures=$((failures + 1))
            cp "${log}" "${REPO_ROOT}/tests/skills/last-failure.log"
            echo "    transcript copied to tests/skills/last-failure.log"
        fi
    done
done

echo
echo "==> Summary"
printf '%s' "${summary}" | sed 's/^/    /'
echo
if [ "${failures}" -gt 0 ]; then
    echo "FAIL: ${failures} with-skill arm(s) did not reach the documented verdict"
    exit 1
fi
echo "PASS: every with-skill arm reached the documented verdict"
