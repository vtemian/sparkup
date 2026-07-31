# sparkup: the DGX Spark as code

## What this is

Ansible that provisions the DGX Spark from a fresh DGX OS install to a working training box —
users, Docker, the NVIDIA container runtime, system monitoring, GPU telemetry — plus **live
training-run observability in Grafana**: launch a training round, watch loss, throughput, GPU and
**power** stream into a dashboard while it runs, compare it against past runs, and get an honest
**energy and cost figure** for each one.

The model is k6. `k6 run -o experimental-prometheus-rw` pushes samples into Prometheus tagged with
a `testid` label, and the official k6 dashboards make that label a template variable. We do the
same with `run_id`. That is not a loose analogy — it is the same mechanism, and Grafana's own k6
dashboard JSON is the reference.

Three halves (the arithmetic is wrong; the independence is the point):

1. **The box as code.** Everything hand-built on `spark.local` becomes an idempotent playbook.
   Today the box works but nothing is reproducible: the state lives only in a chat log.
2. **Training observability.** A callback and a launcher that make a run visible the way k6 makes
   a load test visible.
3. **Energy and cost.** A wall-socket meter, correlated to runs, so "what did this experiment
   cost" and "which config gets the best loss per watt-hour" are answerable.

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
- `sparkup-train demo` streams a synthetic run into Grafana, live, and prints the URL
- A finished run has `training_run_energy_wh`, `_duration_seconds` and `_cost` recorded
- Running the playbook a second time reports **zero changed tasks**
- `make lint` passes (ansible-lint, production profile)

Idempotence is the acceptance test, not a nicety. A playbook that cannot run twice is a shell
script with extra syntax.

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
| Network | **WiFi only** (`wlP9s9`); no wired IPv4. NetworkManager. SSID `Wunderlabs`, both bands |

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
│   ├── monitoring/              prometheus + grafana containers, provisioning, alerts
│   ├── scheduler/               pueue, one-run-at-a-time group
│   └── training_obs/            trainobs package, /srv/bbm, dashboards, launcher
└── files/trainobs/              the Python package (callback + launcher + demo)
```

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
`https://github.com/balajmarius.keys`. `exclusive: false` — never orphan a working key. Docker
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

## Phase C — training observability (the k6 part)

### C0: `/srv/bbm`
`/srv/bbm/{data,checkpoints,runs}`, group `bbm`, setgid so vlad and marius share artifacts.
**This exists because `rsync --delete` owns `~/bbm`.** Every training path points here.

### C1: `trainobs` — the Python package
Small, dependency-light, deployed to a venv on the box and importable by `bbm`'s future `train/`
module. `sparkup` owns it because it knows the Prometheus URL; `bbm` imports it.

Dependency: `prometheus-remote-writer` (v1.1.3, Jan 2026, Apache-2.0; small enough to vendor if
abandoned — the remote-write 1.0 protocol is frozen). On aarch64, `python-snappy` 0.7+ wraps
`cramjam` which ships manylinux aarch64 wheels — **verify a plain install before assuming**; fall
back to a ~50-line DIY protobuf+snappy writer if it fights.

`PrometheusCallback(TrainerCallback)` — structure copied from Axolotl, labels fixed:

- `on_train_begin` → the info metric plus the two timestamps that make everything else work:
  ```
  training_run_info{run_id, run_name, git_sha, model, dataset, tokenizer, status} 1
  training_run_start_timestamp_seconds{run_id}
  training_run_heartbeat_timestamp_seconds{run_id}
  ```
- `on_log` → `loss`, `learning_rate`, `grad_norm`, `epoch` from `logs`; `training_step` from
  `state.global_step`; `training_steps_per_sec` and `training_tokens_per_sec` derived from deltas
  of `global_step` / `num_input_tokens_seen` over `time.monotonic()` (needs
  `TrainingArguments(include_num_input_tokens_seen=True)`; it counts padding). Refresh the
  heartbeat every push.
- `on_train_end` → terminal status, so a dashboard distinguishes finished from crashed.
- Guard with `state.is_world_process_zero`; **wrap every push in try/except — a metrics outage must
  never kill a training run.** Batch pushes on a ~2–5 s cadence (k6 uses 5 s).

**The heartbeat is the trick.** It refreshes while the run lives and freezes when it dies, so one
link expression covers live and finished runs — no sentinel values, no "crashed and never wrote its
end time" hole.

Cardinality: **never put `step` in a label** — step is a gauge value, time is the axis. Metadata
lives on the info metric and joins in PromQL:
`training_loss{run_id=~"$run_id"} * on(run_id) group_left(run_name, git_sha) training_run_info`.

transformers 5.x: `TrainerCallback` signatures and `logs`/`TrainerState` fields are unchanged;
`report_to` now defaults to `"none"`; callback kwargs carry `processing_class`, not `tokenizer`.
Set `logging_steps=1` and `logging_first_step=True` for a live feel.

### C2: `sparkup-train` — the launcher
- `sparkup-train demo` — a **synthetic run** (decaying loss with noise, plausible step timing,
  realistic tokens/sec). `bbm` has no training code yet, so this is the acceptance test for the
  whole pipeline. It must be indistinguishable from a real run in Grafana.
- `sparkup-train run -- <command>` — mint a `run_id`, sample the idle power baseline (Phase D),
  export `run_id` + Prometheus URL into the environment, submit to the queue, record metadata
  under `/srv/bbm/runs/<run_id>/`, and on completion write `summary.json` and the per-run energy
  metrics.
- `run_id` format `run-YYYYmmdd-HHMM-<name>` so runs sort chronologically as strings.
- Print the deep link at launch (live form) and on completion (pinned form):
  ```
  http://spark.local/d/trainrun/training-run?orgId=1&var-run_id=<id>&from=<start_ms>&to=now&refresh=10s
  ```
  Subtract ~60 s from `start_ms` so the first datapoints are not glued to the axis. `&kiosk` must be
  bare. Optionally `POST /api/snapshots` at the end for runs worth keeping.
- **Annotations**: `POST /api/annotations` at start with tags `["training-run", "<run_id>"]`,
  `PATCH` with `timeEnd` at the end → a shaded region marking the run. Omit `dashboardUID` so the
  boundary also appears on infra dashboards — which is where you diagnose "why did throughput tank
  at 03:00". Persist the annotation id so a crash handler can still close the region.
- Keep the Trainer's own `log_history` JSON on disk. Prometheus is the live view; disk is the archive.

### C3: the "Training Runs" dashboard
Clone the k6 structure (dashboard 19665 defines `testid` as `label_values(...)`, `multi: true`,
every panel filtering on it):

- Variable `run_id` = `label_values(training_run_info, run_id)` — anchoring on the info metric is
  far cheaper than scanning every series. `multi: true`, `includeAll: false`, `refresh: 2`
  (re-query on time-range change), **`sort: 8`** (natural descending → newest first; 7/8 exist in
  the schema though the docs list only six).
- Panels: loss, lr, grad-norm, tokens/sec, steps/sec, legend `{{run_id}}`, matcher `=~` (multi-select
  interpolates to a regex). Stats for current step / max steps and latest loss.
- **GPU util, power, unified memory and wall power on the same dashboard.** This is the payoff of
  using the infra Grafana instead of a separate tracker: training curves next to the hardware.
- Annotation query filtered `["training-run", "$run_id"]`, `matchAny: false`. For compare mode add
  a second query with `matchAny: true` and just `["training-run"]`, since ANDing multiple run tags
  matches nothing.

### C4: runs index
A separate `/d/runs` dashboard: one Table panel, three **instant** queries in Table format —
`training_run_info`, `training_run_start_timestamp_seconds * 1000`,
`training_run_heartbeat_timestamp_seconds * 1000` — joined by `run_id` (outer), with an override on
the `run_id` field carrying two data links:

```
Follow live:       /d/trainrun/training-run?var-run_id=${__data.fields["run_id"]}&from=${__data.fields["start_ms"]}&to=now&refresh=10s
Full run (pinned): /d/trainrun/training-run?var-run_id=${__data.fields["run_id"]}&from=${__data.fields["start_ms"]}&to=${__data.fields["end_ms"]}
```

Add energy, duration and cost columns from Phase D. This is the experiment index — ~40 lines of JSON.
`${__data.fields["<name>"]}` pulls another column on the same row; timestamps must be **ms**, hence
the `* 1000` in PromQL rather than a transformation.

### C5: run comparison, honestly scoped
Multi-selecting `$run_id` gives wall-clock side-by-side — all the official k6 dashboards offer, and
enough for most needs. **A step-aligned overlay (loss-vs-step superimposed) is not natural in
Prometheus**; the axis is wall-clock. Options in order of sanity: (1) accept side-by-side — start
here; (2) `$run_a`/`$run_b` with PromQL `offset`, clunky; (3) the Comparison Panel plugin; (4) push
a rebased twin series with `out_of_order_time_window` set generously.

**If step-aligned overlay becomes daily bread rather than a nice-to-have, that is the one genuine
argument for a real experiment tracker instead of bending Prometheus.** Say so out loud rather than
building option 4 by default. Grafana's ceiling here is "watch a run, compare a few, correlate with
infra and power" — a real and valuable ceiling; know where it is. If this ever grows run-comparison
tables, hyperparameter diffing and artifact links, we have reinvented MLflow badly.

### C6: bbm-specific metrics (after stage 3 exists)
`verifier_pass_rate` and per-check failure counts from `bbm.verify.Report.failures` — **the stage-6
GRPO reward signal**, so watching it live is watching the reward. Plus corpus composition from
`stats.as_dict()`, draw-channel PAD fraction per batch (measured baseline 31.3% across the seven
fixtures, per-scene idle 21–48%), and the `stroke` degradation rate once stage 5 runs —
`bbm/PROMPT.md` calls that "the metric that matters".

## Phase D — energy and cost

### D0: the meter
**Shelly Plug M Gen3** (Vlad's choice, verified suitable): 13 A / 3000 W, CEE 7/3 Schuko output +
CEE 7/7 plug — correct for Romania, with vast headroom over a ~240 W box. Gen3 local RPC, no cloud.

`GET /rpc/Switch.GetStatus?id=0` returns `apower` (W), `voltage`, `current`, `freq`, and
**`aenergy.total` in watt-hours** plus `aenergy.by_minute`.

**Use the cumulative counter, not the power gauge.** `aenergy.total` is integrated by the hardware,
so energy is exact rather than an artefact of our scrape interval, and Prometheus's counter
handling copes correctly when it resets on device reboot.

Setup tasks: join `Wunderlabs` (2.4 GHz — the plug is 2.4-only, same subnet), give it a **DHCP
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
The plug measures the whole box and **can never carry a `run_id` label**. Attribution is by time
window, which is why runs must be serialized (see Decisions, and Phase F).

**Live:** the plug series is simply a panel on the run dashboard; because the dashboard's time
range is pinned to the run, it already shows exactly that window. No machinery.

**Durable:** at run end the launcher queries Prometheus over `[start, end]` and writes back
per-run summary series — one sample per run, cheap forever:

```
training_run_energy_wh{run_id}            total wall energy over the run   (plug)
training_run_energy_marginal_wh{run_id}   energy attributable to the run   (plug − idle)
training_run_gpu_energy_wh{run_id}        GPU-rail energy                  (NVML counter, exact)
training_run_idle_baseline_watts{run_id}  measured immediately before the run
training_run_duration_seconds{run_id}
training_run_cost{run_id}                 marginal Wh × tariff
```

`training_run_gpu_energy_wh` comes from `nvmlDeviceGetTotalEnergyConsumption` sampled at run start
and end — **verified working on this box** (10024 mJ / 3 s → 3.34 W, matching `PowerUsage` 3.38 W).
It is millijoules and **resets on driver reload**, so read it as a delta and discard the run's
figure if the counter went backwards. `nvidia-ml-py` is the client; it is now installed in
`~/bbm-train/.venv`.

The ratio `gpu_energy_wh / energy_wh` is the useful derived number: how much of what you paid for
was the GPU actually working, rather than the box merely being switched on. Expect roughly 0.5 at
best given the measured ~2× wall-to-rail gap — if a run scores far below that, the bottleneck is
not the GPU and more epochs will mostly buy electricity.

**Two numbers, both wanted.** *Total* answers "what did this cost me". *Marginal* answers "was this
experiment worth it" — the box draws power whether or not you train. Measure the baseline for ~60 s
immediately before each run rather than assuming a global constant; it drifts with ambient
temperature and whatever else is running.

The PromQL, using the counter:

```promql
# exact Wh over the run window (dashboard: $__range == the pinned run window)
increase(shelly_energy_wh_total[$__range])

# marginal: subtract the idle baseline over the same duration
increase(shelly_energy_wh_total[$__range])
  - (avg_over_time(training_run_idle_baseline_watts[$__range]) * $__range_s / 3600)

# cost, tariff as a Grafana constant variable in currency per kWh
increase(shelly_energy_wh_total[$__range]) / 1000 * $tariff
```

Gauge fallback if the exporter lacks a counter — an approximation whose error scales with the
scrape interval, so say so in the panel description:

```promql
avg_over_time(shelly_power_watts[$__range]) * $__range_s / 3600   # Wh
```

**Tariff is a Grafana variable, not a hardcoded number** — it changes, and a variable means no
dashboard rebuild. Romania is roughly 1.3 RON/kWh at time of writing, so a continuous 200 W box is
on the order of €0.06/hour. **The interesting number is probably watt-hours per run, for comparing
efficiency between configs, more than the euros.**

**Clock discipline:** let Prometheus scrape the plug so all timestamps come from one clock. Never
trust the plug's own.

### D3: cost panels
Add energy, duration and cost columns to the runs index (C4), and a per-run stat row. The
comparison that justifies this whole phase is **final loss per watt-hour** across configs — put it
on the dashboard explicitly rather than leaving it as arithmetic for the reader.

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

## Phase F — the scheduler

**Why it exists:** exclusivity. Energy attribution against a whole-box meter is only valid when one
run owns the machine (Decisions, D2). Convenience is the secondary benefit.

**Recommended: `pueue`** — 6.3 k stars, actively maintained, single Rust binary, groups with
parallelism limits, pause/resume, proper daemon+client. Configure one group with parallelism **1**.
It has no GPU awareness and no metrics, and needs neither: our callback emits the metrics, and with
one GPU and one run, "GPU awareness" is just serialization.

Considered and rejected: `task-spooler`'s GPU-aware fork (2 years stale), Ray (see Prior art),
SLURM (munge + slurmctld + slurmd + slurmdbd + MySQL to serialize jobs on one machine — only worth
it if multi-user fair-share ever matters), `systemd-run`/`at` (no queue).

**The launcher enforces the invariant**: refuse to start when another run is active, or tag the run
`contended=true` so its energy figures are visibly untrustworthy rather than quietly wrong.

## Open questions — need root, a decision, or both

1. **`ufw` rules.** Unknown without root. Read first, then codify. Blanket-resetting a firewall on
   a WiFi-only box risks a lockout.
2. **GRUB's resolved default entry.** `/boot/grub/grub.cfg` is root-only; which kernel GRUB
   actually defaults to is unverified. Confirm before A5 touches anything.
3. **Vendor Docker provenance.** Is 29.2.1 from Docker CE upstream or NVIDIA's repo? Determines
   whether A3 may manage the repo.
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
