# Installing and running sparkup

Everything you need to configure this repo, run it against a box, and work on it when you have no
box at all.

## Requirements

On your laptop: `ansible` (core 2.18+), `ansible-lint`, and `make`. On the box: nothing but SSH.
Docker on your laptop is optional and only needed for the offline test suite.

```bash
pipx install ansible-core ansible-lint     # or your package manager of choice
make deps                                  # installs the pinned collections
```

## What it will not do to your machine

Worth reading before you hand a playbook root.

- **Never flashes firmware.** Config management that flashes an EC on every converge is how a box
  gets bricked unattended. The `thermal` role asserts the version and reports drift; rollback is a
  runbook for a human.
- **Never resets your firewall.** It only ever *adds* allow rules, never a default deny policy.
  Locking yourself out of a WiFi-only box means walking to it.
- **Never creates accounts you did not name.** A fresh clone has an empty user list, so nobody
  else's SSH keys land on your box.
- **Never disables services it did not create.** DGX OS ships some surprising ones; the `base` role
  lists them and leaves them alone.
- **Never sets `default-runtime: nvidia`.** That would inject GPU plumbing into every container,
  Prometheus and Grafana included.
- **Never reboots.** The one role that needs a reboot tells you so and stops.

`sparkup` gets the box into a known state and gets metrics into Prometheus. It does not own training
runs; the wrapper that emits per-run metrics is a separate project, specified in
[`docs/training-observability.md`](docs/training-observability.md).

## First run

```bash
cp host_vars/spark.yml.example host_vars/spark.yml
$EDITOR host_vars/spark.yml                # your accounts and shared paths
$EDITOR inventory/hosts.yml                # ansible_host and ansible_user for your box

make ping                                  # does the box answer?
make check                                 # dry run: exactly what would change
make apply                                 # converge
```

**The copy step is not ceremony.** `host_vars/spark.yml` names the accounts that get sudo on your
machine and whose GitHub keys may log in as them. It is untracked on purpose, so that cloning this
repo and running it cannot create somebody else's users on your box. A fresh clone has
`spark_users: []` and creates nothing.

Keep the inventory host **named** `spark` whatever your machine is called. `ansible_host` carries
the real address; renaming the host would orphan its `host_vars` file silently.

## Configuration

Two files, so an upgrade is a reviewable diff rather than a hunt through roles.

| File | Tracked | What belongs there |
|---|---|---|
| `group_vars/all.yml` | yes | Defaults that suit any Spark: image tags, ports, retention, exporter versions |
| `host_vars/<host>.yml` | **no** | Your box: accounts, shared directory and group, timezone, firmware version |

Anything a single role owns lives in that role's `defaults/main.yml`, prefixed with the role name.
Anything several roles share lives in `group_vars/all.yml`.

### Accounts

```yaml
spark_users:
  - name: alice
    groups: [sudo, docker]
    github_keys: alice-on-github   # or false to manage keys yourself
```

Existing authorized keys are never removed, so a working key cannot be orphaned by a typo. Naming
someone in `github_keys` is a standing delegation, not a one-time copy: adding a key to that GitHub
account grants access at the next converge. If the account also has `sudo`, that is root.

### Optional roles

Three roles do nothing unless asked, so a plain `make apply` never touches firmware, kernels or
power.

| Role | Off because | Turn on with |
|---|---|---|
| `shelly` | not everyone owns a smart plug | `shelly_enabled: true` plus `shelly_host` |
| `thermal` | your EC firmware version is not this box's | `thermal_expected_ec_firmware`, `thermal_gpu_clock_cap_enabled` |
| `kernel` | it is the only role that can leave a headless box unbootable | `kernel_enabled: true`, supervised |

### Power measurement is not tied to Shelly

What this repo provides is a `power` scrape job. Any exporter can fill it:

```yaml
power_scrape_target: tasmota.lan:9999
power_scrape_metrics_path: /metrics
```

The bundled Shelly role is one convenient way to fill that target and sets it for you when enabled.
Set neither and there is simply no power job; no dashboard panel queries those metrics.

## Secrets

**No password belongs in this repo.** In order of preference:

1. **Interactive** (default). `make apply` prompts once via `-K`.
2. **Passwordless sudo.** `make apply BECOME=`.
3. **Unattended.** Encrypt it, and keep the vault password file outside the repository:

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

Most people reading this repo do not have a DGX Spark in front of them, and the acceptance test
above needs one. Everything in `tests/` exists to shrink the gap between "it lints" and "it works".
Docker is the only requirement, and nothing here touches a real host.

```bash
make offline   # lint, syntax, dashboard, dashboard-live, roles-test
```

| Target | What it proves |
|---|---|
| `make dashboard` | Every panel query parses, and every metric it names is one an enabled exporter emits |
| `make dashboard-live` | Every panel query returns data from a real Prometheus holding synthetic samples |
| `make roles-test` | `base` and `users` converge in containers, and a second converge reports `changed=0` |
| `make harness-up` | Grafana and Prometheus locally, with data in the panels, for editing the dashboard |
| `make harness-down` | The harness gone, containers and volumes both |

**Why two dashboard checks.** `make dashboard` enforces the rule that matters most for a board
nobody can look at: never query a metric nobody emits. It parses each expression with `promtool`
out of the pinned `prom/prometheus` image, then checks every metric name against a set derived from
`roles/exporters/defaults/main.yml`. Drop `filesystem` from the collector list and the disk panels
fail here rather than on the box.

That check matches `node_memory_` and `node_filesystem_` by prefix, because an exhaustive list of
what `/proc/meminfo` yields would be a claim about a kernel. So a typo *inside* a real family slips
past it. `make dashboard-live` is what catches that: it brings the real stack up against synthetic
metrics and fails on any panel returning no data. Both run in `make offline` and in CI.

**Editing the dashboard.** `make harness-up` renders the `monitoring` role's own templates, not a
copy, onto your machine and serves synthetic metrics shaped like the box: 20 cores, 121 GiB of
unified memory, a GPU rail peaking near 87 W. Grafana lands on **13000** and Prometheus on
**19090**, so nothing collides with a real stack. Edit
`roles/monitoring/files/dashboards/spark-overview.json` and the file provider picks it up within ten
seconds. `make harness-down` removes the named volumes too, so the next run does not start with
yesterday's synthetic history.

**What the container tests do not cover.** `roles-test` runs `base` and `users` against Ubuntu 24.04
containers booting real systemd. `docker`, `gpu`, `exporters` and `monitoring` are **not** tested,
and are deliberately not stubbed: a container cannot stand in for a GB10, a driver, a second Docker
daemon or a machine on a network, and a fake that reported success would be worse than no test. The
script prints that list before it runs. The GitHub key import is skipped too, since it needs the
network and a real account.

CI runs all of it on every push and pull request, on a fresh clone with no `host_vars` at all.

## Running one part at a time

Every role carries a tag.

```bash
make apply EXTRA="--tags monitoring"
make apply EXTRA="--tags exporters,monitoring"
```

Two of those combinations matter:

- **`--tags monitoring` alone, on a box still running a containerised node-exporter**, removes that
  container and gives nothing back, because the host unit comes from the `exporters` role. Run them
  together.
- **`--tags kernel` alone does nothing at all.** The role is additionally gated on
  `kernel_enabled`, which ships false. You need `-e kernel_enabled=true` as well. See
  `roles/kernel/README.md` before running it, and read the preflight checklist there first.

## Troubleshooting

**`curl 127.0.0.1:9100` hangs even though the exporter is fine.** Known on this hardware. Verify
exporters through Prometheus (`up`, `scrape_samples_scraped`), never by curling them locally.

**A package task reports `changed` on every run.** Check for an interrupted apt transaction:
`dpkg -l | grep -v '^ii'`. A package stuck in `install ok unpacked` reads as not-installed forever.
`sudo dpkg --configure -a` on the box fixes it.

**SSH is socket-activated.** `ssh.socket` is the enabled unit and `ssh.service` is disabled.
Restarting `ssh.service` is a no-op that looks like success.

**GPU memory panels are empty.** Correct, not broken. This hardware has unified memory, so
`nvidia-smi` reports `[N/A]` for framebuffer memory and the exporter drops the field.
`node_memory_*` is the GPU memory signal.

**A `power` target is up but there are no power metrics.** The exporter answers whether or not it
ever reached the plug. Check for `shelly_meter_power_watthours_total`, not for `up`.
