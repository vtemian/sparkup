<p align="center">
  <img src=".github/mascot.png" alt="sparkup" width="240" />
</p>

<h1 align="center">sparkup</h1>

<p align="center">
  Your DGX Spark, as code.
</p>

---

Takes a box from a fresh DGX OS install to a working training machine: user accounts, Docker with
the NVIDIA runtime, supervised GPU and system telemetry, whole-system power and energy read from
the firmware, and Grafana on `http://spark.local` with no login to look at it.

## What it looks like

One dashboard, provisioned from a file in this repo: GPU load, temperature, power and clocks;
CPU, unified memory and disk; and a row saying whether the exporters themselves are still alive.

<p align="center">
  <img src=".github/dashboard.png" alt="The spark-overview dashboard" />
</p>

## Before you run it

This is root-level automation aimed at one specific machine. It assumes a DGX Spark running DGX OS,
with Secure Boot **enabled** — the playbook refuses to start otherwise, before changing anything.

Read this list. On a converged box it will:

- **Rename the host to `spark`** and publish it over mDNS as `spark.local`.
- **Enable `ufw` with a default-deny incoming policy.** Only 22 and 80 stay open. Anything else you
  serve stops answering. It asserts the port your SSH session arrived on is allowed first, so it
  cannot lock you out, but it will not ask about your other services.
- **Restart Docker**, stopping running containers. Your `/etc/docker/daemon.json` is merged, not
  replaced, so a `data-root` or registry mirror survives.
- **Serve Grafana on port 80 with anonymous read access, reachable from your LAN.** No login. See
  [SECURITY.md](SECURITY.md).
- **Install a third-party kernel module.** Whole-system power comes from `spbm`, a DKMS driver built
  from [antheas/spark_hwmon](https://github.com/antheas/spark_hwmon), packaged by
  [vtemian/spark-spbm-builder](https://github.com/vtemian/spark-spbm-builder) and served from
  `ppa:vladtemian/spark-spbm`. It runs in kernel space. If you would rather not, remove the `spbm`
  role from `site.yml` and you lose only the power and energy metrics.
- **Stage any firmware `fwupd` offers**, which the next reboot writes. Older EC firmware reports
  wrong CPU power values, which is why this is not optional. It never reboots for you.
- **Repoint GRUB** at the signed kernel and pin unsigned kernels out of apt.

## Setup

```bash
make deps                                            # once
cp host_vars/spark.yml.example host_vars/spark.yml   # untracked; your accounts
$EDITOR host_vars/spark.yml
$EDITOR inventory/hosts.yml                          # your address and SSH user
```

On a fresh box put its **IP** in `ansible_host`: `spark.local` only resolves after the first
converge has installed avahi. Keep the inventory host named `spark` whatever your machine is called.

```bash
make check     # see what would change, change nothing
make apply     # converge
```

Then `make apply` again. It must report `changed=0`.

## The first reboot

The converge ends by printing what your next reboot will do, because it is usually three things at
once: a blue MokManager screen asking for the Secure Boot key password (`sparkup` unless you changed
it), a firmware write, and a boot into the signed kernel. Do it with a keyboard attached and mains
power — an interrupted firmware write is not recoverable on this hardware.

Power and energy metrics only appear after that key is enrolled.

## Layout

```
site.yml              the playbook
inventory/hosts.yml   which box
group_vars/all.yml    defaults for any Spark
host_vars/spark.yml   your box (untracked)
roles/                base, docker, gpu, users, spbm, exporters, monitoring, firmware, kernel
tests/                everything that runs without a Spark
```

Each role has its own README. There are no feature flags: running the playbook produces the machine
described above, and per-box identity lives in `host_vars`.

No Spark? `make offline` runs lint, every dashboard query against a real Prometheus, and two
roles converged twice in containers.

## License

MIT
