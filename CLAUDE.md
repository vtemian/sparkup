# Working in sparkup

Ansible that provisions a DGX Spark. It runs **as root on real hardware that somebody owns**. The
target is typically headless and on WiFi with no wired fallback, so a firewall or boot mistake is
recovered by physically walking to the machine. Optimise for not breaking the box.

Repo facts, commands and traps: [INSTALL_CLAUDE.md](INSTALL_CLAUDE.md). Read it before changing
anything. This file is only the rules.

## Hard rules

Invariants, not preferences. Breaking one is a defect even if the playbook converges.

1. **Never flash firmware from a converge.** `firmware` stages capsules and stops; `--no-reboot-check`
   is what stops `fwupdmgr` acting on a reboot prompt. It stages on every run, because the SPBM
   power channels report incorrect CPU values on older EC firmware — so the write happens at the
   next reboot, performed by a human, possibly one who did not run the playbook. The role says so on
   every converge while a capsule is pending. Rollback is not universally available on this
   hardware; at least one device's update is one-way, and an interrupted write is unrecoverable.
2. **Never reset a firewall or remove a rule.** `base` only *adds*. It does enable ufw, which means
   default-deny incoming, but only after asserting the port the current connection arrived on is
   allowed. Never weaken that assert.
3. **Never create accounts that were not asked for.** `spark_users` defaults to `[]`, and
   `host_vars/*.yml` is gitignored so a clone cannot provision somebody else's users.
4. **Never reboot from a role.** Report that a reboot is needed and stop.
5. **Never commit a secret.** Not in `group_vars`, not in a role, not in a fixture. The become
   password lives outside the repo.
6. **Never disable a service the repo did not create.**
7. **Idempotence is the acceptance test.** A task reporting `changed` on every run is unfinished.
8. **Never query a metric nobody emits.** Enforced by `make dashboard`.
9. **Pin versions, and never below what the box already runs.** Grafana migrates its schema forward
   only.
10. **Never make `users` authoritative.** `append: true` and `exclusive: false` are deliberate.
    Without them the first run strips existing groups, or deletes a working `authorized_keys`
    against an empty GitHub response. This role only ever grants; revocation is manual.

## Stop and ask

Do not decide these alone, even with working sudo:

- Widening or weakening firewall policy on a box you cannot physically reach.
- Running the `kernel` role, or rebooting.
- Anything touching firmware.
- Publishing outward, including making the repository public.
- Removing kernels, or any package removal that is not trivially reversible.

Everything else, execute. Never ask a human to run a command you can run yourself.

## Standards

**Running this playbook produces the reference box. That is the whole product.** Somebody clones
this because they want the machine it describes, so a default that gives them less than that is a
bug. Identity goes in `host_vars` — accounts, hostname, timezone, this box's EC device id. Anything
else that differs between a fresh clone and the reference box is a defect, not a preference.

**There are no feature flags. Do not add one.** Not to make a role optional, not to make a
verification skippable, not to be careful. This repo had nineteen booleans and produced no power
readings, because `spbm_enabled: false` is indistinguishable from the feature not existing. A
verification with an off switch is a verification that gets switched off.

When something is genuinely dangerous, **guard it with an assert that fails loudly**, not a default
that silently does nothing. `base` refuses to enable ufw unless the port the current connection
arrived on is allowed; `kernel` refuses to move the boot target unless the GRUB menu resolves to
something visible. Both run every time, and both stop the converge rather than skipping quietly.

**Name a role for what it does now.** A role whose name describes what it used to do is worse than a
badly named one, because the name is believed. If a deletion leaves a role doing something other
than its name, rename it or fold it into the role that owns that job.

**Never write history into a file someone reopens.** No dates, no "this used to", no "as of", no
justification of your own decision process. Git holds all of it. The exception is a decision an
agent would otherwise undo — record the *evidence* in `INSTALL_CLAUDE.md`, not the chronology.

**Comments earn their place by preventing a specific mistake.** A comment survives if a competent
engineer would otherwise reintroduce a known failure or undo something load-bearing. Delete
restatements of the task name, and paragraphs defending the absence of code.

**One concern per commit,** conventional messages, and never mention AI assistance in commits, code
or PR descriptions.

**If you change what a role does, update its README in the same commit.** A README describing
different behaviour from its tasks is worse than none.

**If reality contradicts a document, reality wins and the document changes.** Claims here were
measured on one box on one day and several were later proved wrong. Correcting them is the most
valuable work, not a digression.

## Before you claim it works

`make offline` runs lint, syntax, both dashboard checks and the container converges. It needs no
hardware. `ansible-lint` runs the **production** profile.

Against a real box, the acceptance test is `make idempotence`: converge, converge again, second run
reports `changed=0`. `--check` is not proof of idempotence, only of syntax and reachability.

Assert against the machine, never against your own recap.
