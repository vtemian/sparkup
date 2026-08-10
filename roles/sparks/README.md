# `sparks`

The box side of the [sparks](https://github.com/whitemonk/sparks) training framework: the contract
file that tells it what this box provides, and the alerting rules that catch the failures nothing
else reports.

It does **not** install the framework. sparks is a library people `pip install` into their own venv
to write training jobs against; what belongs in this repo is the infrastructure underneath it.

| Variable | Default | |
|---|---|---|
| `sparks_config_dir` | `/etc/sparks` | `0755`, root |
| `sparks_box_config` | `/etc/sparks/box.toml` | `0644`; the contract sparks reads |
| `sparks_rules_dir` | `{{ monitoring_dir }}/prometheus/rules` | host side of a bind mount from `monitoring` |
| `sparks_rules_staging_dir` | `{{ monitoring_dir }}/prometheus/rules.staged` | validated here before installing |
| `sparks_rules_file` | `sparks.yml` | |
| `sparks_textfile_dir` | `{{ exporters_textfile_dir }}` | borrowed; that role creates it |
| `sparks_prometheus_url` | `http://127.0.0.1:{{ prometheus_port }}` | loopback, as Prometheus is bound |
| `sparks_grafana_url` | `http://{{ spark_hostname }}.local` | port appended unless it is 80 |
| `sparks_registry_url` | `http://{{ spark_hostname }}.local:5000` | LAN registry the `registry` role publishes |

## Why a contract file

`spark_shared_dir` is a per-host value: this box overrides it in `host_vars`. Nothing sparks could
probe for would discover that, and its old behaviour — defaulting to this repo's `/srv/spark` and
falling back to an unscraped directory when the textfile collector was missing — recorded runs where
nobody read them while every health signal stayed green.

So the box states what it provisioned, and sparks refuses to guess:

```sh
cat /etc/sparks/box.toml
sparks run --name smoke -- python -c "print(1)"   # exit 78 if this file is missing
```

Exit 78 is `EX_CONFIG`, distinct so that a queue can tell a misconfigured box from a crashed job.

## Laptop Docker and the registry

`registry_url` is plain HTTP on purpose: the trust boundary is the same people who already have
SSH to the box. On each laptop that submits, Docker must allow that insecure registry, e.g.:

```json
{ "insecure-registries": ["spark.local:5000"] }
```

then restart Docker Desktop / dockerd. Without it, `docker push` to the box fails with an HTTPS /
certificate error that looks like a network problem.

## Why the rules are staged first

A malformed dashboard spoils one Grafana panel. A malformed **rule file makes Prometheus refuse to
start**, so a bad file in the mounted directory is a box that silently loses monitoring at its next
reboot. The rules are copied to a staging directory, checked with `promtool` from the same pinned
Prometheus image that will load them, and only installed if that passes. A converge that would break
monitoring fails while monitoring is still working.

The rules are evaluated, not routed: there is no Alertmanager, so nothing pages. Their state is
visible in Prometheus and queryable as `ALERTS{alertname="..."}`.

```sh
curl -s localhost:9090/api/v1/rules | jq '.data.groups[].name'
```

`roles/sparks/files/sparks.yml` is vendored from the sparks repo, where it is authored as
`monitoring/alerts/sparks.yml`. Edit it there and copy it here; provisioning does not reach a
git remote.
