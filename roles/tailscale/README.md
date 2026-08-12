# `tailscale`

Makes a headless Spark reachable from outside the house, without opening anything to the internet.

```yaml
# host_vars/spark.yml
tailscale_hostname: spark
```

Then converge, and run the one command it reports:

```bash
sudo tailscale up --hostname=spark
```

That prints a URL to approve in a browser. No converge can do that, so the role reports it and stops,
the same way `firmware` stages a capsule and leaves the reboot to a human.

| Variable | Default | |
|---|---|---|
| `tailscale_hostname` | `""` | `host_vars`; the name this box takes on the tailnet. Empty does nothing at all |
| `tailscale_keyring_url` | derived from the release codename | Tailscale publish one suite per Ubuntu release |
| `tailscale_keyring_path` | `/usr/share/keyrings/tailscale-archive-keyring.gpg` | named in the apt source, so the two move together |
| `tailscale_repo_url` | `https://pkgs.tailscale.com/stable/ubuntu` | |
| `tailscale_interface` | `tailscale0` | what the ufw allow is scoped to |

## Why this and not a port forward

`tailscaled` dials **out** to Tailscale's coordination server, so the box needs no inbound port, no
router configuration, and no public address. Forwarding 22 to the internet would do the opposite: a
permanent inbound hole on a machine whose only link is WiFi and whose recovery is walking to it.

## What it does to the firewall

It adds one rule, `ufw allow in on tailscale0`, and nothing else. The LAN policy is untouched: this
opens nothing to your 192.168 network and nothing to the internet. Without that rule the box joins the
tailnet and then answers nothing, because default-deny drops traffic arriving on the new interface,
which looks like Tailscale being broken rather than a firewall doing its job.

## What becomes reachable, and to whom

Everything already listening: SSH, Grafana on port 80, and the registry on 5000. Two of those are
worth thinking about before you add a second device to the tailnet.

**Grafana has no login.** That is deliberate and documented in [SECURITY.md](../../SECURITY.md), and
it is a reasonable trade on a home LAN. On a tailnet it means anyone on that tailnet reads your
dashboards. The registry on 5000 speaks plain HTTP for the same LAN-trust reason. Neither is a
problem for a tailnet of your own devices, and both are a decision to revisit before sharing one.

Tailscale ACLs are where you would restrict this, not ufw: ufw sees the whole tailnet as one
interface.

## Not a feature flag

`tailscale_hostname` is identity, like `spark_hostname` and `base_timezone`, and it is empty by
default. The role runs on every converge and does nothing at all until `host_vars` names the box.
That is the same shape as `spark_users: []` creating nobody, and it is deliberately **not** the
`spbm_enabled` shape: there is one gate in this repo, in `site.yml`, and this is not a second one.
See [CLAUDE.md](../../CLAUDE.md).

## Removing it

The role only ever adds. To leave a tailnet, do it yourself and it stays gone; the converge will not
put the box back on one, because rejoining needs the browser approval it cannot perform.

```bash
sudo tailscale logout
```
