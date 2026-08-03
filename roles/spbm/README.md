# `spbm`

Whole-system power telemetry on a DGX Spark, as ordinary hwmon sensors.

`nvidia-smi` reports the GPU rail alone. On this hardware that rail idles at
3–4 W and peaks near 83 W, while NVIDIA rates the GB10 SoC at 140 W for CPU
*and* GPU together inside a 240 W system. The rail does not span even its own
package. The firmware measures the rest and keeps it in a region called the
System Power Budget Manager, maintained by the MediaTek SSPM co-processor,
which no shipped driver binds.

`antheas/spark_hwmon` binds it. This role installs that driver from a PPA as a
DKMS package.

| | |
|---|---|
| Default state | **off**. `spbm_enabled: false` |
| Source | `ppa:vtemian/spark-spbm`, built by [spark-spbm-builder](https://github.com/vtemian/spark-spbm-builder) |
| What you get | 14 power channels, 4 energy accumulators in mJ, 8 thermal zones |
| Survives kernel upgrades | yes, via DKMS |
| Needs a human | **once**, to enrol the signing key at the console |

## Why one step cannot be automated

Secure Boot will not load a module signed by a key it does not trust. A PPA
cannot get modules signed by Canonical's key, so DKMS signs with a key
generated on your machine, and that key only enters the trust store through
**MokManager** — a screen shim shows before the OS starts, with no network and
no SSH.

So this role installs the package, queues the key, and stops. Same shape as the
`kernel` role stopping at a reboot it will not perform.

`mokutil` normally prompts on a tty. It has a documented way round that, which
is what makes the rest of this a role rather than a runbook: `--generate-hash`
produces a password hash, `--hash-file` queues it, and the plaintext is only
ever typed by a human at the console.

## Running it

```sh
ansible-playbook site.yml -K --tags spbm \
  -e spbm_enabled=true -e spbm_mok_password='something-you-will-remember'
```

Pass the password on the command line rather than putting it in `host_vars`: it
is used once, at the next boot, and never again.

Then reboot. Before the OS loads, shim shows a blue screen:

1. **Enroll MOK**
2. **Continue**
3. **Yes**
4. Type the password

A keyboard has to be attached. If you miss the prompt it cancels harmlessly and
you re-run the role.

Afterwards:

```sh
sudo modprobe spbm
sensors | grep -A20 spbm
```

Re-running the role once the key is enrolled is a no-op: it asks
`mokutil --test-key` first and queues nothing.

## What it reads

`sys_total` is the number that matters, around 25 W at idle. Also `dc_input`,
`soc_pkg`, `cpu_gpu`, `cpu_p`, `cpu_e`, `vcore`, `prereg`, `gpu`, `dla`, and the
four EWMA channels the firmware's PID controllers see. `gpu` should track
`nvidia-smi`, which is a useful built-in cross-check.

Upstream notes the **energy accumulators are more accurate than instantaneous
power** for averages, because the firmware runs a 100 ms PID loop that makes
instantaneous values oscillate. Same argument this repo makes for preferring a
plug's cumulative counter over its power gauge.

## What it still cannot tell you

These registers read the **DC side**, downstream of the external power brick.
Conversion loss is invisible to them: at roughly 88–92% efficiency that is
15–20 W at a 170 W draw which the utility bills and no internal sensor can see.
Standby draw is invisible too, since the firmware is not running to report it.

So this answers *where the power goes inside the box*, which no plug can. It
does not replace a plug for *what you owe*. Both are useful; they are not
substitutes.

## Firmware

Upstream warns that older firmware misreports the CPU power channels and tells
you to update the BIOS with `fwupd`. The `firmware` role in this repo does that,
and this box was updated to EC `0x03000508` before the driver was installed. If
your CPU channels look implausible, check your firmware before suspecting the
driver.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `spbm_enabled` | `false` | The gate |
| `spbm_ppa` | `ppa:vtemian/spark-spbm` | Where the DKMS package comes from |
| `spbm_package` | `spbm-dkms` | |
| `spbm_headers_package` | `linux-headers-nvidia-hwe-24.04` | **Load-bearing.** Without it a new kernel arrives with no headers, DKMS cannot build, and the module silently disappears |
| `spbm_mok_cert` | `/var/lib/shim-signed/mok/MOK.der` | The key DKMS signs with |
| `spbm_mok_password` | `""` | One-time, typed at MokManager. Pass with `-e`, do not store |

## Traps

- **The module builds fine and still will not load** until the key is enrolled.
  `modprobe` says `Key was rejected by service`. That is expected before the
  reboot, not a fault.
- **Kernel upgrades are only safe while the headers meta package is installed.**
  Removing it breaks DKMS silently: no error, just a missing module after the
  next kernel. The role asserts it is present.
- **The enrolment is once per machine, not once per module.** Any other DKMS
  module on the box afterwards is covered by the same key.
- **A kernel API change breaks the build, not the boot.** DKMS logs it and the
  module is absent on the new kernel. Visible in `dkms status`, worth an alert
  on the metric disappearing rather than finding out months later.

## Verifying

```sh
dkms status -m spbm                       # one line per installed kernel
mokutil --test-key /var/lib/shim-signed/mok/MOK.der
modprobe spbm && sensors | grep spbm
```
