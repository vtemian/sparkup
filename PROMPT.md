# sparkup: the DGX Spark as code

## What this is

Ansible that provisions the DGX Spark from a fresh DGX OS install to a working training box:
users, Docker, the NVIDIA container runtime, system monitoring, GPU telemetry, and **live
training-run observability in Grafana** — launch a training round, watch loss, throughput and GPU
stream into a dashboard while it runs, and compare it against past runs.

The model is k6. `k6 run -o experimental-prometheus-rw` pushes samples into Prometheus tagged with
a `testid` label, and the official k6 dashboards make that label a template variable. We do the
same thing with `run_id`. That is not an analogy borrowed loosely — it is the same mechanism.

Two halves, and they are independent:

1. **The box as code.** Everything currently hand-built on `spark.local` becomes an idempotent
   playbook. Today the box works but nothing is reproducible: if it dies, the state lives only in
   a chat log.
2. **Training observability.** A `TrainerCallback` and a launcher that make a training run
   visible the way k6 makes a load test visible.

## Working agreement

**The assistant implements. Vlad directs.** Same agreement as `bbm`: Vlad decides architecture,
scope and priorities; the assistant writes the code.

`bbm` is the project this exists to serve. `sparkup` is infrastructure — it must never become the
interesting problem. When a choice is between clever and boring, pick boring.

## Definition of done

`ansible-playbook site.yml -K` against a freshly installed DGX Spark produces a box where:

- `ssh vlad@spark.local` and `ssh marius@spark.local` both work, key-only, both in `docker`
- `http://spark.local` serves Grafana with system + GPU dashboards, no login required to view
- GPU telemetry is supervised (survives reboot and crashes) with per-second granularity
- `docker run --rm --gpus all <cuda13 image> nvidia-smi` works — GPU containers are possible
- `sparkup-train demo` streams a synthetic training run into Grafana, live, and prints the URL
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
(official arm64 images, config templated by Ansible). The two exporters run as **host systemd
units**, not containers. Reasons, both learned the hard way on this box:

- A containerized node-exporter needs `/:/host:ro,rslave`, and that mount makes the filesystem
  collector recurse every Docker overlay and **hang** — `up` flaps to 0. Verified on this box.
  Native install removes the mount and the problem, and gives back disk metrics.
- A containerized GPU exporter needs GPU-in-container plumbing, which is the least reliable piece
  of the stack. Monitoring must not depend on the thing most likely to break. `nvidia_gpu_exporter`
  is a static Go binary with arm64 release tarballs; systemd supervises it properly.

**`nvidia_gpu_exporter`, not DCGM.** NVIDIA states DCGM does not support Spark and there are no
plans to. On GB10, `nvmlDeviceGetMemoryInfo` returns `NVML_ERROR_NOT_SUPPORTED` (unified memory,
no discrete framebuffer), so the whole `DCGM_FI_DEV_FB_*` family is broken and utilization is
reported mirrored across consumers. `utkuozdemir/nvidia_gpu_exporter` wraps `nvidia-smi
--query-gpu`, so it exports exactly the fields that work. The image is already on the box.

**GPU memory is a host memory metric.** On unified memory there is no separate GPU memory to
report — `nvidia-smi` prints `[N/A]`, and that is correct, not a bug to work around.
`node_memory_*` from `/proc/meminfo` **is** the GPU memory signal. Dashboards must say so, or
someone will spend an afternoon "fixing" the missing panel. This is also why the existing
`gpu-metrics.sh` filters non-numeric values.

**The NVIDIA runtime is registered declaratively in `daemon.json`.** Do not shell out to
`nvidia-ctk runtime configure`: it exits 0 unconditionally, so there is no honest changed-state and
you would have to diff the file around it anyway. Ansible owns `/etc/docker/daemon.json` as a
template, the `runtimes.nvidia` block lives in it, and a handler restarts Docker on change.
`daemon.json` gets exactly one owner.

**Prometheus remote-write receiver for training metrics, not Pushgateway.** Pushgateway
deliberately discards timestamps — per-step loss collapses to the scrape interval and only the last
value per scrape survives. It also has no staleness lifecycle, so a finished run shows its last
value forever. Remote-write records every logged step at its true millisecond and goes stale ~5
minutes after the run ends. This is what k6 does.

**Prometheus and Grafana stay on their current ports.** Grafana on 80 (so `http://spark.local`
needs no suffix, anonymous Viewer). Prometheus bound to `127.0.0.1:9090`. Do not "improve" this.

**Retention goes to 1 year.** Currently 30d. Comparing a run against last quarter's run is the
whole point of run history, and at this volume the disk cost is noise on a 3.7 TB disk.

**Secure Boot stays enabled.** The fix for the unsigned-kernel boot failure is to install the
signed kernel and point GRUB at it, not to turn off Secure Boot. NVIDIA's own Aerial-on-Spark doc
tells people to disable it; we are not doing that.

## Measured facts about the box (audit 2026-07-31)

Read-only audit over SSH. These are facts, not estimates — the playbook must converge *this* box,
not an imagined one.

| | |
|---|---|
| Host | `spark`, `spark.local` via avahi, **192.168.1.140** (static DHCP reservation on the router) |
| OS / kernel | Ubuntu 24.04.4 LTS, `6.17.0-1029-nvidia`, aarch64 |
| GPU | NVIDIA GB10, driver 580.173.02, CUDA 13.0, sm_121, persistence mode on |
| CPU / RAM | 20 cores (10× Cortex-X925 + 10× Cortex-A725), 121 GiB unified, 15 GiB swap |
| Disk | one NVMe 3.7 TB, `/` only — **no separate `/home`**, 65 GB used (2%), plus 13 snap loops |
| Network | **WiFi only** (`wlP9s9`); no wired IPv4. NetworkManager. |

**Users.** `vlad` (1000): `sudo`, `docker`, `adm`, one `ssh-rsa` key. `marius` (1001): `sudo`,
**not in `docker`** — a real gap to fix. No passwordless sudo for either.

**Docker.** 29.2.1, compose plugin v5.0.2. Runtimes: `runc` only — **the `nvidia` runtime is not
registered**, `/etc/docker/daemon.json` does not exist, and `/etc/cdi` + `/var/run/cdi` do not
exist. `nvidia-ctk` 1.19.1 and `/usr/bin/nvidia-container-runtime` are installed. So GPU containers
are currently impossible; the monitoring stack is built to avoid needing them.

**Running now.** `prometheus` (`127.0.0.1:9090`, 30d retention), `grafana` (`80→3000`, anonymous
Viewer, dark, home = `spark-overview`), `node-exporter` (host network, textfile collector,
`--collector.disable-defaults` plus an explicit collector list, **no `/host` mount**). Stack lives
in `/home/vlad/monitoring/`. Image `utkuozdemir/nvidia_gpu_exporter` is pulled but unused.

**GPU telemetry today.** `~/monitoring/gpu-metrics.sh` — a bash loop calling `nvidia-smi` every 5s,
writing `~/monitoring/textfile/gpu.prom`, launched from vlad's crontab under `flock -n` every
minute and `@reboot`. It works (`nvidia_gpu_up 1`, util/temp/power/SM-clock present, memory
absent by design), but cron+flock+bash is not supervision and 5s-in-a-loop is not a service.
**This is what the `gpu_telemetry` role replaces.**

**Secure Boot: enabled.** Installed kernels:

```
ii linux-image-6.11.0-1014-nvidia            signed
ii linux-image-6.17.0-1021-nvidia            signed
ii linux-image-nvidia-hwe-24.04  6.17.0-1029.29   (meta → the running signed kernel)
ii linux-image-unsigned-6.17.0-1026-nvidia   UNSIGNED  ← the boot failure
```

`/etc/default/grub`: `GRUB_DEFAULT=0`, `GRUB_TIMEOUT=0` (hidden menu). `/boot/grub/grub.cfg` is
root-only, so the resolved default entry is **unverified**. On 2026-07-30 this box failed to boot
with "bad shim signature" — GRUB's default pointed at the unsigned kernel and shim refused it; a
manual pick of an older signed kernel booted fine. The unsigned twin is normal Ubuntu packaging
(`linux-nvidia-6.17` ships only unsigned binaries; `linux-signed-nvidia-6.17` ships the signed
ones), so **this will recur on every kernel update** unless pinned. `spark-run-apt-upgrade-once`
is an enabled unit on this box, which makes unattended kernel churn a live risk.

**Traps found the hard way — do not rediscover these:**

- **SSH is socket-activated.** `ssh.socket` is enabled and active; `ssh.service` is *disabled*.
  Ansible must manage `ssh.socket`. Restarting `ssh.service` is a no-op that looks like success.
- **`curl 127.0.0.1:9100` hangs on this box** even when node-exporter is healthy. Verify exporters
  through Prometheus (`up`, `scrape_samples_scraped`), never by curling the exporter from the host.
- **`ufw` is enabled but its rules are unknown** (needs root). Grafana on :80 is reachable from
  the LAN, so either it permits that or it is not filtering. Must be read and then codified.
- Textfile `.prom` files must be world-readable — node-exporter runs as `nobody`.

**DGX platform services** (leave alone, but know they exist): `dgx-dashboard` (NVIDIA's own local
monitoring on `localhost:11000`), `dgx-release`, `nvidia-persistenced`, `nv-cpu-governor`, and a
set of `nvidia-*` tuning oneshots. Also enabled and unexpected on a training box: `openvpn`,
`samba-ad-dc`, `gnome-remote-desktop`, `cloud-init`, `kdump-tools`, cups, snapd.

## What bbm expects (the integration contract)

`sparkup` provisions the box that `bbm` drives. `bbm` already has its own remote-control layer and
`sparkup` must not break it.

`bbm/scripts/spark.sh` (driven by `make spark-info|bootstrap|sync|check|parity|shell|gpu`):

- Connects to `${BBM_SPARK_HOST:-vlad@spark.local}` — **keep the hostname and the `vlad` account.**
- Hardcodes `$HOME/.local/bin/uv` in every remote invocation, because a non-login SSH shell lacks
  it on PATH. **Do not relocate or replace uv** (0.12.0, with a managed CPython 3.12.13).
- Syncs the repo to `${BBM_SPARK_DIR:-~/bbm}` with `rsync -az --delete` and a **hardcoded** exclude
  list (`.git/ .venv/ .claude/ __pycache__/ *.pyc dist/`). It does *not* read `.gitignore`, and it
  does *not* exclude `data/` or `checkpoints/`.

  **Consequence, and it is load-bearing: `rsync --delete` owns `~/bbm`.** Anything `sparkup` or a
  training run writes under `~/bbm` that is not in the laptop tree gets deleted on the next
  `make spark-sync`. **All training artifacts — datasets, checkpoints, logs, run metadata — must
  live outside `~/bbm`.** Use `/srv/bbm/{data,checkpoints,runs}`, owned by a shared group, created
  by the `training_obs` role.
- `make spark-parity` compares `scripts/platform_digest.py` output between laptop and box across
  `geometry`, `verdict`, `grid` and `raster` digests for the 7 fixtures, and **exits 1 on any
  disagreement**. This is a cross-machine determinism contract that depends on the Pillow and
  freetype builds resolved by `uv sync --frozen`. `bbm/src/bbm/raster.py` already pins
  `ImageFont.Layout.BASIC` because the Linux aarch64 Pillow wheel bundles Raqm and the macOS one
  does not (76 of 504000 pixels differed on p0 before the pin).

  **So: `sparkup` must not install system Pillow, freetype, or fontconfig packages that could
  shadow the wheel's bundled libraries. Run `make spark-parity` after the first full playbook run
  and treat a regression as a sparkup bug.**

`bbm` is greenfield on observability — grep finds no `grafana`, `prometheus`, `wandb`, or
`tensorboard` anywhere. The natural metric sources it already produces:

- `bbm.verify.verify(model) -> Report` with `Report.ok` and `Report.failures` (`Finding(label, ok,
  detail)`). **This is the RL reward surface for stage 6 (GRPO)** — streaming it is directly on the
  roadmap, not speculative.
- `bbm.stats.corpus_stats(...).as_dict()` — structured corpus statistics.
- `bbm.grid.build_grid` / `Grid` — the training rows, JSONL, one object per scene, with
  `say`/`draw`/`say_mask`/`draw_mask` arrays of equal length and a `meta` dict carrying `topic` and
  `rhythm` curriculum labels.
- CLI exit codes: `bbm verify` returns 0 pass, 1 wrong geometry, **2 unreadable input** — a harness
  must not read an unreadable file as bad geometry.

Training stages this must serve (`bbm/PROMPT.md`): stage 3 text-only interleaving baseline, stage 4
grafting a draw channel onto a speech LM (freeze audio, new embedding + head + thin LoRA), stage 6
GRPO with the verifier as reward. 7B LoRA fits in 128 GB; a full 7B fine-tune is at the limit.

**Network egress matters:** the first use of a real tokenizer fetches from `huggingface.co`. The
tokenizer report measured the proxy counter undercounting gesture commands by 1.50–1.80×, and whole
scenes inflating 10–18% (worst scene +48%) — so the box needs outbound HTTPS and a warm HF cache.

## Repo layout

```
sparkup/
├── README.md
├── PROMPT.md                    ← this file
├── Makefile                     lint, check, apply, apply-check, ping
├── ansible.cfg
├── requirements.yml             collections, version-pinned
├── .ansible-lint                profile: production
├── inventory/hosts.yml          spark ansible_host=spark.local
├── group_vars/all.yml           image tags, ports, retention, users
├── host_vars/spark.yml          box-specific
├── site.yml                     the playbook
├── roles/
│   ├── base/                    hostname, avahi, timezone, apt hygiene, firewall
│   ├── users/                   vlad + marius, keys from GitHub, sudo, docker group
│   ├── docker/                  packages, daemon.json (incl. nvidia runtime), group
│   ├── gpu/                     container toolkit present, CDI spec, GPU smoke test
│   ├── kernel/                  signed-kernel pin, unsigned apt-pin, GRUB default
│   ├── monitoring/              prometheus + grafana containers, provisioning
│   ├── exporters/               node_exporter + nvidia_gpu_exporter as systemd units
│   └── training_obs/            trainobs package, /srv/bbm dirs, dashboards, launcher
└── files/trainobs/              the Python package (callback + launcher + demo)
```

`ansible.cfg`:

```ini
[defaults]
inventory = inventory/hosts.yml
roles_path = roles
interpreter_python = auto_silent
[ssh_connection]
pipelining = True
```

Run: `ansible-playbook site.yml -K`. Never enable passwordless sudo to avoid the prompt.

## Phase A — the box as code

Ordered. Each task ends with: run it, run it **again**, confirm the second run reports `changed=0`.

### A0: Scaffold

`ansible.cfg`, `inventory/hosts.yml`, `group_vars/all.yml`, `requirements.yml` (pin
`community.docker`, `community.general`, `ansible.posix`), `.ansible-lint` with
`profile: production`, a `Makefile` with `lint` (ansible-lint), `check` (`--check --diff`),
`apply`, `ping`. FQCNs everywhere — the production profile enforces it.

Verify: `make lint` clean, `ansible spark -m ansible.builtin.ping` succeeds.

### A1: `base`

Hostname `spark` + the `127.0.1.1 spark` line; avahi installed and enabled (this is what publishes
`spark.local` — the whole access story depends on it); timezone; a small apt package set
(`rsync`, `curl`, `flock`/`util-linux`, `python3-apt`).

**Firewall — read before writing.** `ufw` is enabled with unknown rules. First task: read the
actual state with root and record it in the role's README. Then codify explicitly: allow 22 and 80,
keep 9090/9100/9835 off the LAN (bind localhost or restrict to the subnet). Do not blanket-reset
`ufw` — locking yourself out of a WiFi-only box means walking to it with a keyboard.

**Do not touch** the `dgx-*` or `nvidia-*` platform units. `openvpn`, `samba-ad-dc`,
`gnome-remote-desktop` are surprising on a training box; **list them for Vlad, disable nothing
without a decision.**

Verify: idempotent; `ssh vlad@spark.local` still works; `ufw status` matches the declared rules.

### A2: `users`

`vlad` (1000) and `marius` (1001), shell `/bin/bash`, groups `sudo` + **`docker`** (marius is
missing `docker` today — this closes that gap). Keys via `ansible.posix.authorized_key` with
`ansible.builtin.uri` pulling `https://github.com/balajmarius.keys` for marius, and vlad's existing
`ssh-rsa vladtemian@gmail.com`. `exclusive: false` — never orphan a working key.

Docker group membership only takes effect on the next login; use `meta: reset_connection` if a
later task in the same run needs it.

Verify: `ssh marius@spark.local docker ps` works after one reconnect; idempotent.

### A3: `docker`

**Least change.** Docker 29.2.1 and compose v5.0.2 are already installed from the vendor image.
Do not re-point the apt repo on a working install: `state: present`, never `latest`, and only add
Docker's repo when Docker is absent (so a fresh box still converges). Check
`apt-cache policy docker-ce` first and record what the vendor ships.

The load-bearing piece is `/etc/docker/daemon.json`, templated, single owner, containing the
NVIDIA runtime registration:

```json
{
  "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "runtimeArgs": [] } },
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
```

Handler restarts Docker on change. **Do not set `default-runtime: nvidia`** — every container
would get GPU injection, including Prometheus and Grafana.

Log rotation is not incidental: an unbounded json-file log on a box that will run long training
jobs is a slow disk leak.

Verify: `docker info` lists the `nvidia` runtime; second run `changed=0`; the monitoring containers
survive the Docker restart (`restart: unless-stopped` should bring them back — confirm, don't
assume).

### A4: `gpu`

`nvidia-container-toolkit` present (let DGX OS own the version — 1.19.1 today; the arm64 repo is
`https://nvidia.github.io/libnvidia-container/stable/deb/`). Generate the CDI spec with
`nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`, guarded by a `creates:`-style condition so
it is idempotent, and enable `nvidia-cdi-refresh` if the installed toolkit provides it (1.18+) so
the spec regenerates after driver updates.

**Smoke test as a real task**, not a manual afterthought:
`docker run --rm --gpus all <cuda13-arm64 image> nvidia-smi` must succeed. Note the image must be
CUDA **13**-based and arm64 — sm_121 exists only in CUDA ≥13.0, so most `cu12x` images will not
run. Assert on the output.

Verify: both `--gpus all` and `--runtime=nvidia` work; `/etc/cdi/nvidia.yaml` exists; idempotent.

### A5: `kernel` — the Secure Boot fix

The box already failed to boot once from this. Order matters; never remove a kernel before its
signed replacement is installed and GRUB is retargeted.

1. Ensure the signed image for the target version is installed (`linux-image-<ver>-nvidia`, no
   `unsigned` infix) plus `linux-image-nvidia-hwe-24.04`.
2. Point GRUB at it. Prefer `GRUB_DEFAULT=saved` + `grub-set-default`, guarded for idempotency with
   `grub-editenv list`, over pinning a menu-entry title string (titles change and the pin silently
   rots). Handler: `update-grub`.
3. Keep unsigned kernels out permanently with an apt pin — declarative, and unlike `dpkg` holds it
   applies to packages not yet installed:

   ```
   # /etc/apt/preferences.d/no-unsigned-kernels
   Package: linux-image-unsigned-*
   Pin: release *
   Pin-Priority: -1
   ```
4. Remove `linux-image-unsigned-6.17.0-1026-nvidia` **only** once the box is confirmed running a
   signed kernel. List packages explicitly; do not glob-remove kernels.
5. Assert: `mokutil --sb-state` reports enabled, and `ansible_kernel` matches the intended signed
   version.

**Also raise `GRUB_TIMEOUT`** from 0 to ~5. A hidden menu on a box with a history of boot failures
means the only recovery path is guessing when to hold a key.

**Honest uncertainty:** the packaging split and the Secure Boot default are confirmed, and this box
demonstrably hit the failure. But there is no published post-mortem of a Spark broken *specifically*
by an update swapping signed→unsigned. Treat step 3 as cheap insurance. Note also that reported
Spark boot hangs (EFI-stub, GSP timeouts) are driver/firmware issues, **not** signature ones — do
not misdiagnose one as the other.

### A6: `exporters` — native, supervised

Retire the cron + flock + bash approach entirely.

**`node_exporter`**: install the arm64 binary, a `node_exporter` system user, and a systemd unit
(`Restart=always`). Enable the collectors currently in use plus the **filesystem** collector, with
an exclude regex — this is the whole reason disk metrics are missing today:

```
--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/snapd/.+)($|/)
--collector.filesystem.fs-types-exclude=^(autofs|overlay|squashfs|tmpfs|devtmpfs|nsfs|cgroup.*)$
```

The 13 snap loop devices and the Docker overlays are exactly what pollutes and hangs it. Keep
`--collector.textfile.directory=/var/lib/node_exporter/textfile` for ad-hoc metrics.

**`nvidia_gpu_exporter`**: install the `utkuozdemir/nvidia_gpu_exporter` arm64 release binary
(1.13.x) as a systemd unit on `:9835`, `Restart=always`. It needs `nvidia-smi` on PATH — trivially
true on the host. Metrics: `nvidia_smi_utilization_gpu_ratio`, `nvidia_smi_temperature_gpu`,
`nvidia_smi_power_draw_watts`, `nvidia_smi_clocks_current_*_hz`.
`nvidia_smi_memory_used_bytes`/`_total_bytes` will be absent or NaN on GB10 — **expected, per the
unified-memory decision above.**

Then delete `~/monitoring/gpu-metrics.sh` and both crontab lines, and drop the textfile GPU wiring.
Dashboards must be migrated to the new metric names in the same change (see B2) — do not leave a
window where the dashboard queries metrics nobody emits.

Verify **through Prometheus**, not curl: `up{job="node"} == 1`, `up{job="gpu"} == 1`,
`scrape_samples_scraped > 0` for both; `node_filesystem_avail_bytes{mountpoint="/"}` present;
`systemctl status` both units active; reboot and confirm both come back.

### A7: `monitoring` — Prometheus + Grafana as code

Move the stack from `/home/vlad/monitoring` to `/opt/monitoring` (root-owned; a service stack does
not belong in a user's home, and it must not be reachable by anything that rsyncs).

Templates → `notify: Restart monitoring stack`:

- `compose.yml.j2` — prometheus + grafana only. **Pin image tags** in `group_vars` (e.g.
  `prom/prometheus:v3.5.0`), never `latest`; upgrades become git diffs.
- `prometheus.yml.j2` — jobs `prometheus`, `node` (`:9100`), `gpu` (`:9835`). Retention **1y**.
  Flags: `--web.enable-remote-write-receiver` (Phase C needs it),
  `--storage.tsdb.retention.time=1y`, `--web.enable-lifecycle`, and
  `storage.tsdb.out_of_order_time_window` if the rebased-overlay option in C4 is ever pursued.
- Grafana provisioning: datasource (uid `prometheus`) and dashboard provider, plus dashboard JSON
  via `copy`. Preserve today's env: anonymous Viewer, dark theme, home dashboard
  `spark-overview`, port 80.

Apply with `community.docker.docker_compose_v2` (`project_src: /opt/monitoring`, `state: present`,
`pull: missing`, `remove_orphans: true`, `wait: true`). Handler uses `state: restarted`. The handler
is necessary because bind-mounted config changes do not change the compose file, so `state: present`
alone restarts nothing. Never use `state: restarted` or `recreate: always` in a regular task — they
are deliberately non-idempotent. For Prometheus config specifically, prefer
`POST /-/reload` over a restart.

Grafana keeps its named volume so hand-made dashboards and users survive. Provisioned dashboards
stay file-owned with `allowUiUpdates: true`.

Verify: `http://spark.local` → 200 anonymously; all three targets `up`; second run `changed=0`;
`docker compose down && ansible-playbook` reconverges.

## Phase B — dashboards

### B1: `spark-overview`, migrated

Port the existing dashboard to the native exporters' metric names, and add what was missing:

- GPU: utilization, temperature, power, SM clock (gauges + time series)
- **Memory panel titled to say it is unified GPU+CPU memory**, from `node_memory_*`, with a panel
  description explaining why no GPU-specific memory metric exists
- CPU busy, load, uptime, temperatures (GPU + all hwmon sensors)
- **Disk usage** — newly possible with the filesystem collector, including `/srv/bbm`
- Exporter health row: `up` per job, `scrape_duration_seconds`. When telemetry lies, the first
  question is whether the exporter is alive.

### B2: dashboards as files

All dashboards live in `roles/monitoring/files/dashboards/*.json`, provisioned. A dashboard edited
only in the Grafana UI is not code and will be lost. Document the round-trip: edit in UI → export
JSON → commit.

## Phase C — training observability (the k6 part)

### C0: `/srv/bbm` and why not `~/bbm`

Create `/srv/bbm/{data,checkpoints,runs}`, group-owned by a `bbm` group containing vlad and marius,
`setgid` so collaborators can share artifacts. **This exists because `rsync --delete` owns
`~/bbm`** (see the integration contract). Every training path in every config points at `/srv/bbm`.

### C1: `trainobs` — the Python package

Small, dependency-light, deployed to a venv on the box and importable by `bbm`'s future `train/`
module. `sparkup` owns it because it knows the Prometheus URL; `bbm` imports it.

Dependency: `prometheus-remote-writer` (v1.1.3, Jan 2026 — actively maintained, Apache-2.0, small
enough to vendor if it is ever abandoned; the remote-write 1.0 protocol is frozen). On aarch64,
`python-snappy` 0.7+ wraps `cramjam`, which ships manylinux aarch64 wheels — **verify a plain
install before assuming**, and fall back to a ~50-line DIY protobuf+snappy writer if it fights.

```python
writer.send([{
    "metric": {"__name__": "training_loss", "run_id": run_id},
    "values": [2.31],
    "timestamps": [int(time.time() * 1000)],   # ms epoch, true step time
}])
```

`PrometheusCallback(TrainerCallback)`:

- `on_train_begin` → emit the info metric once:
  `training_run_info{run_id, run_name, git_sha, model, dataset, tokenizer, ...} 1`
- `on_log` → `loss`, `learning_rate`, `grad_norm`, `epoch` from the `logs` dict;
  `training_step` from `state.global_step`; derive `training_steps_per_sec` and
  `training_tokens_per_sec` from deltas of `state.global_step` /
  `state.num_input_tokens_seen` over `time.monotonic()` (requires
  `TrainingArguments(include_num_input_tokens_seen=True)`; note it counts padding)
- `on_train_end` → terminal status metric so a dashboard can distinguish finished from crashed
- Guard everything with `state.is_world_process_zero`, and **wrap every push in try/except: a
  metrics outage must never kill a training run.** Buffer and batch pushes on a ~2–5s cadence (k6
  uses 5s).

Cardinality: `run_id` as a label is fine — hundreds of runs × ~10 series is low thousands total,
and only ~10 are active at once. **Never put `step` in a label**; step is a gauge value and time is
the axis. Metadata goes on the info metric and joins in PromQL:
`training_loss{run_id=~"$run_id"} * on(run_id) group_left(run_name, git_sha) training_run_info`.

transformers 5.x: the `TrainerCallback` signatures and `logs`/`TrainerState` fields are unchanged;
`report_to` now defaults to `"none"` and callback kwargs carry `processing_class` instead of
`tokenizer`. Set `logging_steps=1` and `logging_first_step=True` for a live feel.

### C2: `sparkup-train` — the launcher

- `sparkup-train demo` — a **synthetic run**: decaying loss with noise, plausible step timing,
  realistic tokens/sec. This exists because `bbm` has no training code yet, and it is the
  acceptance test for the whole pipeline. It must be indistinguishable from a real run in Grafana.
- `sparkup-train run -- <command>` — mint a `run_id`, export it plus the Prometheus URL into the
  environment, exec the command, and record run metadata under `/srv/bbm/runs/<run_id>/`.
- `run_id` format `run-YYYYmmdd-HHMM-<name>` so runs sort chronologically as strings (Grafana
  variable sorting is otherwise unhelpful).
- Print the Grafana URL with the run preselected:
  `http://spark.local/d/training-runs/training-runs?var-run_id=<id>&from=now-15m&to=now&refresh=5s`
- Keep the Trainer's own `log_history` JSON on disk as the durable record. Prometheus is the live
  operations view; the JSON is the archive.

### C3: the "Training Runs" dashboard

Clone the structure of the official k6 dashboard (ID 19665) — confirmed to define `testid` as
`label_values(...)` with `multi: true`, every panel filtering on it:

- Variable `run_id` = `label_values(training_run_info, run_id)`, multi-value. Anchor on the info
  metric: cheaper than scanning every series.
- Panels: loss, learning rate, grad-norm, tokens/sec, steps/sec — legend `{{run_id}}` so
  multi-select overlays runs. Stat panels for current step / max steps and latest loss.
- **GPU util, power and unified memory on the same dashboard.** This is the payoff of using the
  infra Grafana rather than a separate tracker: training curves sit next to the hardware they ran
  on, in one pane.
- Row with `repeat: run_id` for per-run blocks when runs have very different value ranges.
- Refresh 5s (Grafana's `min_refresh_interval` default is 5s; lower it in `grafana.ini` only if
  needed).

### C4: run comparison, honestly scoped

Multi-selecting `$run_id` gives wall-clock side-by-side, which is all the official k6 dashboards
offer and covers most needs. **A true step-aligned overlay (loss-vs-step curves superimposed) is
not natural in Prometheus** — the axis is wall-clock. Options, in order of sanity:

1. Accept wall-clock side-by-side. **Start here.**
2. Two variables (`$run_a`, `$run_b`) plus PromQL `offset` — needs a hand-supplied duration, clunky.
3. The third-party Comparison Panel plugin.
4. Push a rebased twin series (`fixed_epoch + elapsed_ms`) so runs overlay exactly — requires a
   generous `out_of_order_time_window`.

**If step-aligned overlay turns out to be daily bread rather than a nice-to-have, that is the one
genuine argument for adding a real experiment tracker (MLflow/W&B/TensorBoard) instead of bending
Prometheus.** Say so out loud rather than building option 4 by default. Prometheus+Grafana is the
right call for *live, single-box, self-hosted, already-running-infra*; it is not a better
experiment tracker than experiment trackers.

### C5: bbm-specific metrics (after stage 3 exists)

Once `bbm` has training code, surface what is actually specific to this project:

- `verifier_pass_rate` and per-check failure counts from `bbm.verify.Report.failures` — **this is
  the stage-6 GRPO reward signal**, so watching it live is watching the reward
- Corpus composition from `bbm.stats.corpus_stats(...).as_dict()`
- Draw-channel PAD fraction per batch (the measured baseline is 31.3% across the 7 fixtures, with
  per-scene idle 21–48% — the plan for `bbm` explicitly says measure this rather than assume the
  "mostly PAD" claim)
- `stroke`-level degradation rate once stage 5 extraction runs — `bbm/PROMPT.md` calls this "the
  metric that matters"

## Open questions — need root, a decision, or both

1. **`ufw` rules.** Unknown without root. Read first, then codify. Blanket-resetting the firewall
   on a WiFi-only box risks a lockout.
2. **GRUB's resolved default entry.** `/boot/grub/grub.cfg` is root-only, so which kernel GRUB
   actually defaults to is unverified. Confirm before A5 touches anything.
3. **Vendor Docker provenance.** Does 29.2.1 come from Docker CE upstream or NVIDIA's repo?
   Determines whether A3 may safely manage the repo.
4. **Surprising enabled services** (`openvpn`, `samba-ad-dc`, `gnome-remote-desktop`, cups,
   `cloud-init`). Disable, or leave? Vlad's call — the role lists, it does not decide.
5. **`marius` sudo.** He has `sudo` today. Keep (shared dev box) or reduce?
6. **Secrets.** If `ansible_become_password` is ever wanted for unattended runs, use
   `ansible-vault`. Until then, `-K` every time. **No plaintext passwords in the repo, ever.**
7. **`spark-run-apt-upgrade-once` and unattended kernel churn.** Should the box auto-upgrade
   kernels at all, given the Secure Boot history?

## Risks

- **A5 can make the box unbootable.** Kernel and GRUB changes on a WiFi-only headless box mean
  physical access to recover. Do A5 last, alone, with a known-good signed kernel installed, GRUB
  timeout raised first, and Vlad able to reach the machine.
- **A6 migrates GPU telemetry.** Retiring `gpu-metrics.sh` changes metric names; the dashboards
  must move in the same change or the board goes blank.
- **A7 moves the stack** from `~/monitoring` to `/opt/monitoring`. Keep the Grafana volume, verify
  dashboards survive, and do not delete the old directory until the new stack is confirmed serving.
- **`make spark-parity` is the canary.** If provisioning perturbs Pillow/freetype resolution, the
  laptop and the box stop computing identical scenes, which silently corrupts the verifier that
  becomes the RL reward. Run parity after the first full playbook run.
- **The playbook must be safe to run against a box that is training.** A Docker restart or an
  exporter swap mid-run is survivable; a reboot is not. Guard reboot-requiring tasks behind an
  explicit flag, and check for active GPU processes first — the audit caught a live training run at
  96% GPU.

## Resources

- k6 Prometheus remote-write output (the pattern we copy): https://grafana.com/docs/k6/latest/results-output/real-time/prometheus-remote-write/
- Official k6 dashboard, `testid` variable structure: https://grafana.com/grafana/dashboards/19665-k6-prometheus/
- Why not Pushgateway: https://prometheus.io/docs/practices/pushing/
- Remote-write 1.0 spec: https://prometheus.io/docs/specs/prw/remote_write_spec/
- `prometheus-remote-writer`: https://pypi.org/project/prometheus-remote-writer/
- HF `TrainerCallback` / `TrainerState`: https://huggingface.co/docs/transformers/en/main_classes/callback
- transformers v5 migration: https://github.com/huggingface/transformers/blob/main/MIGRATION_GUIDE_V5.md
- DCGM does not support Spark: https://forums.developer.nvidia.com/t/unable-to-install-datacenter-gpu-manager-4-cuda12-using-apt-dgx-spark/348428
- GB10 unified-memory telemetry gaps: https://forums.developer.nvidia.com/t/mps-support-and-telemetry-on-grace-blackwell-gb10-with-unified-memory/363137
- Which `nvidia-smi` fields work on GB10: https://github.com/Syllo/nvtop/issues/426
- `nvidia_gpu_exporter`: https://github.com/utkuozdemir/nvidia_gpu_exporter
- NVIDIA runtime not registered by default on Spark: https://forums.developer.nvidia.com/t/docker-nvidia-runtime-not-enabled-by-default/349220
- DGX Spark container runtime docs: https://docs.nvidia.com/dgx/dgx-spark/nvidia-container-runtime-for-docker.html
- `community.docker.docker_compose_v2`: https://docs.ansible.com/projects/ansible/latest/collections/community/docker/docker_compose_v2_module.html
- `geerlingguy.docker` (arm64/noble reference): https://github.com/geerlingguy/ansible-role-docker
- Unsigned kernels break Secure Boot: https://wiki.ubuntu.com/SecurityTeam/KnowledgeBase/GRUB2SecureBootBypass
- Secure Boot enabled by default on Spark: https://forums.developer.nvidia.com/t/secure-boot-requirements/350345
- Grafana dashboard URL variables: https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/create-dashboard-url-variables/
