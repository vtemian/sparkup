# sparkup

Your DGX Spark, as code.

Takes a box from a fresh DGX OS install to a working training machine: user accounts, Docker with
the NVIDIA runtime, supervised GPU and system telemetry, and Grafana on `http://spark.local` with no
login to look at it. Optionally, what a training run costs in electricity (requires a smart plug).

```bash
make deps      # once
make check     # see what would change
make apply     # converge
```

Setup, configuration and operations live in **[INSTALL_CLAUDE.md](INSTALL_CLAUDE.md)**. It is
written for AI agents driving this repo, which makes it blunt about invariants and failure modes;
it is also the complete reference if you are doing it by hand.

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
