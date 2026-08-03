# `shelly`

Runs `easimon/shelly-exporter` as a digest-pinned container under systemd, polling a Shelly Plug M
Gen3 for wall-socket power. A complete no-op while disabled.

| Variable | Default | |
|---|---|---|
| `shelly_enabled` | `false` | the gate |
| `shelly_host` | `""` | the **plug's** reserved IP, never a `.local` name |
| `shelly_scrape_host` | `host.docker.internal` | where Prometheus looks — the Spark, not the plug |
| `shelly_exporter_port` | `9924` | listening port, on the host network |
| `shelly_exporter_metrics_path` | `/prometheus` | Spring Boot actuator, not `/metrics` |
| `shelly_exporter_version` | `3.0.0` | recorded in the unit file |
| `shelly_exporter_image_digest` | see `group_vars/all.yml` | the real pin |
| `shelly_image_repository` | `ghcr.io/easimon/shelly-exporter` | |
| `shelly_container_name` | `shelly-exporter` | |
| `shelly_unit_name` | `shelly_exporter.service` | |
| `shelly_docker_bin` | `/usr/bin/docker` | |

Set up the plug first: join it to the 2.4 GHz SSID and give it a DHCP reservation.

Verify with `shelly_meter_power_watthours_total`, not with `up` — the exporter answers even when it
is discovering nothing.

```sh
journalctl -u shelly_exporter
```
