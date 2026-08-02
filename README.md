# sparkup

Ansible that takes a DGX Spark from a fresh DGX OS install to a working training box: users,
Docker with the NVIDIA runtime, supervised host exporters, and Prometheus + Grafana serving
system, GPU and power dashboards.

The scope is infrastructure. `sparkup` gets the box into a known state and gets metrics into
Prometheus; it does not own training runs. The design for the wrapper that emits per-run metrics
lives in [`docs/training-observability.md`](docs/training-observability.md).

## Quick start

```bash
make deps                                            # install the pinned collections
cp host_vars/spark.yml.example host_vars/spark.yml   # your users and shared paths
$EDITOR host_vars/spark.yml
$EDITOR inventory/hosts.yml                          # point ansible_host at your box
make ping                                            # confirm the box answers
make check                                           # dry run: see the diff it would make
make apply                                           # converge
```

The copy step is not optional and not ceremony: `host_vars/spark.yml` names the accounts that get
sudo on your machine and whose GitHub keys may log in as them. It is **untracked on purpose**, so
that cloning this repo and running it cannot create somebody else's users on your box.

`make apply` prompts once for the sudo password. If your account has passwordless sudo, use
`make apply BECOME=`.

## Configuration

Everything tunable lives in two files, so an upgrade is a reviewable diff rather than a hunt
through roles.

| File | Tracked | What belongs there |
|---|---|---|
| `group_vars/all.yml` | yes | Defaults that suit any Spark: image tags, ports, retention, exporter versions |
| `host_vars/<host>.yml` | **no** | Your box: users, shared directory and group, timezone |

`spark_users` is empty in `group_vars/all.yml` and the only file that fills it is untracked, so a
fresh clone cannot invent accounts on your box. Each entry takes a name, a list of extra groups,
and optionally a GitHub username whose public keys are installed:

```yaml
spark_users:
  - name: alice
    groups: [sudo, docker]
    github_keys: alice-on-github
```

Existing authorized keys are never removed, so a working key cannot be orphaned by a typo.

## Optional pieces

Three roles do nothing unless you ask for them, so a plain `make apply` on a stock DGX Spark never
touches firmware, kernels or power:

| Role | Off by default because | Turn on with |
|---|---|---|
| `shelly` | not everyone owns a smart plug | `shelly_enabled: true` + `shelly_host` |
| `thermal` | the clock cap trades compute for headroom, and your EC version is not this box's | `thermal_gpu_clock_cap_enabled`, `thermal_expected_ec_firmware` |
| `kernel` | it is the only role that can leave a headless box unbootable | `kernel_enabled: true`, deliberately and supervised |

**Power measurement is not tied to Shelly.** What this repo provides is a `power` scrape job, and
any exporter can fill it — set `power_scrape_target` to wherever something already speaks the
Prometheus exposition format. The bundled Shelly role is one convenient way to fill it and sets that
target for you; it is not the only way, and nothing outside `roles/shelly` assumes it. Set neither
and there is no power job at all — no dashboard panel queries those metrics.

## Secrets

**No password belongs in this repo.** The supported options, in order of preference:

1. **Interactive** (default) — `make apply` prompts once via `-K`.
2. **Passwordless sudo** — `make apply BECOME=`.
3. **Unattended** — encrypt `ansible_become_password` with `ansible-vault`, and keep the vault
   password file outside the repository:
   ```bash
   ansible-vault encrypt_string 'your-sudo-password' --name 'ansible_become_password' \
     >> host_vars/spark.yml
   make apply BECOME= EXTRA="--vault-password-file ~/.sparkup-vault-pass"
   ```

## Idempotence is the acceptance test

A playbook that cannot run twice is a shell script with extra syntax.

```bash
make idempotence   # converges, then fails unless the second run reports changed=0
make lint          # ansible-lint, production profile
```

## Working without a Spark

Most people who read this repo do not have a DGX Spark in front of them, and the acceptance test
above needs one. Everything in `tests/` exists to shrink the gap between "it lints" and "it works"
for everyone else. Docker is the only requirement; nothing here touches a real host.

```bash
make offline       # lint, syntax, dashboard, roles-test — the whole no-hardware suite
```

| Target | What it proves |
|---|---|
| `make dashboard` | Every panel query parses, and every metric it names is one an enabled exporter emits |
| `make roles-test` | `base` and `users` converge in containers, and a second converge reports `changed=0` |
| `make harness-up` | Grafana and Prometheus running locally with data in the panels |
| `make harness-down` | The harness gone, containers and volumes both |

**`make dashboard`** enforces the rule that matters most for a board nobody can look at: *never
query a metric nobody emits*. It parses each expression with the real parser — `promtool`, out of
the `prom/prometheus` image `group_vars/all.yml` pins — and then checks every metric name against
a set derived from `roles/exporters/defaults/main.yml`: the enabled node_exporter collectors and
the nvidia-smi query fields. Drop `filesystem` from the collector list and the three disk panels
fail here rather than on the box. Metric names in panel *descriptions* are not examined, so the
"Unified memory" panel can keep explaining at length that `nvidia_smi_memory_used_bytes` does not
exist on unified memory.

**`make harness-up`** is for iterating on the dashboard itself. It renders the `monitoring` role's
own templates — not a copy — onto this machine, brings Prometheus and Grafana up on **13000** and
**19090** rather than 80, and serves synthetic metrics shaped like the box (20 cores, 121 GiB of
unified memory, a GPU rail peaking near 87 W) from a plain host process that Prometheus reaches
through `host.docker.internal`, exactly as it reaches the real host exporters. Before it opens the
browser it asserts that all 21 panel queries return data, which catches a misspelling inside a real
metric family that the offline check cannot. Edit
`roles/monitoring/files/dashboards/spark-overview.json`, and Grafana's file provider picks it up
within ten seconds.

`make harness-down` removes the named volumes as well as the containers. Keeping them would mean
the next run starts with yesterday's synthetic history and a dashboard that may no longer be the
file on disk.

**What the container tests do not cover.** `make roles-test` runs `base` and `users` against
Ubuntu 24.04 containers booting real systemd — `base` needs it for avahi, `hostnamectl` and
`service_facts`. `docker`, `gpu`, `exporters` and `monitoring` are **not** tested, and are not
stubbed either: a container cannot stand in for a GB10, a driver, a second Docker daemon or a
machine on a network, and a fake that reported success would be worse than no test. The script
prints that list before it runs anything. The GitHub key import in `users` is also skipped, because
it needs the network and a real account. For the rest, `make idempotence` against the box remains
the acceptance test.

CI runs the lint, dashboard and container checks on every push and pull request. It works on a
fresh clone with no `host_vars` at all — `ansible-lint` and `--syntax-check` both pass in that
state, because every variable the roles read has a default.

## What this deliberately does not do

- **Never flashes firmware.** Config management that flashes an EC on every converge is how a box
  gets bricked unattended.
- **Never resets your firewall.** The `base` role only *adds* allow rules. It never sets a default
  deny policy, because locking yourself out of a WiFi-only box means walking to it.
- **Never disables services it did not create.** DGX OS ships platform units and a few surprising
  ones; the `base` role lists them in its README and leaves them alone.
- **Never sets `default-runtime: nvidia`.** That would inject GPU plumbing into every container,
  Prometheus and Grafana included.

## Layout

```
inventory/hosts.yml        the host
group_vars/all.yml         defaults for any Spark
host_vars/spark.yml        this box
site.yml                   the playbook
roles/base                 hostname, avahi, timezone, packages, firewall
roles/users                accounts, keys, groups, the shared tree
roles/docker               daemon.json with the nvidia runtime, log rotation
roles/gpu                  container toolkit, CDI spec, GPU smoke test
roles/exporters            node_exporter + nvidia_gpu_exporter as systemd units
roles/monitoring           Prometheus + Grafana containers, provisioning, dashboards
```
