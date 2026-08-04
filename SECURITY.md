# Security

## Reporting a vulnerability

Please use GitHub's [private vulnerability reporting](https://github.com/vtemian/sparkup/security/advisories/new)
rather than opening a public issue. If that is not available to you, email vladtemian@gmail.com.

Expect an acknowledgement within a week. This is a personal project, not a product with an on-call
rota, so please do not publish before there has been a chance to fix it.

## What counts as a vulnerability here

This repo is Ansible that runs as root on a machine you own, so the usual web-application threat
model does not apply. What does matter:

- **Anything that provisions state the operator did not ask for**: creating an account, installing a
  third party's SSH keys, or opening a network port the configuration did not request.
- **Anything that exposes a service to a network the operator believes is closed.** The exporters
  and Prometheus are unauthenticated by design, and Docker's port publishing bypassing `ufw` is the
  specific trap to watch for.
- **Anything that weakens Secure Boot, or that could leave a headless box unbootable.**
- **Anything that could brick hardware.** Only `firmware` stages it, and weakening any of its three
  safety properties is a finding: off unless a box opts in, never reboots, and a staged capsule can
  be deleted from the ESP before it is ever applied.
- **Supply chain.** Downloads are checksum-verified and container images are pinned to an exact
  version or digest; replacing either with a floating tag is a finding.

## What does not count

- The exporters and Prometheus having no authentication. The boundary is the network, and
  `prometheus_bind_address` defaults to `127.0.0.1` in `group_vars/all.yml`.
- Grafana allowing anonymous read access on port 80. Also deliberate, and unconditional:
  `GF_AUTH_ANONYMOUS_ENABLED` in `roles/monitoring/templates/compose.yml.j2`.
- Naming a GitHub account in `github_keys`. That is a standing delegation you chose to make: whoever
  controls that account can log in as that user. See `roles/users/README.md`.
- Needing sudo. The playbook provisions a machine.
