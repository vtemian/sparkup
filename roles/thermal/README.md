# `thermal`

Asserts that the embedded controller firmware has not drifted. It reads; it never flashes.

| Variable | Default | |
|---|---|---|
| `thermal_fwupdmgr_command` | `/usr/bin/fwupdmgr` | also the "is fwupd here" guard |
| `thermal_ec_device_id` | `""` | your box's; empty disables the read |
| `thermal_expected_ec_firmware` | `""` | empty asserts nothing |

Both EC values come from the JSON, not the CLI table — the assert compares strings exactly:

```sh
fwupdmgr get-devices --json
```

This role caps no clocks and runs no fan curve, deliberately: 20 h of uptime including training
logged 0 µs of thermal slowdown against 23 224 s of power capping. The limiter on this hardware is
the power cap, not heat.
