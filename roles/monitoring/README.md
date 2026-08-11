# `monitoring`

Prometheus and Grafana as a compose stack under `{{ monitoring_dir }}`, with a provisioned
datasource and dashboard.

| Variable | Default | |
|---|---|---|
| `monitoring_dir` | `/opt/monitoring` | `group_vars`; holds compose and every config file |
| `monitoring_project_name` | `spark-monitoring` | namespaces the `grafana-data` and `prometheus-data` volumes |
| `monitoring_dashboards_container_dir` | `/etc/grafana/dashboards` | the provider's search root inside Grafana; the mounts sit under it |
| `monitoring_grafana_home_dashboard` | `/d/box-overview/box-overview` | also what `make dashboard` checks the uid against |
| `monitoring_rules_file` | `spark.yml` | the alerting rules in `files/rules/`, staged and validated before install |
| `monitoring_grafana_anonymous_role` | `Viewer` | what an unauthenticated visitor may do. See [SECURITY.md](../../SECURITY.md) |
| `monitoring_grafana_theme` | `dark` | |
| `monitoring_grafana_plugin` | `volkovlabs-echarts-panel` | the one panel type Grafana does not ship that the dashboard needs |
| `monitoring_grafana_plugin_version` | `7.2.5` | needs Grafana 12.3 or newer |
| `monitoring_grafana_plugin_checksum` | a `sha256:` literal | bump it with the version or the converge fails |
| `monitoring_grafana_plugin_url` | grafana.com download API | |
| `prometheus_image` | `prom/prometheus:v3.13.2` | never pin below the running version |
| `grafana_image` | `grafana/grafana:13.1.1` | never pin below the running version |
| `prometheus_bind_address` | `127.0.0.1` | published address on the host |
| `prometheus_docker_bind_address` | the host's `docker0` address | second publish, so job containers can remote-write in |
| `prometheus_port` | `9090` | the container always listens on 9090 |
| `grafana_port` | `80` | so `http://spark.local` needs no suffix |
| `prometheus_retention` | `1y` | roughly 10 GB at 1527 active series |
| `prometheus_scrape_interval` | `15s` | also the datasource's `timeInterval` |
| `spark_shared_dir` | `/srv/spark` | `group_vars`; its `dashboards/` is mounted into Grafana |

Two dashboards are provisioned from `files/dashboards/`: `box-overview`, which every visitor lands
on, and `box-alerts`, which shows what is firing and when it fired before. Every JSON in that
directory is installed, so adding a third needs no change here, and `make dashboard` validates all of
them.

Dashboards edited in the Grafana UI are kept in the `grafana-data` volume; the provisioned file in
this repo wins on the next converge.

**`monitoring_project_name` is load-bearing.** Compose namespaces named volumes by project, not by
directory: `spark-monitoring_grafana-data` holds every dashboard built by hand in the UI and
`spark-monitoring_prometheus-data` holds the history. Rename the project and both are silently
abandoned, full and unreferenced, and the new stack collides with the running one on port 80.

## Alerting rules

`files/rules/spark.yml` covers the hardware failures nothing else reports: the module power cap
collapsing to the EC's USB-PD safety mode, a GPU stuck near 500 MHz under load, spbm going silent
after a kernel upgrade, an exporter down, and root filling. They are staged, validated with the pinned
image's `promtool`, and only then installed, so a rule Prometheus would reject never reaches the box
and the running Prometheus is left alone.

**Evaluated, not routed.** There is no Alertmanager here, so nothing pages. Firing means a series
exists saying so, at `/alerts` or via `ALERTS{alertname="..."}`. `make alerts` proves they stay quiet
on a healthy synthetic box and fire when it serves the safety mode.

The `sparks` role installs its own rules file into the same directory; the two do not collide.

Two rules are written the way they are on purpose:

- **`SparkPowerCapCollapsed` cannot fire on a box without spbm, and that is deliberate.** `< 100` on
  a metric that does not exist yields no series. `SparkGpuClockStuckLow` is the one that covers a
  default box, because it needs only nvidia-smi.
- **`SparkFirmwarePowerSilent` says "it existed recently and does not now".** `absent()` would fire
  forever on the majority of boxes, where spbm was never enabled. The consequence is that it resolves
  by itself six hours after the metric stops: it catches the transition, not the state.

**Where firing alerts are visible, none of which notifies anybody.** `/d/box-alerts` is the
provisioned board: what is firing, and a timeline of when it fired, which is the one thing Grafana's
own page cannot show. Grafana's `/alerting/list` lists every loaded rule with its expression, under a
`Prometheus` heading, and works for an anonymous viewer; the `Grafana-managed` section above it is
empty and always will be. Prometheus at `/alerts` is the third, over an SSH tunnel because it binds
to loopback.

## The panel plugin

The dashboard's power flow diagram is a sankey, and Grafana has no built-in sankey. The role
downloads and checksums the plugin itself, then bind-mounts that one directory into Grafana's plugin
path. `GF_INSTALL_PLUGINS` is not used: it makes Grafana fetch from grafana.com at every container
start, so a box whose WiFi is down comes up with a broken panel and no error anyone sees.

Bumping the version means bumping `monitoring_grafana_plugin_checksum` in the same edit. The variable
carries the `sha256:` prefix; the command below does not print it:

```bash
v=7.3.0    # the version you are moving to
curl -sL "https://grafana.com/api/plugins/volkovlabs-echarts-panel/versions/$v/download" \
  | shasum -a 256 | awk '{print "sha256:" $1}'
```

The unpack is guarded on a stamp file carrying the version, so a bump re-extracts. Guarding on the
plugin directory alone would fetch the new archive, skip the unpack and leave the old version running.

## Editing the dashboards

The JSON cannot carry comments, so the constraints on it live here.

**Stay on schema v1 (`schemaVersion: 39`).** Grafana 13's dynamic dashboards, and with them tabs,
auto-grid and conditional rendering, need schema v2, which is still `v2beta1` and which **file-based
provisioning does not load** (grafana/grafana#106381; the only workaround is a Kubernetes
`GrafanaManifest`). Do not port the JSON to v2 to get tabs. It would also break
`tests/check_dashboard.py`, which walks `panels[]` and `targets[]`.

**Canvas placement is pixels, and the constraint decides what those pixels mean.** With the default
`left`/`top` the drawing sits at its authored size in a corner of a wide panel. With
`leftright`/`topbottom` every element stretches to the panel edges, which turns concentric boxes into
overlapping full-height columns. `scale` is the one that works, and under it Grafana reads
`left`/`right`/`top`/`bottom` as **percentages** and discards `width` and `height` entirely, so a
placement that still carries a width renders somewhere else. The canvas is authored against a 748x330
frame and converted to percentages.

**Concentric canvas elements cannot all centre their value.** `dc_input`, `sys_total` and `soc_pkg`
are drawn inside one another, so a centred value in each stacks all three in the middle of the panel
and then hides them behind the rails. The containers put their value in the top-right corner.

**Every panel on `box-alerts` needs an `or` fallback.** `ALERTS` does not exist at all while nothing
is pending or firing, so a bare query is empty on precisely the boxes worth having, and
`make dashboard-live` would fail on a healthy harness. `label_replace(vector(0), "alertname",
"nothing firing", "", "")` synthesises one named series, so the panels read "nothing firing" instead
of "No data" and stay subject to the same check as everything else.

**Neither dashboard check can tell you the Power row is dead.** `make dashboard` allows `node_hwmon_`
by prefix because the `hwmon` collector is enabled regardless (NVMe and SoC temperatures come through
it), and `make dashboard-live` passes because `tests/fake_exporters.py` synthesises the spbm power,
energy and label series. Both are correct: they check the panels against a box where `spbm_enabled`
is true. Do not "fix" the harness by removing those synthetic channels; that would only stop the row
being checked at all.

**The nav sidebar's "Starred" section never loads, and that is anonymous access, not a bug.** Grafana
asks `/api/user/stars` on every page load and gets 401, because `GF_AUTH_ANONYMOUS_ENABLED` means
there is no user record to hold stars. The skeleton placeholders sit there forever. There is no
setting that hides the section, so the only fix is requiring a login, which is the opposite of the
decision in [SECURITY.md](../../SECURITY.md). Kiosk mode hides the whole sidebar if it bothers you:
`?kiosk` on the dashboard URL.

## Installing a dashboard from another project

`{{ spark_shared_dir }}/dashboards` is bind-mounted read-only at
`{{ monitoring_dashboards_container_dir }}/sparks`. Anyone in `spark_shared_group` can drop a
dashboard JSON there without root, the `spark` provider picks it up within its 10 s interval, and a
converge does not remove it. Other projects depend on that path: keep it where it is.

```bash
cp my-dashboard.json /srv/spark/dashboards/
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://spark.local/
```
