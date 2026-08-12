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
  <img src=".github/dashboard.png" alt="The box-overview dashboard" />
</p>

Those numbers come from `make harness-up`, not from a Spark, so nobody mistakes them for a
measurement. The channels behind them are calibrated to a real box: the peaks are what one machine
actually drew.

## Installation

Paste this to your coding agent. It works from any directory, and it reads the guide before it
touches anything.

```text
Set up my DGX Spark with sparkup. Read the guide first:

curl -s https://raw.githubusercontent.com/vtemian/sparkup/main/INSTALL_CLAUDE.md

Fetch it with curl, not a tool that summarises pages. It is a procedure, and the
rules that stop you breaking my machine do not survive a summary.

Then follow its first-run steps in order, starting from step 0. Stop at `make
report` and show me that output before anything changes the box.

I own this machine and may be the only one who can physically reach it. Do not
reboot it, do not touch firmware, and do not set spbm_enabled without asking me.
```

You can also just read [INSTALL_CLAUDE.md](INSTALL_CLAUDE.md) yourself. It is the same guide, written
to be followed by either of you.

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
[roles/spbm/README.md](roles/spbm/README.md) has the screen-by-screen version. It also documents
the 14 power channels, the PromQL that joins them to their sensor labels, and three readings that
do not mean what their names or upstream's README suggest: `prochot` reads 1 always and does not
report throttling, `tj_max_c` is a temperature and not a rise, and none of the eight temperatures
is a junction temperature.

## Reaching it from outside the house, if you want it

A Spark is usually headless and on WiFi, which makes it a machine you want to reach and a machine you
should not expose. [`tailscale`](roles/tailscale/README.md) dials **out** to join a private network,
so there is no port to forward, nothing on a public address, and no change to the firewall beyond one
rule scoped to the VPN interface.

Name the box and converge:

```yaml
# host_vars/spark.yml
tailscale_hostname: spark
```

The converge installs it and stops, because joining needs a browser. It prints the one command to
run:

```bash
sudo tailscale up --hostname=spark
```

Approve the URL that prints, put Tailscale on your laptop under the same account, and
`ssh you@spark.your-tailnet.ts.net` works from anywhere. `make report` shows the name and address the
box answers to.

Empty leaves everything alone: no packages, no rules, nothing installed. Before you add a **second
person** rather than a second device, read [roles/tailscale/README.md](roles/tailscale/README.md) —
Grafana has no login and the registry speaks plain HTTP, both deliberate on a home LAN and both worth
a second look on a shared network.

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
roles/                base, tailscale, docker, gpu, users, spbm, exporters, monitoring, registry,
                      sparks, queue, firmware, kernel, report
tests/                everything that runs without a Spark
.claude/skills/       diagnosing and benchmarking the box, if you drive it with Claude Code
```

`spark-diagnosis` answers "why is my box slow, hot or drawing less than the spec sheet";
`spark-benchmark` measures throughput and peak power without the three mistakes that have
produced wrong numbers on this hardware. Both load automatically for anyone working in this
clone. `make skills` links them into `~/.claude/skills` so they work from other directories
too, and is the only reason you would run it.

Each role has its own README. Running the playbook produces the machine described above, and per-box
identity lives in `host_vars`. The one thing you can switch on or off is `spbm_enabled`, because it
is the one thing that needs your consent to run third-party code in kernel space.

`make offline` runs lint, every dashboard query against a real Prometheus, and two roles converged
twice in containers. None of it needs a Spark.

## License

MIT
