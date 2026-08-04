# `firmware`

Stages whatever `fwupd` offers and stops — it never reboots, and the reboot that applies a staged
capsule is the only unrecoverable operation in this repo. It also reads the embedded controller
version and asserts it has not moved.

Firmware is staged on every converge because the SPBM power channels report incorrect CPU values on
older EC firmware: a box behind on firmware reports bad numbers. **The next reboot after a converge
that staged something writes it, whoever performs that reboot and for whatever reason.** The role
says so loudly, on every run, for as long as a capsule sits in the capsule directory.

| Variable | Default | |
|---|---|---|
| `firmware_fwupdmgr` | `/usr/bin/fwupdmgr` | absolute; also the file the role stats |
| `firmware_capsule_dir` | `/boot/efi/EFI/UpdateCapsule` | searched for `*.cap` on every converge, opted in or not |
| `firmware_ec_device_id` | `""` | your box's EC; empty disables the read |
| `firmware_expected_ec_firmware` | `""` | empty asserts nothing |

Both EC values come from the JSON, not the CLI table — the assert compares strings exactly:

```sh
fwupdmgr get-devices --json
```

Before the reboot that applies a capsule: keep the machine powered throughout, and afterwards move
`firmware_expected_ec_firmware` to the new version or the drift assert will correctly fire.

To cancel a staged capsule instead:

```sh
sudo rm /boot/efi/EFI/UpdateCapsule/*.cap
```
