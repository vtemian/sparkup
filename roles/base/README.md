# `base`

The identity and reachability layer. Everything else in this repo assumes the box has a stable
name, resolves as `<hostname>.local`, agrees with the wall clock, and lets SSH and HTTP through the
firewall. This role establishes exactly that, and nothing more.

## What it manages

| Concern | How |
|---|---|
| Hostname | `ansible.builtin.hostname` set to `spark_hostname` |
| `/etc/hosts` | the `127.0.1.1` line kept consistent with `spark_hostname` |
| mDNS | `avahi-daemon` installed, enabled and started |
| Timezone | `community.general.timezone` set to `base_timezone` |
| Packages | `rsync`, `curl`, `util-linux`, `python3-apt`, `avahi-daemon` — `state: present`, never `latest` |
| Firewall | `community.general.ufw` **allow** rules for `spark_firewall_allow_ports`, nothing else |
| Reporting | current `ufw status verbose`, and which unexpected platform services are enabled |

## Variables

| Variable | Where it lives | Default |
|---|---|---|
| `spark_hostname` | `group_vars/all.yml` | `spark` |
| `spark_firewall_manage` | `group_vars/all.yml` | `true` |
| `spark_firewall_allow_ports` | `group_vars/all.yml` | `[22, 80]` |
| `base_timezone` | `defaults/main.yml` | `Europe/Bucharest` |
| `base_report_units` | `defaults/main.yml` | the five services listed below |

The split is not arbitrary. ansible-lint's production profile enforces
`var-naming[no-role-prefix]`: any variable a role *defines* must carry the role's name as a prefix.
Variables the *project* defines are unconstrained, which is why the registry in
`group_vars/all.yml` keeps the `spark_` prefix while this role's own two defaults are `base_`.
Reading a `spark_*` variable inside the role is fine; declaring one is not.

## avahi is a hard dependency, not a nicety

`spark.local` is not DNS. Nothing on the network knows that name except `avahi-daemon`, which
publishes it over mDNS from the system hostname. The box has a static DHCP reservation, but every
piece of tooling around it addresses the name, not the address:

- `ssh vlad@spark.local` — the documented way in and the definition of done
- `http://spark.local` — Grafana, which is why it sits on port 80 with no suffix
- `bbm/scripts/spark.sh` connects to `${BBM_SPARK_HOST:-vlad@spark.local}` and drives every
  `make spark-*` target from there

Stop avahi and all three break while the box stays perfectly healthy, which makes it a miserable
failure to diagnose. Hence the handler: changing the hostname or the `127.0.1.1` line restarts
avahi, because it publishes the name it read at startup and will otherwise keep advertising the
old one.

## The firewall: allow rules only, and why that is the whole story

This box is **WiFi-only** — interface `wlP9s9`, no wired IPv4, no fallback link. There is no
console to fall back to either. A firewall mistake here is not recovered by reconnecting; it is
recovered by physically walking to the machine.

So the role performs exactly one ufw operation:

```yaml
community.general.ufw:
  rule: allow
  port: "{{ item }}"
  proto: tcp
```

It **never**:

- resets ufw (`state: reset`)
- sets a default policy, deny or otherwise (`default: deny`)
- enables or disables the firewall (`state: enabled` / `state: disabled`)
- deletes a rule (`delete: true`)

Adding an allow rule is the only ufw operation that cannot lock anybody out. Every operation in
that list can, and several can do it silently — a default deny policy applied while your only
allow rule has a typo ends the session and the recovery path in the same instant. Ports the
monitoring stack uses (9090, 9100, 9835) are deliberately absent from
`spark_firewall_allow_ports`: Prometheus binds `127.0.0.1` and the exporters are reached from the
box itself, so nothing needs them open on the LAN.

If you do not want this role near your firewall at all, set `spark_firewall_manage: false`. Both
the rule tasks and the ufw report are gated on it — a box that told the role to keep its hands off
does not want it running `ufw status` either.

### The current rules are unknown until you converge

`ufw` is enabled on this box, but `ufw status` requires root, and the audit that produced this repo
was read-only and unprivileged. The rules were therefore never captured. That is not a gap to close
by guessing: the role reads the live state with root on every run and prints it, so the first
`make apply` (or `make check`) shows you what is actually there. Paste that output here once you
have it.

## Services it reports and deliberately leaves alone

DGX OS ships a broad desktop-and-server image, so a Spark arrives with units nobody would install
on a training box. All five are **enabled** on this machine as of 2026-07-31:

| Unit | What it is |
|---|---|
| `openvpn` | VPN client/server |
| `samba-ad-dc` | Samba Active Directory domain controller |
| `gnome-remote-desktop` | RDP/VNC server for the desktop session |
| `cups` | print spooler |
| `cloud-init` | first-boot cloud provisioning |

The role gathers `ansible.builtin.service_facts` and prints which of `base_report_units` are
enabled. It does not disable, mask or stop any of them.

That restraint is deliberate. This is a recipe other people run on their own hardware, and a
provisioning run has no business switching off services its author never saw — someone's `openvpn`
is how they reach the box, and someone's `gnome-remote-desktop` is their only screen. Whether these
belong on *this* box is a decision for whoever owns it, made once, in `group_vars`, and not a side
effect of running a playbook. The role's job is to make sure the question gets asked.

The same reasoning, with more force, applies to the platform units: `dgx-dashboard`, `dgx-release`,
`nvidia-persistenced`, `nv-cpu-governor` and the `nvidia-*` tuning oneshots. This role **never
touches a `dgx-*` or `nvidia-*` unit**. They are how the vendor image keeps the GPU working, and
`nvidia-persistenced` in particular is load-bearing for GPU telemetry.

`ssh.socket` is a related trap worth knowing even though this role does not manage SSH: sshd here
is socket-activated, so `ssh.service` is *disabled* and restarting it is a no-op that looks like
success. Manage `ssh.socket`.

## Verifying

```bash
make lint                                   # ansible-lint, production profile
make check                                  # dry run; prints the live ufw state
make apply                                  # converge
ssh vlad@spark.local hostnamectl            # still reachable, still named spark
ping -c1 spark.local                        # avahi still publishing
```

A second `make apply` must report `changed=0`. Every task here is idempotent by construction: the
package installs are `state: present`, the read-only reports are `changed_when: false`, and the ufw
module dry-runs each rule before deciding whether it needs adding.
