# `monitoring`

Prometheus and Grafana as a compose stack under `{{ monitoring_dir }}`, with a provisioned
datasource and dashboard.

| Variable | Default | |
|---|---|---|
| `monitoring_dir` | `/opt/monitoring` | `group_vars`; holds compose and every config file |
| `monitoring_project_name` | `spark-monitoring` | namespaces the `grafana-data` and `prometheus-data` volumes |
| `monitoring_dashboards_container_dir` | `/etc/grafana/dashboards` | mount point inside Grafana |
| `monitoring_grafana_home_dashboard` | `/d/spark-overview/spark-overview` | also what `make dashboard` checks the uid against |
| `prometheus_image` | `prom/prometheus:v3.13.2` | never pin below the running version |
| `grafana_image` | `grafana/grafana:13.1.1` | never pin below the running version |
| `prometheus_bind_address` | `127.0.0.1` | published address on the host |
| `prometheus_port` | `9090` | the container always listens on 9090 |
| `grafana_port` | `80` | so `http://spark.local` needs no suffix |
| `prometheus_retention` | `30d` | |
| `prometheus_scrape_interval` | `15s` | also the datasource's `timeInterval` |
| `power_scrape_target` | derived from `shelly_*` | empty emits no `power` job |

Dashboards edited in the Grafana UI are kept in the `grafana-data` volume; the provisioned file in
this repo wins on the next converge.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://spark.local/
```
