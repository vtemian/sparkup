# Security

## Reporting a vulnerability

Please use GitHub's [private vulnerability reporting](https://github.com/vtemian/sparkup/security/advisories/new)
rather than opening a public issue. If that is not available to you, email vladtemian@gmail.com.

Expect an acknowledgement within a week. This is a personal project, not a product with an on-call
rota, so please be patient and please do not publish before there has been a chance to fix it.

## What counts as a vulnerability here

This repo is Ansible that runs as root on a machine you own, so the usual web-application threat
model does not apply. What does matter:

- **Anything that provisions state the operator did not ask for.** Creating an account, installing a
  third party's SSH keys, or opening a network port that the configuration did not request. A
  previous review caught exactly this: a tracked `host_vars` file auto-loaded and would have created
  the maintainer's accounts, with sudo, on anyone who cloned the repo and ran it. `host_vars/*.yml`
  is gitignored because of it.
- **Anything that exposes a service to a network the operator believes is closed.** The exporters
  and Prometheus are unauthenticated by design and are expected to stay off the LAN. A change that
  publishes one of them past the firewall is a real finding, and Docker's port publishing bypassing
  `ufw` is the specific trap to watch for.
- **Anything that weakens Secure Boot, or that could leave a headless box unbootable.**
- **Anything that could brick hardware.** Firmware is the one genuinely unrecoverable operation
  here. One role can stage it, `firmware`, and the safety properties that keep it out of a routine
  converge are: it is off unless a box opts in, it never reboots, and a staged capsule can be
  deleted from the ESP before it is ever applied. A change that weakens any of those three, or that
  makes any other role write firmware, is a finding.
- **Supply chain.** Downloads are checksum-verified and container images are pinned by digest. A
  change that replaces a digest with a mutable tag, or drops a checksum, is a finding.

## What does not count

- The exporters and Prometheus having no authentication. That is the documented design; the
  boundary is the network, and `prometheus_bind_address` defaults to loopback.
- Grafana allowing anonymous read access on port 80. Also deliberate, and stated in the README.
- Naming a GitHub account in `github_keys`. That is a standing delegation you chose to make: whoever
  controls that account can log in as that user. It is documented in `roles/users/README.md`.
- Needing sudo. The playbook provisions a machine.

## Trust model, stated plainly

Running this playbook gives it root on the target box. It is auditable Ansible rather than a binary,
and the design choices that limit blast radius are documented in each role's README. Read the diff
before you converge, and use `make check` first. That advice is not a disclaimer; it is how anyone
should treat any configuration management they did not write.
