# sparkup

Your DGX Spark, as code.

Takes a box from a fresh DGX OS install to a working training machine: user accounts, Docker with
the NVIDIA runtime, supervised GPU and system telemetry, and Grafana on `http://spark.local` with no
login to look at it.

```bash
make deps      # once
make check     # see what would change
make apply     # converge
```

Full setup in **[INSTALL_CLAUDE.md](INSTALL_CLAUDE.md)**.

## What you get

- **One dashboard that tells you the truth about the box.** GPU utilisation, temperature, power and
  clocks; CPU, load, unified memory, disk; and a row showing whether the exporters themselves are
  alive, because the first question when telemetry looks wrong is whether anything is reporting.
- **Telemetry that survives a reboot.** `node_exporter` and `nvidia_gpu_exporter` run as systemd
  units, not containers, so monitoring does not depend on the thing most likely to break.
- **GPU containers that work.** `docker run --gpus all` on a box where the NVIDIA runtime is not
  registered out of the box.
- **Wall-socket power, optionally.** The GPU rail underreports the wall by roughly 2x on this
  hardware, so if you want to know what a training run actually costs, it has to be measured at the
  plug.
- **A shared artifact tree** at `/srv/...`, deliberately outside any directory that `rsync --delete`
  owns.

## What it will not do to your machine

This matters more than the feature list, because provisioning tools are trusted with root.

- **Never flashes firmware.** Config management that flashes an EC on every converge is how a box
  gets bricked unattended. The firmware role asserts the version and reports drift. Rollback is a
  runbook for a human.
- **Never resets your firewall.** It only ever *adds* allow rules. Locking yourself out of a
  WiFi-only box means walking to it.
- **Never creates accounts you did not name.** A fresh clone has an empty user list. Nobody else's
  SSH keys land on your box.
- **Never disables services it did not create.** It lists the surprising ones and leaves them alone.
- **Never reboots.** The one role that requires a reboot tells you so and stops.

## Scope

`sparkup` gets the box into a known state and gets metrics into Prometheus. It does not own training
runs. The wrapper that emits per-run metrics and correlates them against these series is a separate
project, specified in [`docs/training-observability.md`](docs/training-observability.md).

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

## Status

Built and unverified against hardware. The offline suite (`make offline`) is green, CI is green, and
the acceptance test that needs a real box has not run yet. `PROMPT.md` tracks exactly what is proven
and what is not.
