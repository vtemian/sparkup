# `firmware`

Stages whatever firmware `fwupd` offers and stops. It never reboots, and the reboot that applies a
staged capsule is the only unrecoverable operation in this repo.

| Variable | Default | |
|---|---|---|
| `firmware_update_enabled` | `false` | the only gate; set per box in `host_vars` |
| `firmware_fwupdmgr` | `/usr/bin/fwupdmgr` | absolute; also the file the role stats |
| `firmware_capsule_dir` | `/boot/efi/EFI/UpdateCapsule` | searched for `*.cap` on every converge, opted in or not |

Before the reboot that applies a capsule: keep the machine powered throughout, and afterwards move
`thermal_expected_ec_firmware` to the new version or `thermal` will correctly report drift.

To cancel a staged capsule instead:

```sh
sudo rm /boot/efi/EFI/UpdateCapsule/*.cap
```
