# `firmware`

Two halves. Staging offers whatever `fwupd` has and stops — it never reboots, and the reboot that
applies a staged capsule is the only unrecoverable operation in this repo. Drift detection reads the
embedded controller version and asserts it has not moved; that half runs whether or not staging is
enabled, because a box that opted out of being flashed is exactly where an unexplained version
change matters.

| Variable | Default | |
|---|---|---|
| `firmware_update_enabled` | `false` | gates staging only, never the drift assert |
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
