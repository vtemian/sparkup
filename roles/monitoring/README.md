# `monitoring`

Prometheus and Grafana as a compose stack under `{{ monitoring_dir }}`, with a provisioned
datasource and dashboard.

| Variable | Default | |
|---|---|---|
| `monitoring_dir` | `/opt/monitoring` | `group_vars`; holds compose and every config file |
| `monitoring_project_name` | `spark-monitoring` | namespaces the `grafana-data` and `prometheus-data` volumes |
| `monitoring_dashboards_container_dir` | `/etc/grafana/dashboards` | the provider's search root inside Grafana; the mounts sit under it |
| `monitoring_grafana_home_dashboard` | `/d/spark-overview/spark-overview` | also what `make dashboard` checks the uid against |
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

Two dashboards are provisioned from `files/dashboards/`: `spark-overview`, which every visitor lands
on, and `spark-alerts`, which shows what is firing and when it fired before. Every JSON in that
directory is installed, so adding a third needs no change here, and `make dashboard` validates all of
them.

Dashboards edited in the Grafana UI are kept in the `grafana-data` volume; the provisioned file in
this repo wins on the next converge.

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
