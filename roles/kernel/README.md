# `kernel`

Installs the signed kernel, makes the GRUB menu visible through a drop-in, points GRUB at that
kernel, and pins unsigned images out of apt. It never reboots.

| Variable | Default | |
|---|---|---|
| `kernel_enabled` | `false` | `group_vars`; `site.yml` skips the role when false |
| `kernel_meta_package` | `linux-image-nvidia-hwe-24.04` | the concrete image is discovered from it; `""` on a non-DGX box |
| `kernel_grub_timeout` | `5` | seconds the menu stays up |
| `kernel_grub_recordfail_timeout` | `5` | menu timeout on the retry after a failed boot |
| `kernel_grub_dropin_dir` | `/etc/default/grub.d` | sourced after `/etc/default/grub` |
| `kernel_grub_dropin_name` | `zz-sparkup-menu.cfg` | `zz-` sorts last, so it wins |
| `kernel_grub_default_file` | `/etc/default/grub` | only `GRUB_DEFAULT=saved` is written here |
| `kernel_grub_config` | `/boot/grub/grub.cfg` | read, never written |
| `kernel_apt_preferences_file` | `/etc/apt/preferences.d/no-unsigned-kernels` | `Pin-Priority: -1` |

Both the tag and the flag are required — the tag alone silently no-ops:

```sh
ansible-playbook site.yml -K --tags kernel -e kernel_enabled=true
```

If the box will not boot: tap Esc at power-on and pick a previous signed kernel from the menu.
