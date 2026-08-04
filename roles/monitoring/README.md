# `monitoring`

Prometheus and Grafana as a compose stack under `{{ monitoring_dir }}`, with a provisioned
datasource and dashboard.

| Variable | Default | |
|---|---|---|
| `monitoring_dir` | `/opt/monitoring` | `group_vars`; holds compose and every config file |
| `monitoring_project_name` | `spark-monitoring` | namespaces the `grafana-data` and `prometheus-data` volumes |
| `monitoring_dashboards_container_dir` | `/etc/grafana/dashboards` | the provider's search root inside Grafana; the mounts sit under it |
| `monitoring_grafana_home_dashboard` | `/d/spark-overview/spark-overview` | also what `make dashboard` checks the uid against |
| `monitoring_grafana_anonymous_role` | `Viewer` | what an unauthenticated visitor may do. See [SECURITY.md](../../SECURITY.md) |
| `monitoring_grafana_theme` | `dark` | |
| `prometheus_image` | `prom/prometheus:v3.13.2` | never pin below the running version |
| `grafana_image` | `grafana/grafana:13.1.1` | never pin below the running version |
| `prometheus_bind_address` | `127.0.0.1` | published address on the host |
| `prometheus_port` | `9090` | the container always listens on 9090 |
| `grafana_port` | `80` | so `http://spark.local` needs no suffix |
| `prometheus_retention` | `1y` | roughly 10 GB at 1527 active series |
| `prometheus_scrape_interval` | `15s` | also the datasource's `timeInterval` |
| `spark_shared_dir` | `/srv/spark` | `group_vars`; its `dashboards/` is mounted into Grafana |

Dashboards edited in the Grafana UI are kept in the `grafana-data` volume; the provisioned file in
this repo wins on the next converge.

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
