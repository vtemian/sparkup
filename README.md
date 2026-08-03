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

- **A dashboard at `http://spark.local`.** GPU load, temperature, power and clocks, plus CPU,
  memory and disk. No login to look at it.
- **Monitoring that comes back after a reboot**, and tells you when it hasn't.
- **Working GPU containers.** `docker run --gpus all` does what you expect.
- **Somewhere safe for datasets and checkpoints**, where a laptop sync can't wipe them.
- **What a run costs in electricity**, if you plug the box into a smart meter. Optional, and the
  only honest way to get the number: the GPU's own reading misses about half the draw.

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
