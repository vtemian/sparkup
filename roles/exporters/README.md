# `exporters`

`node_exporter` and `nvidia_gpu_exporter` as supervised host systemd units.

| Variable | Default | |
|---|---|---|
| `node_exporter_version` | `1.12.1` | `group_vars`; the arm64 release archive |
| `node_exporter_port` | `9100` | bound on all interfaces |
| `nvidia_gpu_exporter_version` | `1.13.1` | `group_vars` |
| `nvidia_gpu_exporter_port` | `9835` | |
| `exporters_bin_dir` | `/usr/local/bin` | where both binaries are installed |
| `exporters_textfile_dir` | `/var/lib/node_exporter/textfile` | `2775`, group `spark_shared_group` |
| `exporters_node_collectors` | `cpu`, `meminfo`, `loadavg`, `hwmon`, `thermal_zone`, `netdev`, `uname`, `os`, `textfile`, `filesystem`, `stat` | under `--collector.disable-defaults` |
| `exporters_node_filesystem_mount_points_exclude` | see defaults | stops the collector hanging on snap loops and Docker overlays |
| `exporters_node_filesystem_fs_types_exclude` | see defaults | same |
| `exporters_gpu_query_fields` | 31 `nvidia-smi` fields | explicit list, not the exporter's `AUTO` |
| `exporters_node_user` | `node_exporter` | unprivileged; why textfile `.prom` files must be world-readable |
| `exporters_gpu_user` | `nvidia_gpu_exporter` | unprivileged |
| `exporters_nvidia_smi_command` | `/usr/bin/nvidia-smi` | |

The download URLs, archive names and unpack directories are derived from the two versions above and
need no attention when you bump one. `get_url` is given the release's **checksum file**, not a
pinned hash, so there is no digest to update either.

```sh
systemctl status node_exporter nvidia_gpu_exporter
```
