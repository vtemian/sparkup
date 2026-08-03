# `thermal`

Installs the GPU clock-cap unit, optionally masks the fwupd metadata timer, and asserts the EC
firmware version. It never flashes anything.

| Variable | Default | |
|---|---|---|
| `thermal_gpu_clock_cap_enabled` | `false` | whether the cap applies at boot and now |
| `thermal_gpu_clock_cap_min_mhz` | `300` | floor handed to `nvidia-smi -lgc` |
| `thermal_gpu_clock_cap_max_mhz` | `2200` | ceiling handed to `nvidia-smi -lgc` |
| `thermal_gpu_clock_cap_unit` | `gpu-clock-cap.service` | unit name |
| `thermal_nvidia_smi_command` | `/usr/bin/nvidia-smi` | also the "is this a GPU box" guard |
| `thermal_pin_fwupd` | `false` | masks the refresh timer; never unmasks |
| `thermal_fwupdmgr_command` | `/usr/bin/fwupdmgr` | also the "is fwupd here" guard |
| `thermal_fwupd_refresh_timer` | `fwupd-refresh.timer` | the timer to mask |
| `thermal_systemd_unit_dir` | `/etc/systemd/system` | units, masks and enablement symlinks |
| `thermal_ec_device_id` | `""` | your box's; empty disables the read |
| `thermal_expected_ec_firmware` | `""` | empty asserts nothing |

Both EC values come from the JSON, not the CLI table — the assert compares strings exactly:

```sh
fwupdmgr get-devices --json
```

To cap clocks for one night without a converge:

```sh
sudo systemctl start gpu-clock-cap
```
