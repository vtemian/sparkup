# Contributing

Thanks for looking. This repo provisions real hardware as root, so the bar for a change is a little
different from most projects: it is less about style and more about what a change can do to
somebody's machine when it goes wrong.

## You do not need a DGX Spark

Most people reading this do not have one, and that is designed for. Everything in `tests/` runs on a
laptop with Docker and no hardware at all:

```bash
make deps
make offline    # lint, syntax, dashboard, dashboard-live, roles-test
```

That is the same suite CI runs, so a green `make offline` locally means a green pull request.
[INSTALL_CLAUDE.md](INSTALL_CLAUDE.md) explains what each target proves and, more usefully, what it
does not.

If you *do* have a Spark, the real acceptance test is `make idempotence`: converge, converge again,
and the second run must report `changed=0`. Say so in your pull request if you ran it, and paste the
recap. Nobody else can verify that for you.

## The rules that actually matter

**Idempotence is not a nicety.** A task that reports `changed` on every run is not finished. A
playbook that cannot run twice is a shell script with extra syntax.

**Never query a metric nobody emits.** If you add a dashboard panel, `make dashboard` must still
pass, which means the metric has to come from a collector or query field this repo actually enables.
This is enforced, not advisory.

**Destructive by default is a bug.** This repo runs on other people's machines. It only ever *adds*
firewall allow rules, never resets them. It creates no accounts unless asked. It disables no service
it did not create. It never flashes firmware and never reboots. A change that widens any of those
needs a very good reason in the pull request, not just a flag.

**Anything box-specific goes in `host_vars`, not `group_vars`.** `group_vars/all.yml` holds defaults
that suit any Spark. Your hostname, your accounts, your firmware version and your paths are yours.
A role's own tunables live in that role's `defaults/main.yml`, prefixed with the role name.

**No secrets, ever.** Not in `group_vars`, not in a role, not in a test fixture.
`host_vars/spark.yml` is gitignored on purpose because it names who gets sudo.

## Style

- FQCNs everywhere (`ansible.builtin.apt`, not `apt`). `ansible-lint` runs the **production**
  profile and will tell you.
- Every task has a `name`, capitalised, as the first key. Every file or directory task sets `mode`.
- Use handlers rather than `when: something.changed`.
- `command` and `shell` need a deliberate `changed_when`.
- Comments explain *why*, not what changed. If a line exists because something surprising is true
  about this hardware, say what that is. Several comments in this repo exist because somebody lost
  an afternoon.

## Pull requests

- Branch from `main`. Conventional commit messages (`feat(exporters): ...`, `fix(base): ...`).
- One concern per pull request.
- Explain the failure mode you are preventing or fixing, not just the change.
- If your change affects a role, update that role's README in the same pull request. A role whose
  README describes different behaviour from its tasks is worse than one with no README.
- If you found something about this hardware that contradicts what the docs claim, that is the most
  valuable kind of contribution. Say so plainly, with the evidence. Reality wins.

## Reporting a bug

Please include: what you ran, what happened, `ansible --version`, and whether the box is a DGX Spark
or something else. If a task was not idempotent, the two run recaps are worth more than a
description of them.

For anything with a security dimension, see [SECURITY.md](SECURITY.md) instead.
