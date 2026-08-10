# `spbm`

Installs the `spark_hwmon` DKMS driver from a PPA and queues its signing key for MokManager, giving
whole-system power and energy as hwmon sensors. It does not reboot; the key is enrolled by hand at
the console.

**Off by default.** This is the only role a plain `make apply` does not run, and the only one that
asks for two things the rest of the playbook never does: third-party code running in kernel space,
and a person standing at the machine with a keyboard and a monitor. Skipping it costs you the dashboard's
Power row and the three power tiles on its status strip, which then read "No data" and explain why in
their own descriptions. Nothing else changes.

## Turning it on

```yaml
# host_vars/spark.yml
spbm_enabled: true
```

```bash
make apply     # builds and signs the module, queues the key, stays green
```

Then reboot **with a keyboard and a monitor attached**. Before the OS loads, shim shows a blue
MokManager screen: Enroll MOK, Continue, Yes, then type the password (`sparkup` unless you changed
it). There is no network and no SSH at that point, so this step cannot be done remotely and cannot
be done by the playbook. The screen waits `spbm_mok_timeout` seconds. Miss it and it cancels
harmlessly, and the next converge queues the key again.

Check it afterwards through Prometheus, never by curling the exporter:

```sh
curl -s --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=node_hwmon_power_watt'
```

An empty result means the module is built but not loaded, which means the key is still not trusted.
Every converge says so until it is.

## Turning it off again

Setting `spbm_enabled: false` stops the role running; it removes nothing. The module stays
installed, the PPA stays configured and the metrics keep arriving. Undoing it for real means
removing the `spbm-dkms` package and the `spark-spbm` apt source by hand.

## Variables

| Variable | Default | |
|---|---|---|
| `spbm_enabled` | `false` | lives in `group_vars/all.yml`, not here: `site.yml` reads it to decide whether the role runs at all |
| `spbm_ppa` | `ppa:vladtemian/spark-spbm` | carries the DKMS package |
| `spbm_package` | `spbm-dkms` | |
| `spbm_headers_package` | `linux-headers-nvidia-hwe-24.04` | kept installed so DKMS can rebuild for a new kernel |
| `spbm_mok_cert` | `/var/lib/shim-signed/mok/MOK.der` | the key DKMS signs with |
| `spbm_mok_timeout` | `120` | seconds MokManager waits for a keypress. shim's own default of 10 is too short for a display to wake |
| `spbm_mok_password` | `sparkup` | typed once at MokManager. Not a secret; do not put one here |

## What you get

node_exporter's `hwmon` collector picks the channels up with no further configuration:

```sh
curl -s localhost:9100/metrics | grep node_hwmon_power_watt
```

14 power channels (`sys_total`, `dc_input`, `cpu_gpu`, `soc_pkg`, `gpu`, the PL1/PL2 limits), 4
energy accumulators (`pkg`, `cpu_e`, `cpu_p`, `gpu`) and 8 temperatures, all as hwmon sensors. No
extra exporter, no extra scrape job, no hardware.

The four limit channels also carry `node_hwmon_power_cap_watt`, the limit in force, and
`node_hwmon_power_max_watt`, the firmware ceiling above it. No other channel does. A `pl1` reading
means nothing without the cap beside it, because 140 W is the stock module budget and 20 W is the
USB-PD safety mode and the channel reads the same way in both. On the reference box:

| channel | cap | ceiling |
|---|---|---|
| `pl1` | 140 W | 250 W |
| `pl2` | 142 W | 250 W |
| `syspl1` | 231 W | 300 W |
| `syspl2` | 244 W | 300 W |

All eight temperatures carry a real reading. `tj_max` is a temperature despite the name, tracking the
`gpu` zone, not a limit. The one channel that reads nothing is the `dla` **power** rail, at 0.01 W.

The driver also exposes `prochot`, `pl_level` and `tj_max_c` as plain sysfs attributes rather than
hwmon channels, so node_exporter cannot see them and no panel uses them. Their encoding is
undocumented and the first two read a constant 1 on an idle box, so there is nothing yet to plot.

`node_hwmon_power_watt` is a gauge; `node_hwmon_energy_joule_total` is a **counter** in
**joules**, not watt-hours. The metric drops the sysfs `_input` suffix that the filename carries,
so the obvious spelling is the wrong one. Both are labelled `chip` and `sensor`, where `sensor` is
`power1`/`energy1` rather than the human name, so join `node_hwmon_sensor_label` to get `sys_total`:

```promql
node_hwmon_power_watt * on(chip, sensor) group_left(label) node_hwmon_sensor_label
```

There are 14 power channels but only 4 energy accumulators, and **none of them is `sys_total`**, so
whole-box energy is a gauge integral rather than an `increase()`.

`sys_total` is the firmware's DC-side figure. It excludes PSU conversion loss, so it reads somewhat
under a wall-socket meter. It is still the whole box, unlike `nvidia_smi_power_draw_watts`, which is
the GPU rail alone and roughly half the truth: 87 W at the rail against 180 W at the socket,
measured here.
