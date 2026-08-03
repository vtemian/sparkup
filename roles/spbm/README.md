# `spbm`

Installs the `spark_hwmon` DKMS driver from a PPA and queues its signing key for MokManager, giving
whole-system power as hwmon sensors. It does not reboot; the key is enrolled by hand at the console.

| Variable | Default | |
|---|---|---|
| `spbm_enabled` | `false` | the gate |
| `spbm_ppa` | `ppa:vladtemian/spark-spbm` | carries the DKMS package |
| `spbm_package` | `spbm-dkms` | |
| `spbm_headers_package` | `linux-headers-nvidia-hwe-24.04` | kept installed so DKMS can rebuild for a new kernel |
| `spbm_mok_cert` | `/var/lib/shim-signed/mok/MOK.der` | the key DKMS signs with |
| `spbm_mok_password` | `""` | one-time, typed at MokManager; pass with `-e`, never store it |

```sh
ansible-playbook site.yml -K --tags spbm -e spbm_enabled=true -e spbm_mok_password='...'
```

Then reboot. Before the OS loads, shim shows a blue MokManager screen: Enroll MOK, Continue, Yes,
then type that password. It needs a keyboard attached — there is no network and no SSH at that
point. Miss the prompt and it cancels harmlessly; re-run the role.
