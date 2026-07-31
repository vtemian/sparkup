# `gpu`

Makes GPU containers possible, and then proves it. Installs the NVIDIA container
toolkit, generates the CDI specification, keeps that specification current across
driver updates, and runs `nvidia-smi` inside a container as a real task.

Depends on `docker` having registered the `nvidia` runtime. `site.yml` already
orders them that way.

## The toolkit is not pinned

`nvidia-container-toolkit` is installed with `state: present` and no version.
DGX OS owns it — 1.19.1-1 today, from
`https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/sbsa`,
alongside `nvidia-container-toolkit-base`, `libnvidia-container1` and
`libnvidia-container-tools` at the same version. A pin here would drift behind
the driver, and a toolkit older than its driver is one of the standard ways GPU
containers stop working after a vendor update.

## CDI: one spec file, in `/etc`

`/etc/cdi` and `/var/run/cdi` did not exist before this role, which matches the
audit in `PROMPT.md`. The role creates `/etc/cdi` and writes
`/etc/cdi/nvidia.yaml` with:

```sh
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

guarded by `creates:`, so a converged box reports no change. Regeneration after a
driver update is the refresh unit's job, below — not a rewrite on every run.

**`/etc/cdi`, not `/var/run/cdi`, and this matters.** `/var/run` is a tmpfs, so a
spec written there is gone after a reboot. The refresh unit that would rewrite it
triggers on *file changes* (`PathChanged` on `modules.dep` and
`/usr/bin/nvidia-ctk`), and a reboot changes none of those — so nothing
regenerates it and GPU containers silently lose their CDI devices until the next
driver upgrade. `/etc` survives reboots. This is a case where `PROMPT.md`'s
instruction and the vendor's default disagree, and the plan is right.

### Contradiction found: the refresh unit writes somewhere else

`PROMPT.md` says to "enable `nvidia-cdi-refresh` if the toolkit provides it". It
does — but not in the shape the plan assumes. Measured on the box:

```
$ systemctl list-unit-files 'nvidia-cdi-refresh*'
nvidia-cdi-refresh.path      disabled  enabled
nvidia-cdi-refresh.service   disabled  enabled
```

Two units, not one, both shipped by `nvidia-container-toolkit-base` as dpkg
conffiles in `/etc/systemd/system/`, both **disabled**. The `.path` unit is the
one to enable — it is the trigger; the `.service` is oneshot and is started by
it. The role therefore enables and starts `nvidia-cdi-refresh.path`, after
checking that the unit file exists, and skips cleanly on a toolkit version that
does not ship it.

The service's own default is the problem:

```
Environment=NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=/var/run/cdi/nvidia.yaml
EnvironmentFile=-/etc/nvidia-container-toolkit/nvidia-cdi-refresh.env
ExecStart=/usr/bin/nvidia-ctk cdi generate
```

Enabled as shipped, the next driver update would write a **second** spec at
`/var/run/cdi/nvidia.yaml` while ours sits in `/etc/cdi/nvidia.yaml`. The CDI
cache scans both directories, and a device name claimed by two specs is treated
as a conflict and **dropped** — so `nvidia.com/gpu=all` would stop resolving
precisely because the refresh worked. Two specs is worse than none.

The fix uses the vendor's own documented override point.
`/etc/nvidia-container-toolkit/nvidia-cdi-refresh.env` already exists (another
conffile) and says so in its header, shipping the relevant line commented out:

```
# NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=/var/run/cdi/nvidia.yaml
```

The role uncomments it and points it at `gpu_cdi_spec_path`, so the unit
refreshes the one spec this role owns. `lineinfile` with a regexp that matches
the commented and uncommented forms keeps this idempotent and leaves the vendor's
explanatory comments intact.

## The smoke test

Gated behind `gpu_smoke_test` (default `true`) and skipped in `--check`, because
it pulls an image:

```sh
docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi
```

`changed_when: false` — running `nvidia-smi` changes nothing. An
`ansible.builtin.assert` then requires `rc == 0` plus `NVIDIA-SMI` and
`CUDA Version` in the output, so a container that starts but cannot see the
driver fails the task instead of passing on an exit code. The assertion is
model-agnostic on purpose; asserting `GB10` would make the role wrong on the next
machine for no extra safety.

### Why this tag, and how it was verified

The GPU is **sm_121**, an architecture that exists only from CUDA 13.0. Most
`cu12x` images cannot address it, so the image has to be CUDA 13 **and** publish
a `linux/arm64` manifest — plenty of images publish `amd64` only. The tag was
checked against the registry rather than guessed:

```sh
$ TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:nvidia/cuda:pull" | jq -r .token)
$ curl -sI -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    https://registry-1.docker.io/v2/nvidia/cuda/manifests/13.0.3-base-ubuntu24.04
HTTP/2 200
docker-content-digest: sha256:7c7413a56200486f71f181cad9310f6fd31b6bb21816ade15fc9c1e1e927a5c1
```

The manifest list contains both platforms:

```
linux arm64  sha256:56d9d8183e2181a20be6b0d3801d1f056a0e75c17706df939ba207b126e1cb9c
linux amd64  sha256:97d085a7423ee18ec483a2878b9be2c976dc4ba908aef96518beb00e1899dcc4
```

`13.0.3` is the newest CUDA 13.0 patch on `nvidia/cuda`, matching the driver's
reported CUDA 13.0; `13.0.1`, `13.0.2`, `13.1.1` and `13.1.2` also carry arm64
manifests if a different pin is ever wanted. The `base` flavour is used because
the smoke test needs no CUDA libraries at all — `nvidia-smi` is injected from the
host by the runtime — so `runtime` or `devel` would only be a larger download.

## Variables

| variable | default | notes |
|---|---|---|
| `gpu_toolkit_packages` | `[nvidia-container-toolkit]` | unpinned on purpose |
| `gpu_cdi_spec_path` | `/etc/cdi/nvidia.yaml` | persistent, and the single spec |
| `gpu_cdi_refresh_env_file` | `/etc/nvidia-container-toolkit/nvidia-cdi-refresh.env` | vendor conffile, documented override point |
| `gpu_smoke_test` | `true` | |
| `gpu_smoke_test_image` | `nvidia/cuda:13.0.3-base-ubuntu24.04` | CUDA 13, arm64 verified |

## Verifying

```sh
test -f /etc/cdi/nvidia.yaml
systemctl is-enabled nvidia-cdi-refresh.path
docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi
```

Run the playbook twice; the second run must report `changed=0`.
