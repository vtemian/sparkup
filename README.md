<!-- Drop the hand-drawn mascot at .github/mascot.png and uncomment this.
<p align="center">
  <img src=".github/mascot.png" alt="sparkup" width="240" />
</p>
-->

<h1 align="center">sparkup</h1>

<p align="center">
  Your DGX Spark, as code.
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> &middot;
  <a href="#what-it-looks-like">Dashboard</a> &middot;
  <a href="INSTALL_CLAUDE.md">Operating guide</a> &middot;
  <a href="#what-this-box-taught-us">Field notes</a>
</p>

---

Takes a box from a fresh DGX OS install to a working training machine: user accounts, Docker with
the NVIDIA runtime, supervised GPU and system telemetry, and Grafana on `http://spark.local` with no
login to look at it. Optionally, what a training run costs in electricity (requires a smart plug).

## What it looks like

One dashboard, provisioned from a file in this repo, on a box that had none of this an hour ago.
GPU load, temperature, power and clocks; CPU, unified memory and disk; and a row that tells you
whether the exporters themselves are still alive.

<p align="center">
  <img src=".github/dashboard.png" alt="The spark-overview dashboard" />
</p>

## Quick start

```bash
make deps      # once
make check     # see what would change
make apply     # converge
```

Then `make apply` again. It must report `changed=0`, because a playbook that cannot run twice is a
shell script with extra syntax.

Setup, configuration and operations live in **[INSTALL_CLAUDE.md](INSTALL_CLAUDE.md)**. It is
written for AI agents driving this repo, which makes it blunt about invariants and failure modes;
it is also the complete reference if you are doing it by hand.

## What this box taught us

Every one of these cost somebody an afternoon. They are why the roles look the way they do.

| | |
|---|---|
| **`nvidia-smi` underreports the wall by ~2×** | 87 W on the GPU rail against 180 W at the socket. There is no internal path to system power, so cost is measured at the plug or not at all. |
| **There is no GPU memory metric** | Memory is unified, `nvidia-smi` prints `[N/A]`, and that is correct. `node_memory_*` **is** the GPU memory signal. Do not "fix" it. |
| **DGX OS hides the GRUB menu behind a drop-in** | Writing `GRUB_TIMEOUT` to `/etc/default/grub` does nothing; `no-grubmenu.cfg` is sourced afterwards and wins. Always check the *generated* `grub.cfg`. |
| **80 °C is not the limit** | Under sustained bf16 matmul this box sat at 79–80 °C with clocks at 2405 of 3003 MHz and **zero microseconds** of thermal slowdown. The limiter is the power cap, not heat, so the fan-curve advice going around does not apply here. Measure before you mitigate. |
| **`curl 127.0.0.1:9100` hangs** | Even when the exporter is perfectly healthy. Verify exporters through Prometheus, never by curling them. |
| **Docker's port publishing bypasses `ufw`** | DNAT sits ahead of the firewall's chains, so a published port is open whatever the policy says. |
| **A default-deny firewall breaks your own monitoring** | Prometheus scrapes the host exporters through the docker bridge, which lands on the INPUT chain. Securing the box takes its telemetry with it unless you plan for it. |

## Layout

```
site.yml              the playbook
inventory/hosts.yml   which box
group_vars/all.yml    defaults for any Spark
host_vars/spark.yml   your box (untracked)
roles/                base, users, docker, gpu, exporters, shelly, monitoring, thermal, kernel
tests/                everything that runs without a Spark
```

Each role has its own README explaining what it does and why.

No Spark in front of you? `make offline` runs the whole suite in containers: lint, every dashboard
query parsed and evaluated against a real Prometheus, and two roles converged twice to prove
`changed=0`.

## License

MIT
