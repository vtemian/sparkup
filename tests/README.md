# `tests`

Everything here runs without a Spark. What each target proves, and which ones `make offline` runs, is
in [INSTALL_CLAUDE.md](../INSTALL_CLAUDE.md) under "Working without the hardware". This file is the
constraints on the tests themselves: what breaks if you change them without knowing why.

## Writing a test playbook

**`vars_files` outrank a play's `vars:`.** A test playbook that sets `spark_users` in `vars:` while
loading `group_vars/all.yml` gets the empty list and silently creates nobody.

## The alert test

**An alert nobody has watched fire is a comment with a `for:` clause.** `make alerts` is the reason
`fake_exporters.py` has a `--safety-mode`: it serves the collapsed 20/30 W caps and a 495 MHz SM
clock, and `check_alerts.sh` asserts the two rules that watch for that state reach `pending` or
`firing` while every other hardware rule stays `inactive` on a healthy box. It checks `pending` as
well as `firing` on purpose, because waiting out a 10 minute `for:` twice would make the test
unusable, and `pending` already proves the expression matched.

## The synthetic exporters

`fake_exporters.py` stands in for a box with `spbm_enabled: true`, so the power panels are checked
against the machine they were written for rather than skipped.

**It models all 14 spbm power channels, in the driver's order, and that order is not guessable.** It
is `sys_total soc_pkg cpu_gpu cpu_p cpu_e vcore dc_input gpu prereg dla pl1 pl2 syspl1 syspl2`, taken
from `pwr_chans[]` in the driver source, so `power11` is `pl1` in the harness exactly as on the box.
`powerN_cap`, `powerN_max` and `powerN_min` exist for the four limit channels **only**. `_cap` is the
effective limit and is writable; `_max` is the firmware ceiling.

**The nesting between channels has to hold at idle as well as at load.** The power flow and canvas
panels compute board overhead and uncore as differences between channels, so a synthetic idle value
that puts the rails above `soc_pkg`, or `soc_pkg` above `sys_total`, draws a box larger than the box
containing it. This is why every span in `SPBM_POWER` is scaled against `busy` topping out at 0.65
rather than at 1.0, and why `pl1` tracks `soc_pkg`: it has to graze its 140 W cap at the peak or the
capping panels are a flat "not capped" line that nothing tests.

**`nvidia_smi_power_draw_watts` is derived from the firmware `gpu` channel and then made to read low,
on purpose** — a fixed `0.695`, about 30% under. The dashboard has a panel whose entire point is that
gap, and driving the two from different cycles let them cross, which taught the opposite of what was
measured. On real hardware the undercount is not a constant: it has been measured anywhere from 18%
to 44% under. The harness picks one value because a panel needs one, not because the gap is fixed.

## Reading the harness in a browser

**A panel that looks empty in `make harness-up` is usually not empty.** A fresh browser profile needs
the better part of twenty seconds to load Grafana's plugin bundles before any panel draws, and a
provisioned dashboard rewritten under an already-open tab leaves that tab's scene stale. Reload the
page before believing a blank panel, and check the panel query with
`python3 tests/check_dashboard.py --prometheus-url http://127.0.0.1:19090` before changing it.
