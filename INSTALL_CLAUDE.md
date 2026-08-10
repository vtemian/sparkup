# Operating sparkup

This repo's procedure, facts and traps, for an agent running them. Humans want
[README.md](README.md). The rules (invariants, what to ask before doing, engineering standards) are
in [CLAUDE.md](CLAUDE.md), which loads automatically; read it first and do not restate it here.

Trust the machine over this file. Several claims in it were measured wrong once: the firewall turned
out to be inactive rather than enabled with unknown rules, a pinned exporter version did not exist
on the registry, and editing `/etc/default/grub` did not make the boot menu appear because a drop-in
under `/etc/default/grub.d/` was overriding it. Assume the same of anything here you have not
checked.

---

## First run, in order

Every step is a command. Step 4 exists because an agent cannot answer an interactive prompt.

**1. Collections.**

```bash
make deps
```

**2. Identity.** `host_vars/<host>.yml` is gitignored, so a fresh clone has none, and the playbook
refuses to run against the tracked placeholder.

```bash
cp host_vars/spark.yml.example host_vars/spark.yml
$EDITOR host_vars/spark.yml     # accounts, hostname, timezone, spbm_enabled
```

**3. Address.**

```bash
$EDITOR inventory/hosts.yml     # ansible_host + ansible_user
```

Keep the inventory host **named** `spark` whatever the machine is called; `ansible_host` carries the
address, and renaming the host orphans its `host_vars` file silently. On a box that has never
converged use its IP, because `spark.local` only resolves once this playbook has installed avahi.

With the address set, `make report` already works: it reads the box, needs no sudo, and changes
nothing. Run it before a first converge. It prints what would stop one, and puts this repo's
hardware claims next to what the box actually answers.

**4. Become.** `-K` prompts interactively, and an agent cannot type into a prompt.

```bash
install -m 600 /dev/null ~/.sparkup-become
# the human types the password in; never ask them to paste it into a transcript
ansible spark -m ansible.builtin.command -a 'id -u' --become --become-password-file ~/.sparkup-become
# expect: 0
```

Every command below assumes `BECOME="--become-password-file ~/.sparkup-become"`.

**5. Converge.**

```bash
make apply BECOME="--become-password-file ~/.sparkup-become"
```

**6. Prove it converged.** The second run must report `changed=0`. That is the acceptance test;
`--check` is not, and `make check` is only useful against a box that has converged once. See Traps
for why it cannot survive a fresh one.

```bash
make apply BECOME="--become-password-file ~/.sparkup-become"   # changed=0
```

**7. Verify against the machine**, never against your own recap. The commands are under
[Verification](#verification).

Then stop. **Nothing here reboots.** The converge prints what the next reboot will do and leaves it
to a human.

---

## Configuration model

Three tiers. Putting a value in the wrong one is the most common mistake.

| Tier | Holds | Example |
|---|---|---|
| `group_vars/all.yml` | defaults suiting **any** Spark, and anything several roles share | `prometheus_image`, `spark_firewall_allow_ports`, `spbm_enabled` |
| `host_vars/<host>.yml` | one box's identity. **Untracked** | `spark_users`, `spark_hostname`, `base_timezone` |
| `roles/<r>/defaults/main.yml` | tunables only that role reads, prefixed with the role name | `kernel_grub_timeout`, `spbm_mok_cert` |

`var-naming[no-role-prefix]` is enabled and **not** skipped. A role must prefix what it declares.
Registry variables are read unprefixed and declared only in `group_vars`; do not redeclare them in a
role's defaults, or the same tunable exists in two files.

### There is exactly one gate

`spbm_enabled`, declared in `group_vars/all.yml`, defaulting to **false**, read in exactly one place:
the `when:` on the `spbm` role in `site.yml`. Every other role runs on every converge, and no other
variable in this repo decides whether a feature happens; see [CLAUDE.md](CLAUDE.md) for the test
`spbm_enabled` passes and a second flag would not, and do not add one.

Grep for it before assuming it is read anywhere else. It is not passed into a template, not consulted
by `exporters`, and not consulted by `monitoring`: the dashboard ships the Power row either way, and
those panels explain their own emptiness rather than being generated conditionally. Templating the
dashboard is not an option anyway; see the `copy`, never `template` trap below.

The two things that could once *also* be switched off are guarded by asserts instead, which is the
shape to copy if you are tempted to add a toggle for safety:

- **ufw** ends default-deny, and `base` refuses to enable it unless the port **this connection
  arrived on** is in `spark_firewall_allow_ports`. It reads that port off
  `ansible_env.SSH_CONNECTION` rather than trusting `spark_firewall_ssh_port`, so a box reached on a
  non-standard port cannot be locked out by a config that only mentions 22.
- **`kernel`** asserts the GRUB menu resolves to something visible *before* it moves the boot
  target, so a box whose menu is hidden fails the converge rather than becoming unreachable.

A guard that fails loudly beats a default that does nothing.

### Where power comes from

The firmware, through `spbm`, and only where somebody asked for it. On a default box there is no
power and no energy at all, and the three panels on the dashboard's Power row read "No data". That
is the expected state, not a fault to chase.

`spbm_enabled: true` in `host_vars` installs the driver and queues its signing key. A **human at the
machine** then reboots with a keyboard and monitor attached and answers MokManager, because Secure
Boot will not load the module until that key is trusted and there is no SSH at that screen. Never
flip this variable for a box you cannot reach, and never on someone else's behalf.
[roles/spbm/README.md](roles/spbm/README.md) holds the procedure and the metric reference.

### What the box can actually draw

**`pl1`, the GB10 module budget, is the limit that binds.** Saturated with a dense bf16 GEMM it pins
at 139.7 W against its 140 W cap and will not move. `sys_total` peaks at **171 W**, `syspl1` at 153 W
against a 231 W cap it never approaches. The 240 W in the product spec is the PSU rating, and roughly
70 W of it is unreachable because `pl1` binds first. Nobody is entitled to 240 W and a box that will
not draw it is not broken.

**`pl1` is shared, so the GPU rail cannot approach 140 W.** Under load `cpu_p` rises 10.7 → 20.6 W
while `gpu` rises 79.5 → 91.7 W, together filling `soc_pkg` to 137.9 W. Loading the Grace cores takes
watts from the GPU instead of adding them, and a GPU rail plateauing near 100 W is correct.

**`nvidia-smi` cannot measure any of this.** It read 71.9 W against the spbm `gpu` channel's 103.4 W
at the same instant, 30–44 % low, and `power.limit` is permanently `[N/A]`. Worse, its
`SW Power Capping` counter did not advance through 75 s with `pl1` pinned at its cap: **NVML sits
above the EC, so "Not Active" on every clocks event reason proves nothing.** Diagnose power from the
spbm channels or not at all. The same blindness is what makes the safety mode below so easy to miss.

**Heat is not the limiter at the stock cap,** which is why the fan-curve advice circulating for this
hardware is untested here: saturated at 140 W the GPU sits at 82 °C with 0 µs of SW thermal, HW
thermal and HW power-brake slowdown. That says nothing about a raised cap. `pl1` is writable and its
firmware ceiling is 250 W, but GB10 reports `N/A` for every thermal-limit register, so there is no
Tjmax to raise it against — it would be adjusting the one thing this hardware cannot measure. Board
overhead is ~31 W, so `syspl1`'s 231 W cap corresponds to about 200 W of module: the headroom is real
and deliberately unused by the vendor. Treat raising it as firmware territory and ask first.

**Reading the channels by hand: glob `power*_label`, never index.** `power10` sorts before `power2`,
so a positional read silently returns a different channel, and the hwmon index moves across boots.
Find the device by name, not number:
`for d in /sys/class/hwmon/hwmon*; do [ "$(cat $d/name)" = spbm ] && echo $d; done`. `make report`
already does this correctly and prints every cap and ceiling.

**A workload below the cap is not a fault.** Training on this box sits at `pl1` 117 W of 140 W. Low
power means the job is not compute-bound; it does not mean it is slow. Memory-bandwidth-bound kernels
draw less than a GEMM by nature, so profile before treating the gap as headroom to reclaim.

---

## Tags and play order

Play order is load-bearing:

```
base → docker → gpu → users → spbm → exporters → monitoring → firmware → kernel
```

- `docker` precedes `users` because `ansible.builtin.user` fails hard if a group in `groups:` does
  not exist.
- `exporters` precedes `monitoring` because `monitoring` uses `remove_orphans: true`, which deletes
  a containerised node-exporter. Running `--tags monitoring` alone on an unmigrated box removes host
  metrics and gives nothing back.
- `spbm` precedes `exporters` so its hwmon channels exist before node_exporter starts reading them.
  It is skipped entirely unless `spbm_enabled` is true, which is the default. `skipping: [spark]`
  under the `spbm` tasks is correct output, not a failure.

`pre_tasks` are tagged `always`, so `--tags <anything>` still runs every precondition. `post_tasks`
are **not** tagged, so `--tags` skips the reboot summary. A tagged run tells you less than it looks.

---

## Verification

Assert against reality, not against the recap.

```bash
# exporters: through Prometheus, NEVER by curling them
curl -s --get http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=up'
curl -s --get http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=time() - timestamp(up == 1)'
```

`up == 1` says nothing about power: node_exporter answers whether or not the `spbm` module loaded.
Only run this check on a box where `spbm_enabled` is true. Anywhere else the empty result is the
design, and reporting it as a fault wastes somebody's afternoon:

```bash
curl -s --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=node_hwmon_power_watt'
```

Where it *is* enabled, an empty result means the module is built but not loaded, which means the
signing key is not enrolled and somebody still has to walk to the box.

Other checks worth running after a converge: `docker info --format '{{json .Runtimes}}'` lists
`nvidia`; `docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi`;
`curl -o /dev/null -w '%{http_code}' http://<host>/` returns 200 anonymously; `ufw status verbose`;
and `mokutil --sb-state`. If the box also carries a project with its own environment check, run that
too: provisioning touches apt and Docker, and a native-library resolution it silently changed is the
failure this catches.

---

## Working without the hardware

```bash
make offline   # lint, syntax, dashboard, dashboard-live, roles-test
```

| Target | Proves |
|---|---|
| `make dashboard` | every panel query parses (real `promtool`) and names a metric an enabled exporter emits |
| `make dashboard-live` | every query returns data from a real Prometheus holding synthetic samples |
| `make roles-test` | `base` and `users` converge twice in containers, second run `changed=0`, and `report` renders where none of what it reads exists |
| `make harness-up` / `harness-down` | Grafana and Prometheus locally for editing the dashboard |

`make dashboard` matches `node_memory_` and `node_filesystem_` by **prefix**, so a typo inside a real
metric family passes it. `make dashboard-live` is what catches that. Both run in `offline` and in CI.
Do not treat a green `make dashboard` as proof a panel works.

`docker`, `gpu`, `exporters` and `monitoring` are **not** container-testable and are deliberately not
stubbed. A fake that reported success would be worse than no test.

---

## Traps

- **This hardware has no readable RTC, and it breaks `community.general.timezone`.** The kernel logs
  `rtc-efi rtc-efi.0: hctosys: unable to read the hardware clock` at boot, and every read fails with
  EIO, so bare `timedatectl` exits 1. The module treats a non-zero `timedatectl` as "not systemd",
  falls back to a path requiring `hwclock`, and arm64 Ubuntu's `util-linux` ships that binary's
  documentation and not the binary. The converge dies on a box whose clock is perfectly correct.
  `timedatectl set-timezone` writes fine; only reading the clock fails, so `base` compares
  `readlink -f /etc/localtime` and drives the write itself. Do not "simplify" it back to the module.
- **`curl 127.0.0.1:9100` hangs** on this hardware even when node-exporter is healthy. Verify through
  Prometheus.
- **Prometheus publishes on two addresses, and dropping the second silently loses every training
  curve.** Everything else Prometheus does is a scrape it opens itself, so loopback is enough; the one
  inbound flow is remote-write from job containers. Those sit on the default bridge and reach the host
  only at its docker0 address, so `prometheus_docker_bind_address` publishes there as well. With only
  the loopback publish the whole stack still looks healthy — the supervisor's `sparks_*` metrics travel
  by textfile collector and keep arriving, all scrape targets stay `up`, and Grafana talks to
  Prometheus by service name over the compose network. Only `training_*` vanishes, and the job's own
  log is the only place that says so. Diagnose it from inside a container
  (`docker run --rm --add-host=host.docker.internal:host-gateway alpine nc -z -w3 host.docker.internal
  9090`), never from the host, where loopback always answers.
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
- **`docker` deliberately sets no `default-runtime: nvidia`.** `nvidia` is registered as a *named*
  runtime, so `--runtime=nvidia` and `--gpus all` opt in per container. Making it the default would
  inject GPU device nodes and driver libraries into Prometheus, Grafana and every throwaway
  `alpine`, widening a broken toolkit from "GPU jobs fail" to "monitoring fails". Monitoring is the
  thing that has to survive when the GPU plumbing breaks.
- **The GPU is sm_121, so the smoke-test image must be CUDA 13 *and* publish a `linux/arm64`
  manifest.** sm_121 exists only from CUDA 13.0, so most `cu12x` images cannot address it, and
  plenty of images ship amd64 only. `gpu_smoke_test_image` was checked against the registry manifest
  list rather than guessed; changing that tag means checking both properties again.
- **The two filesystem-collector excludes are what stop node_exporter hanging.** Without
  `exporters_node_filesystem_mount_points_exclude` and `exporters_node_filesystem_fs_types_exclude`
  the collector walks the snap loop devices and every Docker overlay and hangs, flapping `up` to 0:
  telemetry reporting its own absence as an outage. They are not tidiness.
- **`$` is written `$$` in the rendered exporter unit.** systemd expands `$` in `ExecStart` and `$$`
  is its documented literal dollar, so the template applies the substitution and the defaults stay
  readable as plain regexes. Debug against the rendered unit file, never against the defaults.
- **Textfile-collector `.prom` files must be `0644`.** node_exporter drops to an unprivileged user,
  so a `0600` file in `exporters_textfile_dir` is skipped with no error anybody notices. Write them
  world-readable, and write them atomically (`mktemp` in the same directory, then `mv`) so a scrape
  never sees half a file.
- **`monitoring_project_name` is load-bearing.** Compose namespaces named volumes by project, not by
  directory: `spark-monitoring_grafana-data` holds every dashboard built by hand in the UI and
  `spark-monitoring_prometheus-data` holds the history. Rename the project and both are silently
  abandoned, full and unreferenced, and the new stack collides with the running one on port 80.
- **Dashboards are installed with `copy`, never `template`.** Grafana's own legend syntax is
  `{{label}}` and Jinja would eat it. That applies to any JSON this repo hands to Grafana.
- **`firmware` gates on `get-updates` exiting 2, and stages with `--no-reboot-check`.** `update`
  exits 0 on a converged box, so gating on its own result would report a change forever; only
  `get-updates` distinguishes "nothing to do", with exit 2. Without `--no-reboot-check`, `fwupdmgr
  update` offers to reboot and a run holding a pty can act on the answer. Neither token is cosmetic.
- **`kernel` uses an apt pin, not a dpkg hold.** A hold only constrains packages that are already
  installed; the failure being prevented is an update pulling in an unsigned image that is not
  installed yet. `Pin-Priority: -1` on `linux-image-unsigned-*` covers every unsigned kernel that
  will ever exist, including ones NVIDIA has not built.
- **`kernel` resolves the image with `dpkg-query`, deliberately not `apt-cache depends`.** apt-cache
  answers for the *candidate* version, so a newer meta package in NVIDIA's archive would become "the
  intended kernel" and `state: present` would install it, an unrequested kernel upgrade on a box
  with a boot-failure history.
- **GRUB is pinned by menu entry id, never by title.** A title carries the distributor string and
  the kernel version in prose, and when it stops matching GRUB does not complain, it boots something
  else. The id embeds the kernel version and the root UUID, and Ubuntu nests per-kernel entries, so
  the saved value is `<submenu id>><entry id>`.
- **`spbm_headers_package` is what makes the module survive a kernel upgrade.** DKMS can only
  rebuild against headers that arrive with the new kernel. Remove that meta package and there is no
  error, just a missing module, and a metric that stopped, after the next kernel.
- **A skipped role leaves its registers undefined, and `default('')` then lies.** `site.yml`'s
  reboot summary asks whether the MOK key is enrolled by reading `spbm_mok_test.stdout`. With `spbm`
  skipped that variable does not exist, `default('')` yields no match, and the box is told to expect
  a MokManager screen that will never appear. Anything reading a `spbm_*` register must test
  `spbm_enabled` first.
- **Jinja unescapes string literals, so `'\1'` inside a `.j2` is `chr(1)`.** `regex_search(x, '\1')`
  then dies with "Unknown argument", which names neither the filter nor the cause. Double every
  backslash in a template: `'\\1'`. YAML task files do not have this problem, which is why the
  pattern copied out of a role breaks when it lands in a template.
- **`default(x, true)` treats a return code of `0` as missing.** The second argument means "replace
  falsy values too", and `rc: 0` is falsy. `report` claimed a tool was not installed on a box where
  it had just run successfully. Only use the boolean form on strings.
- **Neither dashboard check can tell you the Power row is dead.** `make dashboard` allows
  `node_hwmon_` by prefix because the `hwmon` collector is enabled regardless (NVMe
  and SoC temperatures come through it), and `make dashboard-live` passes because
  `tests/fake_exporters.py` synthesises the spbm power, energy and label series. Both are correct:
  they check the panels against a box where `spbm_enabled` is true. Do not "fix" the harness by
  removing those synthetic channels; that would only stop the row being checked at all.

---

## Decisions not to revisit

Rejected on evidence. Re-proposing one costs the same argument again.

- **Do not add a smart-plug exporter back.** One was tried and removed: a second, optional answer to
  a question the firmware already answers on every Spark, costing a role, 8 variables, its own
  scrape job and a `power_scrape_target` indirection whose only purpose was letting it stay
  optional. The wall-socket number it produced is the one thing `sys_total` cannot give you, and
  that was not worth the surface. If you genuinely need PSU conversion loss measured, that is a
  different conversation from "sparkup should report power".
- **Do not add a GPU clock cap or a fan curve.** The measurement this once asked for has been taken,
  and it killed the idea: saturated at the stock cap the limiter is `pl1` at 140 W, not heat, at
  82 °C with 0 µs of thermal slowdown of any kind. See [What the box can actually draw](#what-the-box-can-actually-draw).
  The fan-curve advice circulating for this hardware addresses a throttle this box does not have.
- **2418 MHz is not throttling.** It is `Default Applications Clocks`, i.e. spec. The 3003 MHz
  `Max Clocks` is the top of the clock table and is not a sustained frequency, so the gap between
  them is not headroom and chasing it wastes a session. Dense bf16 peak is 48 SMs × 1024 FLOP/clk,
  about 119 TFLOP/s at 2418 MHz; the "~213 TFLOPS" figure circulating for this hardware is not dense
  bf16 and is the wrong thing to benchmark against.
