# `spbm`

Installs the `spark_hwmon` DKMS driver from a PPA and queues its signing key for MokManager, giving
whole-system power and energy as hwmon sensors. It does not reboot; the key is enrolled by hand at
the console.

| Variable | Default | |
|---|---|---|
| `spbm_ppa` | `ppa:vladtemian/spark-spbm` | carries the DKMS package |
| `spbm_package` | `spbm-dkms` | |
| `spbm_headers_package` | `linux-headers-nvidia-hwe-24.04` | kept installed so DKMS can rebuild for a new kernel |
| `spbm_mok_cert` | `/var/lib/shim-signed/mok/MOK.der` | the key DKMS signs with |
| `spbm_mok_password` | `sparkup` | typed once at MokManager. Not a secret; do not put one here |

The converge queues the key and stays green. To finish it, reboot: before the OS loads, shim shows a
blue MokManager screen — Enroll MOK, Continue, Yes, then type the password. It needs a keyboard
attached; there is no network and no SSH at that point. Miss the prompt and it cancels harmlessly,
and the next converge queues it again.

Until the key is trusted the module is built but cannot load, and every converge says so. Afterwards
node_exporter's `hwmon` collector picks the channels up with no further configuration:

```sh
curl -s localhost:9100/metrics | grep node_hwmon_power_watt
```

14 power channels (`sys_total`, `dc_input`, `cpu_gpu`, `soc_pkg`, `gpu`, the PL1/PL2 limits), 4
energy counters (`pkg`, `cpu_e`, `cpu_p`, `gpu`) and 8 temperatures. The `sensor` label is `power1`,
not the name — join `node_hwmon_sensor_label` for that.
