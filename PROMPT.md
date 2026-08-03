# sparkup: the DGX Spark as code

## What this is

Ansible that provisions the DGX Spark from a fresh DGX OS install to a working training box:
users, Docker, the NVIDIA container runtime, system monitoring, GPU telemetry, **wall-socket power
measurement**, and the thermal/firmware guardrails this hardware turns out to need.

**Scope is infrastructure.** `sparkup` gets the box into a known state and gets metrics into
Prometheus. It does **not** own training runs. A separate project builds the wrapper that emits
per-run metrics (epoch, loss, throughput) and correlates them against the system and energy series
this repo provides. That design is specified in `docs/training-observability.md`.

Today the box works, but nothing about it is reproducible — the state lives only in a chat log. If
it died tomorrow, rebuilding it would mean rediscovering every trap recorded below. That is the
problem this repo exists to solve.

**Audience correction (2026-07-31, Vlad).** This is a recipe **other people will clone and run on
their own Sparks**, not a config for one machine. Much of what follows is written as "converge
*this* box" and hardcodes `vlad`, `marius` and `/srv/bbm` into `group_vars`; that framing is
superseded. The rule now:

- `group_vars/all.yml` holds only defaults that suit **any** Spark. Identity and site-specific
  paths live in `host_vars/<host>.yml`, which is the one file a newcomer edits.
- Nothing is destructive by default. The playbook does not disable a stranger's services, does not
  reset their firewall, does not pin UIDs, and creates no accounts unless asked.
- Questions in the "Open questions" section that only make sense for *this* box — whether `marius`
  keeps sudo, whether `openvpn` should be off — are not decisions the recipe gets to make. They
  become variables with safe defaults, or they are dropped.

## Working agreement

**The assistant implements. Vlad directs.** Same agreement as `bbm`: Vlad decides architecture,
scope and priorities; the assistant writes the code.

`bbm` is the project this exists to serve. `sparkup` is infrastructure — it must never become the
interesting problem. When a choice is between clever and boring, pick boring.

## Definition of done

`ansible-playbook site.yml -K` against a freshly installed DGX Spark produces a box where:

- `ssh vlad@spark.local` and `ssh marius@spark.local` both work, key-only, both in `docker`
- `http://spark.local` serves Grafana with system, GPU and power dashboards, no login to view
- GPU telemetry is supervised (survives reboot and crashes), including **throttle reasons**
- `docker run --rm --gpus all <cuda13 image> nvidia-smi` works — GPU containers are possible
- wall power and cumulative energy from the Shelly plug are scraped and charted
- `/srv/bbm` exists with the right ownership, ready for the training project
- Running the playbook a second time reports **zero changed tasks**
- `make lint` passes (ansible-lint, production profile)

Idempotence is the acceptance test, not a nicety. A playbook that cannot run twice is a shell
script with extra syntax.

## Status (2026-08-03)

**Converged on the real box, and the second run reported `changed=0`.** The definition of done is
met, except wall power, which needs a plug that does not exist yet.

```
run 1: ok=81  changed=41  failed=0
run 2: ok=72  changed=0   failed=0
```

Verified after converging, through Prometheus rather than by curling anything: `up == 1` for
`node`, `gpu` and `prometheus`; `node_filesystem_avail_bytes` present for the first time (3.76 TB
free on `/`); five `nvidia_smi_clocks_event_reasons_counters_*` series, which is the Phase E signal;
both exporters active as systemd units; the stack serving from `/opt/monitoring` on the pinned
images with the Grafana volume and its dashboard intact; the legacy `gpu-metrics.sh` crontab lines
gone; `nvidia` registered as a Docker runtime and a CUDA 13 container seeing the GPU; `vlad` and
`marius` both in `docker` and `bbm`; `/srv/bbm` setgid. `make spark-parity` still matches on all
four digests across all seven fixtures, so provisioning did not perturb Pillow/freetype.

Nine roles exist and are wired into `site.yml` in this order:

```
base → docker → gpu → users → exporters → shelly → monitoring → thermal → kernel
               (gpu_enabled)              (off)                          (off)
```

What *is* proven, and how:

- `ansible-lint` (production profile) and `ansible-playbook site.yml --syntax-check` pass, on a
  fresh clone with no `host_vars` at all
- `make dashboard` parses all 21 panel queries with real `promtool` and traces all 17 referenced
  metrics back to an enabled exporter, so a panel cannot query a metric nobody emits
- `make roles-test` converges `base` and `users` twice in containers and gets `changed=0`
- `make harness-up` runs Grafana and Prometheus locally against synthetic metrics, so the dashboard
  is editable without a Spark
- CI runs all of the above on every push

What is still **not** proven:

- **A5 `kernel`, partially.** The apt pin and the visible menu are applied and verified; the boot
  target has deliberately not been retargeted (`kernel_manage_grub_default: false`), and no reboot
  has happened yet, so "the box comes back" is still unproven.

  **Open question 2 is answered, and the answer was a trap.** `/boot/grub/grub.cfg` offers 11
  entries and resolved to `hidden / 0`. Writing `GRUB_TIMEOUT=5` and `GRUB_TIMEOUT_STYLE=menu` into
  `/etc/default/grub` did **not** change that: DGX OS ships `/etc/default/grub.d/no-grubmenu.cfg`
  forcing `GRUB_TIMEOUT=0`, `GRUB_TIMEOUT_STYLE=hidden` and `GRUB_RECORDFAIL_TIMEOUT=0`, and
  drop-ins are sourced after the base file, so the vendor wins. `update-grub` ran and the generated
  menu was still hidden. The role now writes `zz-sparkup-menu.cfg`, which sorts last and does not
  modify a vendor file a package update would replace; the menu resolves to `menu / 5`.

  Two things this vindicates. The assertion that the *generated* file resolves to a visible menu,
  rather than trusting the edit, is what caught it — and it caught it **before** the boot target
  moved, which is why that assertion was reordered ahead of `grub-set-default`. And
  `GRUB_RECORDFAIL_TIMEOUT=0` meant a box that had already failed to boot would show no menu on the
  retry, which is precisely when one is worth having.

  Also confirmed: the box already runs the signed kernel `6.17.0-1029-nvidia`, installed as a
  concrete package alongside the meta, with Secure Boot enabled. There was no unsigned kernel to
  escape from. The pin is now effective (`Candidate: (none)` for `linux-image-unsigned-*`), so apt
  cannot install or upgrade one. `linux-image-unsigned-6.17.0-1026-nvidia` is still installed and
  removal stays off.
- **Wall power.** No plug exists, so `shelly` has never run and there is no `power` job.
- **E1 thermal evidence.** The counters are flowing now, but no training run has been observed
  through them, so the fan-curve question is still open.
- **Compose v5 change detection.** `community.docker` scrapes compose stderr against a 2.x
  vocabulary and the box runs v5.0.2, so a false `changed=0` remains possible in principle. Run 2
  reported `changed=0` and the containers were genuinely converged, which is consistent but not
  proof.

**Two claims in this file were wrong, and the converge disproved both:**

- **`ufw` was not enabled. It read `Status: inactive`.** This file said since the audit that it was
  "enabled but its rules are unknown". It was never running, so nothing filtered the LAN, including
  `node_exporter` on 9100 and `nvidia_gpu_exporter` on 9835, both of which bind all interfaces.
  Open question 1 turned into a decision rather than a lookup, and the decision was to switch it on
  (`spark_firewall_enable`, opt-in, default off).

  **Enabling it needed one thing this file never anticipated.** A default-deny incoming policy drops
  Prometheus's scrapes of the host exporters, because Prometheus is a container reaching them
  through the docker bridge gateway and that traffic arrives on the host's INPUT chain. Securing the
  box would have broken its monitoring. The role therefore also allows Docker's address pool
  (`172.16.0.0/12`) to reach those two ports, which keeps the container path open while closing them
  to the LAN. Grafana on 80 is unaffected either way, because Docker's DNAT bypasses ufw for
  published ports. Resulting state, verified: 22 and 80 open to anywhere, 9100 and 9835 open only to
  container subnets, all three scrape jobs `up == 1` with samples 0.0s old, and a repeat converge
  still `changed=0`.
- **The dpkg damage is gone.** `curl` and `ufw` both read `ii`, and no package is in a non-normal
  state. The interrupted apt transaction was resolved at some point between the audit and the
  converge. No repair was needed and none was performed.

Phases C (training observability) and D2 (per-run energy correlation) are out of scope here and
specified in `docs/training-observability.md`. D0 needs a plug that has not been bought. E1 needs a
real training run. A5 needs someone standing next to the machine.

## Decisions already made (do not re-litigate)

**Ansible, not shell or Nix.** The box is a mutable vendor image (DGX OS) that NVIDIA updates
aggressively; declarative-immutable tooling fights that. Ansible converges what exists.

**A flat single-host project layout, not a collection.** Collections are a distribution format.
One host, one repo, `roles/` at the top level. No `galaxy.yml`.

**Prometheus + Grafana in Docker; exporters on the host.** Prometheus and Grafana are containers
(official arm64 images, config templated by Ansible). Exporters run as **host systemd units**, not
containers. Both reasons were learned the hard way on this box:

- A containerized node-exporter needs `/:/host:ro,rslave`, and that mount makes the filesystem
  collector recurse every Docker overlay and **hang** — `up` flaps to 0. Verified here. Native
  install removes the mount and the problem, and gives back disk metrics.
- A containerized GPU exporter needs GPU-in-container plumbing, the least reliable piece of the
  stack. Monitoring must not depend on the thing most likely to break.

**`nvidia_gpu_exporter`, not DCGM.** NVIDIA states DCGM does not support Spark and there are no
plans to. On GB10 `nvmlDeviceGetMemoryInfo` returns `NVML_ERROR_NOT_SUPPORTED` (unified memory, no
discrete framebuffer), so the `DCGM_FI_DEV_FB_*` family is broken and utilization reports mirrored.
`utkuozdemir/nvidia_gpu_exporter` wraps `nvidia-smi --query-gpu`, exporting exactly what works.

**GPU memory is a host memory metric.** On unified memory there is no separate GPU memory —
`nvidia-smi` prints `[N/A]`, and that is correct, not a bug to route around. `node_memory_*` **is**
the GPU memory signal. Dashboards must say so in the panel description, or someone spends an
afternoon "fixing" a missing panel.

**Energy is measured at the wall, not read from the GPU.** This box has **no internal path to
system power** — confirmed by measurement here and stated three times by NVIDIA staff (see below).
`nvidia-smi` reports a GPU rail only, which underreports the wall by roughly **2×** (87 W observed
vs 180 W measured at the socket). A smart plug is not a workaround, it is the only correct
instrument for cost: it captures CPU, memory, NVMe, fans and PSU conversion loss, which is what the
electricity meter charges for.

**GPU-rail energy is still worth recording, as a second series.** NVML exposes an exact cumulative
counter (`nvmlDeviceGetTotalEnergyConsumption`); the plug gives the wall. Together they answer a
question neither answers alone: what fraction of a run's cost was the GPU actually doing work,
versus the box merely being switched on.

**Runs are serialized, and that is a correctness requirement.** A wall meter measures the whole
box. Attribution to a run is only valid if one run owns the machine. The job queue is therefore
load-bearing, not a convenience: overlapping runs silently corrupt every energy number.

**One templated dashboard with a `run_id` variable — never a dashboard per run.** Grafana's own
best-practices doc says it outright: *"you don't need a separate dashboard for each node, you can
use query variables"*, and names dashboard sprawl as a cost. k6 ships two dashboards for unlimited
test runs. A `var-run_id` deep link gives the user a URL showing exactly one run; they cannot tell
it is shared, and comparison comes free from `multi: true`. No maintained project anywhere
generates a dashboard per run — that absence is the answer.

**Prometheus remote-write for training metrics, not Pushgateway.** Pushgateway deliberately
discards timestamps — per-step loss collapses to the scrape interval and only the last value per
scrape survives — and has no staleness lifecycle, so a finished run shows its last value forever.
Remote-write records every logged step at its true millisecond. This is what k6 does.

A pull endpoint (`prometheus_client.start_http_server`, as Axolotl does) is the simpler fallback,
but it **samples at scrape time**: with `logging_steps=1` and sub-second steps, a 5 s scrape aliases
most of the curve away. Prometheus 3.x's native OTLP receiver (`--web.enable-otlp-receiver`) is a
third option that also preserves explicit timestamps. Remote-write stays the default because it is
the k6-proven path; the others are documented fallbacks, not open questions.

**Ansible never flashes firmware.** Config management that flashes an EC on every converge is how
a box gets bricked unattended. The role *asserts* the version, reports drift, and pins the
auto-update path. Flashing stays a manual, deliberate, Vlad-present runbook.

**Prometheus and Grafana stay on their current ports.** Grafana on 80 (so `http://spark.local`
needs no suffix, anonymous Viewer). Prometheus bound to `127.0.0.1:9090`. Do not "improve" this.

**Retention: 30 days in Prometheus; the durable archive is on disk.**
*(This supersedes an earlier decision in this file to set 1-year retention.)* `run_id` is an
unbounded label over time — Ray's metrics agent actively filters high-cardinality labels for
exactly this reason. Keeping every per-step series for a year is the wrong shape. Instead: 30 d of
full-resolution series, and the launcher writes a per-run `summary.json` to `/srv/bbm/runs/<id>/`
plus a Grafana **snapshot** for runs worth keeping. A snapshot embeds its data, so it outlives
retention — a `from`/`to` link does not.

**Secure Boot stays enabled.** The fix for the unsigned-kernel boot failure is to install the
signed kernel and point GRUB at it, not to disable Secure Boot. NVIDIA's own Aerial-on-Spark doc
tells people to disable it; we are not doing that.

## Measured facts about the box (audit 2026-07-31)

Read-only audit over SSH. These are facts, not estimates — the playbook must converge *this* box.

| | |
|---|---|
| Host | `spark`, `spark.local` via avahi, **192.168.1.140** (static DHCP reservation on the router) |
| OS / kernel | Ubuntu 24.04.4 LTS, `6.17.0-1029-nvidia`, aarch64 |
| GPU | NVIDIA GB10, driver 580.173.02, CUDA 13.0, sm_121, persistence mode on |
| CPU / RAM | 20 cores (10× Cortex-X925 + 10× Cortex-A725), 121 GiB unified, 15 GiB swap |
| Disk | one NVMe 3.7 TB, `/` only — **no separate `/home`**, 65 GB used (2%), plus 13 snap loops |
| Network | **WiFi only** (`wlP9s9`); no wired IPv4. NetworkManager. One SSID on both bands |

**Users.** `vlad` (1000): `sudo`, `docker`, `adm`, one `ssh-rsa` key. `marius` (1001): `sudo`,
**not in `docker`** — a real gap to fix. No passwordless sudo for either.

**Docker.** 29.2.1, compose plugin v5.0.2. Runtimes: `runc` only — **the `nvidia` runtime is not
registered**, `/etc/docker/daemon.json` does not exist, `/etc/cdi` and `/var/run/cdi` do not exist.
`nvidia-ctk` 1.19.1 and `/usr/bin/nvidia-container-runtime` are installed. GPU containers are
currently impossible; the monitoring stack is built to avoid needing them.

**Running now.** `prometheus` (`127.0.0.1:9090`, 30 d), `grafana` (`80→3000`, anonymous Viewer,
home `spark-overview`), `node-exporter` (host network, textfile collector, explicit collector list,
no `/host` mount). Stack in `/home/vlad/monitoring/`. Image `utkuozdemir/nvidia_gpu_exporter` is
pulled but unused.

**GPU telemetry today.** `~/monitoring/gpu-metrics.sh` — a bash loop calling `nvidia-smi` every 5 s
into `~/monitoring/textfile/gpu.prom`, launched from vlad's crontab under `flock -n` every minute
and `@reboot`. It works, but cron+flock+bash is not supervision. The `exporters` role replaces it.

### Power telemetry: what does not exist (measured, not assumed)

| source | result |
|---|---|
| `nvidia-smi --query-gpu` energy | **no such field** — but see the correction below; this is true on *every* platform, not a GB10 gap |
| **NVML cumulative energy** | **works — tested here.** `nvmlDeviceGetTotalEnergyConsumption` returned 10024 mJ over 3 s → 3.34 W, cross-checking `PowerUsage` 3.38 W. mJ, resets on driver reload, **GPU rail only** |
| NVML **module** power scope | **`NVML_ERROR_NOT_SUPPORTED` (3) — tested here.** `nvmlDeviceGetFieldValues(POWER_INSTANT, scope=MODULE)` fails while `scope=GPU` returns 3.363 W. GB10 exposes no module scope |
| `nvidia-smi` GPU power | works — `power.draw`, `.average`, `.instant` (32–58 W observed) |
| `nvidia-smi` **Module** power | **N/A** — GPU rail only. (The nvidia-smi manual scopes `Module Power Readings` to "Hopper and newer **datacenter** products"; our N/A reading is the direct evidence that GB10 is excluded) |
| hwmon power / energy rails | **none** (only `acpitz`, `nvme`, `mt7925_phy0` — temperatures) |
| INA3221 / INA2xx | no drivers bound |
| `tegrastats` | not present |
| `/sys/class/power_supply` | empty |
| IPMI | `ipmi_devintf` + `ipmi_msghandler` loaded but **no `/dev/ipmi*` device** |
| BMC / Redfish | **no `bmc_redfish0` interface**; only USB root hubs. `configure-redfish-intf.bash` is generic DGX-server tooling that finds nothing here |
| ACPI power meter | `acpi_power_meter.ko` exists but is **not loaded**; the first-boot service never wrote `enable-power-meter-cap.cfg` and the flag is absent from `/proc/cmdline`. `modprobe acpi_power_meter` yields **no device** (tested) |

**Correction to an earlier claim in this file.** I first reported "no cumulative energy counter
exists" after `nvidia-smi --query-gpu=total_energy_consumption` returned *"not a valid field"*. That
was the wrong inference: **nvidia-smi has no energy query field on any platform** — energy lives in
the NVML API, not the CLI. `nvmlDeviceGetTotalEnergyConsumption` (millijoules, Volta and newer,
resets on driver reload) is almost certainly available here: a community GB10 audit confirms the
DCGM field backed by it (`DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION`, id 156) reading correctly at
3471 mJ/s against 3.5 W idle. **It covers the GPU rail only.** Consequence for D2: GPU-attributed
energy can be read exactly from a counter instead of integrated — verify with `pynvml` first.

**Conclusion: there is no internal route to *system* watts.** NVIDIA staff have confirmed this
three separate times on the developer forums: *"When measuring power usage via NVIDIA-smi, the
wattage displayed measures only GPU power"*; *"There is no method to monitor CPU power and
currently no plans to expose CPU rail information."* The published split is **240 W total system,
140 W GB10 SoC TDP (CPU+GPU), 100 W for ConnectX-7 / SSD / USB-C provisioning**.

**The size of the gap, measured by others:** peak **87 W** via nvidia-smi against **180 W at the
wall**; reviewers report ~170 W wall under heavy load and 40–45 W idle. So the GPU rail
underreports true consumption by roughly **2×** — not the 3–5× I estimated before finding these
numbers. Still far too large to cost from, and non-linear, since idle overhead dominates at low
GPU load. Hence the smart plug.

**One internal path exists but is deferred: `spark_hwmon`** (https://github.com/antheas/spark_hwmon).
A reverse-engineered ACPI driver that binds `NVDA8800` and reads the System Power Budget Manager
region maintained by the MediaTek SSPM firmware, exposing **14 power channels** — including
`sys_total` (~25 W idle) and `dc_input` — plus **four cumulative energy accumulators in mJ** and
writable power caps. That is genuinely whole-system telemetry. **Not adopted**, for reasons that
should be revisited rather than forgotten: the author labels it "vibe coded", the SPBM layout is
"still in flux", it needs a `fwupd`-updated BIOS, and as an out-of-tree module it requires **MOK
enrollment under Secure Boot** — on a box that has already failed to boot once over signature
problems. It is also reported failing on the GX10 sibling over a firmware resource conflict.
Interesting later for *per-rail attribution* (how much of a run is CPU vs GPU); never the
cost-of-record.

### Thermal and firmware state

```
EC firmware       0x03000302   (device 8c948e1db381648c8893897e4d09b7b153309991)
  Minimum Version 0x02003400   ← a rollback to 0x02004e18 is above the floor, so fwupd permits it
UEFI              0x0200980f
fwupd             2.0.20 ; fwupd-refresh.timer ENABLED (hourly)
```

Throttle counters after 20 h uptime **including training**:

```
SW Thermal Slowdown  :           0 us
HW Thermal Slowdown  :           0 us
SW Power Capping     : 23224548995 us   ← 6.45 hours
```

`GPU Shutdown / Slowdown T.Limit` all read **N/A**; `Max Operating` reads `0 C`. Idle observed at
43 °C, 3.26 W, 208 MHz; `clocks.max.sm` is 3003 MHz.

**Read this carefully before acting on community thermal advice.** The EC firmware version does
match the one the community associates with a broken fan curve, and that is worth taking
seriously. But on *this* unit the measured limiter so far is the **power cap**, not temperature:
zero microseconds of thermal slowdown against 6.45 hours of power capping. The often-quoted
"74 °C with 17 °C of headroom" is also not verifiable here, because the thermal limit registers
read N/A. Unit-to-unit variance on Spark is reportedly 10–15 °C, so this is a claim to test on our
hardware, not to inherit. **Instrument first, then decide** — Phase E.

**Traps found the hard way — do not rediscover these:**

- **SSH is socket-activated.** `ssh.socket` is enabled and active; `ssh.service` is *disabled*.
  Manage `ssh.socket`. Restarting `ssh.service` is a no-op that looks like success.
- **`curl 127.0.0.1:9100` hangs on this box** even when node-exporter is healthy. Verify exporters
  through Prometheus (`up`, `scrape_samples_scraped`), never by curling the exporter locally.
- **`ufw` is enabled but its rules are unknown** (needs root). Read, then codify.
- Textfile `.prom` files must be world-readable — node-exporter runs as `nobody`.
- **Grafana `kiosk` must be a bare flag.** `&kiosk` works; `&kiosk=` silently disables it.

**DGX platform services** (leave alone, but know they exist): `dgx-dashboard` (NVIDIA's own local
monitoring on `127.0.0.1:11000`, SPA behind auth), `dgx-release`, `nvidia-persistenced`,
`nv-cpu-governor`, and `nvidia-*` tuning oneshots. Also enabled and unexpected on a training box:
`openvpn`, `samba-ad-dc`, `gnome-remote-desktop`, `cloud-init`, `kdump-tools`, cups, snapd.

## Prior art: what exists, what does not

Researched 2026-07-31. Two findings shape the build.

**There is no experiment→Prometheus bridge library.** PyPI has nothing maintained (15 plausible
package names probed); GitHub search surfaces only student MLOps projects. MLflow's
`prometheus_exporter.py` is a **red herring** — 18 lines wrapping `prometheus_flask_exporter`, it
exports HTTP request latencies of the tracking server and not one logged metric. PyTorch Lightning
has no Prometheus logger. W&B and Aim expose server metrics only. **The ~50-line piece is the part
that does not exist; everything around it does.**

**The one good reference implementation** is Axolotl's `OpenTelemetryMetricsCallback` (~240 lines,
12 k-star repo, active): an HF `TrainerCallback` that wires an OTel `SDKMeterProvider` with
`PrometheusMetricReader` and sets gauges on `on_log`. Copy its structure — and fix its two flaws:
it emits **no run labels at all** (every run produces identically-named series, so runs are
indistinguishable) and hardcodes one HTTP port per process, so concurrent runs collide.

**Ray is the closest off-the-shelf alternative** and was seriously considered: single-node, no
Kubernetes, aarch64 wheels confirmed, and it ships a job queue, run IDs
(`ray_train_run_name`/`run_id`), six Grafana dashboards and embedded Grafana. **Rejected** for this
box because its Train dashboard has *not one panel showing loss* — `tune.report()` metrics never
reach Prometheus (open Ray issue since 2021) — so we would still write the loss gauge ourselves,
and we would carry a ~1 GB-idle distributed-computing runtime to get a queue we can have from a
6 MB Rust binary. Revisit only if multi-node ever happens.

**Everything Kubernetes-shaped is out**: Kubeflow, Katib, Flyte, KAI/Run:ai, SkyPilot's GPU metrics
(needs a k8s Service). **Determined AI** is architecturally the closest thing to this design — and
is dead, last commit 2025-03. Steal its idea of keeping run identity in a *separate* info-metric
joined in PromQL, do not deploy it.

**Label conventions converged everywhere** on `{run_id}` on the series plus a `_info` metric for
metadata, with `label_values(<info metric>, run_id)` driving a Grafana variable.

## What bbm expects (the integration contract)

`sparkup` provisions the box that `bbm` drives, and must not break `bbm`'s own remote-control layer.

`bbm/scripts/spark.sh` (driven by `make spark-info|bootstrap|sync|check|parity|shell|gpu`):

- Connects to `${BBM_SPARK_HOST:-vlad@spark.local}` — **keep the hostname and the `vlad` account.**
- Hardcodes `$HOME/.local/bin/uv` in every remote invocation (a non-login SSH shell lacks it on
  PATH). **Do not relocate or replace uv** (0.12.0, managed CPython 3.12.13).
- Syncs to `${BBM_SPARK_DIR:-~/bbm}` with `rsync -az --delete` and a **hardcoded** exclude list
  (`.git/ .venv/ .claude/ __pycache__/ *.pyc dist/`). It does *not* read `.gitignore` and does
  *not* exclude `data/` or `checkpoints/`.

  **Consequence, load-bearing: `rsync --delete` owns `~/bbm`.** Anything written under `~/bbm`
  that is not in the laptop tree is deleted on the next `make spark-sync`. **All training
  artifacts — datasets, checkpoints, logs, run metadata — live outside `~/bbm`**, in
  `/srv/bbm/{data,checkpoints,runs}`.
- `make spark-parity` compares `scripts/platform_digest.py` between laptop and box across
  `geometry`, `verdict`, `grid` and `raster` digests for the 7 fixtures, **exiting 1 on any
  disagreement**. It depends on the Pillow and freetype builds `uv sync --frozen` resolves;
  `bbm/src/bbm/raster.py` already pins `ImageFont.Layout.BASIC` because the Linux aarch64 Pillow
  wheel bundles Raqm and the macOS one does not (76 of 504000 pixels differed on p0 before the pin).

  **So: do not install system Pillow, freetype or fontconfig packages that could shadow the
  wheel's bundled libraries.** Run `make spark-parity` after the first full playbook run and treat
  a regression as a sparkup bug.

`bbm` is greenfield on observability — no `grafana`, `prometheus`, `wandb` or `tensorboard` anywhere.
Metric sources it already produces:

- `bbm.verify.verify(model) -> Report` with `Report.ok` / `Report.failures`. **This is the stage-6
  GRPO reward surface** — streaming it is on the roadmap, not speculative.
- `bbm.stats.corpus_stats(...).as_dict()`; `bbm.grid.build_grid` / `Grid` (the JSONL training rows,
  with `meta.topic` / `meta.rhythm` curriculum labels).
- CLI exit codes: `bbm verify` → 0 pass, 1 wrong geometry, **2 unreadable input**.

**Network egress matters:** the first use of a real tokenizer fetches from `huggingface.co`. The
proxy counter undercounts gesture commands 1.50–1.80×, whole scenes inflate 10–18% (worst +48%).

## Repo layout

```
sparkup/
├── README.md
├── PROMPT.md                    ← this file
├── Makefile                     lint, check, apply, apply-check, ping
├── ansible.cfg
├── requirements.yml             collections, version-pinned
├── .ansible-lint                profile: production
├── inventory/hosts.yml
├── group_vars/all.yml           image tags, ports, retention, users, tariff
├── host_vars/spark.yml
├── site.yml
├── roles/
│   ├── base/                    hostname, avahi, timezone, apt hygiene, firewall
│   ├── users/                   vlad + marius, keys from GitHub, sudo, docker group
│   ├── docker/                  packages, daemon.json (incl. nvidia runtime), group
│   ├── gpu/                     container toolkit, CDI spec, GPU smoke test
│   ├── kernel/                  signed-kernel pin, unsigned apt-pin, GRUB default
│   ├── thermal/                 clock-cap unit, fwupd pinning, EC assertion
│   ├── exporters/               node_exporter + nvidia_gpu_exporter + shelly, systemd
│   └── monitoring/              prometheus + grafana containers, provisioning, alerts
```

*(An earlier version of this layout also listed `roles/scheduler/`, `roles/training_obs/` and
`files/trainobs/`. Phase C and the scheduler are both out of scope — see below — so those are
gone. The file manifest table near the end of this document is the accurate list.)*

`ansible.cfg`: `inventory = inventory/hosts.yml`, `roles_path = roles`,
`interpreter_python = auto_silent`, `[ssh_connection] pipelining = True`.
Run `ansible-playbook site.yml -K`. Never enable passwordless sudo to skip the prompt.

## Phase A — the box as code

Ordered. Each task ends: run it, run it **again**, confirm the second run reports `changed=0`.

### A0: Scaffold
`ansible.cfg`, inventory, `group_vars/all.yml`, `requirements.yml` (pin `community.docker`,
`community.general`, `ansible.posix`), `.ansible-lint` with `profile: production`, `Makefile`
(`lint`, `check` = `--check --diff`, `apply`, `ping`). FQCNs everywhere.
**Verify:** `make lint` clean; `ansible spark -m ansible.builtin.ping` succeeds.

### A1: `base`
Hostname `spark` + the `127.0.1.1` line; avahi enabled (this publishes `spark.local` — the whole
access story depends on it); timezone; `rsync`, `curl`, `util-linux`, `python3-apt`.

**Firewall — read before writing.** `ufw` is enabled with unknown rules. First task: read the state
with root and record it in the role README. Then codify: allow 22 and 80; keep 9090/9100/9835 off
the LAN. Do not blanket-reset `ufw` — locking yourself out of a WiFi-only box means walking to it.

**Do not touch** `dgx-*` / `nvidia-*` platform units. List the surprising services
(`openvpn`, `samba-ad-dc`, `gnome-remote-desktop`) for Vlad; disable nothing without a decision.

### A2: `users`
`vlad` (1000) and `marius` (1001), shell `/bin/bash`, groups `sudo` + **`docker`** (marius lacks
`docker` today — this closes it). Keys via `ansible.posix.authorized_key`, marius's pulled from
`https://github.com/<their-username>.keys`. `exclusive: false` — never orphan a working key. Docker
group membership needs a reconnect; use `meta: reset_connection` if a later task depends on it.
Also create group `bbm` containing both, for `/srv/bbm`.

### A3: `docker`
**Least change.** Docker 29.2.1 and compose v5.0.2 ship with the vendor image. `state: present`,
never `latest`; only add Docker's apt repo when Docker is absent (so a fresh box still converges).
Check `apt-cache policy docker-ce` first and record what the vendor ships.

The load-bearing piece is `/etc/docker/daemon.json`, templated, **single owner**:

```json
{
  "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "runtimeArgs": [] } },
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
```

**Do not set `default-runtime: nvidia`** — every container would get GPU injection, Prometheus and
Grafana included. Log rotation is not incidental: unbounded json-file logs on a box running long
jobs is a slow disk leak.
**Verify:** `docker info` lists the `nvidia` runtime; monitoring containers return after the
restart (`restart: unless-stopped` should do it — confirm, don't assume).

### A4: `gpu`
`nvidia-container-toolkit` present (let DGX OS own the version). Generate the CDI spec with
`nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`, guarded for idempotency; enable
`nvidia-cdi-refresh` if the toolkit provides it so the spec regenerates after driver updates.

**Correction found during implementation — `nvidia-cdi-refresh` is two units, and enabling it
naively breaks CDI.** The toolkit ships `nvidia-cdi-refresh.path` *and* `nvidia-cdi-refresh.service`,
both disabled, both dpkg conffiles from `nvidia-container-toolkit-base`. The `.path` is the trigger
and is the one to enable. The `.service` hardcodes
`NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=/var/run/cdi/nvidia.yaml`, so enabling it as shipped writes a
**second** spec alongside ours — and the CDI cache *drops* any device that two specs both claim, so
`nvidia.com/gpu=all` stops resolving precisely because the refresh worked. Point it at our path
using the vendor's own override file, `/etc/nvidia-container-toolkit/nvidia-cdi-refresh.env`, which
already exists with that line commented out.

This also justifies `/etc/cdi` over the vendor default for a reason not stated above: `/var/run` is
tmpfs, and `PathChanged` does not fire at boot, so a spec written there is simply gone after a
reboot.

**Smoke test as a real task:** `docker run --rm --gpus all <cuda13-arm64 image> nvidia-smi` must
succeed, asserted on output. The image must be CUDA **13**-based and arm64 — sm_121 exists only in
CUDA ≥ 13.0, so most `cu12x` images will not run.

### A5: `kernel` — the Secure Boot fix
The box already failed to boot from this once. Order matters; never remove a kernel before its
signed replacement is installed and GRUB retargeted.

1. Ensure the signed image is installed (`linux-image-<ver>-nvidia`, no `unsigned` infix) plus
   `linux-image-nvidia-hwe-24.04`.
2. Point GRUB at it. Prefer `GRUB_DEFAULT=saved` + `grub-set-default`, idempotency-guarded with
   `grub-editenv list`, over pinning a menu-entry title (titles change; the pin rots silently).
   Handler: `update-grub`.
3. Keep unsigned kernels out permanently with an apt pin — declarative, and unlike `dpkg` holds it
   applies to packages not yet installed:
   ```
   # /etc/apt/preferences.d/no-unsigned-kernels
   Package: linux-image-unsigned-*
   Pin: release *
   Pin-Priority: -1
   ```
4. Remove `linux-image-unsigned-6.17.0-1026-nvidia` **only** once confirmed running a signed
   kernel. List packages explicitly; never glob-remove kernels.
5. Assert `mokutil --sb-state` enabled and `ansible_kernel` matches the intended version.

**Also raise `GRUB_TIMEOUT`** from 0 to ~5. A hidden menu on a box with a boot-failure history
means the only recovery is guessing when to hold a key.

**Honest uncertainty:** the packaging split and Secure-Boot default are confirmed and this box hit
the failure, but there is no published post-mortem of a Spark broken *specifically* by an update
swapping signed→unsigned. Step 3 is cheap insurance. Reported Spark boot hangs (EFI-stub, GSP
timeouts) are driver/firmware issues, **not** signature ones — do not misdiagnose one as the other.

### A6: `exporters` — native, supervised
Retire the cron + flock + bash approach entirely.

**`node_exporter`**: arm64 binary, `node_exporter` system user, systemd unit (`Restart=always`).
Today's collectors plus the **filesystem** collector — the reason disk metrics are missing:

```
--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/snapd/.+)($|/)
--collector.filesystem.fs-types-exclude=^(autofs|overlay|squashfs|tmpfs|devtmpfs|nsfs|cgroup.*)$
```

The 13 snap loops and Docker overlays are exactly what hangs it. Keep a textfile directory at
`/var/lib/node_exporter/textfile` for ad-hoc metrics.

**`nvidia_gpu_exporter`**: `utkuozdemir/nvidia_gpu_exporter` arm64 binary (1.13.x) as a systemd
unit on `:9835`, `Restart=always`. Metrics: `nvidia_smi_utilization_gpu_ratio`,
`nvidia_smi_temperature_gpu`, `nvidia_smi_power_draw_watts`, `nvidia_smi_clocks_current_*_hz`.
Memory metrics will be absent/NaN on GB10 — expected.

**Add throttle-reason metrics.** `nvidia-smi` exposes `clocks_throttle_reasons.*` and the event
counters as queryable fields. These are what turn the thermal question (Phase E) from forum lore
into our own data, so they are not optional.

**Naming correction, verified against driver 580.173.02 on this box.** `--help-query-gpu` lists both
spellings on one line: `clocks_event_reasons.*` is the current name and `clocks_throttle_reasons.*`
is a deprecated alias. Use the former. There is also a second family this document did not know
about, with **no** `throttle` alias — `clocks_event_reasons_counters.{sw_power_cap,
sw_thermal_slowdown, hw_thermal_slowdown, hw_power_brake_slowdown, sync_boost}` — the cumulative
microsecond counters. Those are the honest Phase E signal: a temperature reading is a snapshot, a
rising slowdown counter is proof of lost work.

Then delete `~/monitoring/gpu-metrics.sh` and both crontab lines, migrating dashboards to the new
metric names **in the same change** — never leave a window where panels query metrics nobody emits.

**Verify through Prometheus, not curl:** `up{job="node"} == 1`, `up{job="gpu"} == 1`,
`scrape_samples_scraped > 0`; `node_filesystem_avail_bytes{mountpoint="/"}` present; reboot and
confirm both units return.

### A7: `monitoring` — Prometheus + Grafana as code
Move the stack from `/home/vlad/monitoring` to `/opt/monitoring` (root-owned; a service stack does
not belong in a user's home, and must not be reachable by anything that rsyncs).

Templates → `notify: Restart monitoring stack`:
- `compose.yml.j2` — prometheus + grafana only. **Pin image tags** in `group_vars`, never `latest`.
- `prometheus.yml.j2` — jobs `prometheus`, `node` (`:9100`), `gpu` (`:9835`), `power` (Phase D).
  Flags: `--web.enable-remote-write-receiver`, `--storage.tsdb.retention.time=30d`,
  `--web.enable-lifecycle`.
- Grafana provisioning: datasource (uid `prometheus`), dashboard provider, dashboards via `copy`.
  Preserve today's env: anonymous Viewer, dark, home `spark-overview`, port 80.

Apply with `community.docker.docker_compose_v2` (`project_src: /opt/monitoring`, `state: present`,
`pull: missing`, `remove_orphans: true`, `wait: true`); handler uses `state: restarted`. The handler
is required because bind-mounted config changes do not change the compose file. Never use
`state: restarted` in a regular task — it is deliberately non-idempotent. Prefer `POST /-/reload`
for Prometheus config.

Grafana keeps its named volume so hand-made dashboards survive; provisioned dashboards stay
file-owned with `allowUiUpdates: true`.

## Phase B — dashboards

### B1: `spark-overview`, migrated
Port to the native exporters' metric names and add what was missing: GPU util/temp/power/clock;
**memory panel explicitly titled as unified GPU+CPU memory** with a description explaining why no
GPU-specific memory metric exists; CPU busy, load, uptime, all hwmon temperatures; **disk usage**
(newly possible), including `/srv/bbm`; and an **exporter-health row** (`up` per job,
`scrape_duration_seconds`). When telemetry lies, the first question is whether the exporter is alive.

### B2: dashboards as files
All dashboards live in `roles/monitoring/files/dashboards/*.json`, provisioned. A dashboard edited
only in the UI is not code and will be lost. Document the round-trip: edit in UI → export JSON →
commit. `grafanalib` is stale (no release since Jan 2024, maintainers asking for help) and the
official Foundation SDK is still "public preview" with confusing PEP 440 epoch versioning — for a
handful of dashboards, hand-write the JSON and `POST /api/dashboards/db` with `overwrite: true`
and a stable `uid`. Reach for the SDK only at 10+ dashboards sharing panel logic.

## Phase C — training observability

**Moved out of scope.** A separate project owns the training wrapper: per-run metrics (epoch, loss,
lr, tokens/sec), correlation of those runs against the system and energy series, the runs index and
the per-run dashboards. The full design — remote-write ingestion, the `TrainerCallback`, the
heartbeat metric, run-scoped dashboards, annotations, and the energy correlation — is specified in
`docs/training-observability.md` so that project starts from a spec rather than from scratch.

**What sparkup owes it**, and must therefore not break:

- Prometheus with `--web.enable-remote-write-receiver`, so a run can push per-step samples with
  true timestamps
- Grafana with a provisioned Prometheus datasource and anonymous Viewer on port 80
- live `node`, `gpu` and `power` scrape jobs
- `/srv/bbm/{data,checkpoints,runs}`, group `bbm`, setgid — **outside `~/bbm`, because
  `rsync --delete` owns that directory** (see the bbm contract above)

**Deferred with it: the scheduler.** One machine, two users. A cluster scheduler (Nomad) was
investigated and is over-scaled for a single node — its placement machinery solves a problem that
does not exist here. A shared `pueue` daemon or a plain `flock` lease will do, and the choice can
wait until the training wrapper exists and the need is real. Recorded so it is not re-litigated:
Nomad's own documented single-node mutex is `resources.cores` set to the node's full
`cpu.reservablecores`, which is scheduler-enforced and needs no device plugin — worth knowing if
this is ever revisited.

**One invariant survives the deferral:** if energy figures are to mean anything, one run must own
the box at a time. Whatever enforces that, the wrapper should record `contended=true` when it
cannot be guaranteed, rather than emitting a number that looks trustworthy and is not.

## Phase D — energy and cost

### D0: the meter
**Shelly Plug M Gen3** (Vlad's choice, verified suitable): 13 A / 3000 W, CEE 7/3 Schuko output +
CEE 7/7 plug — correct for Romania, with vast headroom over a ~240 W box. Gen3 local RPC, no cloud.

`GET /rpc/Switch.GetStatus?id=0` returns `apower` (W), `voltage`, `current`, `freq`, and
**`aenergy.total` in watt-hours** plus `aenergy.by_minute`.

**Use the cumulative counter, not the power gauge.** `aenergy.total` is integrated by the hardware,
so energy is exact rather than an artefact of our scrape interval, and Prometheus's counter
handling copes correctly when it resets on device reboot.

Setup tasks: join the house SSID (2.4 GHz — the plug is 2.4-only, same subnet), give it a **DHCP
reservation** on the router exactly as the Spark has, **plug only the Spark's PSU into it** (a
monitor on the same socket silently corrupts every run's energy), and **disable the relay** in the
device config — this model switches as well as meters, and a stray tap in the Shelly app would cut
power to a running job.

Measuring at the wall is the right place: it captures PSU conversion loss, which is what the
electricity meter charges for and what `nvidia-smi` can never see.

### D1: the exporter
Three maintained options exist ([webdevops/shelly-plug-exporter](https://github.com/webdevops/shelly-plug-exporter),
[geerlingguy/shelly-plug-prometheus](https://github.com/geerlingguy/shelly-plug-prometheus),
[easimon/shelly-exporter](https://github.com/easimon/shelly-exporter)), all using the local API.
Pick one, run it as a systemd unit or container, scrape as job `power`. **This is configuration,
not new code.**

Assert at least: instantaneous watts as a gauge and cumulative Wh as a **counter** (`_total`
suffix). If the chosen exporter only exposes the gauge, prefer a different one — the counter is the
whole point.

**Unknown, flag it:** low-load accuracy is unpublished for this model. It will not matter under
load (tens to hundreds of watts), but it means the *idle baseline* carries more relative error than
the loaded figure. Record the caveat next to the number rather than pretending precision.

### D2: correlation — a time-range join, not a label join
**Owned by the training-observability project, not by `sparkup`.** What `sparkup` owes it is the
`power` scrape job; the per-run join is the launcher's job. The full specification, including the
`training_run_*_wh` series and the PromQL, is in `docs/training-observability.md`.

The plug measures the whole box and **can never carry a `run_id` label**. Attribution is by time
window, which is why runs must be serialized (see Decisions; the scheduler that was to enforce it
is deferred along with Phase C).

**Live:** the plug series is simply a panel on the run dashboard; because the dashboard's time
range is pinned to the run, it already shows exactly that window. No machinery.

**Durable:** at run end the launcher queries Prometheus over `[start, end]` and writes back
per-run summary series — one sample per run, cheap forever.

*(An unclosed code fence used to sit here, which is why the block of `training_run_energy_wh`
metric definitions ended up stranded in `docs/training-observability.md` instead. That is where
they belong anyway, since the launcher writes them.)*

## Phase E — thermal, and the firmware question

**Instrument before acting.** The measured state (above) shows zero thermal throttling and 6.45 h
of power capping, so the community fan-curve advice is a hypothesis about our hardware, not a
finding on it.

### E1: measure
Throttle-reason metrics land in A6. Add Grafana alerts on sustained GPU temperature and on
thermal-slowdown counters *increasing* (the counters are the honest signal — a temperature reading
is a snapshot, a rising slowdown counter is proof of lost work). Then run one real training job and
look at the trace. This costs a day and nothing else, and turns forum lore into our own data — the
same instinct as `bbm`'s "measure it, don't assume".

### E2: clock cap — safe, ship it regardless
`nvidia-smi -lgc 300,2200` as an Ansible-managed systemd unit (idempotent, reversible, survives
reboot; the setting itself does not). Worth having for unattended overnight runs whatever the
thermal verdict: it trades a little compute headroom for a guarantee against thermal shutdown
mid-run. Cheap for bandwidth-bound work (measured 243 GB/s is the bottleneck, not clocks); a real
but modest cost for compute-bound training. **Make it a toggle in `group_vars`, default off until
E1 produces evidence.**

### E3: pin fwupd, never flash
`fwupd-refresh.timer` is enabled. Ansible must pin/mask the auto-update path so a manual rollback
is not silently undone, and **assert** the EC version, reporting drift as a failed assertion rather
than remediating it.

**Mechanism correction (found while implementing).** The sentence above overstates what the timer
does. `fwupd-refresh.service` runs `fwupdmgr refresh`, which downloads *metadata* from configured
remotes and updates the MOTD — it does **not** install firmware. Firmware gets installed by a human
running `fwupdmgr update`, or by a desktop updater acting on that metadata. The latter is not
hypothetical here: `gnome-remote-desktop` is enabled, and a desktop session can be nagged into an
offline firmware update at reboot.

So masking the timer is a real guard but an **indirect** one, and that changes the default. The
role ships `thermal_pin_fwupd: false` and leans on the assertion instead, which catches drift
whatever caused it — vendor tool, desktop updater, or a colleague. Flip the flag in `host_vars`
*before* an E4 downgrade, and move `thermal_expected_ec_firmware` to the rolled-back version after.
The surgical alternative is `fwupdmgr block-firmware <checksum>`, which blocks one specific firmware
from being installed while leaving metadata refresh working.

**Also note:** the registry below lists `gpu_clock_cap_*` and `expected_ec_firmware` unprefixed in
`group_vars`. The implemented rule is narrower: variables a **role declares** carry the role's name
(`thermal_gpu_clock_cap_enabled`), because `var-naming[no-role-prefix]` is enabled and not skipped;
`group_vars` holds only what several roles share. These are role-local, so they live in
`roles/thermal/defaults/main.yml`.

### E4: firmware rollback — a manual runbook, not a task
Document, do not automate:

```
sudo fwupdmgr downgrade 8c948e1db381648c8893897e4d09b7b153309991    # choose 0x02004e18, then reboot
```

The target is above fwupd's stated `Minimum Version: 0x02003400`, so the downgrade is permitted
rather than blocked. **Preconditions: E1 evidence of real thermal throttling, no training run
active, Vlad physically present, and no `fwupdmgr update` afterwards until NVIDIA ships a fixed
EC.** This is the only genuinely unrecoverable step in the project; it earns evidence first and a
human trigger always.

Hardware mitigations (USB fans, printed intake mounts) are a third layer with reported effects
ranging from 2 °C to 10 °C — record them in the runbook, buy nothing until E1 says the box is
actually hot.

## Open questions — need root, a decision, or both

1. **`ufw` rules.** Unknown without root. Read first, then codify. Blanket-resetting a firewall on
   a WiFi-only box risks a lockout.
2. **GRUB's resolved default entry.** `/boot/grub/grub.cfg` is root-only; which kernel GRUB
   actually defaults to is unverified. Confirm before A5 touches anything.
3. ~~**Vendor Docker provenance.**~~ **Answered 2026-07-31: NVIDIA's repo.** `docker-ce`,
   `docker-ce-cli` (5:29.2.1) and `containerd.io` (2.2.1) all resolve to
   `repo.download.nvidia.com/baseos/ubuntu/noble/arm64` at priority 600, and `sources.list.d`
   contains no `docker.list` or `docker.sources`. So A3 must **not** add the upstream repo here —
   it would fight the vendor's pinned build. The role gates that block on both
   `docker_manage_upstream_repo` and Docker being genuinely absent, so a fresh non-DGX box still
   converges.
4. **Surprising enabled services** (`openvpn`, `samba-ad-dc`, `gnome-remote-desktop`, cups,
   `cloud-init`). Disable or leave? The role lists; Vlad decides.
5. **`marius` sudo.** He has it today. Keep (shared dev box) or reduce?
6. **Secrets.** If `ansible_become_password` is ever wanted for unattended runs, use
   `ansible-vault`. Until then, `-K` every time. **No plaintext passwords in the repo, ever.**
7. **`spark-run-apt-upgrade-once` and unattended kernel churn.** Should the box auto-upgrade
   kernels at all, given the Secure Boot history?
8. **Tariff.** What RON/kWh should D2 default to, and does hardware amortisation belong in the cost
   figure or not? (Recommendation: energy only — amortisation is an accounting choice, not a
   measurement, and mixing them makes the number arguable.)
9. **Shared-daemon pueue.** Needs a spike before Phase F is built on it: does `pueued` run cleanly
   as a system service with a group-accessible socket, and do both users' clients reach it? If not,
   fall back to Nomad rather than to per-user queues, which do not satisfy exclusivity.
10. **Whose job runs first.** FIFO is the plan. Confirm that is acceptable to both users, or accept
    the migration cost early rather than after a scheduling argument.

## Risks

- **A5 can make the box unbootable.** Kernel/GRUB changes on a WiFi-only headless box mean physical
  access to recover. Do A5 last, alone, with a known-good signed kernel installed, GRUB timeout
  raised first, and Vlad able to reach the machine.
- **E4 can brick the box.** Firmware is the one unrecoverable operation here. Manual, evidenced,
  supervised — never from a playbook.
- **A6 migrates GPU telemetry.** Retiring `gpu-metrics.sh` changes metric names; dashboards move in
  the same change or the board goes blank.
- **A7 moves the stack** to `/opt/monitoring`. Keep the Grafana volume, verify dashboards survive,
  and do not delete the old directory until the new stack is confirmed serving.
- **`make spark-parity` is the canary.** If provisioning perturbs Pillow/freetype resolution, the
  laptop and box stop computing identical scenes, silently corrupting the verifier that becomes the
  RL reward. Run parity after the first full playbook run.
- **The playbook must be safe against a box that is training.** A Docker restart or exporter swap
  mid-run is survivable; a reboot is not. Guard reboot-requiring tasks behind an explicit flag and
  check for active GPU processes first — the audit caught a live run at 96% GPU.
- **Energy numbers are only as good as the exclusivity invariant.** If the queue is bypassed, or
  something else is plugged into the meter, the cost figures are wrong in a way that looks right.

## Resources

- k6 Prometheus remote-write (the pattern we copy): https://grafana.com/docs/k6/latest/results-output/real-time/prometheus-remote-write/
- k6 dashboard 19665, `testid` variable structure: https://grafana.com/grafana/dashboards/19665-k6-prometheus/
- Grafana dashboard best practices (the anti-sprawl guidance): https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/best-practices/
- Grafana URL variables: https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/create-dashboard-url-variables/
- Grafana data links: https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-data-links/
- Grafana annotations API: https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/api-legacy/annotations/
- Why not Pushgateway: https://prometheus.io/docs/practices/pushing/
- Remote-write 1.0 spec: https://prometheus.io/docs/specs/prw/remote_write_spec/
- Prometheus as an OTLP backend: https://prometheus.io/docs/guides/opentelemetry/
- `prometheus-remote-writer`: https://pypi.org/project/prometheus-remote-writer/
- Axolotl's OTel callback (the reference implementation): https://github.com/axolotl-ai-cloud/axolotl/blob/main/src/axolotl/utils/callbacks/opentelemetry.py
- HF `TrainerCallback`: https://huggingface.co/docs/transformers/en/main_classes/callback
- transformers v5 migration: https://github.com/huggingface/transformers/blob/main/MIGRATION_GUIDE_V5.md
- Shelly Gen2+ RPC (Switch.GetStatus, aenergy): https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/Switch/
- Shelly Plug M Gen3 KB: https://kb.shelly.cloud/knowledge-base/shelly-plug-m-gen3
- pueue: https://github.com/Nukesor/pueue
- DCGM does not support Spark: https://forums.developer.nvidia.com/t/unable-to-install-datacenter-gpu-manager-4-cuda12-using-apt-dgx-spark/348428
- GB10 unified-memory telemetry gaps: https://forums.developer.nvidia.com/t/mps-support-and-telemetry-on-grace-blackwell-gb10-with-unified-memory/363137
- Which `nvidia-smi` fields work on GB10: https://github.com/Syllo/nvtop/issues/426
- `nvidia_gpu_exporter`: https://github.com/utkuozdemir/nvidia_gpu_exporter
- NVIDIA runtime not registered by default on Spark: https://forums.developer.nvidia.com/t/docker-nvidia-runtime-not-enabled-by-default/349220
- `community.docker.docker_compose_v2`: https://docs.ansible.com/projects/ansible/latest/collections/community/docker/docker_compose_v2_module.html
- Unsigned kernels break Secure Boot: https://wiki.ubuntu.com/SecurityTeam/KnowledgeBase/GRUB2SecureBootBypass
- Secure Boot enabled by default on Spark: https://forums.developer.nvidia.com/t/secure-boot-requirements/350345

---

# Implementation notes for executors

This section exists because the work will be done by agents starting from this file with no other
context. Everything above is *why*; this is *what to build and how to know it worked*.

## Rules

- **Idempotence is the acceptance test.** Every task ends: run it, run it again, confirm the second
  run reports `changed=0`. A task that cannot say this is not finished.
- **FQCNs everywhere** (`ansible.builtin.apt`, `community.docker.docker_compose_v2`) — ansible-lint
  runs the `production` profile and will fail otherwise.
- **`make lint` must pass before every commit.** Never commit to `main`; work on a branch.
- **Never break SSH.** It is socket-activated (`ssh.socket`, *not* `ssh.service`) and the box is
  WiFi-only with no wired fallback. A firewall or sshd mistake means walking to the machine.
- **Verify exporters through Prometheus, never by curling them.** `curl 127.0.0.1:9100` hangs on
  this box even when node-exporter is healthy. Use `up`, `scrape_samples_scraped`.
- **The box may be training.** Check `nvidia-smi --query-compute-apps=pid --format=csv` before
  anything disruptive. A container restart is survivable; a reboot is not.
- **Do not install system Pillow, freetype or fontconfig.** They can shadow the wheel-bundled
  libraries that `bbm`'s cross-machine determinism contract depends on.
- **Report, do not improvise.** If a task needs a decision that is not in this file — especially
  anything touching kernels, firewall rules or firmware — stop and report rather than guessing.

## Dependency order, and what can run in parallel

```
A0 scaffold ─┬─ A1 base ──── A7 monitoring ─┬─ B1 dashboards
             ├─ A2 users                    └─ D2 power panels
             ├─ A3 docker ── A4 gpu
             ├─ A6 exporters ───────────────── (feeds A7's scrape config)
             └─ D0/D1 shelly ──────────────── (feeds A7's scrape config)

E1 thermal metrics   depends on A6
E2 clock cap         independent, ships disabled
E3 fwupd pinning     independent
A5 kernel            LAST, ALONE, and only with explicit go-ahead
```

**A0 must land first** — everything else depends on the scaffold and `group_vars`. After that, A1,
A2, A3 and A6 are genuinely independent and can be built concurrently. A7 needs A6 and D1 to exist
so its scrape config has real targets. **A5 is sequenced last and alone**; it is the one task that
can leave the box unbootable.

## The variable registry (`group_vars/all.yml`)

Task A0 creates this. It is the single place anything tunable lives, so an upgrade is a reviewable
diff rather than a hunt through roles.

```yaml
spark_hostname: spark

# CORRECTION: this file is a public recipe others run on their own Sparks, so
# group_vars carries no identity. spark_users defaults to [] — a fresh clone
# must not invent accounts on someone else's box — and the vlad/marius list
# below now lives in host_vars/spark.yml as the worked example someone edits.
# `groups` is what each user gets in addition to their own; the shared group is
# appended by the role, so it is not repeated per user. UIDs are deliberately
# not pinned: 1000/1001 collide on a machine where they are already taken.
spark_users: []

# Deliberately NOT under ~/bbm: bbm's scripts/spark.sh rsyncs that path with
# --delete and would erase anything written here. The bbm-specific values move
# to host_vars; the defaults here are generic.
spark_shared_dir: /srv/spark
spark_shared_group: spark
spark_shared_subdirs: [data, checkpoints, runs]

# ufw: the role only ever ADDS allow rules. It never resets the firewall and
# never sets a default deny policy — adding allows cannot lock anyone out, and
# a lockout on a WiFi-only box means walking to it.
spark_firewall_manage: true
spark_firewall_allow_ports: [22, 80]

monitoring_dir: /opt/monitoring
prometheus_image: prom/prometheus:v3.5.0        # pinned, never `latest`
grafana_image: grafana/grafana:12.1.0
grafana_port: 80                                # http://spark.local, no suffix
prometheus_listen: "127.0.0.1:9090"
prometheus_retention: 30d
prometheus_scrape_interval: 15s
prometheus_enable_remote_write_receiver: true   # the training project needs it

# Both corrected against the upstream release APIs on 2026-07-31. The versions
# first written here were wrong: 1.9.1 was three minors stale, and
# nvidia_gpu_exporter 1.3.2 does not exist at all — it was a typo for the 1.13.x
# line, and pinning it would have 404'd on download. Confirm linux-arm64 assets
# before bumping either; several exporters publish amd64 only.
node_exporter_version: "1.12.1"
node_exporter_port: 9100
nvidia_gpu_exporter_version: "1.13.1"
nvidia_gpu_exporter_port: 9835

shelly_enabled: false            # flip on once the plug is on the network
shelly_host: ""                  # e.g. 192.168.1.141, with a DHCP reservation
shelly_exporter_port: 9924
energy_tariff_per_kwh: 1.3
energy_currency: RON

# OFF until E1 produces evidence. This box currently shows 0 us of thermal
# slowdown against 6.45 h of power capping, so the community fan-curve advice
# is an untested hypothesis here.
gpu_clock_cap_enabled: false
gpu_clock_cap_min_mhz: 300
gpu_clock_cap_max_mhz: 2200

expected_ec_firmware: "0x03000302"   # asserted, never flashed
```

Pin versions rather than tracking `latest`, and confirm each one exists for **linux/arm64** before
using it — several exporters publish amd64-only assets.

## File manifest per task

| Task | Creates |
|---|---|
| A0 | `ansible.cfg`, `inventory/hosts.yml`, `group_vars/all.yml`, `requirements.yml`, `.ansible-lint`, `Makefile`, `site.yml` |
| A1 | `roles/base/{tasks,handlers,defaults}/main.yml`, `roles/base/README.md` (records the discovered ufw state) |
| A2 | `roles/users/tasks/main.yml` |
| A3 | `roles/docker/{tasks,handlers}/main.yml`, `roles/docker/templates/daemon.json.j2` |
| A4 | `roles/gpu/tasks/main.yml` |
| A5 | `roles/kernel/{tasks,handlers}/main.yml`, `roles/kernel/files/no-unsigned-kernels` |
| A6 | `roles/exporters/{tasks,handlers}/main.yml`, `roles/exporters/templates/*.service.j2` |
| A7 | `roles/monitoring/{tasks,handlers}/main.yml`, `templates/{compose.yml,prometheus.yml,datasource.yml,dashboards.yml}.j2` |
| B1 | `roles/monitoring/files/dashboards/spark-overview.json` |
| D1 | shelly exporter unit + scrape job (extends A6/A7) |
| E  | `roles/thermal/{tasks,handlers}/main.yml`, `templates/gpu-clock-cap.service.j2` |

`ansible.cfg` needs at minimum: `inventory = inventory/hosts.yml`, `roles_path = roles`,
`interpreter_python = auto_silent`, and `[ssh_connection] pipelining = True`.
The `Makefile` needs `lint` (ansible-lint), `check` (`--check --diff`), `apply`, and `ping`.

## Verification per task

Run these; paste the output in the report rather than asserting success.

| Task | Verify |
|---|---|
| A0 | `make lint` clean; `ansible spark -m ansible.builtin.ping` succeeds |
| A1 | `ssh vlad@spark.local` still works; `ufw status` matches what the role declares; `avahi` active and `spark.local` resolves |
| A2 | `ssh marius@spark.local docker ps` works after one reconnect |
| A3 | `docker info --format '{{json .Runtimes}}'` lists `nvidia`; the three monitoring containers come back after the daemon restart |
| A4 | `docker run --rm --gpus all <cuda13-arm64> nvidia-smi` exits 0; `/etc/cdi/nvidia.yaml` exists |
| A5 | `mokutil --sb-state` still reports enabled; `uname -r` is the intended signed kernel; **reboot once and confirm it comes back** |
| A6 | via Prometheus: `up{job="node"}==1`, `up{job="gpu"}==1`, `scrape_samples_scraped>0`; `node_filesystem_avail_bytes{mountpoint="/"}` present; both units survive a reboot |
| A7 | `curl -s -o /dev/null -w '%{http_code}' http://spark.local/` → 200 anonymously; all scrape targets `up`; `docker compose down` then re-run converges |
| B1 | every panel renders with data; no panel queries a metric nobody emits |
| D1 | `up{job="power"}==1`; the Wh series is typed as a **counter** and `increase()` over an hour returns a plausible number |
| E1 | throttle-reason metrics present in Prometheus; alert rules load |
| all | second playbook run reports `changed=0`; `make lint` clean |

**Then, once: `cd ~/projects/ai/bbm && make spark-parity`.** It must still pass. This is the canary
that provisioning has not perturbed the Pillow/freetype resolution the verifier depends on — and
that verifier becomes the RL reward signal, so a silent regression here is expensive.

## What "done" reports look like

For each task: what changed, the verification output, anything discovered that contradicts this
file, and anything deliberately left undone. **Contradictions are the valuable part** — this plan
was written from an audit of one box on one day, and several of its facts are hypotheses (marked as
such). If reality disagrees, reality wins and this file should be corrected.
