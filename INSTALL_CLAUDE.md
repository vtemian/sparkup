# Operating sparkup

Documentation for an AI agent working in this repository. Humans want
[README.md](README.md); this file assumes you are the one running the commands.

This repo is Ansible that provisions a DGX Spark. It runs **as root on real hardware that somebody
owns**. The machine it targets is typically headless and on WiFi with no wired fallback, so a
firewall or boot mistake is recovered by physically walking to it. Optimise for not breaking the
box, not for finishing quickly.

**Scope.** sparkup gets the box into a known state and gets metrics into Prometheus. It does not own
training runs. The wrapper that emits per-run metrics and correlates them against these series is a
separate project, specified in [`docs/training-observability.md`](docs/training-observability.md).
What sparkup guarantees it: Prometheus with the remote-write receiver enabled, a provisioned Grafana
datasource, and live `node`, `gpu` and `power` scrape jobs. Do not break those.

---

## Hard rules

These are invariants of the repository, not preferences. Breaking one is a defect even if the
playbook still converges.

1. **Never flash firmware.** No task, no flag, no confirmation prompt. The `thermal` role reads the
   EC version and asserts it. Rollback is a runbook a human executes while standing next to the
   machine.
2. **Never reset a firewall or set a default policy implicitly.** `base` only *adds* allow rules.
   Enabling ufw is opt-in via `spark_firewall_enable` and asserts SSH is allowed first.
3. **Never create accounts that were not asked for.** `spark_users` defaults to `[]`.
   `host_vars/*.yml` is gitignored precisely so a clone cannot provision somebody else's users.
4. **Never reboot from a role.** `kernel` reports that a reboot is required and stops. Rebooting is
   a separate, explicit act (`ansible spark -m ansible.builtin.reboot`) taken with the operator's
   agreement.
5. **Never commit a secret.** Not in `group_vars`, not in a role, not in a test fixture. The become
   password lives outside the repo entirely.
6. **Never disable a service the repo did not create.** `base` lists surprising ones and leaves
   them alone.
7. **Idempotence is the acceptance test.** A task that reports `changed` on every run is unfinished.
8. **Never query a metric nobody emits.** Enforced by `make dashboard`.
9. **Pin versions, and never below what the box already runs.** Grafana migrates its database schema
   forward only. Check `docker exec <container> grafana server -v` before changing a pin.

## Stop and ask the human

Do not decide these alone, even when you have working sudo:

- Enabling or altering the firewall policy on a box you cannot physically reach.
- Running the `kernel` role, or rebooting.
- Anything touching firmware.
- Making the repository public, or anything else that publishes outward.
- Removing kernels, or any package removal that is not trivially reversible.

Everything else, execute. Do not ask a human to run a command you can run yourself.

---

## Setup

```bash
make deps                                            # pinned collections
cp host_vars/spark.yml.example host_vars/spark.yml   # untracked, holds identity
$EDITOR host_vars/spark.yml
$EDITOR inventory/hosts.yml                          # ansible_host + ansible_user
```

Keep the inventory host **named** `spark` whatever the machine is called. `ansible_host` carries the
address. Renaming the host orphans its `host_vars` file silently.

### Become

`-K` prompts interactively and an agent cannot type into a prompt. Use a password file:

```bash
install -m 600 /dev/null ~/.sparkup-become
# the human types the password in; never ask them to paste it into a transcript
make apply BECOME="--become-password-file ~/.sparkup-become"
```

Verify it works before relying on it:

```bash
ansible spark -m ansible.builtin.command -a 'id -u' --become --become-password-file ~/.sparkup-become
# expect: 0
```

---

## Configuration model

Three tiers. Putting a value in the wrong one is the most common mistake.

| Tier | Holds | Example |
|---|---|---|
| `group_vars/all.yml` | defaults suiting **any** Spark, and anything several roles share | `prometheus_image`, `spark_firewall_allow_ports` |
| `host_vars/<host>.yml` | one box's identity. **Untracked** | `spark_users`, `thermal_expected_ec_firmware`, `base_timezone` |
| `roles/<r>/defaults/main.yml` | tunables only that role reads, prefixed with the role name | `kernel_grub_timeout`, `thermal_pin_fwupd` |

`var-naming[no-role-prefix]` is enabled and **not** skipped. A role must prefix what it declares.
Registry variables are read unprefixed and declared only in `group_vars`; do not redeclare them in a
role's defaults, or the same tunable exists in two files.

### Roles that are inert by default

| Role | Off because | Enable with |
|---|---|---|
| `shelly` | not everyone owns a smart plug | `shelly_enabled: true` + `shelly_host` |
| `thermal` clock cap | trades compute for thermal headroom | `thermal_gpu_clock_cap_enabled` |
| `thermal` EC assertion | your firmware version is not this box's | `thermal_expected_ec_firmware` |
| `kernel` | can leave a headless box unbootable | `kernel_enabled: true` |

**`--tags kernel` alone does nothing.** The tag selects the role, `when: kernel_enabled` discards it,
and the run reports success having done nothing. Both are required:
`--tags kernel -e kernel_enabled=true`.

### Power is not tied to Shelly

`power_scrape_target` is the contract. Any exporter speaking the Prometheus exposition format fills
it. The bundled `shelly` role is one way and sets that target when enabled. Set neither and no
`power` job is emitted.

---

## Running

```bash
make check BECOME="--become-password-file ~/.sparkup-become"   # dry run, changes nothing
make apply BECOME="--become-password-file ~/.sparkup-become"
make apply BECOME="--become-password-file ~/.sparkup-become"   # must report changed=0
```

Play order, and it is load-bearing:

```
base → docker → gpu → users → exporters → shelly → monitoring → thermal → kernel
```

- `docker` precedes `users` because `ansible.builtin.user` fails hard if a group in `groups:` does
  not exist.
- `exporters` precedes `monitoring` because `monitoring` uses `remove_orphans: true`, which deletes
  a containerised node-exporter. Running `--tags monitoring` alone on an unmigrated box removes host
  metrics and gives nothing back.
- `shelly` precedes `monitoring` so the exporter exists before Prometheus is told to scrape it.

---

## Verification

Assert against reality, not against the recap.

```bash
# exporters: through Prometheus, NEVER by curling them
curl -s --get http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=up'
curl -s --get http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=time() - timestamp(up == 1)'
```

`up == 1` alone is weak for the `power` job: that exporter answers whether or not it ever reached
the plug. Check for `shelly_meter_power_watthours_total` instead.

Other checks worth running after a converge: `docker info --format '{{json .Runtimes}}'` lists
`nvidia`; `docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi`;
`curl -o /dev/null -w '%{http_code}' http://<host>/` returns 200 anonymously; `ufw status verbose`;
`mokutil --sb-state`; and `cd ../bbm && make spark-parity`, which is the canary that provisioning has
not perturbed Pillow/freetype resolution.

---

## Working without the hardware

```bash
make offline   # lint, syntax, dashboard, dashboard-live, roles-test
```

| Target | Proves |
|---|---|
| `make dashboard` | every panel query parses (real `promtool`) and names a metric an enabled exporter emits |
| `make dashboard-live` | every query returns data from a real Prometheus holding synthetic samples |
| `make roles-test` | `base` and `users` converge twice in containers, second run `changed=0` |
| `make harness-up` / `harness-down` | Grafana and Prometheus locally for editing the dashboard |

`make dashboard` matches `node_memory_` and `node_filesystem_` by **prefix**, so a typo inside a real
metric family passes it. `make dashboard-live` is what catches that. Both run in `offline` and in CI.
Do not treat a green `make dashboard` as proof a panel works.

`docker`, `gpu`, `exporters` and `monitoring` are **not** container-testable and are deliberately not
stubbed. A fake that reported success would be worse than no test.

---

## Traps

Accumulated by losing time to them. Each one has cost somebody an afternoon.

- **`curl 127.0.0.1:9100` hangs** on this hardware even when node-exporter is healthy. Verify through
  Prometheus.
- **SSH is socket-activated.** `ssh.socket` is enabled, `ssh.service` is disabled. Restarting
  `ssh.service` is a no-op that looks like success.
- **`ansible.builtin.cron` with `state: absent` silently does nothing** for a hand-written line. It
  matches only entries carrying its own `#Ansible:` header, and reports `ok` having removed nothing.
- **Docker port publishing bypasses ufw.** DNAT and `DOCKER-USER` sit ahead of ufw's chains, so
  `--publish` exposes a port regardless of policy. Use host networking when ufw must govern a port.
- **A default-deny firewall breaks container scrapes.** Prometheus reaches host exporters through the
  docker bridge gateway, which arrives on the host INPUT chain. `spark_firewall_docker_subnets`
  exists for this; securing the box would otherwise break its monitoring.
- **DGX OS ships `/etc/default/grub.d/no-grubmenu.cfg`** forcing `GRUB_TIMEOUT=0`,
  `GRUB_TIMEOUT_STYLE=hidden` and `GRUB_RECORDFAIL_TIMEOUT=0`. Drop-ins are sourced after
  `/etc/default/grub`, so editing the base file does nothing. The `kernel` role ships
  `zz-sparkup-menu.cfg`, which sorts last. Always verify the **generated** `grub.cfg`, never the edit.
- **`nvidia-cdi-refresh` is two units.** The `.service` defaults to writing `/var/run/cdi/nvidia.yaml`;
  two CDI specs claiming the same device make the cache drop it, so `nvidia.com/gpu=all` stops
  resolving *because* the refresh worked. `/var/run` is also tmpfs.
- **GPU memory metrics are absent by design.** Unified memory means `nvidia-smi` reports `[N/A]` and
  the exporter drops the field. `node_memory_*` is the GPU memory signal. Do not "fix" this.
- **`vars_files` outrank a play's `vars:`.** A test playbook that sets `spark_users` in `vars:` while
  loading `group_vars/all.yml` gets the empty list and silently creates nobody.
- **`make check` fails with "Group does not exist" on a fresh box.** Check mode does not create the
  shared group, so adding users to it fails. Artifact of the dry run; gone after the first apply.
- **A package stuck in dpkg state `install ok unpacked`** reads as not-installed forever, so its task
  reports `changed` on every run. Fix with `dpkg --configure -a`, not with a workaround in a role.

---

## Contributing changes

`make offline` must pass, and `ansible-lint` runs the **production** profile: FQCNs everywhere, every
task named and capitalised as the first key, explicit `mode` on file tasks, handlers rather than
`when: x.changed`, deliberate `changed_when` on `command`/`shell`.

If you change what a role does, update that role's README in the same commit. A README describing
different behaviour from its tasks is worse than none.

Conventional commit messages. Never mention AI assistance in commits, code or PR descriptions.

**If reality contradicts a document, reality wins and the document changes.** Several claims in this
repo were measured on one box on one day and later proved wrong: the firewall was inactive rather
than enabled with unknown rules, a pinned exporter version did not exist, and editing
`/etc/default/grub` did not make the boot menu appear. Correcting those is the most valuable work,
not a digression from it.
