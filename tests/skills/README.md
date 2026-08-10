# Testing the skills

`.claude/skills/` tells an agent how to read this hardware. These tests check that it works on an
agent that has never seen this repo, by putting one in a container with a faked box and grading the
verdict it reaches.

```bash
install -m 600 /dev/null ~/.sparkup-anthropic-key   # the container cannot use a host login
$EDITOR ~/.sparkup-anthropic-key                    # the key, nothing else
./tests/skills/run.sh                               # every scenario, both arms
./tests/skills/run.sh at-the-cap with-skill
```

`ANTHROPIC_API_KEY` in the environment works too, and `SPARKUP_ANTHROPIC_KEY_FILE` can point at any
file, including a project `.env` that already holds the key. Only that one variable is read; the file
is never sourced.

Not part of `make offline`. It calls a model, so it costs tokens and needs a key, and CI has neither.

## What a run does

Four scenarios, each run twice: once with `.claude/skills` mounted and once without. That mount is
the **only** difference between the arms, so a pass can be attributed to it.

| Scenario | The box | The verdict that counts as correct |
|---|---|---|
| `pd-safety-mode` | `pl1` cap collapsed to 20 W, GPU at 495 MHz | EC safety mode, needs a cold drain, needs someone at the machine |
| `at-the-cap` | caps healthy, `pl1` pinned at 139.7/140 W | working as designed, 240 W is the PSU rating, nothing to fix |
| `below-cap` | caps healthy, `pl1` at 117/140 W | not compute-bound, profile the job, do not raise limits |
| `contended-benchmark` | healthy, plus a second process the user did not mention, and a runnable `gemm.py` | a throughput number now is invalid; 213 TFLOPS is the wrong target |

**The `no-skill` arm is the control and is expected to fail.** A skill that changes nothing is not
earning its place, so the run prints both and only fails the build on a `with-skill` arm.

Measured on Sonnet: **all four `with-skill` arms pass, and three of the four controls fail.** That
holds across runs. *Which* control passes does not, so treat a single scenario's control verdict as
weak evidence and the with-skill column as the result. One sample per cell buys no more than that.

How the controls fail, when they do:

- `pd-safety-mode` blames software or thermals and never reaches a cold drain. This is the only
  scenario whose answer exists nowhere but the skill.
- `contended-benchmark` misses the second process on the GPU, runs `gemm.py` anyway, and reports a
  contended number as the box's throughput.
- `below-cap` offers `nvidia-smi -pl` as a limit to raise, the one action the branch exists to rule out.
- `at-the-cap` treats a correctly working box as a fault, or accepts 240 W as a reachable target.

`at-the-cap` is the weakest of the four, because `make report` itself prints that pl1 holds the box
near 171 W and that 240 W is the PSU rating. The fixture reproduces that guidance deliberately: a
control denied what the real report says would make the skill look better than it is.

## Grading is a judge, not a regex

A second model call gets an explicit rubric and the answer, and returns PASS or FAIL with a reason.
The reasons are printed and every transcript is kept under `transcripts/`, so a verdict can be
audited rather than trusted.

Regexes were tried first and were wrong twice, both times grading wording instead of meaning: an
answer that said "requires physical access" was failed for not saying "physically", and an answer
that said a fan curve is **not** the fix was failed for containing the words "fan curve". A substring
cannot tell "do X" from "do not do X", and that distinction is most of what these skills teach.

The rubrics say so explicitly: warning the user against a forbidden action is correct and does not
count as recommending it.

## The faked box

`fakebox.sh` builds all three fakes a skill reads, from one table of microwatt values per scenario:
`/sys/class/hwmon/hwmon6` with the driver's 14 power channels and 8 thermal zones, a `make report`
that prints the real role's formatting, and an `nvidia-smi` that **lies the way the real one does** —
reads the GPU rail low, answers `[N/A]` for `power.limit`, and reports every Clocks Event Reason as
`Not Active` through a throttle the EC is enforcing. A skill that trusts it fails, which is the point.

Four container details that are not optional:

- `--tmpfs /sys/class` before the hwmon bind. `/sys` is read-only sysfs, so Docker cannot create the
  mountpoint, and without the tmpfs the run dies at container init.
- `bash -c`, never `-lc`. A login shell rebuilds `PATH` from `/etc/profile` and drops `/fakebox/bin`,
  so the agent sees no GPU at all and the scenario silently stops testing anything.
- Run as the `node` user. The CLI refuses `--dangerously-skip-permissions` with root privileges, and
  without that flag a headless agent cannot run the commands the skill tells it to run.
- The prompt arrives as a mounted file. `docker run` without `-i` attaches no stdin, and the CLI exits
  saying it was given no input.
- A runnable `gemm.py` and a python to run it. Without them "just run the benchmark and report the
  number" is impossible, so the rubric clause forbidding it could never fire.
- The judge reads the answer from a mounted file and is told it is data. Splicing the answer into the
  judge's prompt let the text being graded close the markers around itself and address the judge.
- The CLI version is pinned in the Dockerfile. It is the thing under test, and `latest` plus a cached
  npm layer means two machines test two different CLIs and neither result reproduces.

`~/.claude` is deliberately **not** mounted. It carries no credential on macOS anyway (the token is in
the Keychain), and it holds this project's memory files and every past transcript, which is to say the
answer key. An agent that can read those reaches the right verdict whether the skill works or not.

Numbers come from the reference box or from the documented safety-mode state; see
[INSTALL_CLAUDE.md](../../INSTALL_CLAUDE.md), "What the box can actually draw". If reality changes,
the scenarios change with it.
