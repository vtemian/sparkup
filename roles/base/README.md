# `base`

Hostname, mDNS, timezone, base packages and ufw allow rules.

| Variable | Default | |
|---|---|---|
| `spark_hostname` | `spark` | system hostname and the `127.0.1.1` line in `/etc/hosts` |
| `base_timezone` | `""` | empty leaves the clock alone |
| `spark_firewall_manage` | `true` | gates every ufw task |
| `spark_firewall_allow_ports` | `[22, 80]` | allow rules; the role adds and never deletes |
| `spark_firewall_docker_subnets` | `["172.16.0.0/12"]` | allowed to reach the container ports |
| `spark_firewall_container_ports` | `[9100, 9835]` | host exporter ports, for container scrapes |
| `spark_firewall_enable` | `false` | turns ufw on; asserts SSH is allowed first and refuses otherwise |
| `spark_firewall_ssh_port` | `22` | the port that assertion checks |

```bash
ansible-playbook site.yml --tags base
```
