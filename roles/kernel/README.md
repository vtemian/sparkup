# `kernel`

The Secure Boot fix. This box has already failed to boot once over kernel signature problems, so
this role's job is to leave it booting a **signed** kernel, with a **visible** GRUB menu, and with
unsigned kernels permanently unable to reinstall themselves — without ever turning Secure Boot off
and without ever rebooting.

It is the one role in this repo that can make the machine unreachable. `PROMPT.md` sequences it
**last, alone, and only with an explicit go-ahead**. It is listed last in `site.yml` and gated on
`kernel_enabled`, which ships `false`, so a plain `make apply` never reaches it.

**`--tags kernel` alone does not run this role.** The tag selects it; the `when: kernel_enabled`
discards it, and the run reports success having done nothing. Every command below therefore passes
`-e kernel_enabled=true`. Leaving it out is not a harmless mistake: you would believe the visible
GRUB menu had landed and reboot a box that still has a hidden menu at timeout 0.

## This role never reboots

Not optionally. Not behind a flag. There is no `ansible.builtin.reboot` anywhere in it and there
will not be one. When the box is not yet running the kernel it is meant to run, the role converges
everything else, says so, and fails the play with a message telling you to reboot by hand.

The reasoning is not squeamishness. The box is headless, WiFi-only with no wired fallback, and may
be halfway through a multi-day training run. A reboot is the one operation here that is not
survivable mid-run and not recoverable over the network. Deciding to do it requires knowing things
a playbook cannot know — whether anyone is using the machine, and whether someone can walk to it.

## What it does, in order

| # | Step | Why it is where it is |
|---|---|---|
| 0 | Discover: Secure Boot state, installed packages, the kernel the meta package points at | read-only; nothing below may guess at these |
| 1 | Install `linux-image-nvidia-hwe-24.04` and the concrete **signed** image, `state: present` | nothing may point at, or remove in favour of, a kernel that is not on disk |
| 2 | `GRUB_TIMEOUT` → `kernel_grub_timeout`, `GRUB_TIMEOUT_STYLE` → `menu` | the menu must be visible **before** the boot target moves |
| 3 | `GRUB_DEFAULT=saved` + `grub-set-default <entry id>` | only now does the boot path actually change |
| 4 | Install the apt pin at `/etc/apt/preferences.d/no-unsigned-kernels` | closes the door before anything walks back through it |
| 5 | Remove the named unsigned kernel packages — **off by default** | the only irreversible step, and it runs last |
| 6 | Assert Secure Boot enabled, menu visible, `ansible_kernel` == intended | reports drift; never remediates it |

### Why the order is a safety property

Each step assumes the previous one succeeded, and every inversion has a specific failure:

- **Remove before install** leaves a box with no bootable kernel. This is the classic way to brick a
  remote machine, and it is why step 5 is last and gated on the signed replacement being present.
- **Retarget before install** points GRUB at a menu entry that does not exist. GRUB falls through to
  whatever it finds, which on a box with three kernels installed is a coin flip.
- **Boot change before the menu is visible** removes your only recovery. With `GRUB_TIMEOUT=0` and
  `GRUB_TIMEOUT_STYLE=hidden` — this box's current state — there is no menu to pick a working kernel
  from; you are guessing when to hold a key against a machine you cannot see. Raising the timeout
  costs five seconds per boot and buys the difference between "pick the previous kernel" and "drive
  to the machine".
- **Assert before converge** turns a check into a gate and tempts whoever is on the other end to
  remediate. Assertions are the last thing that runs, precisely so that they only ever report.

Step 2 needs both lines, not just the timeout `PROMPT.md` mentions. Ubuntu ships
`GRUB_TIMEOUT_STYLE=hidden`, and a hidden menu counts the timeout down invisibly — raising
`GRUB_TIMEOUT` alone would leave the operator exactly where they started. The role therefore sets
the style too, and step 6 verifies the *generated* `grub.cfg` rather than trusting the edit.

## Pre-flight checklist

Do not run this role until every line is true. It is not a formality; each item is the thing that
makes one of the failure modes above survivable.

- [ ] **Someone can physically reach the box.** Keyboard and monitor, or at least hands on the power
      button. `spark.local` resolves over mDNS on WiFi and nothing else; if it does not come back,
      there is no console, no BMC (the audit found no Redfish interface and no `/dev/ipmi*`) and no
      second link.
- [ ] **A known-good signed kernel is installed** and is one you have actually booted. Check what is
      on disk: `dpkg -l 'linux-image-*'`. The role installs the signed image the meta package points
      at, but "installed" is not "proven to boot".
- [ ] **`GRUB_TIMEOUT` is already raised and the menu is already visible.** Land step 2 on its own
      first — see below — and reboot once to confirm the menu appears. Doing this in the same run
      that moves the boot target means the safety net and the risk arrive together.
- [ ] **No training run is active.** `nvidia-smi --query-compute-apps=pid,process_name --format=csv`
      must be empty. `site.yml` already computes `spark_training_active` in `pre_tasks`. Nothing in
      this role restarts a service or touches the GPU, so it is safe to *evaluate* mid-run — but the
      reboot it will ask for is not, and you do not want to be holding a red play while someone's
      job is at epoch 40.
- [ ] **You have read `/etc/default/grub` and `/etc/default/grub.d/`.** Drop-ins are sourced *after*
      `/etc/default/grub` and win. Step 6 catches this, but knowing beforehand is cheaper.
- [ ] **You know which kernel GRUB currently defaults to.** This is open question 2 in `PROMPT.md`
      and it was never answered — `/boot/grub/grub.cfg` is root-only and the audit never read it.
      `sudo grep -E "^\s*(set default|menuentry )" /boot/grub/grub.cfg` and `sudo grub-editenv list`
      answer it in two commands.

### Landing the timeout on its own

Both the tag and `kernel_enabled=true` are required; the tag alone silently skips the role.

```sh
# 1. menu visible, boot target untouched
ansible-playbook site.yml -K --tags kernel \
  -e kernel_enabled=true -e kernel_manage_grub_default=false
# 2. reboot by hand, confirm the menu appears and the box comes back
# 3. now let the role retarget GRUB
ansible-playbook site.yml -K --tags kernel -e kernel_enabled=true
```

After step 1, confirm the role actually ran before you reboot. A run that skipped it reports
`ok=0 changed=0` for every kernel task:

```sh
grub-editenv list                     # saved_entry unchanged at this point
grep -E '^GRUB_TIMEOUT' /etc/default/grub
grep -cE '^set timeout_style=menu' /boot/grub/grub.cfg    # must be 1, not 0
```

With `kernel_manage_grub_default: false` the role still installs the signed kernel, still writes the
apt pin and still asserts — it just does not touch `GRUB_DEFAULT` or `grub-set-default`.

## Recovery: the box does not come back

Work down this list. Nothing here needs the network, because if you are reading it the network is
not available.

1. **Power-cycle once and hold the menu.** With `GRUB_TIMEOUT=5` and `GRUB_TIMEOUT_STYLE=menu` the
   menu appears on its own for five seconds. If step 2 never landed, hold <kbd>Shift</kbd> (BIOS) or
   tap <kbd>Esc</kbd> (UEFI, which is this box) repeatedly from power-on.
2. **Boot the previous kernel.** *Advanced options for Ubuntu* → pick a different
   `Ubuntu, with Linux <version>`. The audit found three kernels installed
   (`6.11.0-1014`, `6.17.0-1021`, `6.17.0-1026-unsigned`) plus the running `6.17.0-1029`, so there is
   more than one thing to fall back to. Prefer a **signed** one: under Secure Boot the unsigned image
   will refuse to load, which looks like a hang.
3. **Undo the pin from the recovered system:**
   ```sh
   sudo grub-editenv list                       # what is GRUB actually saving?
   sudo grub-set-default 0                      # top entry, i.e. newest kernel
   sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub
   sudo update-grub
   ```
4. **If nothing boots at all**, use the *recovery mode* entry for a kernel you trust, get a root
   shell, and reinstall the signed image:
   ```sh
   sudo apt-get install --reinstall linux-image-nvidia-hwe-24.04
   sudo update-grub
   ```
5. **If Secure Boot is rejecting everything**, the correct fix is still a signed kernel. Do **not**
   disable Secure Boot to get the box up "temporarily" — see below. If you disable it to recover,
   write down that you did, because nothing in this repo will tell you later.
6. **Only then consider firmware.** `PROMPT.md` E4 is a manual, supervised runbook, and firmware is
   the one unrecoverable operation on this machine. A kernel that will not boot is not a firmware
   problem.

## Secure Boot stays on

NVIDIA's own Aerial-on-Spark documentation tells people to disable Secure Boot. This project does
not, and the role has no switch to do it. The failure being fixed here is "an unsigned kernel cannot
be verified"; the fix is a kernel that can be verified, not removing the thing doing the verifying.

The role reads `mokutil --sb-state` and asserts it says `SecureBoot enabled`. That reading also does
real work earlier: **Secure Boot being enabled on a box that is up is the proof that the running
kernel is signed.** Shim would not have loaded an unsigned image. That is why step 5 is gated on the
flag rather than merely reporting it at the end — it is the strongest available evidence, and it is
free.

## The apt pin, and why it is not a `dpkg` hold

```
Package: linux-image-unsigned-*
Pin: release *
Pin-Priority: -1
```

A negative pin priority means apt will never select these packages, in any release, from any source.

`dpkg --set-selections hold` (or `apt-mark hold`) is the reflex here and it is the wrong tool, for
one decisive reason: **a hold only constrains packages that are already installed.** It pins the
version of something on disk. The failure mode this role exists to prevent is an update pulling in
an unsigned image that is *not installed yet* — a new ABI, a new meta package dependency, a
vendor-repo change — and a hold has nothing to say about a package it has never seen. The glob in
the pin covers every unsigned kernel image that will ever exist, including the ones NVIDIA has not
built.

Two consequences worth knowing:

- The pin does **not** remove the unsigned kernel already installed. That is step 5's job, and it is
  off by default.
- If a future vendor meta package ever *depends* on an unsigned image, apt will refuse to upgrade it
  rather than silently installing one. That is a loud failure, which is the point — but it will look
  like a broken upgrade, so this file is the first place to look.

## Discovering the kernel name instead of writing it down

The audit found something odd, and the role is built around it. `dpkg -l` on the box lists
`linux-image-6.11.0-1014-nvidia`, `linux-image-6.17.0-1021-nvidia`,
`linux-image-unsigned-6.17.0-1026-nvidia` and the meta `linux-image-nvidia-hwe-24.04` (→ 6.17.0-1029.29)
— but **no explicit `linux-image-6.17.0-1029-nvidia`**, even though `6.17.0-1029-nvidia` is what
`uname -r` reports. So the concrete package name for the running kernel is *unverified*, and
hardcoding it would either be wrong today or rot at the next ABI bump.

The role therefore reads it out of the meta package:

```sh
dpkg-query --showformat=${Depends} --show linux-image-nvidia-hwe-24.04
```

and takes the first dependency matching `linux-image-<digit>…`. Signed images are
`linux-image-<version>-<flavour>`; unsigned ones carry the `unsigned` infix, so a name whose first
character after `linux-image-` is a digit cannot be an unsigned build. An assertion re-checks that
anyway, because `kernel_signed_image_package` lets a human override the discovery.

**`dpkg-query`, deliberately not `apt-cache depends`.** apt-cache answers for the *candidate*
version. If NVIDIA's repo carries a newer meta than the one installed, apt-cache would name a kernel
this box has never booted, and `state: present` would then install it — an unrequested kernel
upgrade on a machine with a boot-failure history. dpkg-query answers for what is installed here.

If the meta package is absent or points at another meta rather than a concrete image, the role falls
back to `linux-image-{{ ansible_kernel }}` — the signed counterpart of whatever is booted right now,
which is the conservative answer.

## Pinning GRUB by entry id, not by title

`GRUB_DEFAULT=saved` plus `grub-set-default`, as `PROMPT.md` specifies. What gets saved is the
**menu entry id**, parsed out of the generated `grub.cfg`:

```
gnulinux-advanced-<root-uuid>>gnulinux-6.17.0-1029-nvidia-advanced-<root-uuid>
```

Ubuntu nests every per-kernel entry inside the *Advanced options for Ubuntu* submenu, so the saved
entry is the submenu id and the entry id joined by `>`. The role extracts both from
`$menuentry_id_option '…'` and joins them; on a menu with no submenu the join collapses to the entry
id alone.

A **title** (`'Ubuntu, with Linux 6.17.0-1029-nvidia'`) would have been easier and is a trap. It
carries the distributor string and the kernel version in prose, both of which change, and when it
stops matching GRUB does not complain — it just boots something else. The id embeds the kernel
version and the root filesystem UUID, which is what we actually mean.

Idempotency comes from `grub-editenv list`: the role parses `saved_entry=` out of it and skips
`grub-set-default` when it already holds the target. A converged box reports `changed=0`.

The handler is `update-grub`, and it is **flushed mid-role** rather than at the end of the play.
Nothing in `/etc/default/grub` takes effect until `grub.cfg` is regenerated, and every task after the
flush reads the generated menu — the entry ids it pins to, and the timeout it verifies.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `kernel_meta_package` | `linux-image-nvidia-hwe-24.04` | the vendor meta the concrete image is discovered from |
| `kernel_signed_image_package` | `""` | empty means discover; set to override |
| `kernel_secure_boot_packages` | `[mokutil]` | reads the Secure Boot state |
| `kernel_grub_timeout` | `5` | seconds the menu stays up; `0` on this box today |
| `kernel_grub_timeout_style` | `menu` | `hidden` on this box today, which is the actual problem |
| `kernel_grub_default_file` | `/etc/default/grub` | |
| `kernel_grub_config` | `/boot/grub/grub.cfg` | read, never written; `update-grub` owns it |
| `kernel_manage_grub_default` | `true` | `false` lands the menu timeout alone |
| `kernel_assert_grub_menu` | `true` | `false` if your `grub.cfg` is laid out unusually **and** you checked by hand |
| `kernel_apt_preferences_file` | `/etc/apt/preferences.d/no-unsigned-kernels` | |
| `kernel_remove_unsigned` | `false` | the destructive gate |
| `kernel_unsigned_packages` | `[]` | explicit names only — **never a glob** |

Every variable carries the `kernel_` prefix because ansible-lint's production profile enforces
`var-naming[no-role-prefix]` and this repo does not skip it. Nothing here belongs in
`group_vars/all.yml`: a kernel is not a site-wide tunable, and this role is run on its own with
explicit arguments rather than as part of a routine converge.

### Removing the unsigned kernel

Off by default, empty by default, and gated five ways. To actually retire
`linux-image-unsigned-6.17.0-1026-nvidia`, all of these must hold:

1. `kernel_remove_unsigned` is `true`
2. `kernel_unsigned_packages` names the packages explicitly
3. `mokutil` reports Secure Boot **enabled** — the proof that the running kernel is signed
4. `ansible_kernel` equals the intended version — you are on the kernel you meant to be on
5. the signed image package for that version is installed

and then one more assertion refuses outright to remove any package whose name contains the running
kernel's version. So:

```sh
ansible-playbook site.yml -K --tags kernel \
  -e kernel_enabled=true \
  -e kernel_remove_unsigned=true \
  -e '{"kernel_unsigned_packages": ["linux-image-unsigned-6.17.0-1026-nvidia"]}'
```

`purge: false` and `autoremove: false` are set explicitly. `autoremove` is the interesting one:
letting apt decide which now-unneeded packages to take with the removal is how a kernel cleanup
turns into an outage.

## Honest uncertainty

Carried forward from `PROMPT.md`, because it matters more than the code does:

**The packaging split is confirmed** — Ubuntu really does ship `linux-image-unsigned-*` and
`linux-image-*` as separate binary packages. **The Secure Boot default is confirmed** — it is on,
`mokutil` says so. **This box really did hit the failure.** What does *not* exist is a published
post-mortem of a DGX Spark broken **specifically** by an update swapping a signed kernel for an
unsigned one. The apt pin is cheap insurance against a mechanism that is plausible and unproven, not
a fix for a documented incident.

**Do not misdiagnose an unrelated hang as this.** Reported Spark boot hangs — EFI-stub stalls, GSP
firmware timeouts — are **driver and firmware** problems. They are not signature problems, they will
not be fixed by anything in this role, and reaching for Secure Boot when you see one will cost you a
security property and leave the actual bug in place. The tell is straightforward: a signature
rejection under Secure Boot fails at *shim*, before the kernel prints anything. If you are seeing
kernel log output, it is not this.

## Assumptions made while the box was unreachable

This role was written and verified entirely offline — `spark.local` had left the network, so nothing
below was confirmed against the machine. Each one is a thing to check on the first real run.

1. **`/boot/grub/grub.cfg` follows Ubuntu's standard `grub-mkconfig` layout** — `$menuentry_id_option
   '…'` tokens, per-kernel entries nested inside a `gnulinux-advanced-<uuid>` submenu, and the
   `set timeout_style=…` / `set timeout=…` pair emitted by `00_header`. The file is root-only and was
   never read by the audit (`PROMPT.md` open question 2), so the parsing is written against Ubuntu's
   published template and tested against a synthetic `grub.cfg`, not against this box. Both
   assumptions are guarded: an unrecognised menu fails the "GRUB has no entry for the intended
   kernel" assertion rather than pointing GRUB somewhere arbitrary, and `kernel_assert_grub_menu`
   exists as the escape hatch if only the timeout parse is off.
2. **The `set timeout=` the role reads is the one that applies.** `00_header` emits `set timeout=30`
   first, inside the `recordfail` branch. Matching `timeout_style` and `timeout` as an adjacent pair
   skips it; a lone `regex_findall('set timeout=…') | first` would have read 30 and passed on a box
   whose menu was still hidden. Verified against a synthetic `grub.cfg`, not this one.
3. **`linux-image-nvidia-hwe-24.04` depends on a concrete `linux-image-<version>-nvidia`.** If it
   depends on another meta package instead, discovery finds nothing and the role falls back to
   `linux-image-{{ ansible_kernel }}`. That fallback is safe but it is a fallback; the run's
   "Report the kernel state this role resolved" line tells you which path was taken.
4. **`GRUB_TIMEOUT_STYLE=hidden` is what is actually set.** The audit reported `GRUB_TIMEOUT=0`; it
   did not report the style. If the style is already `menu`, the second `lineinfile` is a no-op and
   nothing changes.
5. **No `/etc/default/grub.d/` drop-in overrides these settings.** Unverified — DGX OS ships plenty
   of its own configuration. Step 6 catches it after the fact by reading the generated file.
6. **`mokutil` is installable and prints `SecureBoot enabled`.** The audit reported Secure Boot on;
   it did not record whether `mokutil` is installed, so the role installs it.
7. **`GRUB_SAVEDEFAULT` is unset or false.** Ubuntu ships it commented out. If something has set it
   to `true`, GRUB overwrites `saved_entry` with whatever booted last, and the role's pin becomes
   advisory rather than binding. The role does not manage this variable; check it by hand.
8. **The signed image is already installed under a name `dpkg -l` did not obviously show.** Step 1 is
   expected to be a no-op on this box. If it is not — if apt reports a change — a kernel was
   genuinely installed, and the pre-flight checklist's "known-good signed kernel" item was not
   actually true.

## Verifying

Offline, which is all that was possible:

```sh
cd .worktrees/kernel && ansible-lint roles/kernel
# Passed: 0 failure(s), 0 warning(s) in 4 files processed of 5 encountered.
# Profile 'production' was required, and it passed.
```

On the box, in this order:

```sh
sudo grub-editenv list                  # saved_entry names the intended kernel
grep -E '^GRUB_(DEFAULT|TIMEOUT)' /etc/default/grub
sudo grep -E 'set (timeout_style|timeout)=' /boot/grub/grub.cfg   # menu / 5, not hidden / 0
mokutil --sb-state                      # SecureBoot enabled
dpkg -l 'linux-image-*'                 # signed image present; unsigned still there until step 5
apt-cache policy linux-image-unsigned-6.17.0-1026-nvidia          # candidate priority -1
```

Then run the playbook twice; the second run must report `changed=0`. Then, and only with someone
able to reach the machine, **reboot once and confirm it comes back** on the intended kernel — that
is the acceptance test `PROMPT.md` sets for A5, and it is the one this role will never do for you.
