# `users`

Accounts, keys and the shared artifact tree. This is the role that turns a freshly installed box
into one that two people can log into and work on without stepping on each other.

It does four things:

1. creates the shared group `{{ spark_shared_group }}`;
2. creates every account in `spark_users` with shell `/bin/bash`, adding each one to its own
   supplementary groups **plus** the shared group;
3. installs public keys for any account that names a GitHub username;
4. creates `{{ spark_shared_dir }}` and its subdirectories, group-owned and **setgid**.

The role manages no passwords, no sudoers files and no UIDs. Sudo comes from membership of the
`sudo` group, which is data in `spark_users`, not policy in this role.

## Variables

| variable | default | meaning |
|---|---|---|
| `spark_users` | `[]` | list of `{name, groups, github_keys}`. Empty by default, so a fresh clone creates nobody |
| `spark_shared_group` | `spark` | group that owns the shared tree; every managed user joins it |
| `spark_shared_dir` | `/srv/spark` | root of the shared artifact tree |
| `spark_shared_subdirs` | `[data, checkpoints, runs]` | directories created beneath it |

The real values live in `group_vars/all.yml` and `host_vars/spark.yml`; on this box the group is
`bbm` and the tree is `/srv/bbm`. A `github_keys` of `false` means "this account's keys are managed
by hand" — the key task is skipped entirely for it.

## Why `{{ spark_shared_dir }}` exists at all

This is the load-bearing part of the role, and it is easy to "simplify" into a bug.

`bbm`'s `scripts/spark.sh` synchronises the laptop tree to the box with
`rsync -az --delete` into `${BBM_SPARK_DIR:-~/bbm}`, using a **hardcoded** exclude list
(`.git/ .venv/ .claude/ __pycache__/ *.pyc dist/`). It does not read `.gitignore`, and it does not
exclude `data/` or `checkpoints/`.

`--delete` means rsync makes the destination *identical* to the source. Anything under `~/bbm` that
does not exist on the laptop is deleted on the next `make spark-sync` — silently, and without
asking. A checkpoint written by a training run is exactly that: a file the laptop has never heard
of.

So `~/bbm` is owned by rsync, and every artifact that must survive a sync lives outside it:

| artifact | path | why |
|---|---|---|
| datasets | `{{ spark_shared_dir }}/data` | large, generated on the box, never in the laptop tree |
| checkpoints | `{{ spark_shared_dir }}/checkpoints` | written mid-run; losing these loses the run |
| run metadata | `{{ spark_shared_dir }}/runs` | per-run `summary.json`, read long after the run ends |

Moving these back under `~/bbm` would look tidier and would destroy data on the next sync.

## The setgid bit (`2775`)

Two people share this box, and both write into the same tree. Under ordinary Unix semantics a new
file gets the *creating user's* primary group — so a dataset written by `vlad` lands as
`vlad:vlad`, and `marius` cannot write to it even though the parent directory is group-writable.
That failure appears hours later, in the middle of someone else's job.

The setgid bit on a directory changes group inheritance: new entries inherit the **directory's**
group rather than the creator's, and new subdirectories inherit the setgid bit itself, so the
property propagates all the way down. Combined with `g+w`, that is what makes the tree genuinely
shared.

```
drwxrwsr-x  root  bbm  /srv/bbm
     ^^^
     └── the `s` is the setgid bit; 2775 = setgid + rwx owner + rwx group + r-x other
```

The owner is `root` deliberately: the tree belongs to the machine, not to whichever human happened
to be provisioning it that day. Access is by group membership.

Note the limit of this mechanism: setgid fixes the *group* of new files, not their *mode*. A
process with a restrictive `umask` (`0077`) still creates group-unreadable files inside a setgid
directory. If that ever bites, the fix is the umask of the training launcher, not this role.

## `append: true` is not optional

The `groups` list in `spark_users` is what the box's owner wants each account to *gain*, not the
complete set of groups it should have. Without `append: true`, `ansible.builtin.user` treats the
list as authoritative and **removes** every other membership.

On this box that would strip `vlad` of `adm`, `audio`, `dip`, `plugdev`, `users` and `lpadmin` on
the first run. On someone else's box it could strip an administrator of `sudo` — a change that only
becomes visible the next time they need it, when they have no way to get it back without another
administrator or console access. Appending is strictly safer and costs nothing: the role is still
idempotent, because adding a user to a group they are already in is a no-op.

The role deliberately provides **no** removal path. Taking someone's access away is a decision, not
a convergence step, and it belongs in a human's hands.

## `exclusive: false` for GitHub keys

`ansible.posix.authorized_key` fetches `https://github.com/<username>.keys` from the target host
and installs every key it finds. With `exclusive: true` it would also delete every key *not* in
that response — including the laptop key someone is currently connected with.

The failure mode is worth stating plainly: GitHub returns an empty body for an account with no
public keys, and an exclusive run would then truthfully install "no keys" over a working
`authorized_keys` file. A WiFi-only headless box that has just had its keys emptied is a box you
walk to. `exclusive: false` means the role can only ever add.

The consequence is that key *revocation* is manual. That is the correct trade for a two-person box:
adding keys is routine and safe to automate, removing them is rare and worth doing deliberately.

## Docker group membership needs a new session

Group membership is baked into a login session when it is created; adding a user to `docker`
does nothing for connections that already exist. Ansible's persistent SSH connection is one of
those, so a task that runs `docker ps` as `marius` later in the same play can fail even though the
membership is correctly configured.

The fix is one line, in the play that needs it — not in this role:

```yaml
- name: Reset the connection so new group membership applies
  ansible.builtin.meta: reset_connection
```

No such task is included here, because nothing in `site.yml` currently depends on docker membership
taking effect within the same run, and a `meta:` task is unconditional — it cannot be made
idempotent or conditional, and it would tear down and rebuild the SSH connection on every converge
for no reason. Add it at the point of need.

Humans see the same rule: `ssh marius@spark.local docker ps` works after one reconnect, not before.

## Deliberate omissions

**No UIDs.** `vlad` is 1000 and `marius` is 1001 on this box, but that is an accident of install
order, not a fact worth pinning. Hardcoding it would fail on any machine where those IDs are taken,
and would give this recipe a hidden requirement to be run before anyone else logs in.

**No group creation beyond the shared group.** Every group named in a user's `groups` list must
already exist — `ansible.builtin.user` fails if one does not. In practice `sudo` is universal and
`docker` is created by the Docker package, which DGX OS ships preinstalled. On a box without
Docker, run the `docker` role first or create the group by hand. This role does not create them,
because a role that silently creates any group it is handed also silently absorbs a typo: `dokcer`
would converge green and grant nothing.

## Verify

```bash
ansible-lint roles/users                 # clean under the production profile
ansible-playbook site.yml -K --tags users
ansible-playbook site.yml -K --tags users   # second run: changed=0

ssh vlad@spark.local 'id vlad; id marius'   # both in docker and the shared group
ssh marius@spark.local 'docker ps'          # works after one reconnect
ssh vlad@spark.local 'ls -ld /srv/bbm /srv/bbm/*'   # drwxrwsr-x root <group>
```

A stricter check of the setgid behaviour, which is the property that actually matters:

```bash
ssh vlad@spark.local 'touch /srv/bbm/data/.probe && ls -l /srv/bbm/data/.probe && rm /srv/bbm/data/.probe'
```

The file must be group-owned by the shared group, not by `vlad`.
