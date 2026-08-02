# `monitoring`

Prometheus and Grafana as code, in Docker, under `/opt/monitoring`.

Everything the box measures lands here: the host exporter (`node`), the GPU exporter (`gpu`) and —
once the plug is on the network — wall power (`power`). The exporters themselves are **not** this
role's job; they are host systemd units owned by the `exporters` role, for two reasons learned the
hard way on this box. A containerised node-exporter needs `/:/host:ro,rslave`, and that mount makes
the filesystem collector recurse every Docker overlay and hang. A containerised GPU exporter needs
GPU-in-container plumbing, which is the least reliable piece of the stack; monitoring must not
depend on the thing most likely to break.

## What it lays down

```
/opt/monitoring/                                  root-owned, 0755
├── compose.yml                                   prometheus + grafana
├── prometheus/prometheus.yml                     scrape config
└── grafana/
    ├── provisioning/datasources/datasource.yml   uid: prometheus
    ├── provisioning/dashboards/dashboards.yml    the file provider
    └── dashboards/spark-overview.json            provisioned boards
```

The stack used to live in `/home/vlad/monitoring`. It moved because a service stack does not belong
in a user's home directory, and because anything under `~` is reachable by the laptop's
`rsync --delete`, which owns `~/bbm` and does not read `.gitignore`. **The old directory is left in
place on purpose.** Delete it by hand once the new stack is confirmed serving, not before.

One ordering caveat comes with the move. `remove_orphans: true` deletes containers that are not in
this compose file, which on the first converge means the old containerised `node-exporter` — correct
only once the `exporters` role has installed the host unit that replaces it. Run the full playbook,
or `--tags exporters,monitoring`; running `--tags monitoring` alone on the un-migrated box takes the
host metrics away and gives nothing back.

## The trap: `host.docker.internal`

Prometheus runs in a container. Its targets — node_exporter on `:9100`, nvidia_gpu_exporter on
`:9835` — run on the host. Inside the container, `localhost` is the container, so a scrape config
naming `localhost:9100` finds nothing and every exporter target reads down, with no error more
specific than "connection refused".

The fix is two lines that must stay in sync:

```yaml
# compose.yml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

```yaml
# prometheus.yml
- job_name: node
  static_configs:
    - targets: ["host.docker.internal:9100"]
```

`host-gateway` is a Docker-provided magic value that resolves to the host's address on the bridge
network. Docker Desktop ships `host.docker.internal` for free; on Linux the name does not exist
unless `extra_hosts` creates it.

The Grafana datasource is the mirror image of this and is a common place to overcorrect: it points
at `http://prometheus:9090`, the compose service name on the shared network. Container to container
needs no host gateway. Only targets **on the host** do.

## Why there is a handler

`community.docker.docker_compose_v2` with `state: present` converges the compose file. A change to a
bind-mounted config file — `prometheus.yml`, `datasource.yml`, `dashboards.yml` — does not change
`compose.yml`, so compose sees the desired state already met and leaves the containers running with
the configuration they read at start. The change is on disk and has no effect.

So the config templates `notify: Restart monitoring stack`, and the handler uses `state: restarted`.
That state is deliberately non-idempotent: in a regular task it would report `changed` on every run
and fail the acceptance test, which is exactly why it belongs in a handler and nowhere else.

For Prometheus specifically the handler is `Reload Prometheus configuration`, a `POST` to
`/-/reload` — that is what `--web.enable-lifecycle` is for. A reload re-reads the scrape config
while keeping the TSDB head in memory and the series continuous; a restart drops both and puts a
gap in every graph for the sake of a config change.

Provisioned dashboards need neither. Grafana's file provider rescans its directory every
`updateIntervalSeconds` (10), so a dashboard file change lands on its own.

## Variables

From `group_vars/all.yml` (the registry — change them there, not here):

| variable | today | note |
|---|---|---|
| `monitoring_dir` | `/opt/monitoring` | root-owned, outside any rsynced tree |
| `prometheus_image` | `prom/prometheus:v3.5.0` | pinned; never `latest` |
| `grafana_image` | `grafana/grafana:12.1.0` | pinned; never `latest` |
| `prometheus_bind_address` | `127.0.0.1` | loopback only — unauthenticated, and it accepts remote writes |
| `prometheus_port` | `9090` | published port on the host; the container always listens on 9090 |
| `grafana_port` | `80` | so `http://spark.local` needs no suffix |
| `prometheus_retention` | `30d` | the durable archive is per-run summaries on disk, not the TSDB |
| `prometheus_scrape_interval` | `15s` | also fed to the datasource as `timeInterval` |
| `prometheus_enable_remote_write_receiver` | `true` | a contract with the training-observability project |
| `node_exporter_port` / `nvidia_gpu_exporter_port` | `9100` / `9835` | targets, via the host gateway |
| `shelly_enabled` | `false` | the `power` job is emitted only when this is true |
| `shelly_scrape_host` / `shelly_exporter_port` | `host.docker.internal` / `9924` | where Prometheus scrapes the exporter |
| `shelly_host` | `""` | the **plug's** address — the exporter's config, never a scrape target |
| `shelly_exporter_metrics_path` | `/prometheus` | Spring Boot actuator; `/metrics` returns 404 |

Role-local defaults live in `defaults/main.yml`: the compose project name, the container-side
dashboard path, and the four Grafana environment settings this box already had (anonymous access,
Viewer role, dark theme, `spark-overview` as the home page).

**The compose project name is load-bearing.** Named volumes are namespaced by project, not by
directory: `spark-monitoring_grafana-data` holds every dashboard built by hand in the UI, and
`spark-monitoring_prometheus-data` holds the history. Keeping the name the stack already used is
what makes the move from `/home/vlad/monitoring` a move rather than a fresh install, and it lets
compose adopt the running containers instead of colliding with them on port 80. Rename the project
and both volumes are silently abandoned, full and unreferenced.

## Dashboards

`files/dashboards/*.json` is the source of truth. They are installed with `ansible.builtin.copy`,
never `template`, because the JSON is full of Grafana's own `{{label}}` legend syntax and Jinja
would eat it.

The provider sets `allowUiUpdates: true`, so editing a provisioned board in the UI works — and the
file wins on the next converge. The round trip is therefore:

1. Edit in the UI until it says what you want.
2. Dashboard settings → JSON Model (or `Export → Export for sharing externally: off`).
3. Paste over `roles/monitoring/files/dashboards/<uid>.json`, keeping the `uid` stable.
4. `python3 -m json.tool` it, commit it, converge.

A dashboard edited only in the UI is not code, and the next run of this role will overwrite it.

`grafanalib` and Grafana's Foundation SDK were both considered and rejected at this scale: the
former has had no release since January 2024, the latter is still public preview. Hand-written JSON
is boring and reviewable for a handful of boards. Revisit at ten or more sharing panel logic.

### `spark-overview`

Stable `uid: spark-overview`, which is what `GF_USERS_HOME_PAGE=/d/spark-overview/spark-overview`
resolves. Four rows: GPU, Host, Disk, Exporter health.

**Every panel queries a metric these exporters actually emit.** The names were taken from the
running box's own Prometheus (`/api/v1/label/__name__/values` against node_exporter 1.12.1) and from
the nvidia_gpu_exporter `docs/METRICS.md` and its integration testdata, not from memory:

| panel | metrics |
|---|---|
| GPU utilisation | `nvidia_smi_utilization_gpu_ratio` (a ratio 0–1, not a percentage) |
| GPU temperature | `nvidia_smi_temperature_gpu` |
| GPU power draw | `nvidia_smi_power_draw_watts` |
| GPU clocks | `nvidia_smi_clocks_current_graphics_clock_hz`, `nvidia_smi_clocks_current_sm_clock_hz` |
| Unified memory | `node_memory_MemTotal_bytes`, `node_memory_MemAvailable_bytes` |
| CPU busy, load, uptime | `node_cpu_seconds_total`, `node_load{1,5,15}`, `node_boot_time_seconds` |
| Temperatures | `node_hwmon_temp_celsius` |
| Disk | `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` |
| Exporter health | `up`, `scrape_duration_seconds` |

**GB10 memory metrics from the GPU exporter are absent by design.** Spark has unified memory: CPU
and GPU share one 121 GiB pool, there is no discrete framebuffer, and `nvidia-smi` prints `[N/A]`
for `memory.used` and `memory.total`. The exporter drops unavailable fields rather than guessing, so
`nvidia_smi_memory_used_bytes` and `nvidia_smi_memory_total_bytes` **do not exist on this box**. That
is correct, not a gap to route around — `node_memory_*` *is* the GPU memory signal, and the panel
says so in its description so nobody spends an afternoon "fixing" it. DCGM is not the answer either:
NVIDIA states DCGM does not support Spark, and `nvmlDeviceGetMemoryInfo` returns
`NVML_ERROR_NOT_SUPPORTED` here.

Two more honest limitations recorded on the panels themselves:

- **GPU power is the GPU rail only.** 87 W by `nvidia-smi` against 180 W measured at the socket —
  roughly 2× under, and non-linearly so, because idle overhead dominates at low GPU load. Cost comes
  from the `power` job, never from this panel.
- **`/srv/bbm` has no filesystem of its own.** This box has one NVMe and no separate `/home`, so
  `node_filesystem_*{mountpoint="/srv/bbm"}` would match nothing at all. The shared-artifact panel
  reports the root filesystem, which is the pool `/srv/bbm` actually draws from, and says so.

### What this board needs from the `exporters` role

Panels are only as honest as the collectors behind them. `spark-overview` requires node_exporter to
run, at minimum:

| collector | metrics | panels |
|---|---|---|
| `cpu` | `node_cpu_seconds_total` | CPU busy, core count |
| `meminfo` | `node_memory_*` | unified memory |
| `loadavg` | `node_load{1,5,15}` | load average |
| `hwmon` | `node_hwmon_temp_celsius` | temperatures |
| `filesystem` | `node_filesystem_*` | all three disk panels |
| `stat` | `node_boot_time_seconds` | uptime |

The first four are already enabled on this box. **`filesystem` and `stat` are not.** The running
exporter uses `--collector.disable-defaults` with an explicit list — `cpu, hwmon, loadavg, meminfo,
netdev, os, textfile, thermal_zone, uname` — so both disk metrics and boot time are missing today.
Enabling `filesystem` is already in the plan; `stat` is the one easy to overlook, and without it the
uptime panel queries a metric nobody emits.

Throttle-reason metrics (`nvidia_smi_clocks_event_reasons_*`) are deliberately **not** on this board.
They arrive with the exporters role and belong on the thermal work in Phase E, where they are the
subject rather than a decoration — and where whether driver 580 exposes those query fields on GB10
gets answered by looking, rather than by adding a panel that might query nothing.

## Verifying

Idempotence is the acceptance test; the rest is worth checking once after the first converge.

```bash
# anonymous, no login, no port suffix
curl -s -o /dev/null -w '%{http_code}\n' http://spark.local/

# every target up, from Prometheus — never by curling an exporter.
# curl 127.0.0.1:9100 hangs on this box even when node-exporter is healthy.
ssh vlad@spark.local 'curl -s 127.0.0.1:9090/api/v1/query --get \
  --data-urlencode "query=up" | python3 -m json.tool'

# the remote-write receiver the training project depends on
ssh vlad@spark.local 'curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST 127.0.0.1:9090/api/v1/write'   # 400 means enabled, 404 means the flag is gone

# and the acceptance test
make apply && make apply    # the second run must report changed=0
```

## The `power` job

Settled when the `shelly` role landed. The target is the **Spark**, not the plug: the plug speaks
Shelly JSON-RPC and serves no metrics on any port, so a separate exporter process on the host polls
it and speaks Prometheus itself. That puts it behind the same host-gateway alias as `node` and
`gpu`.

- `shelly_scrape_host` — where Prometheus looks (`host.docker.internal`)
- `shelly_host` — the **plug's** address, which is the exporter's configuration and never a target
- `shelly_exporter_metrics_path` — `/prometheus`, because the exporter is a Spring Boot app whose
  actuator does not serve `/metrics`. At the default path the target reads down with a 404,
  which looks exactly like a dead exporter.

The whole block is emitted only when `shelly_enabled` is true, so an absent plug leaves no
permanently-red target.

**`up{job="power"} == 1` is not sufficient verification.** The exporter answers whether or not it
has ever reached the plug — it discovers devices on an interval and simply exposes nothing for one
that does not respond. A green target with no `shelly_meter_power_watthours_total` means the
exporter is healthy and the *plug* is unreachable. Check for the metric, not the target.
