# `shelly`

Wall-socket power and cumulative energy, from a **Shelly Plug M Gen3** read by
`easimon/shelly-exporter` and scraped by Prometheus as job `power`.

| | |
|---|---|
| Meter | Shelly Plug M Gen3, local JSON-RPC, no cloud |
| Exporter | `ghcr.io/easimon/shelly-exporter` 3.0.0, digest-pinned, `linux/arm64` verified |
| Runs as | `shelly_exporter.service`, a container under a systemd unit, `Restart=always` |
| Listens on | `shelly_exporter_port` = 9924, on the host network so ufw governs it |
| Metrics path | **`/prometheus`**, not `/metrics` |
| The number that matters | `shelly_meter_power_watthours_total` — a **counter**, in watt-hours |
| Default state | **off**. `shelly_enabled: false`, the role no-ops, the `power` job is absent |

Everything ships disabled. The plug does not exist yet, and until it does the
role installs nothing and Prometheus carries no `power` target — a permanently
red target teaches people to ignore red targets, which costs more than the
missing metric.

## Why there is a plug at all

**This box exposes no supported path to system power.** Audited here: no hwmon
power or energy rails, an empty `/sys/class/power_supply`, `acpi_power_meter`
binding no device, no `/dev/ipmi*` and no Redfish interface. NVIDIA staff have
said three separate times on the developer forums that CPU rail information is
not exposed and there are no plans to expose it.

`nvidia-smi` reports the **GPU rail only**. Measured here, that rail idles at
**3–4 W** and peaks near **83 W** under sustained bf16 matmul.

The wall side is **not** measured here — this box has no meter, which is what
the role exists to fix. Published figures, with their caveats intact:

| Reading | Source and caveat |
|---|---|
| 87 W rail vs 180 W socket | One forum post, single session. An **MSI GB10 variant**, a fullscreen **Vulkan** demo rather than compute, and the 180 W includes a **~10 W monitor** drawing through the box. Machine-only ≈ 170 W, so ≈ **1.95×**. |
| 16–20 W rail vs 75–80 W | Kill-A-Watt, NVFP4 quantisation at ~50% utilisation. **≈ 4–5×.** |
| 22–25 W idle | Post-firmware-update, but taken with a **USB-C meter inline on the DC cable**, so DC-side, not the socket. |
| 40–45 W idle | Pre-update AC figures. |

So **~2× is the floor of the range, not its middle** — it appears only near
peak GPU load, and the multiplier climbs past 10× at idle. The steadier quantity
is the **offset**: the wall runs roughly 60–90 W above the rail under load.
Neither is a constant you can calibrate away.

Note what the rail cannot cover even in principle: NVIDIA publishes **140 W for
the GB10 SoC**, which is CPU *and* GPU together, against **240 W for the
system** — and that 240 W is a supply rating, not an observed draw; no reviewer
has exceeded about 200 W. A number that does not span its own package cannot be
the cost.

The Spark also draws through an **external brick**, so AC-to-DC conversion loss
happens outside the chassis. At roughly 88–92% efficiency that is **15–20 W at a
170 W draw** which the utility bills and which no internal register can ever
see, however good it gets.

The audit found no substitute anywhere on the box: no hwmon power or energy
rails, an empty `/sys/class/power_supply`, an empty `/sys/class/powercap` (no
RAPL), no energy PMU, no `/dev/ipmi*` and no Redfish interface.
`acpi_power_meter` is present as a module but binds `ACPI000D` only, which does
not exist here — and NVIDIA's own `/etc/nvidia-platform.d/nvidia-platform-configs.json`
sets `"EnablePowerMeterCap": "False"` for `dgx_spark` while other platforms say
`True`. NVML answers `NVML_ERROR_NOT_SUPPORTED` for every power field at
`MODULE` scope. NVIDIA's own `dgx-dashboard` shells out to
`nvidia-smi --query-gpu=power.draw`. Its cumulative counter
(`nvmlDeviceGetTotalEnergyConsumption`) does work and is worth recording as a
second series, but it is the same GPU rail — exact, and exactly half the story.

### The telemetry exists. It is simply not wired up.

This is the part worth knowing before someone tries to save the cost of a plug.
Decoding this box's DSDT turns up `NVDA8800` at `\_SB.MTEL`, whose `_DSM`
publishes a register map for the MediaTek **System Power Budget Manager**,
including:

```
SPBM_TE_SYS_TOTAL_TELEMETRY_OFFSET       0x300
SPBM_TE_TOTAL_GPU_IN_OFFSET              0x32c
SPBM_TE_TOTAL_SYS_IN_OFFSET              0x330
SPBM_PKG_ENERGY_VALUE_ACCUMULATE_OFFSET  0x344
```

Separate registers for GPU input and system input, plus a package energy
accumulator. The firmware distinguishes them; NVML only ever reports the first.

It is unreachable, four ways over: nothing on the box binds `acpi:NVDA8800:`,
the `0x1C238000` aperture is absent from `/proc/iomem`, `/dev/mem` returns
`EPERM` because Secure Boot puts the kernel in integrity lockdown, and there is
no ACPI debugger to invoke `_DSM` out of band. A third-party out-of-tree driver
(`spark_hwmon`) does bind it, at the cost of MOK enrolment on a box with a
boot-failure history.

**And even if you did all that, it would not give you cost.** Those registers
read the DC side, downstream of the external brick, so conversion loss is
invisible to them. Their units are undocumented 32-bit values with no scaling
hint in the AML, so calibrating them needs an external meter anyway. They answer
*where the power goes inside the box*, which is a genuinely interesting question
and a different one.

So a smart plug is not a workaround. It is **the only correct instrument for
cost**, because it captures what the electricity meter charges for: CPU,
memory, NVMe, fans, and the conversion loss in the brick.

## Choosing the exporter

**This is configuration, not new code.** Three maintained exporters exist, all
using the plug's local API. The decisive criterion is narrow: the exporter must
expose **cumulative watt-hours as a Prometheus counter** — a metric name ending
`_total`, typed `counter`.

That is not a stylistic preference. `aenergy.total` is integrated by the plug's
own hardware, so energy is **exact** rather than an artefact of our 15 s scrape
interval, and Prometheus's counter handling copes correctly when the device
reboots and the counter resets. An instantaneous watts gauge integrated in
PromQL is a different, worse number wearing the same units.

| | webdevops | geerlingguy | **easimon** |
|---|---|---|---|
| Wh as a **counter** | **no** | **no** | **yes** |
| linux/arm64 | yes | n/a (script) | **yes, manifest-verified** |
| Shape | Go binary / image | PHP CGI under Apache | JVM container |
| Gen3 | untested | correct RPC path | **attested, issue #132** |
| Latest release | 26.1.0 (2026-01-08) | none, ever | **3.0.0 (2026-04-12)** |

Both rejections were confirmed by reading the source, not the README — and in
one case the README is what would have misled us.

### `webdevops/shelly-plug-exporter` — rejected, and the near miss is instructive

Its README advertises `shellyplug_power_load_total`, "Total power load in
watt/hours". That reads like exactly what we need. It is neither.

- **There is not one counter in the codebase.** `shellyplug/metrics.go` has 25
  `prometheus.NewGaugeVec` and **zero** `NewCounterVec`. `powerLoadTotal` is a
  `GaugeVec` whose own help string says `"ShellyPlug current power load total
  in watts"` — the code and the README disagree about the unit.
- **On our device it is never populated at all.** `powerLoadTotal` is only
  `Set` inside `case strings.HasPrefix(configName, "em:")`, from
  `EmData.GetStatus` — the three-phase energy-meter component of a Shelly 3EM.
  A Plug M Gen3 has a `switch:0` component and no `em:`, and the `switch:`
  branch sets only `apower`, `voltage` and `current`.
- **`aenergy` is parsed and then thrown away.** The string `Aenergy` occurs
  exactly once in the whole repository: the struct field declaration in
  `shellyprober/gen2.go`. Nothing ever reads it.

Net result on this hardware: instantaneous watts, volts and amps, and no
cumulative energy whatsoever. Trusting the README here would have shipped a
false claim into our own docs.

### `geerlingguy/shelly-plug-prometheus` — rejected

It does read the hardware's `aenergy.total` from the correct Gen2/Gen3 RPC
endpoint. Then:

```
# HELP total Total energy consumed by the attached electrical appliance in Watt-minute
# TYPE total gauge
```

- **Declared a gauge**, so `rate()` and `increase()` misbehave across a device
  reboot — the one case the counter exists to survive.
- **The unit in the HELP string is wrong.** `Watt-minute` is the Gen1
  `/status` unit, copy-pasted onto the Gen2 path. Shelly's own Gen2 docs say
  `aenergy.total` is "Total energy consumed in **Watt-hours**". Anyone
  trusting that string divides by 60 and is wrong by 60×.
- Metric names are `power`, `total`, `is_valid` — unnamespaced, and `total`
  will collide with something eventually.
- It is a PHP script served by Apache as CGI, not a daemon. The author's own
  `.htaccess` comment calls the approach "a dumb idea if you're building
  anything resembling a 'real' application". He is right, and he is describing
  a deliberately simple toy, not a defect.

### `easimon/shelly-exporter` — chosen

The evidence, from `src/main/kotlin/.../metrics/ShellyGen2Metrics.kt`:

```kotlin
counter(
  "meter.power",
  "Total power consumption in watt-hours.",
  "watthours",
  switchTags
) { status(address)?.switches?.get(index)?.energy?.total }
```

`counter(...)` registers a Micrometer `FunctionCounter`; `energy` is
`@JsonProperty("aenergy")`. So the exported value is the device's own
hardware-integrated `aenergy.total`, passed through unmodified, and the scrape
output is:

```
# TYPE shelly_meter_power_watthours_total counter
shelly_meter_power_watthours_total{address="...",channel="0",...} 721189.0
```

A `_total` suffix, typed `counter`, in watt-hours, sourced from hardware. That
is the requirement, met exactly.

**arm64, verified against the registry rather than assumed.** The OCI index for
`ghcr.io/easimon/shelly-exporter:3.0.0` was queried directly and lists
`linux/amd64`, **`linux/arm64`**, `linux/ppc64le`, `linux/s390x` and
`linux/riscv64`. Index digest:

```
sha256:3032562bcff4415a39de32a169ac2c2e200ae27c9bed551cded3831d31437ac9
```

**Gen3 is attested, not inferred.** Issue #132 was a Gen3 plug
(`type=S3PL-00112EU`) failing with a `ClassCastException`; the maintainer fixed
it in 2.7.0 and the reporter confirmed working metrics. One honest gap: that
was a Plug **S** MTR Gen3, not the Plug **M** Gen3 we are buying. The RPC shape
is identical — `switch:0` with an `aenergy` block — so it should behave the
same, but no report names our exact SKU. Treat first light as a test.

### The trade-off we are accepting

It is a JVM, capped at `-Xmx64m`, where webdevops is a single static Go binary.
On a box with 121 GiB of unified memory that is not a real cost, but it is a
real difference and worth naming rather than glossing. The alternative to
paying it is not one of the other two exporters — it is writing ~50 lines that
poll `Switch.GetStatus` ourselves, which the plan explicitly rules out.

## Why a container here, when the other exporters are native

Not an inconsistency. The two reasons `roles/exporters` keeps node and GPU
telemetry off Docker are both specific, and neither applies:

- a containerised node-exporter needs `/:/host:ro,rslave`, and that mount makes
  the filesystem collector recurse every Docker overlay and hang;
- a containerised GPU exporter needs GPU-in-container plumbing, the least
  reliable piece of the stack.

This exporter needs no host mount and no device access — only a network route
to the plug. And there is nothing else to install: the project publishes a
container image and **no release binaries**, so the image *is* the artifact.

**The digest is the checksum.** `roles/exporters` verifies downloads with
`get_url`'s `sha256:` check; a registry spells the same guarantee as a content
digest. The role pulls and runs `…@sha256:3032562b…`, never a tag, so an
unchanged unit file cannot quietly start running different software.

The unit deliberately omits the `ProtectSystem=strict` block the other exporter
units carry. This process is a Docker client talking to a root-equivalent
socket — sandboxing it is theatre, and a read-only `/run` would block the
socket outright. The container runs as uid 65535 with `--cap-drop ALL
--security-opt no-new-privileges`.

### Why `--network host` and not `--publish`

This is a firewall decision. Docker inserts its DNAT and `DOCKER-USER` rules
**ahead of** ufw's chains, so a container port published with `--publish` is
reachable from the LAN no matter what ufw says. That matters here because this
exporter serves more than power: alongside the meter series it exposes `mac`,
`name`, `type` and `firmwareVersion` labels and `shelly_wifi_rssi_dbmw`, all
unauthenticated. Device inventory for anyone on the WiFi.

The repo's stated posture is that 9090, 9100 and 9835 stay off the LAN.
Port 9924 belongs in that class, and `--publish` is the one way to put it
beyond ufw's reach. On the host network it is an ordinary listening port that
ufw governs like any other, exactly as the native `node` and `gpu` exporter
units are.

Loopback publishing (`127.0.0.1:9924:8080`) is **not** the alternative:
Prometheus is containerised and reaches the host through `host.docker.internal`
— the bridge gateway, not loopback — so a loopback bind breaks scraping
entirely. Host networking keeps that path working, which is the same path the
other two exporters already use.

`SERVER_PORT` sets the listening port inside the container, since with host
networking there is no port mapping to do it. Verified against the pinned
image: `SERVER_PORT=9924` and `GET /prometheus` returns 200.

## The scrape target: what was wrong and what it is now

`prometheus.yml.j2` used to emit the `power` target as
`{{ shelly_host }}:{{ shelly_exporter_port }}`. **That could never have
worked**, and it is worth understanding why rather than just reading the diff.

`shelly_host` is the **plug**. The plug speaks Shelly JSON-RPC and serves no
Prometheus metrics on any port. The exporter is a **separate process** that
polls the plug's RPC and speaks the exposition format itself — and it runs on
the Spark. So the scrape target is the host running the exporter, reached from
inside the Prometheus container through the same host-gateway alias the `node`
and `gpu` jobs already use:

```yaml
  - job_name: power
    metrics_path: /prometheus
    static_configs:
      - targets: ["host.docker.internal:9924"]
```

The variable pair now says this out loud, so the two hosts cannot be confused
again:

| variable | what it is |
|---|---|
| `shelly_host` | the **plug's** reserved IP — the exporter's *configuration*, the device it polls. Never a target. |
| `shelly_scrape_host` | where **Prometheus** looks — `host.docker.internal`, the Spark, via the host gateway |

`metrics_path` matters too: this exporter is a Spring Boot app and its actuator
serves the exposition format at **`/prometheus`**. Left at Prometheus's default
`/metrics` the target reads down with a 404, which looks exactly like an
exporter that is not running.

## D0 — the meter: a human runbook

None of this is automatable, and none of it should be. Do it once, by hand,
before flipping `shelly_enabled`.

**Buy the Shelly Plug M Gen3.** 13 A / 3000 W, CEE 7/3 Schuko output and a
CEE 7/7 plug — correct for Romania, with vast headroom over a box rated at
240 W system power. Gen3 means a local RPC API and no cloud dependency.

1. **Join the 2.4 GHz SSID.** The plug is 2.4 GHz only. Pointing it at a
   5 GHz-only SSID fails in a way the app describes as a generic connection
   problem. Same subnet as the Spark.
2. **Give it a DHCP reservation on the router**, exactly as the Spark has. The
   exporter is configured with an address, and it runs in a container with no
   mDNS resolver — so `shelly_host` must be that reserved **IP**, not a
   `.local` name.
3. **Plug ONLY the Spark's PSU into it.** A monitor, a dock or a phone charger
   sharing the socket silently corrupts every run's energy figure. There is no
   way to detect this after the fact from the data; the numbers just quietly
   become someone else's.
4. **Disable the relay in the device config.** This model switches as well as
   meters. A stray tap in the Shelly app cuts power to a running training job.
   Metering does not need the relay to be operable.
5. Leave the local HTTP API unauthenticated (the Shelly default) or set a
   password — see below.

Only then set `shelly_host` in `host_vars/spark.yml` and flip `shelly_enabled`
to `true`.

### If you set a password on the plug's local API

The role does not template one, deliberately: the unit file is mode `0644` and
a secret does not belong in it. Write an `EnvironmentFile` by hand, mode
`0600`, root-owned, containing `SHELLY_GEN2AUTH_PASSWORD=…`, and add an
`EnvironmentFile=` line to the unit. The username is fixed to `admin` upstream
and cannot be changed on the device.

### What the plug reports

`GET /rpc/Switch.GetStatus?id=0` returns, per Shelly's Gen2 documentation:

| field | meaning |
|---|---|
| `apower` | last measured instantaneous active power, **watts** |
| `voltage` | volts |
| `current` | amperes |
| `freq` | mains frequency, Hz |
| **`aenergy.total`** | **total energy consumed, watt-hours** — hardware-integrated |
| `aenergy.by_minute` | last three complete minutes, in **milliwatt-hours** |

The two `aenergy` fields use different units. `total` is what we export, and it
is Wh.

## What lands in Prometheus

The metrics that matter, all tagged `address`, `mac`, `type`, `name`,
`firmwareVersion`, and `channel="0"` for a single-channel plug:

| metric | type | from |
|---|---|---|
| `shelly_meter_power_watthours_total` | **counter** | `aenergy.total` |
| `shelly_meter_power_current_watts` | gauge | `apower` |
| `shelly_meter_voltage_current_volts` | gauge | `voltage` |
| `shelly_meter_current_current_amperes` | gauge | `current` |
| `shelly_meter_frequency` | gauge | `freq` |
| `shelly_meter_powerfactor` | gauge | `pf` |
| `shelly_relay_on` | gauge | `output` |

Plus the device's own housekeeping — `shelly_wifi_rssi_dbmw`,
`shelly_uptime_seconds_total`, `shelly_temperature_degrees_celsius` and
friends. `shelly_meter_power_returned_watthours_total` exists as well; it is
grid export and will sit at zero forever here.

Energy over a window is `increase(shelly_meter_power_watthours_total[1h])`. The
per-run join belongs to the training-observability project, not to this repo —
what `sparkup` owes it is a live `power` job.

**The plug measures the whole box and can never carry a `run_id` label.**
Attribution is by time window, which is precisely why runs must be serialised.
Two overlapping runs do not produce two wrong numbers; they produce one number
attributed twice.

## Accuracy, and what we do not know

**Low-load accuracy for this model is unpublished.** Shelly documents no
accuracy figure at the bottom of the range for the Plug M Gen3, and we have no
reference meter to characterise it against.

Under load this does not matter — at tens to hundreds of watts, any plausible
error is small relative to the reading. But the **idle baseline carries more
relative error than the loaded figure**, and the idle baseline is exactly what
gets subtracted to compute "what did this run cost". Record the caveat next to
the number rather than presenting a precision we cannot support. If idle power
ever becomes load-bearing, characterise it against a known resistive load
rather than assuming.

Two things that are *not* sources of error, and are worth knowing so nobody
goes hunting: the plug integrates energy in hardware, so a scrape gap loses
resolution but **not total energy** — the counter's next value already contains
the missed interval. And a device reboot resets the counter, which Prometheus's
counter handling is built for.

### Clock discipline

**Let Prometheus scrape the exporter, so every timestamp comes from one
clock.** Prometheus stamps each sample at scrape time with its own clock, the
same clock that stamps the `node` and `gpu` series, which is what makes power
and GPU utilisation comparable on one graph.

**Never trust the plug's own clock.** The device does carry timestamps —
`aenergy.minute_ts` — but it is a WiFi appliance whose time comes from
wherever NTP left it, and a skewed clock would silently shift energy into the
wrong run's window. Nothing in this role reads it, and nothing should.

## Verifying

**Not with `curl`.** `curl 127.0.0.1:9100` hangs on this box even when the
exporter is healthy, and people have chased that as a bug. Verify through
Prometheus:

```promql
up{job="power"} == 1
scrape_samples_scraped{job="power"} > 0
shelly_meter_power_watthours_total
increase(shelly_meter_power_watthours_total[1h])
```

**`up == 1` is not sufficient here, and this is the trap of this role.** The
exporter answers `/prometheus` whether or not it has ever reached the plug — it
discovers devices on an interval and simply exposes nothing for a device that
does not respond, logging the reason. So a green target with no
`shelly_meter_power_watthours_total` series means the exporter is fine and the
**plug** is unreachable: wrong IP, wrong SSID, or listed under the Gen1
variable. The third metric in that list, not the first, is the real check.

`increase()` over an hour is watt-hours, so an idle box drawing 40–45 W should
land near **40–45 Wh**, and a loaded one near **170–180 Wh**. Anything in the
hundreds for an idle box means the plug is metering more than the Spark.

**Do not sanity-check it against `nvidia-smi`.** The wall-to-rail gap is not a
constant: roughly 2× under sustained load, but **over 10×** at idle, because the
rail falls to 3–4 W while the rest of the box does not. Comparing the two during
first light — which happens on an idle box, since you install the plug before you
train — makes a correctly working plug look like it is double-counting. That
varying gap is the reason this role exists.

Locally, `systemctl status shelly_exporter` and
`journalctl -u shelly_exporter` are safe and do not hang. Device discovery
failures are logged with a reason, so the journal is where a silent plug
explains itself.

Then reboot once. `Restart=always` covers crashes and
`WantedBy=multi-user.target` covers boot, but only a reboot proves the second
one — and only a reboot proves the unit comes up after `docker.service`.

## Idempotency

A second run reports `changed=0`.

- the image is pulled by **digest** with `pull: not_present` — immutable
  content, so there is nothing to re-check and a converge does not need the
  internet;
- the unit file is a template, so it notifies the restart handler only when the
  digest, the plug address or the port actually changes;
- `systemd_service` with `enabled: true, state: started` is a no-op once the
  unit is enabled and running.

`daemon_reload` appears both in the task and in the handler on purpose: on a
first run the unit file is brand new and systemd must be told about it before
it can be enabled.

## Turning it off again

`shelly_enabled: false` makes the role a **complete no-op** — that is the
requirement, so it does not tear anything down. Flipping it back to `false`
after a successful install therefore removes the `power` scrape job and leaves
the unit running. That is harmless but untidy, and it is a manual cleanup on
purpose rather than a speculative code path:

```bash
sudo systemctl disable --now shelly_exporter.service
sudo rm /etc/systemd/system/shelly_exporter.service
sudo systemctl daemon-reload
```

## Wiring

This role runs from `site.yml`, sequenced before `monitoring` so the exporter exists before
Prometheus is told to scrape it. It is a complete no-op while `shelly_enabled` is false. It shares
nothing with `exporters` but the Prometheus config they both feed.
