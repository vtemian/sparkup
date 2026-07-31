# sparkup

Ansible that takes a DGX Spark from a fresh DGX OS install to a working training box: users,
Docker with the NVIDIA runtime, supervised host exporters, and Prometheus + Grafana serving
system, GPU and power dashboards.

The scope is infrastructure. `sparkup` gets the box into a known state and gets metrics into
Prometheus; it does not own training runs. The design for the wrapper that emits per-run metrics
lives in [`docs/training-observability.md`](docs/training-observability.md).

## Quick start

```bash
make deps                      # install the pinned collections
$EDITOR inventory/hosts.yml    # point ansible_host at your box
$EDITOR host_vars/spark.yml    # your users and shared paths
make ping                      # confirm the box answers
make check                     # dry run: see the diff it would make
make apply                     # converge
```

`make apply` prompts once for the sudo password. If your account has passwordless sudo, use
`make apply BECOME=`.

## Configuration

Everything tunable lives in two files, so an upgrade is a reviewable diff rather than a hunt
through roles.

| File | What belongs there |
|---|---|
| `group_vars/all.yml` | Defaults that suit any Spark: image tags, ports, retention, exporter versions |
| `host_vars/<host>.yml` | Your box: users, shared directory and group |

`spark_users` is empty by default — a fresh clone will not invent accounts on your box. Each entry
takes a name, a list of extra groups, and optionally a GitHub username whose public keys are
installed:

```yaml
spark_users:
  - name: alice
    groups: [sudo, docker]
    github_keys: alice-on-github
```

Existing authorized keys are never removed, so a working key cannot be orphaned by a typo.

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
