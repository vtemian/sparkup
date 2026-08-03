# `exporters`

Installs `node_exporter` and `nvidia_gpu_exporter` as supervised host systemd
units, and retires the cron + `flock` + bash loop that used to produce GPU
telemetry.

| | |
|---|---|
| `node_exporter` | `node_exporter_version` = 1.12.1, `node_exporter_port` = 9100, user `node_exporter` |
| `nvidia_gpu_exporter` | `nvidia_gpu_exporter_version` = 1.13.1, `nvidia_gpu_exporter_port` = 9835, user `nvidia_gpu_exporter` |
| Binaries | `/usr/local/bin/`, from checksum-verified GitHub release archives |
| Units | `/etc/systemd/system/{node_exporter,nvidia_gpu_exporter}.service`, `Restart=always` |
| Textfile collector | `/var/lib/node_exporter/textfile` |

Versions and ports come from `group_vars/all.yml`. Everything else is in
`defaults/main.yml`.

Both versions were checked to publish a **linux-arm64** asset before being
used — several exporters are amd64-only:

```
node_exporter-1.12.1.linux-arm64.tar.gz        + sha256sums.txt
nvidia_gpu_exporter_1.13.1_linux_arm64.tar.gz  + checksums.txt
```

`nvidia_gpu_exporter` **1.3.2 does not exist** — the version the original plan's
variable registry names was never released. 1.13.1 is the current release and
the one `group_vars/all.yml` carries.

## Why host units and not containers

Both reasons were learned the hard way on this box, and neither is a
preference.

**A containerised node-exporter needs `/:/host:ro,rslave`.** That mount makes
the filesystem collector recurse every Docker overlay and **hang**, which
flaps `up` to 0 — telemetry that reports its own absence as an outage. The
running workaround was to drop the mount *and* disable the filesystem
collector entirely, which is why this box has no disk metrics today. A native
install removes the mount, removes the hang, and gives the disk metrics back.

**A containerised GPU exporter needs GPU-in-container plumbing** — the NVIDIA
runtime, a CDI spec, device injection. That is the least reliable piece of the
whole stack (on this box it is not even registered yet). Monitoring must not
depend on the thing most likely to break: when the GPU plumbing fails, the
exporter is exactly what you need to still be running.

## `node_exporter`

Collectors: today's set (`cpu`, `meminfo`, `loadavg`, `hwmon`, `thermal_zone`,
`netdev`, `uname`, `os`, `textfile`) **plus `filesystem`**, under
`--collector.disable-defaults`.

The filesystem collector is the whole point of this role's node half, and it
only stays up because of two excludes:

```
--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/snapd/.+)($|/)
--collector.filesystem.fs-types-exclude=^(autofs|overlay|squashfs|tmpfs|devtmpfs|nsfs|cgroup.*)$
```

Without them the collector walks the 13 snap loop devices and every Docker
overlay mount, and hangs. Changing these is changing the thing that keeps the
exporter alive.

**`$` is written `$$` in the rendered unit file.** systemd expands `$` in
`ExecStart`, and `$$` is its documented escape for a literal dollar. The
template applies the substitution, so the values in `defaults/main.yml` stay
readable as plain regexes. Read the rendered unit, not the defaults, if you
are debugging what the collector actually received.

**Textfile files must be world-readable.** node_exporter drops to the
unprivileged `node_exporter` user, so a `.prom` file written `0600` in
`/var/lib/node_exporter/textfile` is skipped without an error you will notice.
Write them `0644`, and write them atomically (`mktemp` in the same directory,
then `mv`) so a scrape never sees a half-written file.

The exporter binds `:9100` on all interfaces, not `127.0.0.1`: Prometheus runs
in a container and reaches the host over the Docker bridge gateway, so a
loopback-only bind would make it unscrapeable. Keeping 9100 off the LAN is
`ufw`'s job, in the `base` role.

## `nvidia_gpu_exporter`

`utkuozdemir/nvidia_gpu_exporter` wraps `nvidia-smi --query-gpu`. That is
deliberate, not a fallback: **NVIDIA states DCGM does not support this
hardware**, and on GB10 `nvmlDeviceGetMemoryInfo` returns
`NVML_ERROR_NOT_SUPPORTED`, so the `DCGM_FI_DEV_FB_*` family is broken and
utilization reports mirrored. `nvidia-smi` exports exactly what works.

The unit passes an explicit `--query-field-names` list rather than the
exporter's `AUTO`, so the throttle-reason fields are guaranteed instead of
dependent on what auto-discovery happens to parse out of
`nvidia-smi --help-query-gpu`.

### Throttle reasons are required, not optional

They are what turns the thermal question from forum lore into our own data, so
they are queried explicitly. Confirmed against `nvidia-smi --help-query-gpu`
on the box (driver 580.173.02):

- The current spelling is **`clocks_event_reasons.*`**. `clocks_throttle_reasons.*`
  is the deprecated alias; the help output lists both on the same line
  (`"clocks_event_reasons.active" or "clocks_throttle_reasons.active"`) and
  both still resolve. The `event` spelling is used here because it is the one
  the driver leads with and the one that will outlive the alias.
- There is a second family, **`clocks_event_reasons_counters.*`**, with no
  `throttle` alias at all. These are the cumulative microsecond counters — the
  honest signal, because a temperature reading is a snapshot while a rising
  slowdown counter is proof of lost work.

Emitted metric names, all gauges labelled by `uuid`:

| Metric | From | Values |
|---|---|---|
| `nvidia_smi_clocks_event_reasons_active` | `clocks_event_reasons.active` | bitmask, hex parsed to decimal |
| `nvidia_smi_clocks_event_reasons_supported` | `.supported` | bitmask |
| `nvidia_smi_clocks_event_reasons_sw_power_cap` | `.sw_power_cap` | `Active` → 1, `Not Active` → 0 |
| `nvidia_smi_clocks_event_reasons_hw_thermal_slowdown` | `.hw_thermal_slowdown` | 1 / 0 |
| `nvidia_smi_clocks_event_reasons_sw_thermal_slowdown` | `.sw_thermal_slowdown` | 1 / 0 |
| `nvidia_smi_clocks_event_reasons_hw_slowdown` | `.hw_slowdown` | 1 / 0 |
| `nvidia_smi_clocks_event_reasons_hw_power_brake_slowdown` | `.hw_power_brake_slowdown` | 1 / 0 |
| `nvidia_smi_clocks_event_reasons_gpu_idle` | `.gpu_idle` | 1 / 0 |
| `nvidia_smi_clocks_event_reasons_applications_clocks_setting` | `.applications_clocks_setting` | 1 / 0 |
| `nvidia_smi_clocks_event_reasons_sync_boost` | `.sync_boost` | 1 / 0 |
| `nvidia_smi_clocks_event_reasons_counters_sw_power_cap_seconds` | `_counters.sw_power_cap` | µs, rescaled to **seconds** |
| `nvidia_smi_clocks_event_reasons_counters_sw_thermal_slowdown_seconds` | `_counters.sw_thermal_slowdown` | seconds |
| `nvidia_smi_clocks_event_reasons_counters_hw_thermal_slowdown_seconds` | `_counters.hw_thermal_slowdown` | seconds |
| `nvidia_smi_clocks_event_reasons_counters_hw_power_brake_slowdown_seconds` | `_counters.hw_power_brake_slowdown` | seconds |
| `nvidia_smi_clocks_event_reasons_counters_sync_boost_seconds` | `_counters.sync_boost` | seconds |

The exporter rescales any `[us]` field by 1e-6 and appends `_seconds`, so the
23224.5 s of power capping this box had accumulated at audit time reads as
seconds, not microseconds.

The `_counters_*` series are monotonic but are exported as **gauges**, not
counters, so `rate()` and `increase()` do not apply. Use
`x - x offset 1h` (or Grafana's `delta`) to ask "how much slowdown did we
accumulate in the last hour". Alert on the counter *rising*, not on its value.

### GPU memory metrics will be absent or NaN. That is correct.

GB10 has **unified memory**. There is no discrete framebuffer, so
`nvidia-smi --query-gpu=memory.total,memory.used,memory.free` prints `[N/A]`
on this box — verified, not predicted — and `nvidia_smi_memory_used_bytes` and
friends will be missing or NaN.

**`node_memory_*` is the GPU memory signal here.** The 121 GiB the node
exporter reports is the same physical memory the GPU allocates from. Do not
spend an afternoon "fixing" a blank GPU-memory panel; label the host memory
panel as unified GPU+CPU memory and move on.

`power.limit` and `enforced.power.limit` also read `[N/A]` on this box, for
the same class of reason. `power.draw` works, and reports the **GPU rail
only** — roughly half the wall figure. Cost comes from the smart plug, not
from here.

## Verifying it worked — never with `curl`

**`curl 127.0.0.1:9100` hangs on this box even when node-exporter is
healthy.** A hanging curl is not evidence of a broken exporter, and people
have chased it as one. Verify through Prometheus instead, which is the
`monitoring` role's job:

```promql
up{job="node"} == 1
up{job="gpu"} == 1
scrape_samples_scraped > 0
node_filesystem_avail_bytes{mountpoint="/"}
nvidia_smi_clocks_event_reasons_counters_sw_power_cap_seconds
```

Then reboot once and confirm both units come back — `Restart=always` covers
crashes, `WantedBy=multi-user.target` covers boot, and only a reboot proves
the second one.

Locally, `systemctl status node_exporter nvidia_gpu_exporter` and
`journalctl -u nvidia_gpu_exporter` are safe and do not hang.

## Retiring the old GPU telemetry

Guarded behind `exporters_retire_legacy_gpu_script`, **default `false`**:
only the box that grew this by hand has anything to retire.

What it removes, when true:

- both of vlad's crontab lines that launched it under `flock -n` — the
  every-minute one and the `@reboot` one — first, so nothing relaunches it
- the running copy of the loop (`pkill`), because deleting the file leaves the
  process writing stale metrics until the next reboot
- `~/monitoring/gpu-metrics.sh` itself — a `while true` bash loop calling
  `nvidia-smi` every 5 s into `~/monitoring/textfile/gpu.prom`

It worked. It was not supervision: cron + `flock` + bash has no restart
policy, no status, no logs, and no way to ask whether it is running.

**This changes metric names.** The old script emitted
`nvidia_gpu_utilization_percent`, `nvidia_gpu_temperature_celsius`,
`nvidia_gpu_power_watts`, `nvidia_gpu_clock_sm_mhz`, `nvidia_gpu_up`. The
exporter emits the `nvidia_smi_*` family above. Dashboards must move in the
same change or the board goes blank.

Two things this role deliberately does **not** clean up, because they belong
to the `monitoring` role's move to `/opt/monitoring`: the stale
`~/monitoring/textfile/gpu.prom`, and the containerised `node-exporter` that
mounts it. Until that lands, the old container will keep serving a frozen
`gpu.prom` — which is worse than no metric, so do not leave the two roles half
applied.

### Why not `ansible.builtin.cron`

Because it does not work here, and it fails **silently**, which is worse than
failing. With `state: absent` the module calls `find_job(name)` and ignores
the `job` parameter entirely, so it can only match a line carrying an
`#Ansible: <name>` header — a line it wrote itself. These two were written by
hand and have no header. The task would report `ok` and change nothing.

Verified against the installed `ansible/modules/cron.py` (identical in
ansible-core 2.18.5 and 2.21.2): `find_job("gpu-metrics")` returns `[]`
against the real crontab contents. And even on the code path that *does*
accept a job string, the reconstruction cannot match the `@reboot` line — the
module joins `@reboot` to the job with one space, while the crontab pads it
out to the width of a five-field schedule.

So the role rewrites the crontab through `crontab(1)`, the supported
interface: read it, drop every line naming the script, write the rest back.
That is indifferent to spacing, removes both lines in one pass, preserves any
other job in there, and is idempotent — the second run finds no match and
skips.

## Idempotency

A second run reports `changed=0`. The archive handling is where this normally
breaks, so:

- `get_url` verifies `sha256:<url of the release's checksum file>` and skips
  the download when the staged file already matches
- `unarchive` is guarded by `creates:` pointing at the unpacked binary under a
  **version-specific** path, so a version bump unpacks fresh instead of
  trusting whatever is already there
- `copy … remote_src: true` installs the binary and compares checksums, so it
  notifies the restart handler only when the binary actually changed

The `nvidia_gpu_exporter` archive is flat — no version prefix inside it — so
the role makes a versioned directory for it to unpack into. The node_exporter
archive already has one.
