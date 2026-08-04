# Contributing

This repo provisions real hardware as root, so the bar for a change is less about style and more
about what it can do to somebody's machine when it goes wrong.

## You do not need a DGX Spark

Everything in `tests/` runs on a laptop with Docker and no hardware at all:

```bash
make deps
make offline                # lint, syntax, dashboard, dashboard-live, roles-test
shellcheck tests/*.sh       # CI gate, not part of make offline
```

CI does not run `make offline`; it runs those same checks as individual steps and adds
`shellcheck`. So a green `make offline` on its own is not yet a green pull request.
[INSTALL_CLAUDE.md](INSTALL_CLAUDE.md) explains what each target proves and what it does not.

If you *do* have a Spark, the real acceptance test is `make idempotence`: converge, converge again,
and the second run must report `changed=0`. Paste the recap in your pull request if you ran it.

## The rules that actually matter

- A task that reports `changed` on every run is not finished.
- Never query a metric nobody emits: a new dashboard panel must still pass `make dashboard`.
- Nothing is destructive by default: never *remove* a firewall rule, create no account unless asked,
  disable no service you did not create, never reboot, never flash firmware during a converge.
- Box-specific values go in `host_vars`; `group_vars/all.yml` holds defaults that suit any Spark. A
  role's own tunables live in its `defaults/main.yml`, prefixed with the role name.
- No secrets, ever — not in `group_vars`, not in a role, not in a test fixture.
  `host_vars/spark.yml` is gitignored because it names who gets sudo.

## Style

- FQCNs everywhere (`ansible.builtin.apt`, not `apt`); `ansible-lint`'s production profile enforces it.
- Every task has a `name`, capitalised, as the first key. Every file or directory task sets `mode`.
- Use handlers rather than `when: something.changed`.
- `command` and `shell` need a deliberate `changed_when`.
- Comments explain *why*, not what changed.

## Pull requests

- Branch from `main`. Conventional commit messages (`feat(exporters): ...`, `fix(base): ...`).
- One concern per pull request.
- Explain the failure mode you are preventing or fixing, not just the change.
- Update a role's README if you change a variable, a default or what the role does.
- If your hardware contradicts what a doc claims, say so with the evidence.

## Reporting a bug

Please include: what you ran, what happened, `ansible --version`, and whether the box is a DGX Spark
or something else. If a task was not idempotent, paste the two run recaps.

For anything with a security dimension, see [SECURITY.md](SECURITY.md) instead.
