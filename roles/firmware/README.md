# `firmware`

Stages firmware updates with `fwupd`, tracking whatever the vendor currently
offers, and then stops.

**This is the only role in this repository that can permanently destroy
hardware.** Everything else here is recoverable with a reboot, a rollback or a
reinstall. This is not. Read the recovery section before you enable it.

It never chooses when the flash happens. `fwupd` writes a capsule to the EFI
system partition and UEFI applies it during the next boot, so nothing reaches
the hardware while this role runs. The dangerous moment is the restart, and
choosing it belongs to whoever can watch the machine.

| | |
|---|---|
| Default state | **off**. `firmware_update_enabled: false`, nothing runs |
| What it stages | every device `fwupdmgr` reports an update for |
| Reboots | **never** |
| Idempotent | yes, from `fwupdmgr get-updates` exit code 2 |
| Recovery if interrupted | **none advertised on this hardware** |

## The rule this role broke

Until this role existed, the repo said flatly that it never flashes firmware.
That appeared in three places, and all three have been amended rather than
quietly left wrong:

- `INSTALL_CLAUDE.md` hard rule 1, previously *"Never flash firmware. No task,
  no flag, no confirmation prompt."*
- `CONTRIBUTING.md`, previously *"It never flashes firmware and never reboots."*
- `SECURITY.md`, previously *"Firmware is the one genuinely unrecoverable
  operation here, which is why nothing in this repo flashes it."*

The argument for changing them: **a converge cannot flash anything.** The role
is off unless a box opts in, and even then it only stages. The property worth
protecting was never "no firmware code exists in the repo", it was "a routine
`make apply` cannot write firmware", and that still holds.

The second argument is against pinning. An earlier version of this role
required you to name exact device ids and versions. That is worse, not better:
a pinned version goes stale while security and stability fixes queue behind it,
and the pin gives no protection that the no-reboot rule doesn't already give.

## What it does

Three `fwupdmgr` calls and a report:

1. `refresh` — downloads the vendor catalogue. Touches no firmware. Exit 2 means
   the cache is already fresh, exit 101 that LVFS was unreachable; neither is
   worth failing over, because the check below then reads a slightly stale cache
   rather than nothing.
2. `get-updates` — **the idempotency gate.** Exit 0 means something is on offer,
   exit 2 means every device is current. Nothing parses its output to decide
   anything.
3. `update --assume-yes --no-reboot-check --no-unreported-check` — stages the
   capsules, only when step 2 returned 0.

`--no-reboot-check` is the single most load-bearing token here. Without it
`fwupdmgr update` asks *"An update requires a reboot to complete. Restart
now?"* and acts on the answer. `fwupd` does suppress that on a non-tty, but a
run that acquired a pty is outside that behaviour, and the no-reboot promise
should be stated by this role rather than inherited from another program's tty
detection.

**Why the gate is `get-updates` and not `update`.** `update` exits **0** on a
converged box, so gating on its own result would report a change on every
converge and break the repo's acceptance test. Only `get-updates` distinguishes
"nothing to do" with exit 2. This is also why `fwupdmgr refresh && fwupdmgr
update` does not work as a shell one-liner: `refresh` exits 2 when the cache is
fresh, so `&&` short-circuits and the update never runs.

## Recovery, and where it runs out

**Before the reboot: fully reversible, but not through fwupd.** There is no
cancel, unstage or abort subcommand. `clear-results` clears a device's update
*history*, not a pending capsule. Staging writes files to the ESP and sets one
EFI variable:

```
/boot/efi/EFI/UpdateCapsule/fwupd-<guid>.cap
OsIndications = 0x04    (FILE_CAPSULE_DELIVERY_SUPPORTED)
```

That variable tells UEFI to look in `\EFI\UpdateCapsule\` at boot. Delete the
capsules and there is nothing to find:

```sh
sudo rm /boot/efi/EFI/UpdateCapsule/*.cap
```

**During the flash: nothing.** On this hardware `fwupdmgr get-devices` reports
**no `self-recovery` flag and no `dual-image` flag on any updatable device**.
There is no second firmware copy and no device that can restore itself. If the
write is interrupted — a power cut during the UEFI flash window, which is
exactly when the machine is least observable — the device is gone. Absence of
those flags is not proof the silicon lacks the capability, vendors set them
inconsistently, but nothing here should be relied on that is not advertised.

**After the reboot: usually, but not always.** `fwupdmgr downgrade` works down
to each device's `VersionLowest` floor. Check it per device before you assume:

```sh
fwupdmgr get-devices --json | \
  python3 -c 'import json,sys; [print(d.get("Name"), d.get("Version"), "floor", d.get("VersionLowest")) for d in json.load(sys.stdin)["Devices"]]'
```

On the audited box one device reported a current version **below** its own
floor, which means once updated it can never be returned to where it started.
For that device the update is a one-way door and the E4-style rollback in
`roles/thermal/README.md` does not generalise.

**To block one specific release**, do not reach for an Ansible-side exclusion
list. An earlier version of this role had one; it did not work, because
`fwupdmgr update` takes no device argument and stages everything pending
regardless. Use fwupd's own primitive, which is daemon-side and therefore binds
every path including a colleague running `fwupdmgr` by hand or a desktop
updater acting on the same metadata:

```sh
fwupdmgr get-releases <device-id>       # find the checksum
sudo fwupdmgr block-firmware <checksum>
```

## Before you reboot into a staged capsule

- [ ] No training run active
- [ ] Mains power that will not drop for the duration. Note this repo can also
      provision a smart plug, which is itself a thing that can cut power
- [ ] Someone able to reach the machine physically
- [ ] A snapshot of every current version taken first, so drift is diagnosable
      afterwards: `fwupdmgr get-devices --json > firmware-before.json`

## What this does to the `thermal` role

They are coupled, and the coupling is deliberate but sharp.

`thermal` asserts `thermal_expected_ec_firmware` and reports drift as a failed
assertion. It runs **before** `firmware` in `site.yml`. So on the first converge
after a firmware reboot, thermal's assertion fails and the play aborts at role
nine of ten — `firmware` and `kernel` never run — until a human edits
`host_vars`.

**That is correct and must not be automated away.** A guard that writes its own
expectation from its own output can never fire again. This role also cannot know
the new version, because it runs before the reboot that applies it; writing the
*offered* version would produce a false "something flashed this box" if the
capsule failed to apply, and a false positive on the one assertion whose job is
to be believed is worse than no assertion.

Two things that are **not** obvious:

- **`thermal_pin_fwupd` does not stop this role.** That flag masks
  `fwupd-refresh.timer`, starving the metadata path. This role calls
  `fwupdmgr refresh` directly, so the mask is defeated within the same play.
- **Following the E4 rollback runbook with `firmware_update_enabled: true` will
  re-flash your deliberate downgrade away** on the next converge. E4's
  precondition "no `fwupdmgr update` afterwards" is not enforced by anything.
  If you roll firmware back on purpose, turn this role off, and block the
  release you rolled away from.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `firmware_update_enabled` | `false` | The only gate. Set in `host_vars`, per box |
| `firmware_fwupdmgr` | `/usr/bin/fwupdmgr` | Absolute, so it does not depend on root's `PATH`; also the file the role stats to decide whether fwupd exists |

Role-owned variables carry the `firmware_` prefix; this role declares nothing in
the shared `spark_*` registry and reads nothing from it.

## Traps

- **`--tags firmware` runs this role.** Unlike `kernel`, there is no
  `site.yml`-level `when`, so the tag alone is enough to reach it on a box that
  has opted in.
- **There is deliberately no "refuse while training" guard.** The role stages
  and stops, so it disturbs nothing running, and an assert would abort a
  converge at role nine for a job it cannot affect. It would also fail open
  under `--tags firmware`, which skips the `pre_tasks` that compute
  `spark_training_active`.
- **`make check` is not perfectly read-only here.** `refresh` and `get-updates`
  carry `check_mode: false`, so a dry run downloads LVFS metadata to
  `/var/lib/fwupd`. It cannot stage anything: the staging task has no
  `check_mode: false` and is skipped. The consequence is that a dry run also
  shows no `changed` for staging, so `make check` will not warn you that a real
  converge would flash. The capsule check below is what covers that gap.
- **fwupd forgets what it staged.** Once a capsule is written, `get-updates`
  stops offering the update, so this role cannot tell "current" from "armed and
  waiting for a reboot" — and on a shared box the second reads as the first to
  whoever converges next. That is why the role checks
  `/boot/efi/EFI/UpdateCapsule/*.cap` on **every** converge, opted in or not,
  and says loudly when a flash is pending. It also catches a partial failure,
  where some capsules were written before the run aborted.
- **`--assume-yes` suppresses fwupd's full-disk-encryption warning.** For any
  device carrying `affects-fde`, fwupd would normally warn that platform secrets
  may be invalidated and tell you to have your recovery key. That prompt is
  skipped. No device on the audited box carries the flag, but the opt-out is
  permanent and applies to any future one.
- **A failed metadata refresh is invisible.** `refresh` runs with
  `failed_when: false`, so no network, no LVFS remote, or a signature failure
  leaves `get-updates` reading a stale cache and the role reporting a converged
  box. It cannot distinguish "current" from "I could not find out".
- **A device fwupd declines to update still counts as changed.** `fwupdmgr
  update` exits 0 whenever any supported device existed, even if it skipped
  every one of them for an inhibit like unmet `require-ac`. The staging task
  reports `changed` on that exit, so a permanently inhibited device would report
  a change on every converge. The capsule check is the ground truth: if nothing
  new appears in the capsule directory, nothing was staged.

## Verifying

```sh
ansible-lint roles/firmware
fwupdmgr get-devices --json > firmware-before.json    # snapshot, before anything

ansible-playbook site.yml -K --tags firmware          # stages, or reports nothing to do
ansible-playbook site.yml -K --tags firmware          # must report changed=0
```

A converged box prints nothing from this role and reports `changed=0`. A box
with something on offer prints fwupd's own device tree followed by the
STAGED, NOT APPLIED warning, and reports `changed=1`. Staging twice without a
reboot in between still reports `changed=0` on the second run, because fwupd
stops offering an update it has already staged.
