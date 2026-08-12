---
name: spark-diagnosis
description: Use when a DGX Spark seems slow, hot, throttled or underpowered - "why does my GPU only draw 60 W", "why can't I reach 240 W", "is my box throttling", "GPU stuck at low clocks", "training got slower". Reads the firmware power channels, which are the only instrument on this hardware that tells the truth.
---

# Diagnosing a DGX Spark

Work through this in order. Do not skip to a fix.

## Rule zero: never diagnose from nvidia-smi

On GB10, NVML sits above the Embedded Controller. It reads the GPU rail **low** — between 18 % and
44 % under across measured runs, so the direction is reliable and the magnitude is not worth quoting.
It reports `power.limit` as `[N/A]` forever, and leaves every Clocks Event Reason at `Not Active`
through a throttle the EC is actively enforcing. A box can be pinned at its power cap while
`nvidia-smi` reports no throttling at all.

Every number that decides anything below comes from the `spbm` firmware channels.

## Step 0 — reach the box

If `spark.local` does not resolve, you are not on its LAN. mDNS does not leave the network, so a box
that answered from the sofa is unreachable from anywhere else — that is not a fault to diagnose.

Where the `tailscale` role is configured, the box answers on a tailnet as well, under a name that is
assigned rather than chosen. `make report` prints it on the `Reachable from` line, and so does a
converge scoped to `--tags tailscale`. From any device signed into the same tailnet:

```sh
ssh <user>@<name>.<tailnet>.ts.net
```

If that line says the box is on this LAN only, remote access is not set up and no amount of
diagnosing changes it: see `roles/tailscale/README.md`. Do not respond by opening a port or editing
the firewall — the whole design is that nothing is exposed, and this repo's rules forbid weakening a
firewall on a box nobody can physically reach.

## Step 1 — get the channels

```sh
make report
```

`make report` needs no sudo, which is why it is first. Anything that *changes* the box does, and `-K`
prompts interactively, which an agent cannot answer. Pass the password file instead:

```sh
make apply BECOME="--become-password-file ~/.sparkup-become"
```

That file lives outside the repo at mode `0600` and is never committed. If it is missing, the human
creates it; never ask anyone to paste a password into a transcript.
[INSTALL_CLAUDE.md](../../../INSTALL_CLAUDE.md) step 4 has the setup and the check that it works.
A bare `make apply` also runs `firmware` and `kernel`, and CLAUDE.md says not to decide those alone,
so scope the converge to what you are fixing. Read the tag's own trap first: `--tags monitoring` on a
box that still runs a containerised node-exporter deletes it and gives nothing back, because the role
uses `remove_orphans: true`. See INSTALL_CLAUDE.md, "Play order is load-bearing".

Read the `WHOLE-SYSTEM POWER` section. Every channel prints its reading; only `pl1`, `pl2`, `syspl1`
and `syspl2` also print the cap in force and the firmware ceiling, because only those four carry them.
Ten channels with no cap column is correct output, not truncated output.

**If it says `spbm module not loaded`**, there is no power instrumentation on this box and you
cannot diagnose power at all. That is the default state and not a fault. Enabling it is `spbm_enabled`
in `host_vars`, and it requires a human at the machine with a keyboard to answer MokManager — see
`roles/spbm/README.md`. Do not flip it for a box nobody can physically reach. Stop here.

## Step 2 — read the caps, then branch

Look at the `pl1` and `syspl1` cap columns.

### pl1 cap ~20 W, syspl1 cap ~30 W → the EC safety mode

The box is wedged after a failed USB-C PD negotiation. The GPU will sit near 500 MHz. This is a
hardware state, not a software one.

**Only a cold drain clears it.** Reboots do not — one box stayed wedged through three, because the EC
and PD controller keep state on the standby rail and `shutdown -h now` leaves that rail live. Writing
`0` to `powerN_cap`, which the driver documents as a reset, does not clear it either.

Tell the owner to: shut down, unplug the PSU at both the wall and the unit, remove every USB-C
peripheral, hold the power button 30 s, leave it disconnected 10 minutes, then reconnect. Confirm the
fix by re-running `make report` and checking the caps came back healthy.

You cannot do this over SSH. Hand it to the human and say so plainly.

### Caps healthy, but the SM clock is stuck near 500 MHz

Same wedge, caught from the other side. Follow the cold drain above.

For reference, a healthy idle SM clock is **2418 MHz**, which is `Default Applications Clocks` —
what the GPU asks for, not what it holds. Under a saturating job the power cap pulls the sustained
clock to roughly **2150 MHz**, and that is also healthy: it is the cap doing its job, not a fault.
The `3003 MHz` that `nvidia-smi` reports as `Max Clocks` is the top of the clock table and never
sustained. Neither gap is throttling to chase.

### Caps healthy, and pl1 is well below its cap under load → not power-limited

This is the common case and usually not a fault. `pl1` is the GB10 module budget; if a running
workload leaves it 20 W short of its cap, the workload is **not compute-bound**.

Low power does not mean slow. Memory-bandwidth-bound kernels draw less than a dense GEMM by nature,
and on LPDDR5X that is a very likely explanation for a training job. The gap is a symptom to explain,
not headroom to reclaim.

Do not respond by raising limits or chasing clocks — neither does anything for a job that is not
compute-bound. Profile it: look for dataloader starvation, a host sync per step, small unfused
kernels, optimizer overhead.

### Caps healthy, and pl1 is pinned at its cap under load → at the ceiling

Working as designed. There is nothing to fix. `pl1` is the limit that binds on this hardware, and it
binds long before the system budget does.

If the complaint is "I can't reach the 240 W on the spec sheet": that is the PSU rating. About 70 W
of it is structurally unreachable, because `pl1` caps the module and the rest of the board only adds
~31 W. `syspl1`'s much larger cap is never approached. Say so and stop; the box is not broken.

## Step 3 — sampling under load, when one instant is not enough

`make report` is a single sample, so it cannot tell "pinned at the cap" from "briefly near it". To
watch the channels over time, sample on the box:

```sh
ssh <box> 'for i in $(seq 1 40); do
  for d in /sys/class/hwmon/hwmon*; do [ "$(cat $d/name)" = spbm ] && H=$d; done
  for f in $H/power*_label; do
    b=${f%_label}
    case "$(cat $f)" in pl1|sys_total|gpu|cpu_p)
      printf "%s=%s " "$(cat $f)" $(( $(cat ${b}_input) / 1000000 )) ;;
    esac
  done; echo; sleep 0.5
done'
```

**Find the device by name and the channels by label, never by index.** `power10` sorts before
`power2`, so a positional read silently returns a different channel, and the hwmon index moves across
boots.

## Step 4 — before blaming the hardware

Check what else is on the GPU:

```sh
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

A live training job made a benchmark GEMM read 9.3 TFLOP/s instead of 23.75 — a 2.5× error that sent
an earlier investigation chasing the toolchain for nothing. Contended measurements are valid for
peak power and worthless for throughput.

## Things not to do

- **Do not raise `pl1`** to make the numbers look better. It is writable and its ceiling is 250 W, but
  GB10 reports `N/A` for every thermal-limit register, so there is no Tjmax to raise it against. Heat
  is not the limiter at the stock cap — saturated, the GPU sits at 82 °C with zero thermal slowdown of
  any kind — but that says nothing about a raised one. This is firmware territory. Ask the owner first.
- **Do not add a fan curve.** The advice circulating for this hardware addresses a thermal throttle
  that measurement did not find on this box.
- **Do not unload `spbm` to rule it out.** It is the only instrument that can see any of this.

`INSTALL_CLAUDE.md`, section "What the box can actually draw", holds the measured evidence behind
every claim here.
