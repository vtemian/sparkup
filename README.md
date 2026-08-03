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
