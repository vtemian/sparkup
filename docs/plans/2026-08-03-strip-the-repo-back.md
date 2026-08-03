# Strip the repo back Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Cut sparkup to what it actually needs: delete features that provably never run, strip comments down to the ones that stop a maintainer breaking something, and make the READMEs describe the roles instead of arguing for them.

**Architecture:** Subtraction only. Nothing is restructured, no role is merged, no task is refactored into a loop. Every change is either a deletion, a comment rewrite, or a one-line bug fix. Two structural moves that came up in review (folding `shelly` into `exporters`, moving `thermal`'s fwupd half into `firmware`) are **explicitly rejected** — see "Rejected" at the bottom — because both require renaming 5 and 11 variables respectively to satisfy `ansible-lint`, which is churn, not simplification.

**Tech Stack:** Ansible (production `ansible-lint` profile), Jinja2 templates, Make, Python test harness, Docker.

**Baseline (measured 2026-08-03, before any change):**

- 3451 markdown lines, 2656 of them in eleven `roles/*/README.md`
- 2959 lines of YAML/Jinja outside `tests/`
- 127 declared variables, 19 boolean toggles
- Config surface (group_vars + all role defaults + host_vars example): 726 lines, 52% comment

**Target:** ~950 markdown lines, ~2200 YAML lines, ~113 variables. No behaviour change on a converged box except the two bug fixes in Phase 1 and the `firmware` scoping fix.

---

## Read this before you start

**Line numbers in this plan are pre-edit.** They shift as soon as the first deletion lands. Every deletion below quotes its exact first and last line — **anchor on the quoted text, never on the number.** If a quoted anchor does not match the file, stop and report; do not guess.

**Order matters within a file.** Phase 2 does deletions and comment stripping for a role in one pass, so the two never race. Phase 3 touches shared config only after Phase 2 has removed every consumer.

**Do not touch `tests/`** except where a task explicitly says so. Three tasks do.

**Never delete a comment marked KEEP** in this plan. Those are the ones that stop somebody reintroducing a measured failure.

---

## Verification commands

These are the only checks. Learn what PASS looks like before you need it.

| Command | Needs Docker | PASS looks like |
|---|---|---|
| `make lint` | no | `Passed: 0 failure(s), 0 warning(s) in N files processed` |
| `make syntax` | no | exit 0, one line: `playbook: site.yml` |
| `make dashboard` | yes | `PASS 21 panel queries across 18 panels` |
| `make dashboard-live` | yes | `PASS all 21 panel queries returned data` |
| `make roles-test` | yes | `IDEMPOTENT: base and users both reported changed=0 on the second run` |
| `make offline` | yes | all five of the above, in that order |
| `shellcheck tests/*.sh` | no | exit 0 (CI-only gate, not in `make offline`) |

`make lint` and `make syntax` are the fast gate and catch most of this work: every `var-naming` violation, every YAML error, every reference to a deleted role. Run them after **every** task.

**Blind spots — no test can see these, verify by eye:**
`tests/harness/vars.yml` shadows `monitoring_dir`, `monitoring_project_name`, `grafana_port`, `prometheus_bind_address`, `prometheus_port`, `node_exporter_port`, `nvidia_gpu_exporter_port`, `prometheus_scrape_interval` and `shelly_enabled`. Delete any of those from `group_vars/all.yml` and the whole suite still passes while the box breaks. Same for `shelly_scrape_host`, `shelly_exporter_port` and `shelly_exporter_metrics_path`, which live in an untaken Jinja branch whenever `shelly_enabled` is false.

**Do not delete these — a test reads them by name:**
`exporters_gpu_query_fields`, `exporters_node_collectors` (`tests/check_dashboard.py:516-517`), `monitoring_grafana_home_dashboard` (`:470`, must stay a top-level key in `roles/monitoring/defaults/main.yml` with shape `/d/<uid>/<slug>`), `prometheus_image` (`:510`), `monitoring_project_name`, `monitoring_dir`, `spark_users`, `base_timezone`, and every port above.

---

## Task 0: Branch and baseline

**Step 1: Branch**

```bash
cd /Users/whitemonk/projects/ai/sparkup
git status --short          # must be clean
git checkout -b strip-the-repo-back
```

**Step 2: Record the baseline so you can prove nothing regressed**

```bash
make lint 2>&1 | tail -3
make syntax
make dashboard 2>&1 | tail -3
```

Expected: all three pass with the strings in the table above. If any fails **now**, stop — that is a pre-existing break and needs reporting before this work starts.

**Step 3: Commit nothing.** This task produces no diff.

---

# Phase 1 — Defects

Five real bugs, found during review, unrelated to verbosity. Small and independent. They land first so they survive even if the rest of the plan is trimmed.

## Task 1: `spbm` invokes `mokutil` without installing it

**Files:** Modify `roles/spbm/tasks/main.yml`

`roles/spbm/tasks/main.yml` calls `mokutil` three times (`--test-key`, `--generate-hash`, `--import`). The only role that installs it is `kernel`, which is off by default **and** runs last, while `spbm` runs fifth. On a box with `spbm_enabled: true` and `kernel_enabled: false`, `--test-key` fails silently (`failed_when: false`), the assert then demands a password, and `mokutil --import` fails the converge with a bare "command not found".

**Step 1: Insert the install task**

Find the task named `Install the SPBM DKMS package`. Immediately after its final line (`        state: present`) and the blank line following it, insert:

```yaml
    - name: Install the Secure Boot key enrolment tool
      ansible.builtin.apt:
        name: mokutil
        state: present

```

Indentation is 4 spaces for `- name:`, matching its siblings inside the `spbm_enabled` block.

**Step 2: Verify**

```bash
make lint && make syntax
```

**Step 3: Commit**

```bash
git add roles/spbm/tasks/main.yml
git commit -m "fix(spbm): install mokutil in the role that uses it"
```

## Task 2: `spbm` can enrol a stale password hash

**Files:** Modify `roles/spbm/tasks/main.yml`

Three problems in one task. `creates: /root/.spbm-mok-hash` never fires on the happy path, because `Remove the hash file` deletes that file at the end of every successful run. On a run that aborts between generate and import, the file survives, `creates` then **skips** regeneration, and `mokutil --import --hash-file` enrols the **old** password. The operator types the new password at MokManager and enrolment fails with no diagnostic. Separately, `set -o pipefail` guards nothing — the command is a redirect, not a pipe.

**Step 1: Replace the whole `Hash the enrolment password` task**

Current text:

```yaml
        - name: Hash the enrolment password
          ansible.builtin.shell:
            cmd: >-
              set -o pipefail &&
              mokutil --generate-hash='{{ spbm_mok_password }}' > /root/.spbm-mok-hash
          args:
            creates: /root/.spbm-mok-hash
          no_log: true
```

Replace with:

```yaml
        - name: Hash the enrolment password
          ansible.builtin.shell:
            cmd: >-
              umask 077 &&
              mokutil --generate-hash='{{ spbm_mok_password }}' > /root/.spbm-mok-hash
          changed_when: true
          no_log: true
```

`changed_when: true` is **required**, not optional: `creates:` is what currently satisfies `ansible-lint`'s `no-changed-when` rule under the production profile. Removing it without adding `changed_when` fails the lint.

`umask 077` makes the redirect create the file 0600 at creation time, which is strictly better than the old two-step that left a world-readable password hash on disk between the shell and the chmod.

**Step 2: Delete the now-redundant `Restrict the hash file` task**

First line: `        - name: Restrict the hash file`
Last line: `            mode: "0600"`

Take the trailing blank line too. **Only delete this if Step 1 landed** — `umask 077` is what takes over the 0600 guarantee.

**Step 3: Verify**

```bash
make lint && make syntax
```

Expected: no `no-changed-when` violation. If you see one, Step 1's `changed_when: true` is missing.

**Step 4: Commit**

```bash
git add roles/spbm/tasks/main.yml
git commit -m "fix(spbm): regenerate the enrolment hash every run instead of reusing a stale one"
```

## Task 3: the GRUB menu assert checks itself

**Files:** Modify `roles/kernel/tasks/main.yml`, `roles/kernel/templates/zz-sparkup-menu.cfg.j2`, `roles/kernel/defaults/main.yml`

`roles/kernel/tasks/main.yml:207` asserts `kernel_grub_menu_settings[0][0] == kernel_grub_timeout_style`. The left side is the `timeout_style` parsed out of the generated `grub.cfg`; the right side is the variable the template wrote it from. So the assert compares the variable against itself. Set `kernel_grub_timeout_style: hidden` and the check passes on a hidden menu — the single outcome this role exists to prevent. The companion `!= 0` check does not save it: `hidden` with a non-zero timeout still shows nothing.

`menu` is the only value the role can accept, so this is not a tunable.

**Step 1: Hardcode the assert**

In `roles/kernel/tasks/main.yml`, inside the task named `Assert that the GRUB menu will be visible`, replace:

```yaml
      - kernel_grub_menu_settings[0][0] == kernel_grub_timeout_style
```

with:

```yaml
      - kernel_grub_menu_settings[0][0] == 'menu'
```

**Step 2: Hardcode the template**

In `roles/kernel/templates/zz-sparkup-menu.cfg.j2`, replace:

```
GRUB_TIMEOUT_STYLE={{ kernel_grub_timeout_style }}
```

with:

```
GRUB_TIMEOUT_STYLE=menu
```

**Step 3: Delete the variable**

In `roles/kernel/defaults/main.yml`, delete the line `kernel_grub_timeout_style: menu`. Grep to confirm nothing else reads it:

```bash
grep -rn "kernel_grub_timeout_style" --include="*.yml" --include="*.j2" . | grep -v "^./docs/plans"
```

Expected after the edit: only `roles/kernel/README.md` (rewritten in Phase 4).

Keep `kernel_grub_timeout` and `kernel_grub_recordfail_timeout` as variables — any positive value is legitimate there, and the assert checks `!= 0` rather than equality, so neither carries the same hole.

**Step 4: Verify**

```bash
make lint && make syntax
```

**Step 5: Commit**

```bash
git add roles/kernel/
git commit -m "fix(kernel): assert the generated menu is visible, not that a variable equals itself"
```

## Task 4: the pending-flash warning never fires by default

**Files:** Modify `roles/firmware/tasks/main.yml`

`Look for firmware capsules already staged` and `Warn that the next boot will write firmware` are indented 4 spaces, which puts them **inside** the `when: firmware_update_enabled | bool` block opened at `roles/firmware/tasks/main.yml:29-31`. Two comments claim the opposite:

- `roles/firmware/tasks/main.yml:90` — "Deliberately outside the fwupd block, and unconditional"
- `roles/firmware/defaults/main.yml:13-15` — "Checked on every converge, opted in or not"

Both are false. The consequence is the exact failure they describe: on a box with `firmware_update_enabled: false` — the default — a capsule staged by someone who ran with the flag on is never reported to the next person who converges. Commit `33a5d66` ("make it admit when a flash is pending") shows the intent was unconditional.

**Step 1: Dedent both tasks out of the block**

Move `- name: Look for firmware capsules already staged` and `- name: Warn that the next boot will write firmware`, with all their keys, from 4-space to 0-space indentation, so they sit after the `Stage firmware updates` block rather than inside it. Verify with:

```bash
grep -n "^- name:\|^    - name:\|^        - name:" roles/firmware/tasks/main.yml
```

Expected after the edit: `Look for firmware capsules already staged` and `Warn that the next boot will write firmware` both at column 0.

**Step 2: Verify**

```bash
make lint && make syntax
```

**Step 3: Commit**

```bash
git add roles/firmware/tasks/main.yml
git commit -m "fix(firmware): report a staged capsule even on a box that never opted in"
```

## Task 5: this box's identity is the public default

**Files:** Modify `inventory/hosts.yml`, `roles/thermal/defaults/main.yml`

Two values that name one specific machine ship as defaults in a repo other people clone.

**Step 1: `inventory/hosts.yml`**

Replace `ansible_user: vlad` with `ansible_user: youruser`. Leave `ansible_host: spark.local` — that is the documented default and applies to anyone.

**Step 2: `roles/thermal/defaults/main.yml`**

Replace:

```yaml
thermal_ec_device_id: 8c948e1db381648c8893897e4d09b7b153309991
```

with:

```yaml
thermal_ec_device_id: ""
```

This is a per-box hardware hash. The role's own comment says so and `host_vars/spark.yml.example` already tells people to set their own. Empty disables the firmware read, which is the correct default for a stranger's box — the assertion is skipped rather than failed.

**Step 3: Check the local `host_vars/spark.yml` still works**

`host_vars/spark.yml` is gitignored and holds this box's real values. It sets `thermal_expected_ec_firmware` but **not** `thermal_ec_device_id`. Add the device id there so this box keeps its drift guard:

```yaml
thermal_ec_device_id: 8c948e1db381648c8893897e4d09b7b153309991
```

**Step 4: Verify**

```bash
make lint && make syntax
```

**Step 5: Commit**

```bash
git add inventory/hosts.yml roles/thermal/defaults/main.yml
git commit -m "Keep this box's identity out of the defaults everyone clones"
```

---

# Phase 2 — Per-role cuts

Each task here is one role: delete its dead code, strip its comments, write its new README. Roles are independent, so these can run in parallel worktrees. **Do not touch `group_vars/all.yml`, `host_vars/`, `site.yml` or `inventory/` in this phase** — Phase 3 owns those. Leaving a variable declared with no consumer is harmless; deleting a declaration a role still reads is not.

**Comment standard for every task in this phase.** A comment survives only if a competent engineer reading the code would otherwise undo something important or reintroduce a known failure. Delete: history ("the audit found", "today's", "carried over", "previously"), justification of the author's own decision process, restatements of the task name, anything duplicated elsewhere in the repo, and paragraphs defending the **absence** of code. Prefer one line; never more than two.

Delete from **every** `defaults/main.yml` the paragraph explaining `ansible-lint`'s `var-naming[no-role-prefix]` convention. It appears in `base`, `exporters`, `monitoring`, `shelly`, `kernel` and `thermal`, plus `.ansible-lint`. The linter enforces the rule; six copies of an explanation do not.

## Task 6: `exporters`

**Files:** Modify `roles/exporters/tasks/main.yml`, `roles/exporters/defaults/main.yml`, `roles/exporters/handlers/main.yml`, `roles/exporters/templates/*.j2`; Replace `roles/exporters/README.md`

**Step 1: Delete the legacy retirement block**

Set nowhere in the repo — not in `host_vars/spark.yml`, not in tests, not in CI. Verified by grep. Migration scaffolding for a box that already migrated.

Delete the whole `Retire the cron-driven GPU metrics script` block, 5 tasks:
- First line: `` # GPU telemetry used to come from a bash loop launched by cron under `flock`. ``
- Last line: `        state: absent` (end of file)

Delete the `Remove the containerised node exporter` task:
- First line: `# The containerised exporter this role replaces runs with network_mode: host`
- Last line: `    - exporters_legacy_container_name | default('', true) | trim | length > 0`

Delete the six variables from `roles/exporters/defaults/main.yml`:
- First line: `# Off by default: only the box that grew the cron+flock+bash GPU loop by hand`
- Last line: `exporters_legacy_gpu_cron_pattern: "{{ exporters_legacy_gpu_script | regex_escape }}"`

This removes the role's only `community.docker` usage. **Do not trim `requirements.yml`** — `monitoring`, `shelly` and `tests/roles/inventory.yml` still need that collection.

**Step 2: Delete the three dead GPU query fields**

`memory.total`, `memory.used` and `memory.free` in `exporters_gpu_query_fields`. `nvidia-smi` reports `[N/A]` for these on GB10 and the exporter drops unavailable fields, so no `nvidia_smi_memory_*` series exist. Documented at `tests/fake_exporters.py:211-213`.

**Lockstep test edit, same commit.** Delete these three lines from `tests/check_dashboard.py` (around line 125):

```python
    "memory.total": ["nvidia_smi_memory_total_bytes"],
    "memory.used": ["nvidia_smi_memory_used_bytes"],
    "memory.free": ["nvidia_smi_memory_free_bytes"],
```

Do **not** touch `tests/check_dashboard.py:21-24` or `tests/fake_exporters.py:211-213` — that prose explains why the series are absent and stays true.

**Step 3: Strip comments**

DELETE:
- `tasks/main.yml` header `# node_exporter and nvidia_gpu_exporter as supervised` — restates the role name
- `tasks/main.yml` `# The nvidia_gpu_exporter archive is flat —` — duplicates the defaults comment
- `defaults/main.yml` `# Versions and ports live in group_vars/all.yml` — the prefix convention
- `defaults/main.yml` `# Release archives are staged under a` — the versioned paths say it
- `defaults/main.yml` `# Today's collector set, plus filesystem —` — history

COMPRESS:
- `tasks/main.yml` `# The groups are created explicitly rather` →
  `# Explicit, not useradd's user-private-group default: the units name a Group=,`
  `# and a unit that cannot resolve its group fails to start.`
- `tasks/main.yml` `# Group-writable and setgid so the shared` →
  `# setgid so the shared group can drop .prom files without root; node_exporter`
  `# reads them unprivileged, so they must stay world-readable.`
- `defaults/main.yml` `# Both projects publish a checksum file` →
  `# get_url is handed the checksum file's URL rather than a pinned hash that rots.`
- `defaults/main.yml` `# Ad-hoc metrics dropped here are served` →
  `# node_exporter runs unprivileged, so every .prom file here must be`
  `# world-readable or it is skipped in silence.`
- `defaults/main.yml` `` # `stat` is what exports node_boot_time_seconds. `` →
  `` #   `stat` exports node_boot_time_seconds; the uptime panel is blank without it. ``
- `defaults/main.yml` `# These two excludes are what stops` →
  `# Without these the filesystem collector recurses the snap loop devices and every`
  `` # Docker overlay, hangs, and flaps `up` to 0. `$` is written `$$` in the unit. ``
- `defaults/main.yml` `# An explicit list, not the exporter's` →
  `# Explicit, not the exporter's AUTO, so the throttle-reason fields are guaranteed.`
  `` # `clocks_event_reasons.*` is the driver-580 spelling; identity fields are appended. ``
- `handlers/main.yml` `# Both handlers reload the unit files` →
  `# daemon_reload before restart: a template change is invisible to systemd until`
  `# reloaded, and a restart on a stale definition looks like success.`
- `node_exporter.service.j2` `# Hardening. The exporter only ever reads,` →
  `# ProtectHome is read-only rather than true: hiding it costs the filesystem`
  `# collector every series for a separate /home mount.`
- `nvidia_gpu_exporter.service.j2` `# Native host unit, deliberately not a` →
  `# Native host unit, not a container: monitoring must not depend on GPU-in-container`
  `# plumbing. DCGM is unsupported on this hardware, hence nvidia-smi --query-gpu.`
- `nvidia_gpu_exporter.service.j2` `# Hardening, kept to directives that cannot` →
  `# PrivateDevices is deliberately absent: it hides /dev/nvidia* and breaks every`
  `# metric this unit exists for.`

KEEP verbatim:
- `defaults/main.yml` `# The node_exporter archive carries its own version prefix inside it.` — explains why the two unpack dirs differ; stops someone unifying them
- `defaults/main.yml` `# This archive is flat, so the version has to come from a directory we make.` — the other half of that pair
- `tasks/main.yml` `# daemon_reload here as well as in` — removing `daemon_reload` from the enable tasks breaks the first run on a brand-new unit file
- `node_exporter.service.j2` `# Native host unit, deliberately not a` — containerising it reintroduces the `/:/host:ro,rslave` hang

**Step 4: Replace the README**

`roles/exporters/README.md`, 246 lines → this exactly:

````markdown
# `exporters`

`node_exporter` and `nvidia_gpu_exporter` as supervised host systemd units.

| Variable | Default | |
|---|---|---|
| `node_exporter_version` | `1.12.1` | `group_vars`; the arm64 release archive |
| `node_exporter_port` | `9100` | bound on all interfaces |
| `nvidia_gpu_exporter_version` | `1.13.1` | `group_vars` |
| `nvidia_gpu_exporter_port` | `9835` | |
| `exporters_bin_dir` | `/usr/local/bin` | where both binaries are installed |
| `exporters_textfile_dir` | `/var/lib/node_exporter/textfile` | `2775`, group `spark_shared_group` |
| `exporters_node_collectors` | `cpu`, `meminfo`, `loadavg`, `hwmon`, `thermal_zone`, `netdev`, `uname`, `os`, `textfile`, `filesystem`, `stat` | under `--collector.disable-defaults` |
| `exporters_node_filesystem_mount_points_exclude` | see defaults | stops the collector hanging on snap loops and Docker overlays |
| `exporters_node_filesystem_fs_types_exclude` | see defaults | same |
| `exporters_gpu_query_fields` | 30 `nvidia-smi` fields | explicit list, not the exporter's `AUTO` |

```sh
systemctl status node_exporter nvidia_gpu_exporter
```
````

**Step 5: Verify**

```bash
make lint && make syntax && make dashboard
```

`make dashboard` is the one that judges the query-field deletion. Expected: `PASS 21 panel queries across 18 panels`.

**Step 6: Commit**

```bash
git add roles/exporters/ tests/check_dashboard.py
git commit -m "Drop the one-box migration path from exporters and cut its comments back"
```

## Task 7: `docker`

**Files:** Modify `roles/docker/tasks/main.yml`, `roles/docker/defaults/main.yml`, `roles/docker/handlers/main.yml`, `roles/docker/templates/daemon.json.j2`; Replace `roles/docker/README.md`

**Step 1: Delete the upstream-repo path**

51 lines and 6 tasks gated on `'docker-ce' not in ansible_facts.packages`, which is never true on DGX OS — the vendor ships `docker-ce` from `repo.download.nvidia.com`. The role's own comments admit it ("On DGX OS this stays inert"). It is also untested: it never runs on the maintainer's hardware and is not in `tests/roles/converge.yml`. Untested code that adds a third-party apt key is a liability, not a safety net. Without it, `apt install docker-ce` on a Docker-less box fails with an unambiguous error, which is a perfectly good failure mode for a recipe whose README says DGX Spark.

Delete:
- First line: `- name: Read the installed package set`
- Last line: `        update_cache: true`

That range covers the `package_facts` task, the `set_fact docker_needs_upstream_repo`, and the 4-task block (keyring dir, GPG key, deb822 repo, apt update). Leave `---` on line 1 followed by a blank line and then `- name: Install Docker, containerd and the compose plugin`.

`ansible_facts.packages` has exactly one consumer in this role, the `set_fact` that goes with it. `roles/kernel` runs its own `package_facts`, so there is no cross-role orphan.

Delete from `roles/docker/defaults/main.yml`:
- First line: `# Upstream (download.docker.com) is a fallback for a box that has no Docker at`
- Last line: `docker_apt_architecture: arm64`

That removes `docker_manage_upstream_repo`, `docker_upstream_repo_url`, `docker_upstream_gpg_url` and `docker_apt_architecture`. **The `group_vars/all.yml` copy of `docker_manage_upstream_repo` is Phase 3's job** — leave it for now.

**Step 2: Strip comments**

DELETE:
- `tasks/main.yml` `# DGX OS ships docker-ce from repo.download.nvidia.com.` — path removed
- `tasks/main.yml` `# deb822 rather than the one-line format:` — task removed
- `tasks/main.yml` `# The users role puts people in` — `site.yml` carries the ordering

COMPRESS:
- `defaults/main.yml` `# Docker itself ships with DGX OS,` →
  `` # DGX OS ships these from NVIDIA's repo. `state: present` converges what the ``
  `# vendor installed; never chase latest and never race the vendor's pinned build.`
- `defaults/main.yml` `# Unbounded json-file logs are a slow` →
  `# Unbounded json-file logs are a slow disk leak on multi-day jobs. 150 MB cap.`
- `handlers/main.yml` `# Restarting dockerd stops every running container.` →
  `# Restarting dockerd stops every running container, including a training run.`
- `tasks/main.yml` `# Without this, the restart waits until` →
  `# Without this the restart waits until the end of the play: the gpu role would`
  `# smoke-test a daemon that never read the new daemon.json.`
- `daemon.json.j2` `{#- Managed end to end by` →
  `` {#- JSON takes no comments, so there is no `ansible_managed` banner in the output. ``
  `    Hand edits on the box are overwritten on the next converge. -#}`

KEEP verbatim:
- `defaults/main.yml` `# Registered as a named runtime, deliberately NOT as `default-runtime`.` — one line, stops someone promoting it and routing Prometheus through the NVIDIA runtime
- `tasks/main.yml` the `validate: python3 -m json.tool %s` argument — not a comment, but do not remove it; it catches a template typo before it takes dockerd down
- `handlers/main.yml` the refuse-to-restart-while-training `fail` task — exemplary; leave it whole

**Step 3: Replace the README**

`roles/docker/README.md`, 150 lines → this exactly:

````markdown
# `docker`

Installs Docker, owns `/etc/docker/daemon.json` and registers `nvidia` as a named runtime.

| Variable | Default | |
|---|---|---|
| `docker_packages` | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` | always `state: present` |
| `docker_group` | `docker` | existence only; membership belongs to `users` |
| `docker_config_dir` | `/etc/docker` | holds the templated `daemon.json` |
| `docker_nvidia_runtime_path` | `nvidia-container-runtime` | a named runtime, never the default |
| `docker_log_driver` | `json-file` | |
| `docker_log_max_size` | `50m` | with `max-file`, caps each container at 150 MB |
| `docker_log_max_file` | `3` | |
| `spark_allow_docker_restart` | `true` | `false` fails the play instead of restarting mid-training |

```sh
docker info --format '{{json .Runtimes}}'   # must list nvidia
```
````

**Step 4: Verify**

```bash
make lint && make syntax
```

`tests/role-idempotence.sh` explicitly declares docker untested, so no test edit is needed.

**Step 5: Commit**

```bash
git add roles/docker/
git commit -m "Drop the untested upstream Docker fallback that DGX OS never reaches"
```

## Task 8: `kernel`

**Files:** Modify `roles/kernel/tasks/main.yml`, `roles/kernel/defaults/main.yml`, `roles/kernel/handlers/main.yml`, `roles/kernel/templates/zz-sparkup-menu.cfg.j2`; Replace `roles/kernel/README.md`

25 tasks for 4 outcomes. Take it to 18.

**Step 1: Delete the unsigned-kernel removal path**

Double-gated off (`kernel_remove_unsigned: false` **and** `kernel_unsigned_packages: []`), so it never runs. Turning it on requires typing a package name into a var file, at which point `apt remove <name>` is shorter.

- First line: `# ---------------------------------------------------------------------------` (the section banner beginning `# 5. Removal, last and`)
- Last line: `      notify: Update GRUB`

Also delete from `roles/kernel/defaults/main.yml`:
- First line: `# Removal is off, and the list is empty, so the role removes nothing until it`
- Last line: `kernel_unsigned_packages: []`

`kernel_secure_boot_enabled` is **not** orphaned — the final Secure Boot assert still reads it. The `Update GRUB` handler is still notified twice elsewhere.

**Step 2: Delete the three report-only tasks and the redundant assert**

Order matters: do these before Step 3, because Step 3 depends on them.

a) `Report the kernel state this role resolved`
- First line: `- name: Report the kernel state this role resolved`
- Last line: `` |  sort | join(', ') | default('none', true) }}. `` (the closing line of the msg)

Running-vs-intended already appears in the final assert's `fail_msg` exactly when it matters.

b) `Refuse to treat an unsigned image as the signed kernel` — the assert is unreachable. The regex that builds `kernel_intended_version` only captures `linux-image-([0-9]...`, so it structurally cannot yield `unsigned`, and `ansible_kernel` is `uname -r` which cannot either. The only way to trip it is hand-setting the override the assert then tells you to fix.
- First line: `- name: Refuse to treat an unsigned image as the signed kernel`
- Last line: `      Intended kernel {{ kernel_intended_version }} is a signed image name.`

Also delete `kernel_signed_image_package` from `defaults/main.yml` (the assert is its only guard) and simplify the expression that builds `kernel_intended_version` from three branches to two.

c) `Report how the generated GRUB menu will behave` — the assert three lines below carries the same string in both `fail_msg` and `success_msg`.
- First line: `- name: Report how the generated GRUB menu will behave`
- Last line: `      {{ kernel_grub_entry_ids | length }} menu entries.`

**Step 3: Delete the `package_facts` task**

Only safe once Steps 1 and 2 have landed — they remove both consumers. `package_facts` is one of the slowest modules in the run.
- First line: `- name: Read the installed package set`
- Last line: `    manager: apt`

**Step 4: Delete the GRUB drop-in directory task**

- First line: `- name: Ensure the GRUB drop-in directory exists`
- Last line: `    mode: "0755"`

`/etc/default/grub.d` exists on every Ubuntu with grub installed, and demonstrably exists on DGX OS because the vendor ships `no-grubmenu.cfg` in it — the fact this role's entire drop-in strategy rests on. **Accepted trade, state it in the commit message:** `ansible.builtin.template` does not create parent directories, so on a box where the directory is genuinely absent the template task now fails with a `dest` error instead of self-healing. If grub is not installed, this role has no business running.

**Step 5: Delete two variables that are one-element lists or FHS constants**

From `roles/kernel/defaults/main.yml`, delete `kernel_secure_boot_packages` and inline `name: mokutil` at its single call site. Delete `kernel_assert_grub_menu` — a switch to turn off the one safety check on the one role that can brick a headless box; its escape hatch ("your grub.cfg is laid out differently") applies to nobody running this on a Spark. Remove the `when:` condition that reads it.

Keep `kernel_manage_grub_default` — it encodes a real two-phase procedure (converge menu only, reboot, verify, converge target) that tags cannot express.

**Step 6: Strip comments**

COMPRESS:
- `tasks/main.yml` header `# This role NEVER reboots. Not optionally,` →
  `# This role NEVER reboots. The box is headless, WiFi-only and has already`
  `# failed to boot once over kernel signatures; power-cycling it is a human's call.`
  (drop the numbered 1-6 list: each section header below carries its own ordering constraint, and after Step 1 the numbering is wrong anyway)
- `tasks/main.yml` `# dpkg-query, deliberately not `apt-cache depends`.` →
  `` # dpkg-query, never `apt-cache depends`: apt-cache answers for the *candidate* ``
  `# version, so a newer kernel in the vendor archive becomes "the intended" one.`
- `tasks/main.yml` `# Ubuntu names the signed image` →
  `` # `[0-9]` after `linux-image-` is what excludes `linux-image-unsigned-...`. The ``
  `# ansible_kernel fallback keeps this correct on a box with no vendor meta package.`
- `tasks/main.yml` section banner `# 1. The signed replacement,` →
  `` # Install before anything points at it. `state: present`, never `latest`: this ``
  `# converges the kernel the box already boots, it does not look for newer ones.`
- `tasks/main.yml` section banner `# 2. The menu, before` →
  `# A drop-in, not /etc/default/grub: DGX OS ships no-grubmenu.cfg, sourced after`
  `` # the base file, which forces the menu back off. `zz-` sorts this last and wins. ``
- `tasks/main.yml` section banner `# 3. Retarget GRUB. `saved`` →
  `` # `saved` plus grub-set-default, never a menu-entry title: titles carry the ``
  `# distributor string and the version in prose, and a pin on one rots silently.`
- `tasks/main.yml` `# grub.cfg only honours ${saved_entry} once it` →
  `` # grub.cfg only honours ${saved_entry} once regenerated with GRUB_DEFAULT=saved. ``
- `tasks/main.yml` `# Submenu ids, taken from the file` →
  `    # Read from the file, never guessed: only the file says which submenus exist.`
- `tasks/main.yml` `# Ubuntu nests every per-kernel entry inside` →
  `    # A nested entry is only selectable as "<submenu id>>><entry id>"; with no`
  `    # submenu the join collapses to the entry id alone.`
- `tasks/main.yml` `# If the menu nests anything, the` →
  `          # A bare nested id is unresolvable at top level: GRUB falls back to`
  `          # entry 0, the newest kernel on disk. This one fails open, so check it.`
- `tasks/main.yml` `# The idempotency guard. grubenv already holding` →
  `    # The idempotency guard: without it a converged box reports changed forever.`
- `tasks/main.yml` section banner `# 4. Keep unsigned kernels` →
  `# An apt pin, not a dpkg hold: a hold only constrains packages already`
  `# installed, and the failure here is an update pulling in a NEW unsigned image.`
- `defaults/main.yml` `# The vendor meta package that actually` →
  `# DGX OS packaging; exists nowhere else. On a non-DGX box the install dies with`
  `# "No package matching ..." — set it to "" there and discovery falls back.`
- `defaults/main.yml` `# GRUB_TIMEOUT is 0 on this box.` →
  `# The only thing between a bad kernel and a drive to wherever the box lives.`
- `defaults/main.yml` `# Set false for a first pass` →
  `# false lands the menu timeout only, so a reboot can be proved safe first.`
- `zz-sparkup-menu.cfg.j2` `# Why a drop-in and not /etc/default/grub:` →
  `# DGX OS ships /etc/default/grub.d/no-grubmenu.cfg, which forces the menu off;`
  `` # `zz-` sorts this after it. GRUB_TIMEOUT alone is not enough — hidden counts down. ``
- `zz-sparkup-menu.cfg.j2` `# The vendor sets this to 0,` →
  `# The vendor sets this to 0, hiding the menu on exactly the boot that needs it.`

DELETE:
- `tasks/main.yml` `# --------- Discovery: read-only, restarts nothing,`
- `tasks/main.yml` `# Two things are pulled out of` — restates the task name and duplicates the compressed section banner
- `tasks/main.yml` section banner `# 6. Assertions. They report` — the never-reboot promise survives in the header and the final `fail_msg`
- `defaults/main.yml` the `var-naming` paragraph
- `defaults/main.yml` `# A machine that failed to boot` — duplicated verbatim in the template, which is what a sysadmin on the box reads
- `defaults/main.yml` `# The menu settings are written here,` — third copy of the same argument
- `defaults/main.yml` `# The generated menu is parsed to` — dies with `kernel_assert_grub_menu`
- `handlers/main.yml` `# Nothing written to /etc/default/grub takes` — the mid-run flush is explained where it happens

KEEP verbatim:
- `tasks/main.yml` `# Before the boot target moves, not after.` — compress to two lines but keep the fact; a maintainer tidying asserts to the bottom recreates "moved boot target behind a hidden menu on an unreachable box"
- `tasks/main.yml` `# Repeats the assertion above rather than` — stops someone deleting these `when:` conditions as redundant with the assert, which is skipped under `--check`
- `zz-sparkup-menu.cfg.j2` `{{ ansible_managed }}` — the marker that stops hand-editing

**Step 7: Replace the README**

`roles/kernel/README.md`, 363 lines → this exactly:

````markdown
# `kernel`

Installs the signed kernel, makes the GRUB menu visible through a drop-in, points GRUB at that
kernel, and pins unsigned images out of apt. It never reboots.

| Variable | Default | |
|---|---|---|
| `kernel_enabled` | `false` | `group_vars`; `site.yml` skips the role when false |
| `kernel_meta_package` | `linux-image-nvidia-hwe-24.04` | the concrete image is discovered from it; `""` on a non-DGX box |
| `kernel_grub_timeout` | `5` | seconds the menu stays up |
| `kernel_grub_recordfail_timeout` | `5` | menu timeout on the retry after a failed boot |
| `kernel_grub_dropin_dir` | `/etc/default/grub.d` | sourced after `/etc/default/grub` |
| `kernel_grub_dropin_name` | `zz-sparkup-menu.cfg` | `zz-` sorts last, so it wins |
| `kernel_grub_default_file` | `/etc/default/grub` | only `GRUB_DEFAULT=saved` is written here |
| `kernel_grub_config` | `/boot/grub/grub.cfg` | read, never written |
| `kernel_manage_grub_default` | `true` | `false` lands the menu alone, so a reboot can be proved safe first |
| `kernel_apt_preferences_file` | `/etc/apt/preferences.d/no-unsigned-kernels` | `Pin-Priority: -1` |

Both the tag and the flag are required — the tag alone silently no-ops:

```sh
ansible-playbook site.yml -K --tags kernel -e kernel_enabled=true
```

If the box will not boot: tap Esc at power-on and pick a previous signed kernel from the menu.
````

**Step 8: Verify**

```bash
make lint && make syntax
```

**Step 9: Commit**

Commit Steps 1-5 and Steps 6-7 separately:

```bash
git add roles/kernel/
git commit -m "Cut kernel to the four outcomes it actually has"
git commit -m "Strip kernel's comments to the ones that stop a bad edit"
```

## Task 9: `thermal`

**Files:** Modify `roles/thermal/tasks/main.yml`, `roles/thermal/defaults/main.yml`, `roles/thermal/handlers/main.yml`, `roles/thermal/templates/gpu-clock-cap.service.j2`; Replace `roles/thermal/README.md`

**Step 1: Delete the fwupd-timer stat pair and its debug**

Biggest single win in the role. Nothing consumes `thermal_fwupd_timer_mask` or `thermal_fwupd_timer_wanted` except the debug message. The `systemd_service` task below is idempotent and reports `ok`/`changed` by itself, which is the same information Ansible prints for free.

- First line: `    # The timer's state is read from the two symlinks systemd keeps it in,`
- Last line: `          updater acting on the metadata this timer fetched.`

Producer and consumer go together; nothing is orphaned.

**Step 2: Delete three more report-only tasks**

a) `Report that firmware state cannot be read`
- First line: `- name: Report that firmware state cannot be read`
- Last line: `  when: not thermal_fwupdmgr.stat.exists`

b) `Report that the GPU clock cap has nothing to cap`
- First line: `- name: Report that the GPU clock cap has nothing to cap`
- Last line: `  when: not thermal_nvidia_smi.stat.exists`

Both say "the tasks you can see marked `skipping` were skipped."

c) `Report the embedded controller firmware version`
- First line: `    - name: Report the embedded controller firmware version`
- Last line: `          id — normal on any box that is not the one this repo was audited on.`

The assert three lines below carries the same version pair in both `success_msg` and `fail_msg`. `thermal_ec_version` is still read by the assert.

**Step 3: Delete the redundant daemon-reload handler**

`Set whether the GPU clock cap applies at boot` carries `daemon_reload: true` and runs unconditionally immediately after the template — earlier than the handler would fire at end of play. No coverage is lost.

In `tasks/main.yml`, delete the single line `        - Reload the systemd unit files` from the `notify:` list. With one item left, collapse to `      notify: Restart the GPU clock cap`.

In `handlers/main.yml`, delete:
- First line: `# daemon-reload is split out and unconditional: systemd has to be told about a`
- Last line: `    daemon_reload: true`

**Step 4: Strip comments**

COMPRESS:
- `tasks/main.yml` header `# THIS ROLE NEVER FLASHES FIRMWARE. Not` →
  `# This role never flashes firmware and never removes a guard: it masks the fwupd`
  `# timer but never unmasks, starts the clock cap but never stops a running one.`
- `tasks/main.yml` `# Masking, not disabling: a masked unit` →
  `    # Masking, not disabling: disable only removes the boot symlink, which the`
  `    # next fwupd upgrade puts back. No unmask task on purpose — reverse by hand.`
- `tasks/main.yml` `` # `first | default('')` collapses three cases `` →
  `    # Empty covers all three "no version to assert" cases, so the assert skips.`
- `tasks/main.yml` `# An inverted or zero range is` →
  `    # A typo here is accepted by the template and rejected by the driver at boot.`
- `tasks/main.yml` `# Installed whether or not it is` →
  `    # Installed whether or not enabled: on disk is what makes turning it on for`
  `    # one night a single systemctl command.`
- `tasks/main.yml` `# Started when the flag is on,` →
  `    # Started when on, never stopped when off: `state: stopped` runs`
  `` #     `nvidia-smi -rgc` and would release a cap an operator started by hand. ``
- `defaults/main.yml` `# E2 — the clock cap.` →
  `# OFF: measured 0 us of thermal slowdown on this box, so the fan-curve advice is`
  `` # a hypothesis. The unit installs anyway — `systemctl start gpu-clock-cap`. ``
- `defaults/main.yml` `# The driver CLI. The clock cap` →
  `# Absolute path: also the file the role stats to decide whether there is a GPU.`
- `defaults/main.yml` `# E3 — the fwupd pin.` →
  `# OFF: the timer refreshes LVFS metadata, it does not flash anything.`
- `defaults/main.yml` `# The EC firmware version is asserted,` →
  `# A per-box hash. On another Spark the lookup finds nothing and the assert skips`
  `` # — run `fwupdmgr get-devices` there. Empty disables the firmware read. ``
- `defaults/main.yml` `# Empty asserts nothing. This is a` →
  `# Empty asserts nothing. Per-box fact, not a project constant — a stranger's`
  `# Spark on newer EC firmware is a different machine, not drift.`
- `handlers/main.yml` `# Gated, because a restart would *start*` →
  `` # Gated: a restart *starts* a stopped oneshot, so without this a template edit ``
  `# would silently cap the GPU on a box whose owner left the flag off.`
- `gpu-clock-cap.service.j2` `# Caps the GPU SM clock range` →
  `# A clock lock does not survive a reboot — that is why this is a unit, not a`
  `# command. After= avoids "Unable to set GPU clocks"; the Condition keeps it inert.`
- `gpu-clock-cap.service.j2` `# oneshot + RemainAfterExit so systemd models` →
  `` # RemainAfterExit makes the cap a state: `systemctl stop` is what releases it. ``
- `gpu-clock-cap.service.j2` `# Deliberately unhardened. This runs as root` →
  `# Unhardened on purpose: PrivateDevices and ProtectSystem cut nvidia-smi off`
  `# from /dev/nvidia*.`
  (this is technically a paragraph defending absent code, but it is also exactly the case the standard protects — a security reviewer adding `PrivateDevices=yes` breaks the unit)

DELETE:
- `tasks/main.yml` `# -------- E3 — firmware: assert,` and `# -------- E2 — the clock` — the E-phase labels are from a plan document that is not in this repo
- `tasks/main.yml` `# Drift is reported, never remediated. If` — the `fail_msg` below says it to the person who needs it
- `tasks/main.yml` `# Boot behaviour follows the flag in` — `enabled: "{{ flag | bool }}"` says it
- `defaults/main.yml` the `var-naming` paragraph
- `defaults/main.yml` `# Where systemd keeps local unit files,` — "reads all three out of here" is false once Step 1 lands
- `gpu-clock-cap.service.j2` the `-lgc`/`-rgc` glossary — `man:nvidia-smi(1)` is already in `Documentation=`

**Step 5: Replace the README**

`roles/thermal/README.md`, 345 lines → this exactly. Note the old file claims in bold at line 338 that the role is "not yet in `site.yml`"; it has been there since `site.yml:58`.

````markdown
# `thermal`

Installs the GPU clock-cap unit, optionally masks the fwupd metadata timer, and asserts the EC
firmware version. It never flashes anything.

| Variable | Default | |
|---|---|---|
| `thermal_gpu_clock_cap_enabled` | `false` | whether the cap applies at boot and now |
| `thermal_gpu_clock_cap_min_mhz` | `300` | floor handed to `nvidia-smi -lgc` |
| `thermal_gpu_clock_cap_max_mhz` | `2200` | ceiling handed to `nvidia-smi -lgc` |
| `thermal_gpu_clock_cap_unit` | `gpu-clock-cap.service` | unit name |
| `thermal_nvidia_smi_command` | `/usr/bin/nvidia-smi` | also the "is this a GPU box" guard |
| `thermal_pin_fwupd` | `false` | masks the refresh timer; never unmasks |
| `thermal_fwupdmgr_command` | `/usr/bin/fwupdmgr` | also the "is fwupd here" guard |
| `thermal_fwupd_refresh_timer` | `fwupd-refresh.timer` | the timer to mask |
| `thermal_systemd_unit_dir` | `/etc/systemd/system` | units, masks and enablement symlinks |
| `thermal_ec_device_id` | `""` | your box's; empty disables the read |
| `thermal_expected_ec_firmware` | `""` | empty asserts nothing |

Both EC values come from the JSON, not the CLI table — the assert compares strings exactly:

```sh
fwupdmgr get-devices --json
```

To cap clocks for one night without a converge:

```sh
sudo systemctl start gpu-clock-cap
```
````

**Step 6: Verify**

```bash
make lint && make syntax
```

**Step 7: Commit**

```bash
git add roles/thermal/
git commit -m "Cut thermal's report-only tasks and its redundant reload handler"
git commit -m "Strip thermal's comments and rewrite its README as a variable list"
```

## Task 10: `firmware`

**Files:** Modify `roles/firmware/tasks/main.yml`, `roles/firmware/defaults/main.yml`; Replace `roles/firmware/README.md`

Task 4 already fixed the capsule scoping. This is the verbosity pass: 48 comment lines to 60 code lines for 7 tasks.

**Step 1: Delete the duplicate report debug**

`Report the firmware a reboot will apply` duplicates the surviving unconditional warning. `firmware_updates` is still read by its own `failed_when` and by the staging task's `when:`.

- First line: `        # Runs under --check too, because the read above does. This is the only`
- Last line: `          when: firmware_updates.rc == 0`

**One sentence must survive the merge:** the handoff telling the operator to move `thermal_expected_ec_firmware` after a flash lands. That is the only cross-role coupling stated anywhere in the tasks; losing it means the next converge fails a thermal assert with no explanation.

**Accepted loss:** `{{ firmware_updates.stdout }}`, the vendor's actual device list. It cannot move to the surviving warning, which now lives outside the block where `firmware_updates` is defined. The warning gives a count, not a manifest.

Replace the surviving `Warn that the next boot will write firmware` task's `msg` with exactly:

```yaml
        msg: >-
          {{ firmware_capsules.matched }} firmware capsule(s) are staged in
          {{ firmware_capsule_dir }}. THE NEXT REBOOT WILL WRITE THEM, whoever
          performs it and for whatever reason. Keep the machine powered
          throughout; an interrupted write is not recoverable on this hardware.
          To cancel instead, delete them — fwupd has no command that will:
          rm {{ firmware_capsule_dir }}/*.cap
          Once they are applied, move thermal_expected_ec_firmware to the new
          version or the thermal role will correctly report drift.
```

**Step 2: Strip comments**

COMPRESS:
- `tasks/main.yml` header `# THIS ROLE STAGES FIRMWARE. IT NEVER` (26 lines) →
  `` # THIS ROLE STAGES FIRMWARE AND NEVER REBOOTS. `--no-reboot-check` is what ``
  `` # enforces it: without the flag `fwupdmgr update` offers to reboot and can act. ``
  Dropped: the `rm *.cap` paragraph (duplicated in the runtime warning), the rc 0/2 idempotence paragraph (duplicated at the gate), and the whole "there is deliberately no refuse-while-training guard" paragraph (defends absent code).
- `tasks/main.yml` `# Downloads the vendor catalogue; touches no` →
  `        # rc 2 is fresh cache, rc 101 is LVFS unreachable. Both leave the check`
  `        # below reading the cache — degraded but safe, so nothing fails here.`
- `tasks/main.yml` `# The idempotency gate, and the only` →
  `        # rc 0 means the vendor is offering something; rc 2 is a converged box.`
- `tasks/main.yml` `# Only reached when something is on` →
  `        # Only reached when something is on offer, so it always changes something.`
- `tasks/main.yml` `# Deliberately outside the fwupd block, and` →
  `` # Outside the block: once a capsule is staged `get-updates` stops offering it, ``
  `# so "armed and waiting for a reboot" reads as "current".`
- `defaults/main.yml` `# Off. A converge on a box` →
  `# Off. On means "stage firmware"; nothing reaches the hardware until a reboot.`
- `defaults/main.yml` `# Absolute path, so the command does` →
  `# Absolute path: also the file the role stats to decide whether fwupd exists.`
- `defaults/main.yml` `# Where fwupd leaves capsules for UEFI` →
  `# Where fwupd leaves capsules for UEFI. Their presence IS a pending flash.`

DELETE:
- `tasks/main.yml` `# Runs under --check too, because the` — goes with Step 1

KEEP:
- the `get-updates` rc-0/rc-2 gate itself — the role's only real idempotency mechanism

**Step 3: Replace the README**

`roles/firmware/README.md`, 225 lines → this exactly:

````markdown
# `firmware`

Stages whatever firmware `fwupd` offers and stops. It never reboots, and the reboot that applies a
staged capsule is the only unrecoverable operation in this repo.

| Variable | Default | |
|---|---|---|
| `firmware_update_enabled` | `false` | the only gate; set per box in `host_vars` |
| `firmware_fwupdmgr` | `/usr/bin/fwupdmgr` | absolute; also the file the role stats |
| `firmware_capsule_dir` | `/boot/efi/EFI/UpdateCapsule` | searched for `*.cap` on every converge, opted in or not |

Before the reboot that applies a capsule: keep the machine powered throughout, and afterwards move
`thermal_expected_ec_firmware` to the new version or `thermal` will correctly report drift.

To cancel a staged capsule instead:

```sh
sudo rm /boot/efi/EFI/UpdateCapsule/*.cap
```
````

**Step 4: Verify**

```bash
make lint && make syntax
```

**Step 5: Commit**

```bash
git add roles/firmware/
git commit -m "Cut firmware's header essay and its duplicate pending-flash report"
```

## Task 11: `spbm`

**Files:** Modify `roles/spbm/tasks/main.yml`, `roles/spbm/defaults/main.yml`; Replace `roles/spbm/README.md`

Tasks 1 and 2 already fixed the two defects. This is the verbosity pass.

**Step 1: Delete the DKMS report pair**

Nobody reads DKMS build tables in a converge log. `spbm_dkms` is registered and read only inside the block being cut.

- First line: `    - name: Read which kernels DKMS has built the module for`
- Last line: `          {{ spbm_dkms.stdout_lines | default(['dkms reported nothing']) }}`

**Step 2: Delete `Report that the driver is ready`**

Fires on every converge of an already-converged box to say "modprobe works." `spbm_mok_test` is still read by the enrolment block's `when:`.

- First line: `    - name: Report that the driver is ready`
- Last line: `      when: "'is already enrolled' in (spbm_mok_test.stdout | default(''))"` (end of file)

**Step 3: Strip comments**

COMPRESS:
- `tasks/main.yml` header `# Whole-system power telemetry, from the SPBM` →
  `# Secure Boot will not load a module signed by an untrusted key, and a key only`
  `# enters the trust store through MokManager, at the console. This role queues and stops.`
- `tasks/main.yml` `# Ordered before the module so DKMS` →
  `    # Before the module: DKMS needs headers to build against.`
- `tasks/main.yml` `# mokutil normally prompts on a tty,` →
  `        # mokutil prompts on a tty, which Ansible cannot answer. --generate-hash`
  `        # plus --hash-file is the documented way round it.`
- `defaults/main.yml` `# Off. Installing an out-of-tree kernel module` →
  `# Off. An out-of-tree kernel module is not a converge's business by default.`
- `defaults/main.yml` `# The PPA that carries the DKMS` →
  `# Built from antheas/spark_hwmon by github.com/vtemian/spark-spbm-builder.`
- `defaults/main.yml` `# DKMS rebuilds the module for each` →
  `# The meta package, not a versioned one: without headers arriving with each new`
  `# kernel the module silently vanishes on the next upgrade.`
- `defaults/main.yml` `# Secure Boot rejects unsigned modules. DKMS` →
  `# DKMS signs with this key; a human enrols it once at the console.`
- `defaults/main.yml` `# The one-time password typed at the` →
  `# Typed at the MokManager screen on the next boot. Pass with`
  `` # `-e spbm_mok_password=...` for a single run; empty leaves the module unloadable. ``

DELETE:
- `tasks/main.yml` `# Idempotence for the enrolment: mokutil answers` — restates the task name

KEEP:
- `tasks/main.yml` the `Report what the operator has to do at the console` debug — this is a handoff to a human who must be physically at the machine, not reporting
- `tasks/main.yml` the password assert — same
- `no_log: true` on the hash task — non-negotiable

**Step 4: Replace the README**

`roles/spbm/README.md`, 131 lines → this exactly:

````markdown
# `spbm`

Installs the `spark_hwmon` DKMS driver from a PPA and queues its signing key for MokManager, giving
whole-system power as hwmon sensors. It does not reboot; the key is enrolled by hand at the console.

| Variable | Default | |
|---|---|---|
| `spbm_enabled` | `false` | the gate |
| `spbm_ppa` | `ppa:vladtemian/spark-spbm` | carries the DKMS package |
| `spbm_package` | `spbm-dkms` | |
| `spbm_headers_package` | `linux-headers-nvidia-hwe-24.04` | kept installed so DKMS can rebuild for a new kernel |
| `spbm_mok_cert` | `/var/lib/shim-signed/mok/MOK.der` | the key DKMS signs with |
| `spbm_mok_password` | `""` | one-time, typed at MokManager; pass with `-e`, never store it |

```sh
ansible-playbook site.yml -K --tags spbm -e spbm_enabled=true -e spbm_mok_password='...'
```

Then reboot. Before the OS loads, shim shows a blue MokManager screen: Enroll MOK, Continue, Yes,
then type that password. It needs a keyboard attached — there is no network and no SSH at that
point. Miss the prompt and it cancels harmlessly; re-run the role.
````

**Step 5: Verify**

```bash
make lint && make syntax
```

**Step 6: Commit**

```bash
git add roles/spbm/
git commit -m "Cut spbm's report-only tasks and its README preamble"
```

## Task 12: `base`

**Files:** Modify `roles/base/tasks/main.yml`, `roles/base/defaults/main.yml`, `roles/base/handlers/main.yml`; Replace `roles/base/README.md`

**Step 1: Delete the ufw report pair**

Log noise. The rule tasks above already report their own outcome.

- First line: `# Read-only, and gated on the same flag as the rules above: a box that told`
- Last line: `  when: spark_firewall_manage`

**Step 2: Delete the platform-services report pair**

A hardcoded list of five services somebody once found surprising on a DGX box, printed forever, with the message itself admitting "This role reports them and leaves them alone." It forces a full `service_facts` enumeration on every converge purely to build a string.

- First line: `- name: Gather the state of every installed service`
- Last line: `      a decision for whoever owns the box.` (end of file)

Delete `base_report_units` from `roles/base/defaults/main.yml`:
- First line: `# Reported at every converge, never remediated. DGX OS enables all of these;`
- Last line: `  - cloud-init`

**Lockstep test edits, same commit.** Two comments go stale. The container image is still correct because `avahi` and `hostnamectl` still need systemd — do **not** remove `dbus` or `systemd` from `tests/roles/Dockerfile`.

In `tests/role-idempotence.sh`, replace:
```
  base    tested. Needs systemd for avahi, hostnamectl and service_facts, so
          the container boots a real init.
```
with:
```
  base    tested. Needs systemd for avahi and hostnamectl, so the container
          boots a real init.
```

In `tests/roles/Dockerfile`, in the comment beginning `# \`base\` enables avahi-daemon`, replace `and reads` / `service_facts. All three` with `. Both`.

The second-run recap goes from `ok=13` to `ok=11`; the script only greps for `changed=0`, `failed=0` and `unreachable=0`, so it stays green.

**Step 3: Inline `base_firewall_packages`**

A list containing exactly `ufw`, in a role that has no other firewall backend. Delete the variable and its comment from `defaults/main.yml`, and make the task:

```yaml
- name: Install ufw
  ansible.builtin.apt:
    name: ufw
    state: present
```

**Step 4: Wrap the firewall section in one block**

`when: spark_firewall_manage` currently repeats on five consecutive tasks. `when` on a block is ANDed onto each contained task, so this is behaviour-identical. Replace the whole firewall section with:

```yaml
- name: Manage the ufw firewall
  when: spark_firewall_manage
  block:
    - name: Install ufw
      ansible.builtin.apt:
        name: ufw
        state: present

    # ADD allow rules only. No reset, no delete, no default policy except through
    # the opt-in below: this box's only link is WiFi, so a mistake means walking to it.
    - name: Allow inbound service ports through ufw
      community.general.ufw:
        rule: allow
        port: "{{ item }}"
        proto: tcp
      loop: "{{ spark_firewall_allow_ports }}"

    # Prometheus scrapes the host exporters from a container via the docker bridge
    # gateway; default-deny drops that traffic without these rules.
    - name: Allow containers to reach the host exporters
      community.general.ufw:
        rule: allow
        from_ip: "{{ item.0 }}"
        port: "{{ item.1 }}"
        proto: tcp
      loop: "{{ spark_firewall_docker_subnets | product(spark_firewall_container_ports) | list }}"
      loop_control:
        label: "{{ item.0 }} -> {{ item.1 }}"

    # Ordering matters: the allow rules above must already be applied when ufw
    # switches to default-deny.
    - name: Refuse to enable the firewall without an SSH allow rule
      ansible.builtin.assert:
        that:
          - spark_firewall_ssh_port | int in (spark_firewall_allow_ports | map('int') | list)
        fail_msg: >-
          spark_firewall_enable is on but port {{ spark_firewall_ssh_port }} is not in
          spark_firewall_allow_ports. Enabling ufw would set a default-deny policy
          and drop your own SSH session on a box whose only link is WiFi. Add the
          port, or leave the firewall off.
        success_msg: >-
          SSH on {{ spark_firewall_ssh_port }} is allowed, so enabling ufw cannot
          close the way in.
      when: spark_firewall_enable

    - name: Enable the firewall
      community.general.ufw:
        state: enabled
      when: spark_firewall_enable
```

**Step 5: Strip the remaining comments**

COMPRESS:
- `tasks/main.yml` `# avahi rides along in the same` →
  `# avahi is not optional: it publishes <hostname>.local, which every other role`
  `# here assumes resolves.`
- `tasks/main.yml` `# Debian-family convention: the machine's own name` →
  `# Debian family resolves the machine's own name through 127.0.1.1. A stale entry`
  `# makes sudo pause on every invocation.`
- `defaults/main.yml` `# Empty leaves the clock untouched. Set` →
  `# Empty leaves the clock untouched.`

DELETE:
- `defaults/main.yml` the `var-naming` paragraph
- `tasks/main.yml` `# Empty means leave the clock alone.` — the `when:` on the next line says it and the default says it again
- `tasks/main.yml` `# Silently moving a stranger's machine to the timezone this repo's author happens to live in is not provisioning.` — justification of the author's decision process

KEEP verbatim:
- `handlers/main.yml` `# avahi publishes <hostname>.local from the system` — dropping the restart leaves the network answering to the old name
- the SSH assert's whole `fail_msg` — every line of it is instructions to somebody about to be locked out

**Step 6: Replace the README**

`roles/base/README.md`, 135 lines → this exactly. The old file claims at lines 66-71 that the role "never enables or disables the firewall", which has been false since `spark_firewall_enable` landed.

````markdown
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
````

**Step 7: Verify**

```bash
make lint && make syntax && make roles-test
```

`make roles-test` is the one that judges this role. Expected: `IDEMPOTENT: base and users both reported changed=0 on the second run`.

**Step 8: Commit**

```bash
git add roles/base/ tests/role-idempotence.sh tests/roles/Dockerfile
git commit -m "Stop base reporting things nobody acts on"
git commit -m "Scope base's firewall tasks with one block instead of five when clauses"
```

## Task 13: `gpu`, `users`, `monitoring`, `shelly`

**Files:** Modify the four roles; Replace their four READMEs

These four are the cleanest in the repo. `users/tasks/main.yml` is 6% comment and is the model. Small cuts only.

**Step 1: `users` — delete the comment that names private individuals**

- First line: `# No uid is set anywhere in this role. The box this was written for happens to`
- Last line: `# machine where those ids are already taken.`

Names two people and their uids on one specific machine, in a public repo, and defends the absence of a `uid:` key nobody would think to add.

**Do not** collapse the two `file:` tasks for the shared dir and its subdirs into one loop. The clean version needs a `map('regex_replace', ...)` or a `'.'` sentinel, both cleverer than what is there. Eight obvious duplicated lines beat a Jinja trick.

**Step 2: `gpu` — compress three comments**

- `defaults/main.yml` `# DGX OS owns the toolkit version.` →
  `# Never pin: a toolkit pin drifting behind the driver breaks GPU containers.`
- `defaults/main.yml` `# Persistent, not /var/run/cdi. /var/run is tmpfs,` →
  `# Persistent, not /var/run/cdi: that is tmpfs, so the spec is simply gone after a`
  `# reboot. Exactly one spec file may declare nvidia.com/gpu.`
- `defaults/main.yml` `# GB10 is sm_121, an architecture that` →
  `# GB10 is sm_121, which exists only from CUDA 13.0 — most cu12x images cannot run`
  `# on it — and the tag must publish a linux/arm64 manifest.`
- `tasks/main.yml` `` # `creates` is the idempotency guard: the `` →
  `` # `creates` is the idempotency guard; the refresh unit below regenerates the spec. ``
- `tasks/main.yml` `# The unit defaults to /var/run/cdi/nvidia.yaml. Left` →
  `# The unit defaults to /var/run/cdi/nvidia.yaml. A second spec declaring the same`
  `# devices makes the CDI cache drop them, so redirect rather than duplicate.`

KEEP the smoke-test assert's whole `fail_msg` — it names three concrete things to check and the sm_121/CUDA-12 trap, which is the failure people actually hit.

**Step 3: `monitoring` — three small deletions**

a) Delete the three redundant parents from the mkdir loop in `tasks/main.yml`:
```
    - "{{ monitoring_dir }}"
    - "{{ monitoring_dir }}/grafana"
    - "{{ monitoring_dir }}/grafana/provisioning"
```
`ansible.builtin.file` with `state: directory` creates parents like `mkdir -p`. Caveat worth knowing: implicitly created parents take their mode from the umask, not from `mode: "0755"`. Under root's default umask 022 that is 0755 root:root — identical in practice, not guaranteed by contract.

**Lockstep test edit, same commit:** remove the same three lines from `tests/harness/render.yml`.

b) Delete the explicit `files:` argument from both `tasks/main.yml` and `handlers/main.yml`:
```
    files:
      - compose.yml
```
`community.docker.docker_compose_v2` discovers `compose.yml` by default.

c) Do **not** inline `monitoring_grafana_home_dashboard`. `tests/check_dashboard.py:470` parses it out of `roles/monitoring/defaults/main.yml` to derive the expected dashboard uid. Inlining it into the compose template requires a ~20-line rewrite of the checker, which is churn for one variable. The other three `monitoring_grafana_*` variables could be inlined but are not worth a separate pass.

**Step 4: `monitoring` — strip comments**

COMPRESS:
- `defaults/main.yml` `# The compose project name, not the` →
  `# The project name, not the directory, namespaces the named volumes. Changing it`
  `# abandons grafana-data (hand-made dashboards) and prometheus-data (history).`
  (this drops the `/home/vlad/monitoring` history, which also removes a personal path from a public recipe)
- `defaults/main.yml` `# Where the provisioned dashboard JSON is` →
  `# Not under /var/lib/grafana: that path is the named volume's, and nesting a bind`
  `# mount inside it is a needless ordering dependency.`
- `handlers/main.yml` `# Required, and not redundant with the` →
  `` # Not redundant with the `state: present` task: a bind-mounted config change does ``
  `# not change compose.yml, so only a restart re-reads it.`
- `handlers/main.yml` `` # `docker compose restart`, which is enough: `` →
  `` #     `docker compose restart` does not accept --wait, which is why the reload ``
  `    # below retries rather than assuming Prometheus is back.`
- `handlers/main.yml` `# Preferred over a restart for Prometheus:` →
  `# Reload, not restart: it keeps the TSDB head in memory and the scrape series`
  `# continuous. Retried because it can land while Prometheus is still binding.`
- `tasks/main.yml` `# Empty, and created on purpose: Grafana` →
  `    # Empty on purpose: Grafana logs a provisioning error at every start for each`
  `    # of these it cannot open.`
  (drop the "Phase E's thermal rules will land here" forward reference — a roadmap note, not a constraint)
- `tasks/main.yml` `# Copied, not templated: the JSON is` →
  `# Copied, not templated: the JSON is full of Grafana's own {{label}} legend syntax,`
  `# which Jinja would eat.`
- `compose.yml.j2` `# No container_name on either service. Fixing` →
  `# No container_name: fixing it would stop two stacks (a real one and the test`
  `# harness) coexisting. Service names stay prometheus/grafana for the datasource.`
- `compose.yml.j2` `# THE TRAP: Prometheus runs in a` →
  `` #     # THE TRAP: inside the container `localhost` is the container, so :9100 and ``
  `    # :9835 read down. On Linux this alias does not exist unless this line makes it.`
- `prometheus.yml.j2` `# Wall-socket power. What this repo owes` (13 lines) →
  `  # The target is never the meter itself — a smart plug speaks its own RPC — but`
  `  # always some exporter. Emitted only when configured; a red target teaches neglect.`
- `prometheus.yml.j2` `# The exporters are systemd units on` →
  `` #   # Host systemd units, not containers: `localhost` would be the container, so the ``
  `  # host is named through the host-gateway alias declared in compose.yml.`

DELETE:
- `defaults/main.yml` the `var-naming` paragraph
- `defaults/main.yml` `# Today's Grafana environment, preserved deliberately:` — "today's" is history and the four names say what they do
- `datasource.yml.j2` `# Lets $__rate_interval work out honest windows` — restates what `timeInterval` is for
- `dashboards.yml.j2` `# The provider rescans on this interval,` — restates `updateIntervalSeconds`

KEEP verbatim:
- `compose.yml.j2` the host-gateway TRAP comment (compressed above, but the fact stays) — the single most expensive thing to rediscover in this repo, and it sits exactly where the `extra_hosts` line is
- `datasource.yml.j2` `# The uid is load-bearing:` — renaming it silently blanks every provisioned panel's query
- `dashboards.yml.j2` `# Editing a provisioned board in the` — prevents losing UI work without warning
- `handlers/main.yml` `# Handlers run in the order they` — reordering makes the reload run before the restart
- `compose.yml.j2` `# Port 80 so http://spark.local needs no` — stops someone "improving" it to 3000 and breaking every bookmark

**Step 5: `shelly` — strip comments**

`shelly_exporter.service.j2` is 57% comment: 38 comment lines to 24 lines of unit.

COMPRESS:
- `tasks/main.yml` `# Without a plug address the exporter` →
  `    # Without a plug address the exporter still answers /metrics and reads up == 1`
  `    # while exporting no power at all. Refuse rather than converge.`
- `tasks/main.yml` `# not_present rather than the module default` →
  `` #         # not_present, not the default `always`: a digest is immutable, so re-asking ``
  `        # the registry every converge only makes an offline run need the internet.`
- `defaults/main.yml` `# Pulled and run by digest, never` →
  `# By digest, never by tag: a tag is mutable, so an unchanged unit file could`
  `# quietly start running different software.`
- `handlers/main.yml` `# daemon_reload before the restart: a template` →
  `# daemon_reload before restart: without it the container keeps the old image`
  `# digest or the old plug address while the restart reports success.`
- `shelly_exporter.service.j2` `# easimon/shelly-exporter {{ shelly_exporter_version }}, pinned by` →
  `# A container where the other two exporters are native binaries: the project ships`
  `# a JVM image and publishes no release binaries, so a container is the artifact.`
- `shelly_exporter.service.j2` `# A container left behind by an` →
  `` # A container left by an unclean stop owns the name, and `docker run` would then ``
  `` # fail forever. The leading `-` keeps a clean start from counting as a failure. ``
- `shelly_exporter.service.j2` the 17-line block `# SHELLY_GEN2DEVICES_HOSTS, not SHELLY_DEVICES_HOSTS.` → **split into two two-line comments**, each placed at what it explains:
  `# SHELLY_GEN2DEVICES_HOSTS, not SHELLY_DEVICES_HOSTS: a Gen3 plug under the Gen1`
  `# variable is never discovered, silently.`
  and immediately above `ExecStart`:
  `# --network host, not --publish: Docker's DNAT jumps ahead of ufw, so a published`
  `# 9924 would be LAN-reachable whatever ufw says. Prometheus still scrapes it.`
- `shelly_exporter.service.j2` `# systemd owns the restart policy, so` →
  `# systemd owns the restart policy, so the container carries none. Two supervisors`
  `# over one process is how a crash loop goes unreported by both.`
- `shelly_exporter.service.j2` `# The hardening the other exporter units` →
  `# No ProtectSystem=strict here, deliberately: this is a Docker client talking to a`
  `# root-equivalent socket, and a read-only /run would block the socket outright.`

DELETE:
- `defaults/main.yml` the `var-naming` paragraph
- `tasks/main.yml` header `# easimon/shelly-exporter as a digest-pinned container under` — restates the role and duplicates `group_vars`

Also delete the digest-format half of the assert in `tasks/main.yml` — it asserts against a value the repo itself provides in `group_vars`. Keep the `shelly_host` half; that one guards a real trap.

KEEP:
- `tasks/main.yml` `# daemon_reload here as well as in` — removing it breaks the first run

**Step 6: Replace the four READMEs**

`roles/gpu/README.md`, 149 lines → :

````markdown
# `gpu`

Installs the NVIDIA container toolkit, writes and keeps the CDI spec current, and proves a GPU
container works.

| Variable | Default | |
|---|---|---|
| `gpu_enabled` | `true` | `group_vars`; `site.yml` skips the role when false |
| `gpu_toolkit_packages` | `[nvidia-container-toolkit]` | `state: present`, unpinned |
| `gpu_cdi_spec_path` | `/etc/cdi/nvidia.yaml` | the single CDI spec; `/var/run` is tmpfs |
| `gpu_cdi_refresh_env_file` | `/etc/nvidia-container-toolkit/nvidia-cdi-refresh.env` | redirected to the path above |
| `gpu_smoke_test` | `true` | skipped in `--check`; it pulls an image |
| `gpu_smoke_test_image` | `nvidia/cuda:13.0.3-base-ubuntu24.04` | CUDA 13, `linux/arm64` |

```sh
docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi
```
````

`roles/users/README.md`, 174 lines → :

````markdown
# `users`

Accounts, GitHub keys and the setgid shared artifact tree. Declares no variables of its own.

| Variable | Default | |
|---|---|---|
| `spark_users` | `[]` | list of `{name, groups, github_keys}`; empty creates nobody |
| `spark_shared_group` | `spark` | appended to every managed account; owns the shared tree |
| `spark_shared_dir` | `/srv/spark` | created `2775`, owner `root` |
| `spark_shared_subdirs` | `[data, checkpoints, runs]` | created beneath it, same mode and owner |

Naming an account in `github_keys` is a standing delegation: whoever controls it can log in as that
user at the next converge. `false` skips key installation.

```bash
ssh you@spark.local 'id; ls -ld /srv/spark /srv/spark/*'
```
````

`roles/monitoring/README.md`, 242 lines → . Note the old file gives `prometheus_image` as `v3.5.0` and `grafana_image` as `12.1.0`; both are stale.

````markdown
# `monitoring`

Prometheus and Grafana as a compose stack under `{{ monitoring_dir }}`, with a provisioned
datasource and dashboard.

| Variable | Default | |
|---|---|---|
| `monitoring_dir` | `/opt/monitoring` | `group_vars`; holds compose and every config file |
| `monitoring_project_name` | `spark-monitoring` | namespaces the `grafana-data` and `prometheus-data` volumes |
| `monitoring_dashboards_container_dir` | `/etc/grafana/dashboards` | mount point inside Grafana |
| `monitoring_grafana_home_dashboard` | `/d/spark-overview/spark-overview` | also what `make dashboard` checks the uid against |
| `prometheus_image` | `prom/prometheus:v3.13.2` | never pin below the running version |
| `grafana_image` | `grafana/grafana:13.1.1` | never pin below the running version |
| `prometheus_bind_address` | `127.0.0.1` | published address on the host |
| `prometheus_port` | `9090` | the container always listens on 9090 |
| `grafana_port` | `80` | so `http://spark.local` needs no suffix |
| `prometheus_retention` | `30d` | |
| `prometheus_scrape_interval` | `15s` | also the datasource's `timeInterval` |
| `power_scrape_target` | derived from `shelly_*` | empty emits no `power` job |

Dashboards edited in the Grafana UI are kept in the `grafana-data` volume; the provisioned file in
this repo wins on the next converge.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://spark.local/
```
````

`roles/shelly/README.md`, 496 lines → :

````markdown
# `shelly`

Runs `easimon/shelly-exporter` as a digest-pinned container under systemd, polling a Shelly Plug M
Gen3 for wall-socket power. A complete no-op while disabled.

| Variable | Default | |
|---|---|---|
| `shelly_enabled` | `false` | the gate |
| `shelly_host` | `""` | the **plug's** reserved IP, never a `.local` name |
| `shelly_scrape_host` | `host.docker.internal` | where Prometheus looks — the Spark, not the plug |
| `shelly_exporter_port` | `9924` | listening port, on the host network |
| `shelly_exporter_metrics_path` | `/prometheus` | Spring Boot actuator, not `/metrics` |
| `shelly_exporter_version` | `3.0.0` | recorded in the unit file |
| `shelly_exporter_image_digest` | see `group_vars/all.yml` | the real pin |
| `shelly_image_repository` | `ghcr.io/easimon/shelly-exporter` | |
| `shelly_container_name` | `shelly-exporter` | |
| `shelly_unit_name` | `shelly_exporter.service` | |
| `shelly_docker_bin` | `/usr/bin/docker` | |

Set up the plug first: join it to the 2.4 GHz SSID and give it a DHCP reservation.

Verify with `shelly_meter_power_watthours_total`, not with `up` — the exporter answers even when it
is discovering nothing.

```sh
journalctl -u shelly_exporter
```
````

**Step 7: Verify**

```bash
make lint && make syntax && make dashboard && make dashboard-live && make roles-test
```

`make dashboard-live` is the only thing that catches an undefined variable in a monitoring template.

**Step 8: Commit**

```bash
git add roles/gpu/ roles/users/ roles/monitoring/ roles/shelly/ tests/harness/render.yml
git commit -m "Trim the four roles that were already close to right"
```

---

# Phase 3 — Shared configuration

Runs after every Phase 2 task. By now no role reads the variables being deleted here.

## Task 14: `group_vars/all.yml`, `host_vars/spark.yml.example`, `site.yml`, `inventory/hosts.yml`

**Files:** Modify all four

**Step 1: Rewrite `group_vars/all.yml`**

137 lines → 74. Every survivor below was grep-verified against `roles/`, `site.yml` and `tests/`. Only `docker_manage_upstream_repo` is dropped outright (Task 7 removed its consumer).

**Deliberately kept in `group_vars` rather than moved to `roles/shelly/defaults`:** `shelly_scrape_host`, `shelly_exporter_port` and `shelly_exporter_metrics_path`. `power_scrape_target` reads them, and `tests/harness/render.yml` loads `group_vars/all.yml` without `roles/shelly/defaults`. It survives today only because Jinja's inline `if` short-circuits while `shelly_enabled` is false. Moving them buys tidiness and costs a latent trap that no test catches.

```yaml
---
# Project-wide registry. Per-box values go in host_vars/<host>.yml.

spark_hostname: spark

# Empty by default: a fresh clone must not invent users on someone else's box.
# See host_vars/spark.yml.example for the shape.
spark_users: []

# Keep this outside any directory a laptop rsyncs with --delete. setgid so the
# group shares what it writes.
spark_shared_dir: /srv/spark
spark_shared_group: spark
spark_shared_subdirs: [data, checkpoints, runs]

# The role only ADDS allow rules; it never resets ufw or sets a default policy.
spark_firewall_manage: true
spark_firewall_allow_ports: [22, 80]
spark_firewall_ssh_port: 22

# Enabling ufw sets default-deny incoming — the one operation that can lock you
# out. The role asserts SSH is allowed first and refuses otherwise.
spark_firewall_enable: false

# Prometheus scrapes host exporters from a container via the docker bridge, so
# that traffic hits the host INPUT chain and default-deny drops it without these.
spark_firewall_docker_subnets: ["172.16.0.0/12"]
spark_firewall_container_ports: [9100, 9835]

# nvidia-container-toolkit comes from NVIDIA's repo, which DGX OS configures.
# Turn off on a box without it rather than dying partway through the play.
gpu_enabled: true

# Off by default: the only role that can leave a headless box unbootable.
kernel_enabled: false

monitoring_dir: /opt/monitoring
# Never pin BELOW the running version: Grafana migrates its schema forward only,
# and Prometheus can refuse a TSDB written by a newer build.
prometheus_image: prom/prometheus:v3.13.2
grafana_image: grafana/grafana:13.1.1
grafana_port: 80
# Split, not "host:port": used both as a Docker port-binding prefix and as a URL
# authority, and a value valid for one is not always valid for the other.
prometheus_bind_address: "127.0.0.1"
prometheus_port: 9090
prometheus_retention: 30d
prometheus_scrape_interval: 15s
# The training-observability project pushes per-step samples with true
# timestamps. Turning this off breaks that contract.
prometheus_enable_remote_write_receiver: true

# Check linux-arm64 assets before bumping; several exporters are amd64-only.
node_exporter_version: "1.12.1"
node_exporter_port: 9100
nvidia_gpu_exporter_version: "1.13.1"
nvidia_gpu_exporter_port: 9835

# The `power` scrape job is the contract with the training-observability project:
# any Prometheus-format exporter fills it. Empty means no power job is emitted.
power_scrape_target: "{{ shelly_scrape_host ~ ':' ~ shelly_exporter_port if shelly_enabled | bool else '' }}"
power_scrape_metrics_path: "{{ shelly_exporter_metrics_path if shelly_enabled | bool else '/metrics' }}"

# False makes roles/shelly a complete no-op and emits no power scrape job.
shelly_enabled: false

# The PLUG, polled over JSON-RPC — never a scrape target. Use its reserved IP:
# the exporter runs in a container with no mDNS resolver.
shelly_host: ""
# Where PROMETHEUS looks: the Spark, through the host-gateway alias.
shelly_scrape_host: host.docker.internal
shelly_exporter_port: 9924
# Spring Boot's actuator serves the exposition format here, not at /metrics.
shelly_exporter_metrics_path: /prometheus

# The only maintained candidate exporting cumulative watt-hours as a counter, and
# verified to carry linux/arm64. Pinned by index digest, not by tag.
shelly_exporter_version: "3.0.0"
shelly_exporter_image_digest: "sha256:3032562bcff4415a39de32a169ac2c2e200ae27c9bed551cded3831d31437ac9"

# False refuses disruptive work while a GPU process is running.
spark_allow_docker_restart: true
```

**Step 2: Rewrite `host_vars/spark.yml.example`**

72 lines → 35. The worst comment ratio in the repo at 8.3:1. The four `exporters_*legacy*` examples go because Task 6 deleted the tasks that read them.

```yaml
---
# cp host_vars/spark.yml.example host_vars/spark.yml — untracked, because it
# names the accounts that get sudo and whose GitHub keys can log in.

# `groups` is on top of the user's own; the shared group is appended by the role.
# `github_keys` is a GitHub username whose keys are installed, or false.
spark_users:
  - name: you
    groups: [sudo, docker]
    github_keys: false

# Outside any directory a laptop rsyncs with --delete. Renaming this after data
# exists is a migration, not an edit.
spark_shared_dir: /srv/spark
spark_shared_group: spark

# Empty leaves the clock alone.
# base_timezone: Europe/Bucharest

# From `fwupdmgr get-devices --json`, not the CLI table: the thermal role compares
# strings exactly and asserts on every converge. Leave empty until you know yours.
# thermal_ec_device_id: "<your box's EC device id>"
# thermal_expected_ec_firmware: "0x03000302"

# Stages firmware on converge; UEFI applies it at the next boot, which nothing
# here performs for you.
# firmware_update_enabled: true

# Wall-socket power, optional. Either the bundled Shelly role:
# shelly_enabled: true
# shelly_host: 192.168.1.141      # the plug's reserved IP, never a .local name
#
# or any other meter that already speaks the exposition format:
# power_scrape_target: tasmota.lan:9999
# power_scrape_metrics_path: /metrics
```

**Step 3: Rewrite `site.yml`**

70 lines → 57. Keep only ordering comments that are load-bearing. Delete comments that merely restate a role is off by default — `group_vars` and the role defaults both already say that.

Behaviour is unchanged: `gpu_enabled` and `kernel_enabled` keep their `when:` exactly as they are.

```yaml
---
- name: Provision the DGX Spark
  hosts: spark
  become: true
  gather_facts: true
  # Handlers run in definition order across all roles; one failure skips the rest,
  # leaving new exporter units unreloaded and a new prometheus.yml unread.
  force_handlers: true

  pre_tasks:
    - name: Detect training processes on the GPU
      ansible.builtin.command: nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader
      register: spark_gpu_apps
      changed_when: false
      failed_when: false
      check_mode: false

    - name: Record whether the box is training
      ansible.builtin.set_fact:
        spark_training_active: "{{ (spark_gpu_apps.stdout | default('') | trim) | length > 0 }}"

    - name: Warn that a training run owns the box
      ansible.builtin.debug:
        msg: >-
          A GPU process is running ({{ spark_gpu_apps.stdout | trim }}).
          Container restarts are survivable; a reboot is not.
      when: spark_training_active

  roles:
    - role: base
      tags: [base]
    # docker before users: ansible.builtin.user fails hard when a group named in
    # `groups:` does not exist, and users are put in the docker group.
    - role: docker
      tags: [docker]
    - role: gpu
      tags: [gpu]
      when: gpu_enabled | bool
    - role: users
      tags: [users]
    # Before exporters: the hwmon sensors must exist before the exporters start.
    - role: spbm
      tags: [spbm]
    - role: exporters
      tags: [exporters]
    # Before monitoring: the exporter must exist before Prometheus is told to scrape it.
    - role: shelly
      tags: [shelly]
    - role: monitoring
      tags: [monitoring]
    - role: thermal
      tags: [thermal]
    - role: firmware
      tags: [firmware]
    # LAST and alone: the only role that can leave a headless WiFi-only box
    # unbootable. Run it deliberately with someone able to reach the machine.
    - role: kernel
      tags: [kernel]
      when: kernel_enabled | bool
```

**Step 4: Compress `inventory/hosts.yml`**

Task 5 already changed `ansible_user`. Replace the 6-line header comment with:

```yaml
# Keep the host NAMED `spark` whatever the machine is called: ansible_host carries
# the real address, and renaming here silently orphans its host_vars file.
```

**Step 5: Verify**

```bash
make offline
```

All five targets. This is the first point where the full suite is worth the wall-clock: `group_vars` feeds every monitoring template, and `make dashboard-live` is the only thing that judges that.

Then confirm nothing lost a variable it reads:

```bash
grep -rn "docker_manage_upstream_repo\|exporters_legacy\|exporters_retire\|kernel_remove_unsigned\|base_report_units\|kernel_grub_timeout_style\|kernel_assert_grub_menu\|kernel_signed_image_package" \
  --include="*.yml" --include="*.j2" --include="*.py" --include="*.sh" . \
  | grep -v "^./docs/plans"
```

Expected: no output.

**Step 6: Commit**

```bash
git add group_vars/ host_vars/spark.yml.example site.yml inventory/
git commit -m "Cut the configuration surface to what a person cloning this actually sets"
```

---

# Phase 4 — Prose

## Task 15: `INSTALL_CLAUDE.md`

**Files:** Modify `INSTALL_CLAUDE.md`

This is the one file that earns its length, and it grows: ~242 → ~330 lines, absorbing the decisions worth keeping from the eleven READMEs. Match its existing formatting exactly — Hard rules are `N. **Bold imperative.** Explanation.` with 3-space continuation indent; Traps are `- **Bold claim.** Explanation.` with 2-space continuation indent. Prose wraps at ~100 columns.

**Step 1: Add hard rule 10**

After hard rule 9 (the list currently ends there):

```markdown
10. **Never make `users` authoritative.** `ansible.builtin.user` carries `append: true` and
    `ansible.posix.authorized_key` carries `exclusive: false`. Both read like sloppiness and are the
    opposite. Without `append`, `groups:` becomes the complete set and the first run strips `sudo`,
    `adm`, `audio` and everything else the account already had. With `exclusive: true`, every key
    absent from `https://github.com/<user>.keys` is deleted — and GitHub answers an account with no
    public keys with an empty body, so it would truthfully install nothing over a working
    `authorized_keys` on a headless WiFi-only box. This role only ever grants. Revocation is manual
    and deliberate, and naming an account in `github_keys` is a standing delegation: whoever
    controls it can log in as that user at the next converge, with whatever key they add.
```

**Step 2: Fix the two stale spots**

`spbm` is missing from both. Add a row to the "Roles that are inert by default" table:

```markdown
| `spbm` | out-of-tree kernel module, and a key a human must enrol at the console | `spbm_enabled: true` + `-e spbm_mok_password=…` |
```

Replace the play-order line inside the fenced block:

```
base → docker → gpu → users → spbm → exporters → shelly → monitoring → thermal → firmware → kernel
```

Add one bullet after the existing ordering bullets:

```markdown
- `spbm` precedes `exporters` so its hwmon channels exist before node_exporter starts reading them.
```

**Step 3: Add the thermal measurement**

After the `--tags kernel` paragraph, before `### Power is not tied to Shelly`:

```markdown
**The clock cap ships off because of a measurement, not caution.** Over 20 h of uptime including
training this box logged 0 µs of SW and HW thermal slowdown against 23 224 s of SW power capping, at
79–80 °C with clocks at 2405 of 3003 MHz. The limiter here is the power cap, not heat, so the
fan-curve advice circulating for this hardware is a hypothesis about our box rather than a finding
on it. `nvidia-smi` also reports `N/A` for every thermal-limit register, so there is no headroom
figure to check it against. Measure before mitigating.
```

**Step 4: Add fifteen traps**

Append these to the end of the Traps list. Each one is a decision an agent would otherwise undo.

```markdown
- **`docker` deliberately sets no `default-runtime: nvidia`.** `nvidia` is registered as a *named*
  runtime, so `--runtime=nvidia` and `--gpus all` opt in per container. Making it the default would
  inject GPU device nodes and driver libraries into Prometheus, Grafana and every throwaway
  `alpine`, widening a broken toolkit from "GPU jobs fail" to "monitoring fails". Monitoring is the
  thing that has to survive when the GPU plumbing breaks.
- **The GPU is sm_121, so the smoke-test image must be CUDA 13 *and* publish a `linux/arm64`
  manifest.** sm_121 exists only from CUDA 13.0, so most `cu12x` images cannot address it, and
  plenty of images ship amd64 only. `gpu_smoke_test_image` was checked against the registry manifest
  list rather than guessed; changing that tag means checking both properties again.
- **The two filesystem-collector excludes are what stop node_exporter hanging.** Without
  `exporters_node_filesystem_mount_points_exclude` and `exporters_node_filesystem_fs_types_exclude`
  the collector walks the snap loop devices and every Docker overlay and hangs, flapping `up` to 0 —
  telemetry reporting its own absence as an outage. They are not tidiness.
- **`$` is written `$$` in the rendered exporter unit.** systemd expands `$` in `ExecStart` and `$$`
  is its documented literal dollar, so the template applies the substitution and the defaults stay
  readable as plain regexes. Debug against the rendered unit file, never against the defaults.
- **Textfile-collector `.prom` files must be `0644`.** node_exporter drops to an unprivileged user,
  so a `0600` file in `exporters_textfile_dir` is skipped with no error anybody notices. Write them
  world-readable, and write them atomically (`mktemp` in the same directory, then `mv`) so a scrape
  never sees half a file.
- **`monitoring_project_name` is load-bearing.** Compose namespaces named volumes by project, not by
  directory: `spark-monitoring_grafana-data` holds every dashboard built by hand in the UI and
  `spark-monitoring_prometheus-data` holds the history. Rename the project and both are silently
  abandoned, full and unreferenced, and the new stack collides with the running one on port 80.
- **Dashboards are installed with `copy`, never `template`.** Grafana's own legend syntax is
  `{{label}}` and Jinja would eat it. That applies to any JSON this repo hands to Grafana.
- **The Shelly exporter serves `/prometheus`, not `/metrics`.** It is a Spring Boot actuator. Left
  at Prometheus's default path the target reads down with a 404, which looks exactly like a dead
  exporter.
- **`shelly_host` is the plug; the scrape target is the Spark.** The plug speaks Shelly JSON-RPC and
  serves no metrics on any port, so it is the exporter's *configuration* and never a target.
  `shelly_scrape_host` is where Prometheus looks, through the same host-gateway alias as `node` and
  `gpu`.
- **The Shelly exporter runs on the host network on purpose.** `--publish` would put port 9924
  beyond ufw, and it serves unauthenticated device inventory alongside the power series. Loopback
  publishing is not the alternative either: Prometheus is containerised and arrives over the bridge
  gateway, not loopback.
- **`firmware` gates on `get-updates` exiting 2, and stages with `--no-reboot-check`.** `update`
  exits 0 on a converged box, so gating on its own result would report a change forever; only
  `get-updates` distinguishes "nothing to do", with exit 2. Without `--no-reboot-check`, `fwupdmgr
  update` offers to reboot and a run holding a pty can act on the answer. Neither token is cosmetic.
- **`kernel` uses an apt pin, not a dpkg hold.** A hold only constrains packages that are already
  installed; the failure being prevented is an update pulling in an unsigned image that is not
  installed yet. `Pin-Priority: -1` on `linux-image-unsigned-*` covers every unsigned kernel that
  will ever exist, including ones NVIDIA has not built.
- **`kernel` resolves the image with `dpkg-query`, deliberately not `apt-cache depends`.** apt-cache
  answers for the *candidate* version, so a newer meta package in NVIDIA's archive would become "the
  intended kernel" and `state: present` would install it — an unrequested kernel upgrade on a box
  with a boot-failure history.
- **GRUB is pinned by menu entry id, never by title.** A title carries the distributor string and
  the kernel version in prose, and when it stops matching GRUB does not complain, it boots something
  else. The id embeds the kernel version and the root UUID, and Ubuntu nests per-kernel entries, so
  the saved value is `<submenu id>><entry id>`.
- **`spbm_headers_package` is what makes the module survive a kernel upgrade.** DKMS can only
  rebuild against headers that arrive with the new kernel. Remove that meta package and there is no
  error — just a missing module, and a metric that stopped, after the next kernel.
```

**Step 5: Verify**

Read the file end to end. Every line must change what an agent would do; delete anything that does not. Confirm the two tables still render and the Hard rules list runs 1-10 without a gap.

**Step 6: Commit**

```bash
git add INSTALL_CLAUDE.md
git commit -m "Move the decisions worth keeping out of eleven READMEs and into the agent doc"
```

## Task 16: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, PR template

**Files:** Modify all four

**Step 1: `README.md`, 83 → 55 lines**

Apply bottom-up so line numbers stay valid.

a) Replace the trailing 5-line paragraph about role READMEs and `make offline` with:
```markdown
Each role has its own README.

No Spark? `make offline` runs lint, every dashboard query against a real Prometheus, and two
roles converged twice in containers.
```

b) In the Layout block, replace the `roles/` line — it currently omits `spbm`:
```
roles/                base, docker, gpu, users, spbm, exporters, shelly, monitoring, thermal, firmware, kernel
```

c) Delete the whole `## Learned the hard way` section and its table. Its content is either already in `INSTALL_CLAUDE.md`'s Traps or arrived there in Task 15. The line above it — "Every one of these cost somebody an afternoon. They are why the roles look the way they do." — is the failure mode in miniature: the author telling the reader the work was hard.

d) Replace the 6 lines after the quick-start block with 3:
```markdown
Then `make apply` again. It must report `changed=0`.

Setup, configuration and operations live in **[INSTALL_CLAUDE.md](INSTALL_CLAUDE.md)**.
```

e) Replace the dashboard paragraph with 2 lines:
```markdown
One dashboard, provisioned from a file in this repo: GPU load, temperature, power and clocks;
CPU, unified memory and disk; and a row saying whether the exporters themselves are still alive.
```

f) Delete the nav paragraph near the top. Its anchors point at sections that no longer all exist, and the `INSTALL_CLAUDE.md` link further down is the one navigation that matters.

**Step 2: `CONTRIBUTING.md`, 75 → ~49 lines**

Cut "The rules that actually matter" and "Style" back to bullets. Both currently restate `INSTALL_CLAUDE.md`'s hard rules. Delete the aphorisms — "a playbook that cannot run twice is a shell script with extra syntax", "Several comments in this repo exist because somebody lost an afternoon".

Also correct a factual error: `CONTRIBUTING.md` and the PR template both claim CI runs `make offline`. It does not — CI invokes the individual commands, and `shellcheck tests/*.sh` is a CI-only gate absent from `make offline`. A green `make offline` locally is not the same as a green PR. Say so.

**Step 3: `SECURITY.md`, 48 → ~41 lines**

Delete the closing "Trust model, stated plainly" section, which is a disclaimer explicitly saying it is not a disclaimer, and the war story about a past review finding. Keep the five "What counts" bullets at one sentence each — they are right.

Three of its cross-references point into role READMEs that Phase 2 rewrote. Repoint them at `INSTALL_CLAUDE.md` or at the defaults file that now carries the fact.

**Step 4: `.github/pull_request_template.md`, 29 → ~18 lines**

Delete the three editorialising HTML comments ("That is a feature of the report, not a digression"). Keep the checklist items as bare checkboxes. Update the README item, since role READMEs are now variable lists:

```markdown
- [ ] I updated the role's README if I changed a variable, a default or what the role does
```

**Step 5: Verify**

```bash
make lint && make syntax
grep -rn "Learned the hard way" README.md .github/ || echo "clean"
```

**Step 6: Commit**

```bash
git add README.md CONTRIBUTING.md SECURITY.md .github/pull_request_template.md
git commit -m "Say what the repo is and how to run it, then stop"
```

Leave `CODE_OF_CONDUCT.md` alone. It is the Contributor Covenant 2.1 verbatim; its value is being unmodified, and editing it produces a bespoke document somebody has to read.

## Task 17: `docs/training-observability.md`

**Files:** Modify `docs/training-observability.md`

Keep the file. It is agent-facing explanatory content, it is the contract `INSTALL_CLAUDE.md` points at, and it is the only place the remote-write receiver and the `power` job are justified. Two things in it are wrong.

**Step 1: Fix the PromQL that names metrics nobody emits**

It uses `shelly_energy_wh_total` and `shelly_power_watts`. The exporter this repo installs emits `shelly_meter_power_watthours_total` (counter) and `shelly_meter_power_current_watts` (gauge). A handoff spec whose queries return nothing is exactly the failure hard rule 8 exists to prevent, and `make dashboard` does not scan this file.

Replace the three-query block with:

```promql
# exact Wh over the run window (dashboard: $__range == the pinned run window)
increase(shelly_meter_power_watthours_total[$__range])

# marginal: subtract the idle baseline over the same duration
increase(shelly_meter_power_watthours_total[$__range])
  - (avg_over_time(training_run_idle_baseline_watts[$__range]) * $__range_s / 3600)

# cost, tariff as a Grafana constant variable in currency per kWh
increase(shelly_meter_power_watthours_total[$__range]) / 1000 * $tariff
```

and the later single query with:

```promql
avg_over_time(shelly_meter_power_current_watts[$__range]) * $__range_s / 3600   # Wh
```

**Step 2: Stop the doc hardcoding this box's paths**

It gives `/srv/bbm` and group `bbm`. The repo defaults are `/srv/spark` and `spark`. Add one clause: `` `/srv/bbm` is this box's value of `spark_shared_dir`; the repo default is `/srv/spark`. ``

**Step 3: Commit**

```bash
git add docs/training-observability.md
git commit -m "Point the observability handoff at metrics the exporter actually emits"
```

---

# Phase 5 — Verify

## Task 18: Full suite and the numbers

**Step 1: Everything**

```bash
make offline
shellcheck tests/*.sh
```

All five targets pass with the strings in the verification table. `shellcheck` exits 0.

**Step 2: Nothing references a deleted name**

```bash
grep -rn "docker_manage_upstream_repo\|docker_upstream_repo_url\|docker_upstream_gpg_url\|docker_apt_architecture\|exporters_legacy\|exporters_retire\|exporters_remove_legacy\|kernel_remove_unsigned\|kernel_unsigned_packages\|kernel_grub_timeout_style\|kernel_assert_grub_menu\|kernel_signed_image_package\|kernel_secure_boot_packages\|base_report_units\|base_firewall_packages" \
  --include="*.yml" --include="*.j2" --include="*.py" --include="*.sh" --include="*.md" . \
  | grep -v "^./docs/plans"
```

Expected: no output.

**Step 3: No identity left in tracked files**

```bash
git grep -n "ansible_user: vlad\|8c948e1db381648c\|/home/vlad\|marius" -- . ':!docs/plans'
```

Expected: no output. `host_vars/spark.yml` is gitignored, so its contents do not appear.

**Step 4: Report the numbers**

```bash
find . -name "*.md" -not -path "./.git/*" -not -path "./docs/plans/*" | xargs wc -l | tail -1
find . \( -name "*.yml" -o -name "*.j2" \) -not -path "./.git/*" -not -path "./tests/*" | xargs wc -l | tail -1
grep -rhoE "^[a-z_]+:" group_vars/all.yml roles/*/defaults/main.yml | wc -l
```

Baseline was 3451 markdown, 2959 YAML/Jinja, 127 variables. Report the actual figures rather than asserting the target was hit.

**Step 5: On the box, if one is reachable**

```bash
make check     # read the diff before converging
make apply
make idempotence
```

`make idempotence` is the real acceptance test and the only thing that proves the cuts did not break convergence. Expected: `IDEMPOTENT: second run reported changed=0`.

**Step 6: Final commit and push**

```bash
git add -A && git status --short    # review before committing
git commit -m "Record the post-cleanup line counts"
git push -u origin strip-the-repo-back
```

Check the push succeeded. A push that fails silently is a push that did not happen.

---

## Rejected, with reasons

Do not do these. They came up in review and were considered and turned down. Recorded so they are not re-proposed.

**Folding `roles/shelly` into `roles/exporters`.** Superficially a simplification: 5 tasks and 6 variables plus their own defaults, handler and README, installing a third exporter into a role literally called `exporters`. But `ansible-lint`'s production profile enforces `var-naming[no-role-prefix]`, so the move requires renaming `shelly_image_repository`, `shelly_image_ref`, `shelly_container_name`, `shelly_docker_bin` and `shelly_unit_name` to `exporters_shelly_*`, plus every reference in the tasks, handler and template. That is five renames and a template move to save one entry in `site.yml`. Churn, not simplification.

**Moving `roles/thermal`'s fwupd half into `roles/firmware`.** The right shape on the merits — the two roles already `stat` the same binary under two different variable names, and `firmware` prints a message telling you to go edit a `thermal_` variable. But `ansible-lint` forces eleven renames (six defaults plus five `register`/`set_fact` targets), there is a collision to resolve (`firmware_fwupdmgr` and `thermal_fwupdmgr_command` are the same path), and `thermal_systemd_unit_dir` has to exist in both roles afterwards. Neither role is converged by any test, so nothing but lint would catch a mistake. Revisit as its own change, never as part of a cleanup.

**Collapsing the two exporter install paths into a loop.** Seven tasks become three, with a list in defaults carrying a `--strip-components` field per exporter. It is standard Ansible and it is genuinely shorter. It is also a restructure, and every other change in this plan is a deletion. The duplication costs 30 lines and confuses nobody.

**Inlining all 69 single-use plumbing variables.** The cross-reference found 36 variables referenced exactly once and 33 referenced 2-5 times within one role. Inlining them all would take the count from 127 to ~58. Not done, for two reasons: the churn is large and touches every role, and at least one carries a trap — `exporters_node_filesystem_*_exclude` is passed through a `| replace('$', '$$')` filter in the template, so inlining requires hand-writing `$$` and a mistake there silently breaks the filesystem collector. A few obvious ones are inlined where a task already deletes their neighbours (`base_firewall_packages`, `kernel_secure_boot_packages`). The rest can wait for a pass that has nothing else going on.

**Inlining `monitoring_grafana_home_dashboard`.** `tests/check_dashboard.py:470` parses it out of `roles/monitoring/defaults/main.yml` to derive the expected dashboard uid. Inlining needs a ~20-line rewrite of the checker to regex it out of the compose template instead. Not worth it for one variable.

**Standardising how roles are gated.** `gpu_enabled` and `kernel_enabled` gate via `when:` in `site.yml`; `shelly_enabled`, `spbm_enabled` and `firmware_update_enabled` gate inside their roles. In-role gating is better — a role that always runs can print why it did nothing, where a skipped role prints `skipping: [spark]` and nothing else — and it wins on count, 4 roles to 2. But changing it is a behaviour change dressed as tidying. Separate decision, separate change.
