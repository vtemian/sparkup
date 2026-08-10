# Testing the skills

`.claude/skills/` tells an agent how to diagnose this hardware. These tests check that it works on
an agent that has never seen this repo, by putting one in a container with a faked box and grading
the verdict it reaches.

```bash
install -m 600 /dev/null ~/.sparkup-anthropic-key   # the container cannot use a host login
$EDITOR ~/.sparkup-anthropic-key                    # the key, nothing else
./tests/skills/run.sh                               # every scenario, both arms
./tests/skills/run.sh at-the-cap with-skill
```

`ANTHROPIC_API_KEY` in the environment works too. The file is the default because it keeps the key
out of shell history, out of `ps` and out of any transcript, the same reason `~/.sparkup-become`
exists.

Not part of `make offline`. It calls a model, so it costs tokens and needs a key, and CI has neither.

## What a run does

Three scenarios, each run twice: once with `.claude/skills` mounted and once without.

| Scenario | The box | The verdict that counts as correct |
|---|---|---|
| `pd-safety-mode` | `pl1` cap collapsed to 20 W, GPU at 495 MHz | EC safety mode, needs a cold drain, cannot be done over SSH |
| `at-the-cap` | caps healthy, `pl1` pinned at 139.7/140 W | working as designed, 240 W is the PSU rating, nothing to fix |
| `below-cap` | caps healthy, `pl1` at 117/140 W | not compute-bound, profile it, do not raise limits |

**The `no-skill` arm is the control and is expected to fail.** A skill that changes nothing is not
earning its place, so the run prints both and only fails the build on a `with-skill` arm that misses
the verdict. A failing transcript is copied to `tests/skills/last-failure.log`.

Grading is on the conclusion, not the wording. Checking for phrases lifted from the skill would only
prove an agent can copy.

## The faked box

`fakebox.sh` builds all three fakes a skill reads, from one table of microwatt values per scenario:
`/sys/class/hwmon/hwmon6` with the driver's 14 power channels and 8 thermal zones, a `make report`
that prints the real role's formatting, and an `nvidia-smi` that **lies the way the real one does** —
reads the GPU rail low, answers `[N/A]` for `power.limit`, and reports every Clocks Event Reason as
`Not Active` through a throttle the EC is enforcing. A skill that trusts it fails, which is the point.

Two container details that are not optional:

- `--tmpfs /sys/class` before the hwmon bind. `/sys` is read-only sysfs, so Docker cannot create the
  mountpoint, and without the tmpfs the run dies at container init.
- `bash -c`, never `-lc`. A login shell rebuilds `PATH` from `/etc/profile` and drops `/fakebox/bin`,
  so the agent sees no GPU at all and the scenario silently stops testing anything.

Numbers come from the reference box or from the documented safety-mode state; see
[INSTALL_CLAUDE.md](../../INSTALL_CLAUDE.md), "What the box can actually draw". If reality changes,
the scenarios change with it.
