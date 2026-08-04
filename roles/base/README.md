# `base`

Hostname, mDNS, timezone, base packages and ufw.

ufw ends up enabled with a default-deny incoming policy, so `spark_firewall_allow_ports` is the
complete list of what stays reachable from the LAN. Before enabling, the role asserts that the port
**this connection arrived on** is in that list, not a configured guess, so reaching the box on a
non-standard port cannot lock you out of it.

| Variable | Default | |
|---|---|---|
| `spark_hostname` | `spark` | system hostname and the `127.0.1.1` line in `/etc/hosts` |
| `base_timezone` | `""` | empty leaves the clock alone |
| `spark_firewall_allow_ports` | `[22, 80]` | allow rules; the role adds and never deletes |
| `spark_firewall_docker_subnets` | `["172.16.0.0/12"]` | allowed to reach the container ports |
| `spark_firewall_container_ports` | `[9100, 9835]` | host exporter ports, for container scrapes |
| `spark_firewall_ssh_port` | `22` | fallback only; the assert reads the live connection's port |

```bash
ansible-playbook site.yml --tags base
```
