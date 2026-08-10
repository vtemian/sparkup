<p align="center">
  <img src=".github/mascot.png" alt="sparkup" width="240" />
</p>

<h1 align="center">sparkup</h1>

<p align="center">
  Your DGX Spark, as code.
</p>

---

Takes a box from a fresh DGX OS install to a working training machine: user accounts, Docker with
the NVIDIA runtime, supervised GPU and system telemetry, and Grafana on `http://spark.local` with no
login to look at it. Whole-system power and energy are available too, from the firmware, if you opt
in to a kernel module.

## What it looks like

One dashboard, provisioned from a file in this repo. A status strip you can read from across the
room, then the power the firmware reports and the cap it is being held to, the GPU rail measured both
ways so you can see `nvidia-smi` reading low, clocks, temperatures, CPU, unified memory, network,
disk, and a row saying whether the exporters themselves are still alive. Whole-system power is the part you opt
into: without it the three leftmost tiles and the Power row read "No data", and every panel that does
says so in its own description. Everything else arrives by default.

<p align="center">
  <img src=".github/dashboard.png" alt="The spark-overview dashboard" />
</p>

## Before you run it

This is root-level automation aimed at one specific machine. It assumes a DGX Spark running a DGX OS
built on Ubuntu 24.04, with Secure Boot **enabled**. The playbook refuses to start without Secure
Boot, before changing anything. On an older base it fails later and less clearly, when apt has no
`linux-image-nvidia-hwe-24.04`.

Read this list. On a converged box it will:

- **Rename the host to `spark`** and publish it over mDNS as `spark.local`. Set `spark_hostname`
  in your `host_vars` for a different name.
- **Enable `ufw` with a default-deny incoming policy.** Only 22 and 80 stay open. Anything else you
  serve stops answering. It asserts the port your SSH session arrived on is allowed first, so it
  cannot lock you out, but it will not ask about your other services.
- **Restart Docker**, stopping running containers. Your `/etc/docker/daemon.json` is merged, not
  replaced, so a `data-root` or registry mirror survives.
- **Serve Grafana on port 80 with anonymous read access, reachable from your LAN.** No login. See
  [SECURITY.md](SECURITY.md).
- **Stage any firmware `fwupd` offers**, which the next reboot writes. Older EC firmware reports
  wrong CPU power values, which is why this is not optional. It never reboots for you.
- **Repoint GRUB** at the signed kernel and pin unsigned kernels out of apt.

`make report` prints what your box is and what would stop a converge, without changing it. It needs
no sudo, only `make deps` and your address in `inventory/hosts.yml`.

## Whole-system power, if you want it

`nvidia-smi` sees the GPU rail alone, which is about half of what the box pulls. The firmware knows
the real figure, and [`spbm`](roles/spbm/README.md) is what reads it: a DKMS driver built from
[antheas/spark_hwmon](https://github.com/antheas/spark_hwmon), packaged by
[vtemian/spark-spbm-builder](https://github.com/vtemian/spark-spbm-builder) and served from
`ppa:vladtemian/spark-spbm`.

It is **off by default**, because it costs two things nothing else here does: third-party code in
kernel space, and a trip to the machine. Secure Boot will not load the module until its key is
enrolled at a blue MokManager screen that needs a keyboard and a monitor, and no converge can do
that for you. Leave it off and the Power row on the dashboard stays empty; nothing else differs.

```yaml
# host_vars/spark.yml
spbm_enabled: true
```

Then `make apply`, reboot with a keyboard attached, and enrol the key.
[roles/spbm/README.md](roles/spbm/README.md) has the screen-by-screen version.

## Setup

You need `ansible-core` on your own machine, and SSH access to the Spark as an account with sudo.

```bash
make deps                                            # once
cp host_vars/spark.yml.example host_vars/spark.yml   # untracked; your accounts
$EDITOR host_vars/spark.yml
$EDITOR inventory/hosts.yml                          # your address and SSH user
```

On a fresh box put its **IP** in `ansible_host`: `spark.local` only resolves after the first
converge has installed avahi. Keep the inventory host named `spark` whatever your machine is called.

```bash
make apply     # converge
```

Then `make apply` again. It must report `changed=0`.

`make check` shows what a converge would change without changing it, but only on a box that has
been converged once. A dry run cannot create the shared group, so on a fresh machine it fails
adding your accounts to a group that does not exist yet.

## The first reboot

The converge ends by printing what your next reboot will do, because it is usually two things at
once: a firmware write and a boot into the signed kernel. Do it on mains power. An interrupted
firmware write is not recoverable on this hardware.

With `spbm_enabled: true` there is a third: a blue MokManager screen asking for the Secure Boot key
password (`sparkup` unless you changed it), which needs a keyboard and a monitor attached.

## Layout

```
site.yml              the playbook
report.yml            reads a box and prints what it is, changing nothing
inventory/hosts.yml   which box
group_vars/all.yml    defaults for any Spark
host_vars/spark.yml   your box (untracked)
roles/                base, docker, gpu, users, spbm, exporters, monitoring, firmware, kernel, report
tests/                everything that runs without a Spark
.claude/skills/       diagnosing and benchmarking the box, if you drive it with Claude Code
```

Each role has its own README. Running the playbook produces the machine described above, and per-box
identity lives in `host_vars`. The one thing you can switch on or off is `spbm_enabled`, because it
is the one thing that needs your consent to run third-party code in kernel space.

`make offline` runs lint, every dashboard query against a real Prometheus, and two roles converged
twice in containers. None of it needs a Spark.

## License

MIT
