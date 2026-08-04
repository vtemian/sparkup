# Working in sparkup

Ansible that provisions a DGX Spark. It runs **as root on real hardware that somebody owns**. The
target is typically headless and on WiFi with no wired fallback, so a firewall or boot mistake is
recovered by physically walking to the machine. Optimise for not breaking the box.

Repo facts, commands and traps: [INSTALL_CLAUDE.md](INSTALL_CLAUDE.md). Read it before changing
anything. This file is only the rules.

## Hard rules

Invariants, not preferences. Breaking one is a defect even if the playbook converges.

1. **Never flash firmware unattended.** `firmware` stages capsules and stops. Staging is opt-in and
   never reboots, so a flash happens only when a human restarts the machine. Rollback is not
   universally available on this hardware; at least one device's update is one-way.
2. **Never reset a firewall or set a default policy implicitly.** `base` only *adds* allow rules.
   Enabling ufw is opt-in and asserts SSH is allowed first.
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

- Enabling or altering firewall policy on a box you cannot physically reach.
- Running the `kernel` role, or rebooting.
- Anything touching firmware.
- Publishing outward, including making the repository public.
- Removing kernels, or any package removal that is not trivially reversible.

Everything else, execute. Never ask a human to run a command you can run yourself.

## Standards

**A toggle must guard an irreversible action, or it does not exist.** There are three:
`kernel_enabled`, `firmware_update_enabled`, `spark_firewall_enable`. Each one, set wrong, costs
somebody hardware, a boot, or their way into the box. "Maybe do the thing this repo exists to do" is
not a reason for a variable — it is how a repo ends up with nineteen booleans and no power readings.
A verification with an off switch is a verification that gets switched off.

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
