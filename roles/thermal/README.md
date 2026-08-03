# `thermal`

Phase E. The role that decides how hot this box is allowed to get, and what it is allowed to do
about it. Two thirds of that is refusal: it asserts firmware rather than fixing it, it ships the
clock cap switched off, and it never flashes anything.

That posture is not caution for its own sake. It is what the measurements say.

## The absolute rule

**This role never flashes firmware.** Not behind a flag, not behind a confirmation prompt, not
ever. Config management that writes an embedded controller on every converge is how a box gets
bricked while nobody is watching, and an interrupted EC write is the only genuinely unrecoverable
step in this project. The rollback in [E4](#e4-the-firmware-rollback-runbook) is a runbook a human
executes standing next to the machine. It is documented here precisely so that it stays out of
`tasks/main.yml`.

The role has one other principle, which explains two otherwise-odd asymmetries below: **it only
ever adds protection.** It masks the firmware auto-update path but never unmasks it; it starts the
clock cap but never stops a running one. Every guard here exists to survive somebody's absence, so
removing one is always a deliberate manual act.

## What it manages

| Concern | How |
|---|---|
| GPU clock ceiling | `gpu-clock-cap.service`, a `oneshot` running `nvidia-smi -lgc min,max`, **installed disabled** |
| Firmware auto-update | `fwupd-refresh.timer` masked when `thermal_pin_fwupd`, never unmasked |
| EC firmware version | read with `fwupdmgr get-devices --json`, **asserted**, never remediated |
| Reporting | timer state and EC version printed at every converge, whatever the flags say |

Nothing here reboots, restarts a daemon anything depends on, or touches the driver except through
`nvidia-smi`. **Every task is safe to run while the box is training**, which is why the role
carries no training guard: the worst it does mid-run is change a clock ceiling.

## Variables

All of them live in this role's `defaults/main.yml` and carry the `thermal_` prefix, because
ansible-lint's production profile enforces `var-naming[no-role-prefix]` on anything a role
declares. Override in `host_vars/<host>.yml`.

| Variable | Default | What it decides |
|---|---|---|
| `thermal_gpu_clock_cap_enabled` | `false` | whether the cap applies at boot and now |
| `thermal_gpu_clock_cap_min_mhz` | `300` | floor handed to `nvidia-smi -lgc` |
| `thermal_gpu_clock_cap_max_mhz` | `2200` | ceiling handed to `nvidia-smi -lgc` |
| `thermal_gpu_clock_cap_unit` | `gpu-clock-cap.service` | unit name |
| `thermal_nvidia_smi_command` | `/usr/bin/nvidia-smi` | driver CLI, and the "is this a GPU box" guard |
| `thermal_pin_fwupd` | `false` | whether `fwupd-refresh.timer` gets masked |
| `thermal_fwupdmgr_command` | `/usr/bin/fwupdmgr` | fwupd CLI, and the "is fwupd here" guard |
| `thermal_fwupd_refresh_timer` | `fwupd-refresh.timer` | the timer to mask |
| `thermal_systemd_unit_dir` | `/etc/systemd/system` | where units, masks and enablement symlinks live |
| `thermal_ec_device_id` | `8c948e1d…09991` | fwupd device id of *this* box's EC; empty disables the read |
| `thermal_expected_ec_firmware` | `""` | the version the assertion demands; **empty means no assertion at all** |

**the original variable registry disagrees with this table, and this table is right.** The plan
put `gpu_clock_cap_enabled`, `gpu_clock_cap_min_mhz`, `gpu_clock_cap_max_mhz` and
`expected_ec_firmware` in `group_vars/all.yml`. Unprefixed names declared by a role fail the lint
rule the repo deliberately does not skip, and none of these are the kind of tunable the registry
exists for — the registry is version numbers and ports, the things an upgrade is a diff of. These
are safety decisions. They belong next to the tasks that act on them. The shipped
`group_vars/all.yml` never carried them, so nothing is being moved; the plan's registry was simply
never implemented that way.

## The measured situation, and why it governs everything below

From the audit of 2026-07-31, after 20 h of uptime **including training**:

```
SW Thermal Slowdown  :           0 us
HW Thermal Slowdown  :           0 us
SW Power Capping     : 23224548995 us   ← 23 224.5 s, 6.45 h, about a third of the window
```

Idle sits at 43 °C, 3.26 W, 208 MHz. `clocks.max.sm` is 3003 MHz. `GPU Shutdown / Slowdown
T.Limit` all read **N/A** and `Max Operating` reads **0 C**, so the driver on this hardware will
not tell you what temperature it considers dangerous.

Read that carefully, because it cuts against the advice you will find in forums. This box's EC
firmware version does match the one the community associates with a broken fan curve, and that is
worth taking seriously. But **the limiter this unit actually hit is the power cap, not
temperature**: zero microseconds of thermal slowdown against six and a half hours of power
capping. The much-quoted "74 °C with 17 °C of headroom" cannot even be checked here, because the
thermal limit registers read N/A. Reported unit-to-unit variance on Spark is 10–15 °C.

So the fan-curve story is **a claim to test on our hardware, not one to inherit**. That is why the
clock cap ships off and the firmware stays where it is. Instrument first — E1 — then decide.

## E1: measuring it, without inventing metric names

The `exporters` role already emits everything needed. Its README is the authority on the names, and
the two that matter are cumulative microsecond counters, rescaled by the exporter to seconds:

```
nvidia_smi_clocks_event_reasons_counters_sw_thermal_slowdown_seconds
nvidia_smi_clocks_event_reasons_counters_hw_thermal_slowdown_seconds
```

with `nvidia_smi_clocks_event_reasons_counters_sw_power_cap_seconds` as the context: on this box
that one is the series that actually moves.

**Alert on the counters rising, never on a temperature.** A temperature reading is a snapshot of
one instant; a slowdown counter that grew is proof that work was lost. And these series are
monotonic but are exported as **gauges**, not counters — `rate()` and `increase()` do not apply to
them. Ask the question with an offset:

```promql
# Thermal slowdown accumulated in the last hour. Anything above zero is the
# evidence E2 and E4 are waiting for.
(nvidia_smi_clocks_event_reasons_counters_sw_thermal_slowdown_seconds
   - nvidia_smi_clocks_event_reasons_counters_sw_thermal_slowdown_seconds offset 1h) > 0

(nvidia_smi_clocks_event_reasons_counters_hw_thermal_slowdown_seconds
   - nvidia_smi_clocks_event_reasons_counters_hw_thermal_slowdown_seconds offset 1h) > 0

# Context, deliberately NOT an alert: this box spent a third of its last audit
# window here, so a rule on it would fire constantly and teach people to
# ignore the ones that matter.
(nvidia_smi_clocks_event_reasons_counters_sw_power_cap_seconds
   - nvidia_smi_clocks_event_reasons_counters_sw_power_cap_seconds offset 1h)
```

**These are documented rather than shipped as provisioned Grafana rules, and that is a deliberate
gap.** Two reasons. The narrow one: this role's file list was fixed when it was commissioned, and
the alerting directory belongs to `monitoring`, which already creates
`{{ monitoring_dir }}/grafana/provisioning/alerting/` and says in a comment that Phase E's rules
land there. The real one: this repo provisions no contact point and no notification policy, so a
rule added today would fire into Grafana's UI and nowhere else — an alert nobody receives is a
dashboard panel with extra steps. Wire a contact point first, then drop a rule file into that
directory using the queries above verbatim.

One name is deliberately absent: there is **no temperature alert here** because the `exporters`
README documents the `clocks_event_reasons*` family in full and does not state the emitted name for
`temperature.gpu`. Guessing a metric name into an alert rule produces a rule that silently never
fires, which is worse than no rule. Read the name off the real exporter output before writing one —
and note that per the argument above, the counters are the better signal anyway.

## E2: the clock cap, and its honest cost

`gpu-clock-cap.service` is a `oneshot` with `RemainAfterExit=true`, so systemd models the cap as a
*state* rather than a command that ran once: `systemctl status gpu-clock-cap` answers "is the cap
on", and `systemctl stop gpu-clock-cap` runs `nvidia-smi -rgc` and releases it.

It is a unit rather than a one-off command for exactly one reason: **a clock lock does not survive
a reboot.** Persistence mode keeps it across process exits; nothing keeps it across a power cycle.
A guarantee that quietly evaporates the next time the box restarts is not a guarantee.

The trade-off, stated plainly:

| Workload | Cost of capping at 2200 MHz against a 3003 MHz ceiling |
|---|---|
| Bandwidth-bound | close to nothing — the measured 243 GB/s is the bottleneck, not the clock |
| Compute-bound training | **real but modest**; you are giving up roughly a quarter of the top of the frequency curve, and the top of that curve is its least efficient part |
| Unattended overnight runs | worth having regardless of the thermal verdict — it trades a little headroom for a guarantee that the box cannot chase the ceiling all night with nobody watching |

**It ships disabled anyway**, because on this unit the evidence for needing it is currently zero
microseconds. Turning it on permanently is `thermal_gpu_clock_cap_enabled: true` in
`host_vars/<host>.yml`. Turning it on for one night, which is the more useful mode and the reason
the unit is installed even when disabled:

```sh
sudo systemctl start gpu-clock-cap    # caps now, does not survive reboot
sudo systemctl stop  gpu-clock-cap    # nvidia-smi -rgc, releases it
```

Two behaviours that look inconsistent and are not:

- **Boot enablement follows the flag in both directions.** A toggle that cannot be toggled off is
  not a toggle, so setting the flag back to `false` does remove the unit from boot.
- **A running cap is never stopped by a converge.** Stopping runs `-rgc`. With the flag off by
  default, a converge that stopped the unit would silently release a cap an operator had started by
  hand for tonight's run. The role will not do that; `systemctl stop` is yours to run.

On a box with no `/usr/bin/nvidia-smi` the unit is not deployed at all, and the unit itself carries
`ConditionPathExists=` as a second guard, so it cannot leave a failed unit in a stranger's boot log.

**Unverified, and worth knowing before you flip the flag:** that `nvidia-smi -lgc` is actually
supported on GB10 has not been confirmed on this box — the audit that produced everything else in
this file was read-only, and setting clocks is a write. If the driver refuses, the unit fails
loudly at start, which is the correct failure. Check `systemctl status gpu-clock-cap` the first
time you enable it.

## E3: pinning fwupd, and what that does and does not buy

`fwupd-refresh.timer` is enabled on this box and fires hourly. `thermal_pin_fwupd` masks it.

### `thermal_pin_fwupd` defaults to `false`, and here is the argument

**First, a correction to the original plan.** It said the enabled refresh timer means "an automatic
update could silently undo a deliberate firmware rollback". That overstates the mechanism.
`fwupd-refresh.service` runs `fwupdmgr refresh`, which per its own manual page downloads *"the
latest online metadata from configured and enabled remotes"* and updates the message of the day. It
**does not install firmware**. What installs firmware is a human running `fwupdmgr update`, or a
desktop updater acting on the metadata this timer fetched — and that second path is not
hypothetical here, since this box has `gnome-remote-desktop` enabled and therefore a desktop
session that can be nagged into applying an offline firmware update at the next reboot.

So masking the timer is a real guard, but an **indirect** one: it starves the desktop path of
metadata. It is not what makes a rollback safe.

Given that, the default is `false` for three reasons:

1. **House precedent.** The `base` role finds `openvpn`, `samba-ad-dc`, `cups` and friends enabled,
   reports them, and refuses to disable them, on the grounds that switching off services on
   somebody else's box is not a provisioning run's call. A firmware metadata refresh is squarely in
   that category, and it is one of the few such services whose purpose is *security*.
2. **There is nothing to protect yet.** This box has not been rolled back. Its EC is the current
   version. Pinning matters from the moment a deliberate, non-current firmware state exists — which
   is step 1 of the E4 runbook, not step zero of every converge.
3. **The protection that does ship on by default is the one that works regardless of mechanism.**
   The assertion catches drift whether it came from the desktop updater, a colleague running
   `fwupdmgr update`, or a vendor tool nobody knew about. Masking one path cannot make that claim.

Flip it to `true` in `host_vars/<host>.yml` before you downgrade anything. On a box where a
rollback has happened, the calculus inverts completely and masking is obviously correct.

### What masking does, and how to undo it

The role masks rather than disables. A masked unit resolves to `/dev/null` and cannot be started by
its timer, by boot, by a package post-install script, or by a desktop updater; disabling only
removes the boot symlink, which the next `fwupd` package upgrade is free to put back.

There is **no unmask task**, on purpose: the role cannot tell its own mask from one the box's owner
applied for their own reasons, and quietly undoing a firmware guard is not something a converge
should do. The reversal is one command:

```sh
sudo systemctl unmask fwupd-refresh.timer && sudo systemctl start fwupd-refresh.timer
```

### The surgical alternative, if you want metadata *and* a pin

`fwupdmgr block-firmware <checksum>` *"blocks a specific firmware from being installed by install or
update"*, with `get-blocked-firmware` and `unblock-firmware` alongside it. That blocks exactly the
release you are hiding from while leaving metadata refresh alone — strictly better than masking,
and not automated here only because the checksum is per-release and has to be read off the box
first:

```sh
fwupdmgr get-releases 8c948e1db381648c8893897e4d09b7b153309991   # find the checksum
sudo fwupdmgr block-firmware <checksum>
```

### The assertion

The EC version is read with `fwupdmgr get-devices --json`, `changed_when: false`, and compared
against `thermal_expected_ec_firmware`. Drift is a **failed assertion** and nothing else — the role
will not put the old version back, and the failure message says so.

**It is off until you set your own version.** `thermal_expected_ec_firmware` defaults to `""` and
an empty value skips the assertion entirely, because asserting one box's firmware version on
somebody else's machine is meaningless: a different Spark on newer firmware is not drifting, it is a
different machine. Record yours in `host_vars` and the guard arms itself:

```sh
fwupdmgr get-devices --json | python3 -c "import json,sys; print([(d.get('DeviceId'),d.get('Version')) for d in json.load(sys.stdin)['Devices']])"
```

**Take the version from `--json`, not from the CLI table.** The assertion compares strings exactly,
and if fwupd ever renders that field differently in the two outputs, a value copied from the table
fails the converge with *"Something flashed this box"* on a box nobody touched. A false positive on
the one assertion whose entire job is to be believed is worse than no assertion.

Three behaviours, all verified against simulated `fwupdmgr` output rather than assumed:

| Situation | Result |
|---|---|
| Version matches | assert passes, `changed=0` |
| Version differs | **converge fails** with the device id, both versions, and a pointer to this runbook |
| No device with that id, or no `fwupdmgr`, or the daemon is unreachable | reported as `N/A`, assertion **skipped** |

That last row is what makes this recipe safe to run on someone else's Spark. fwupd device ids are
hashes derived from the device's own identity, so `thermal_ec_device_id` names the EC on *this*
box; on another machine the lookup finds nothing and says so. Run `fwupdmgr get-devices` there and
set your own id and expected version.

## E4: the firmware rollback runbook

**Manual. Documented, never automated.** If it ever appears in `tasks/main.yml`, that is a bug.

```sh
sudo fwupdmgr downgrade 8c948e1db381648c8893897e4d09b7b153309991    # choose 0x02004e18
sudo reboot
```

The target `0x02004e18` sits above fwupd's stated `Minimum Version: 0x02003400`, so the downgrade
is permitted rather than blocked.

**Preconditions, all four, no exceptions:**

1. **E1 evidence of real thermal throttling** — a thermal slowdown counter that actually rose. Not
   a forum post, not a temperature that looked high once.
2. **No training run active.** `nvidia-smi --query-compute-apps=pid --format=csv` comes back empty.
3. **The operator physically present.** This step can require someone to touch the machine.
4. **No `fwupdmgr update` afterwards** until NVIDIA ships a fixed EC.

**This is the only genuinely unrecoverable step in the project.** It earns evidence first and a
human trigger always.

Afterwards, two edits keep this role honest about the new deliberate state:

```yaml
# host_vars/<host>.yml
thermal_pin_fwupd: true                       # do this BEFORE the downgrade
thermal_expected_ec_firmware: "0x02004e18"    # after it, so drift is detected again
```

Hardware mitigations — USB fans, printed intake mounts — are a third layer with reported effects
ranging from 2 °C to 10 °C. Record them here when someone tries one. **Buy nothing until E1 says
the box is actually hot.**

## Verification

Offline, and the only verification that was possible while the box was off the network:

```
$ ansible-lint roles/thermal
Passed: 0 failure(s), 0 warning(s) in 5 files processed of 6 encountered.
Profile 'production' was required, and it passed.
```

The role was also run against `localhost`, where no `nvidia-smi` and no `fwupdmgr` exist: every
task skipped with an explanatory message and the play reported `changed=0`. That is the "harmless
on a box that is not a Spark at all" requirement, demonstrated rather than asserted.

On the box, once it is reachable:

```sh
ansible-playbook site.yml -K --tags thermal          # after the role is added to site.yml
systemctl cat gpu-clock-cap                          # unit installed
systemctl is-enabled gpu-clock-cap                   # disabled, by default
systemctl is-enabled fwupd-refresh.timer             # enabled, by default
fwupdmgr get-devices --json | grep -A2 8c948e1d      # version the assertion reads
```

Then run it twice and confirm the second run reports `changed=0`.

**This role is not yet in `site.yml`.** Adding it was outside the scope of the change that created
it — `site.yml` belongs to the scaffold, and several roles were being built in parallel against it.
It wants to land after `exporters`, since E1's evidence comes from that role's metrics:

```yaml
    - role: thermal
      tags: [thermal]
```
