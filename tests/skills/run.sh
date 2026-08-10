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

SCENARIOS=(pd-safety-mode at-the-cap below-cap contended-benchmark)
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
        contended-benchmark)
            echo "Can you benchmark my DGX Spark and tell me what dense bf16 throughput it \
should be getting? I have seen 213 TFLOPS quoted for this hardware and I want to know whether \
mine is reaching it."
            ;;
    esac
}

# Grading is a second model call against an explicit rubric, not a regex.
#
# Regexes were tried and failed twice, both times passing judgement on wording
# rather than meaning: an answer saying "requires physical access" was failed for
# not saying "physically", and an answer saying a fan curve is NOT the fix was
# failed for containing the words "fan curve". A substring cannot tell "do X"
# from "do not do X", and that distinction is most of what these skills teach.
rubric_for() {
    case "$1" in
        pd-safety-mode)
            cat <<'RUBRIC'
The box is in the EC/USB-PD safety mode: the pl1 power cap has collapsed to about
20 W and syspl1 to about 30 W, against healthy values of 140 W and 231 W, and the
GPU is stuck near 500 MHz.

To PASS, the answer must:
  1. identify that the power caps themselves are wrong, i.e. the safety mode or a
     failed PD negotiation, rather than blaming the workload or the software;
  2. prescribe a cold drain: power off, unplug at wall and unit, hold the power
     button, leave it disconnected for minutes, then reconnect;
  3. say that this needs someone physically at the machine and cannot be done
     over SSH.

It must NOT claim a plain reboot will clear it, and must NOT conclude the box is
healthy or that nothing is wrong.
RUBRIC
            ;;
        at-the-cap)
            cat <<'RUBRIC'
The box is saturated and working correctly: pl1 sits at 139.7 W against its 140 W
cap, sys_total at 170.8 W, and the 240 W on the spec sheet is the PSU rating.

To PASS, the answer must:
  1. identify pl1 at its cap as the binding limit;
  2. conclude that this is expected and there is nothing to fix, and that the
     240 W figure is the PSU rating with part of it structurally unreachable.

It must NOT recommend raising pl1 or any power limit as the remedy, and must NOT
recommend a fan curve or chasing the 3003 MHz max clock. Warning the user AGAINST
those things is correct and does not count as recommending them.
RUBRIC
            ;;
        contended-benchmark)
            cat <<'RUBRIC'
Another process is already resident on the GPU: nvidia-smi --query-compute-apps
reports pid 4711, python3, using about 41 GiB. The box itself is healthy.

To PASS, the answer must:
  1. notice that something else is already on the GPU, and say that a throughput
     benchmark taken now is not valid (a contended measurement understates
     throughput badly, though it remains usable for peak power);
  2. either refuse to quote a throughput number from a contended run, or clearly
     mark any number it does produce as invalid until the GPU is idle.

If the answer discusses the 213 TFLOPS figure, it must say that this is not dense
bf16 and is the wrong target; roughly 119 TFLOP/s at 2418 MHz is the dense bf16
expectation. It must NOT simply run a benchmark and report the contended result as
this box's throughput.
RUBRIC
            ;;
        below-cap)
            cat <<'RUBRIC'
The caps are healthy and pl1 sits at 117 W against a 140 W cap while a training
job runs, so the workload is simply not drawing the whole budget.

To PASS, the answer must:
  1. conclude the job is not compute-bound, and that low power does not mean slow
     (memory-bandwidth-bound work draws less by nature);
  2. point at profiling the job, for example dataloader starvation, a per-step
     host sync, or small unfused kernels, rather than at the hardware.

It must NOT recommend raising pl1 or any power limit, and must NOT recommend a fan
curve. Warning the user AGAINST those things is correct and does not count as
recommending them.
RUBRIC
            ;;
    esac
}

# The judge gets the rubric and the answer, and nothing else. It is not given the
# skill: its job is to say whether the answer reached the documented verdict, not
# whether it resembles the document.
judge() {
    local scenario="$1" answer="$2" workdir="$3"
    {
        echo "You are grading one answer to a hardware diagnosis question about an"
        echo "NVIDIA DGX Spark. Apply the rubric literally and do not add requirements."
        echo
        echo "RUBRIC:"
        rubric_for "${scenario}"
        echo
        echo "ANSWER UNDER TEST, between the markers:"
        echo "<<<<<<<<"
        cat "${answer}"
        echo ">>>>>>>>"
        echo
        echo "Reply with PASS or FAIL as the very first word, then one sentence saying why."
    } >"${workdir}/judge-prompt.txt"

    docker run --rm \
        -v "${workdir}/judge-prompt.txt:/work/judge-prompt.txt:ro" \
        -e ANTHROPIC_API_KEY \
        "${IMAGE}" \
        "claude -p \"\$(cat /work/judge-prompt.txt)\" --model ${MODEL} --dangerously-skip-permissions"
}

# A file rather than only an env var, for the same reason the become password is
# one: it keeps the key out of shell history and out of any transcript. Same
# shape as ~/.sparkup-become. It is handed to the container as `-e NAME`, by name,
# so it does not appear in the docker argv either.
#
# The file may be a bare key or a dotenv holding ANTHROPIC_API_KEY, because the
# key usually already exists in some project's .env and copying it to a second
# place is one more copy to leak. Only that one variable is read; the file is
# never sourced, so nothing else in it can execute.
KEY_FILE="${SPARKUP_ANTHROPIC_KEY_FILE:-${HOME}/.sparkup-anthropic-key}"
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -r "${KEY_FILE}" ]; then
    from_file="$(sed -n -E \
        's/^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_API_KEY[[:space:]]*=[[:space:]]*//p' \
        "${KEY_FILE}" | head -1 | sed -E 's/[[:space:]]+#.*$//' | tr -d '"'"'"'[:space:]')"
    # Only if the whole file is one token. Falling back to the file's entire
    # contents would send every other secret in a .env as the API key.
    if [ -z "${from_file}" ] && [ "$(wc -l <"${KEY_FILE}")" -le 1 ]; then
        from_file="$(tr -d '[:space:]' <"${KEY_FILE}")"
    fi
    ANTHROPIC_API_KEY="${from_file}"
    export ANTHROPIC_API_KEY
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "No API key. The container cannot use a host login, so the CLI in it needs one:" >&2
    echo "  install -m 600 /dev/null ${KEY_FILE}" >&2
    echo "  \$EDITOR ${KEY_FILE}      # paste the key, nothing else" >&2
    echo "or export ANTHROPIC_API_KEY in the environment before running." >&2
    exit 2
fi

if [ "$#" -ge 1 ]; then
    case " ${SCENARIOS[*]} " in
        *" $1 "*) SCENARIOS=("$1") ;;
        *) echo "unknown scenario: $1" >&2; exit 2 ;;
    esac
fi
# Validated, because `with-skil` silently ran the control and then reported that
# every with-skill arm had passed.
if [ "$#" -ge 2 ]; then
    case "$2" in
        no-skill|with-skill) ARMS=("$2") ;;
        *) echo "unknown arm: $2 (want no-skill or with-skill)" >&2; exit 2 ;;
    esac
fi

echo "==> Building ${IMAGE}"
docker build -q -t "${IMAGE}" "${HERE}" >/dev/null

# Kept, not deleted: reading what the control arm said is most of the value, and
# a verdict nobody can inspect is a number nobody should trust.
RESULTS_DIR="${HERE}/transcripts"
rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"
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
            # /sys is read-only sysfs, so Docker cannot create the mountpoint for
            # the hwmon bind and the container dies at init. A tmpfs over
            # /sys/class gives it somewhere writable; Docker orders mounts by
            # depth, so this lands before the bind inside it.
            --tmpfs /sys/class
            -v "${fake}/bin:/fakebox/bin:ro"
            -v "${fake}/hwmon:/sys/class/hwmon:ro"
            -v "${fake}/Makefile:/work/Makefile:ro"
            -v "${fake}/report.sh:/work/report.sh:ro"
        )
        # Only the skills. INSTALL_CLAUDE.md used to be mounted here too, and it
        # states three of the four rubrics almost verbatim, so the arms differed by
        # two things and a pass could not be attributed to the skill.
        if [ "${arm}" = "with-skill" ]; then
            mounts+=(-v "${REPO_ROOT}/.claude/skills:/work/.claude/skills:ro")
        fi

        # The prompt goes in as a mounted file, not on stdin: `docker run` without
        # -i attaches no stdin, so the CLI exits complaining it was given no
        # input. A file also keeps the quoting out of the docker argv.
        prompt_for "${scenario}" >"${fake}/prompt.txt"
        mounts+=(-v "${fake}/prompt.txt:/work/prompt.txt:ro")

        log="${RESULTS_DIR}/${scenario}.${arm}.log"
        # --dangerously-skip-permissions is safe here and nowhere else: the
        # container is disposable, holds no repo checkout and no credentials
        # beyond the key, and the alternative is an agent that cannot run the
        # very commands the skill tells it to run.
        if ! docker run --rm "${mounts[@]}" \
            -e ANTHROPIC_API_KEY \
            "${IMAGE}" \
            "claude -p \"\$(cat /work/prompt.txt)\" --model ${MODEL} --dangerously-skip-permissions" \
            >"${log}" 2>&1; then
            echo "    CLI FAILED, see below"
            tail -20 "${log}" | sed 's/^/    | /'
            summary+="${scenario} ${arm}: ERROR"$'\n'
            failures=$((failures + 1))
            continue
        fi

        judgement="${RESULTS_DIR}/${scenario}.${arm}.judgement"
        if ! judge "${scenario}" "${log}" "${fake}" >"${judgement}" 2>&1; then
            echo "    JUDGE FAILED"
            tail -5 "${judgement}" | sed 's/^/    | /'
            summary+="${scenario} ${arm}: ERROR"$'\n'
            failures=$((failures + 1))
            continue
        fi

        # First word only, and unparseable is an error rather than a pass. Scanning
        # the whole file graded a FAIL that itemised its reasoning as a pass, the
        # moment any line began "Passes requirement 1".
        first="$(tr -d '\r' <"${judgement}" | grep -m1 -oiE '^[^[:alpha:]]*(pass|fail)' || true)"
        case "$(printf '%s' "${first}" | tr '[:upper:]' '[:lower:]')" in
            *pass) verdict="pass" ;;
            *fail) verdict="fail" ;;
            *)
                echo "    JUDGE GAVE NO VERDICT"
                head -3 "${judgement}" | sed 's/^/    | /'
                summary+="${scenario} ${arm}: ERROR"$'\n'
                failures=$((failures + 1))
                continue
                ;;
        esac
        head -3 "${judgement}" | sed 's/^/    /'

        echo "    ${verdict}"
        summary+="${scenario} ${arm}: ${verdict}"$'\n'
        # The no-skill arm is expected to fail. It is the control, not a defect.
        if [ "${verdict}" = "fail" ] && [ "${arm}" = "with-skill" ]; then
            failures=$((failures + 1))
        fi
        echo "    transcript: ${log#"${REPO_ROOT}/"}"
    done
done

echo
echo "==> Summary"
printf '%s' "${summary}" | sed 's/^/    /'
echo
if [ "${failures}" -gt 0 ]; then
    echo "FAIL: ${failures} arm(s) errored or missed the documented verdict"
    exit 1
fi
echo "PASS: every with-skill arm reached the documented verdict"
