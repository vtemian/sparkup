# `firmware`

Stages whatever `fwupd` offers and stops — it never reboots, and the reboot that applies a staged
capsule is the only unrecoverable operation in this repo.

Firmware is staged on every converge because the SPBM power channels report incorrect CPU values on
older EC firmware: a box behind on firmware reports bad numbers. **The next reboot after a converge
that staged something writes it, whoever performs that reboot and for whatever reason.** The role
says so loudly, on every run, for as long as a capsule sits in the capsule directory.

There is no pinned firmware version to assert against. Converging toward what the vendor currently
offers *is* how this repo keeps boxes alike, so a pin would fight it — and break the moment NVIDIA
ships an update. `fwupdmgr get-devices` tells you what a box is running.

| Variable | Default | |
|---|---|---|
| `firmware_fwupdmgr` | `/usr/bin/fwupdmgr` | absolute; also the file the role stats |
| `firmware_capsule_dir` | `/boot/efi/EFI/UpdateCapsule` | searched for `*.cap` on every converge, opted in or not |

Before the reboot that applies a capsule, keep the machine powered throughout.

To cancel a staged capsule instead:

```sh
sudo rm /boot/efi/EFI/UpdateCapsule/*.cap
```
