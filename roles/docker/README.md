# `docker`

Installs the Docker engine, owns `/etc/docker/daemon.json`, and registers the
NVIDIA container runtime so that the `gpu` role can prove GPU containers work.

The role is deliberately small. Docker already runs on this box; the job here is
to converge one config file without disturbing anything the vendor pinned.

## Where Docker actually comes from — settling an open question

`PROMPT.md` lists "Vendor Docker provenance. Is 29.2.1 from Docker CE upstream
or NVIDIA's repo?" as an open question, because it decides whether this role may
manage an apt repository. It is measured, and the answer is **NVIDIA's repo**:

```
$ apt-cache policy docker-ce
docker-ce:
  Installed: 5:29.2.1-1~ubuntu.24.04~noble
  Candidate: 5:29.2.1-1~ubuntu.24.04~noble
  Version table:
 *** 5:29.2.1-1~ubuntu.24.04~noble 600
        600 https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64 noble-updates/common arm64 Packages
        100 /var/lib/dpkg/status
     5:29.1.3-1~ubuntu.24.04~noble 600
     ...
```

`docker-ce-cli` (5:29.2.1) and `containerd.io` (2.2.1) resolve to the same
source. There is **no `docker.list` or `docker.sources` in
`/etc/apt/sources.list.d/` at all** — the directory holds `dgx.sources`,
`spark.sources`, `cuda-compute-repo.sources`, the Canonical/NVIDIA edge PPAs and
the stock Ubuntu sources, and nothing from `download.docker.com`.

**Consequence.** Adding Docker's upstream repository on a DGX box would give apt
a second source for `docker-ce` at the same or higher priority, and a routine
`apt upgrade` could then swap NVIDIA's build for an upstream one that the rest of
the DGX stack was never tested against. So the repo is added **only when Docker
is genuinely absent**, guarded on two conditions at once:

- `docker_manage_upstream_repo` (default `true`, in `group_vars/all.yml`), and
- `docker-ce` missing from `ansible.builtin.package_facts`.

On this box the second condition is false, the whole block skips, and a fresh
non-DGX machine still converges. Packages are installed with `state: present`,
never `state: latest`: the vendor owns the version.

## `daemon.json`, and two things it deliberately does not say

`/etc/docker/daemon.json` did not exist before this role. It is now templated and
**owned end to end** — hand edits on the box are overwritten on the next
converge. It renders exactly:

```json
{
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
```

**No `default-runtime: nvidia`.** Setting it would route *every* container
through the NVIDIA runtime — Prometheus, Grafana, an exporter, a throwaway
`alpine`. Each would get GPU device nodes and driver libraries injected that it
has no use for, which widens the blast radius of a broken toolkit from "GPU jobs
fail" to "monitoring fails", and monitoring is the thing that must survive when
the GPU plumbing breaks. `nvidia` is registered as a *named* runtime instead:
`docker run --runtime=nvidia` and `--gpus all` opt in per container, and nothing
else pays for it.

**Log rotation is not decoration.** The `json-file` driver is unbounded by
default: a container's log grows until the disk fills. This box runs multi-day
training jobs, and the `/` filesystem is the only filesystem — there is no
separate `/home` to absorb the damage. `max-size: 50m` with `max-file: 3` caps
each container at 150 MB, which turns an open-ended disk leak into a fixed cost.
A full root filesystem on a headless WiFi-only box is an expensive way to learn
this.

## The restart gate

A `daemon.json` change notifies `Docker configuration changed`, which two
handlers listen on:

| handler | fires when |
|---|---|
| `Refuse to restart Docker while a training run owns the box` | `spark_training_active` **and** not `spark_allow_docker_restart` |
| `Restart Docker` | otherwise |

`site.yml` sets `spark_training_active` from
`nvidia-smi --query-compute-apps=pid,process_name`; `group_vars/all.yml` sets
`spark_allow_docker_restart` (default `true`). Restarting dockerd stops every
running container, so when a run owns the box and restarts are disallowed the
play **fails with an actionable message** rather than converging quietly over
somebody's work. The new `daemon.json` is already on disk at that point and takes
effect at the next restart, so the fix is to wait, or to re-run with
`-e spark_allow_docker_restart=true`.

The template also carries `validate: python3 -m json.tool %s`. An invalid
`daemon.json` is not a config error you notice at the next reboot — it is a
dockerd that refuses to start, on a box whose monitoring lives in containers.
Validating before the file lands costs nothing.

## The `docker` group

The role guarantees the group **exists** (`state: present`, no fixed GID — it is
988 on this box, assigned by the package) and manages **no members**. Membership
belongs to the `users` role, which is the single owner of who is in which group.

**Ordering caveat worth knowing:** `site.yml` runs `users` *before* `docker`. On
this box that is harmless because the group already exists, but on a genuinely
fresh machine the `users` role would reference a group nothing had created yet.
If that ever bites, the fix belongs in `site.yml`'s role order, not in a second
group definition here.

## Variables

| variable | default | notes |
|---|---|---|
| `docker_packages` | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` | always `state: present` |
| `docker_manage_upstream_repo` | `true` | ANDed with "Docker is absent"; inert on DGX OS |
| `docker_upstream_repo_url` | `https://download.docker.com/linux/ubuntu` | |
| `docker_upstream_gpg_url` | `.../ubuntu/gpg` | keyring at `/etc/apt/keyrings/docker.asc` |
| `docker_apt_architecture` | `arm64` | single-host project, single architecture |
| `docker_group` | `docker` | existence only, never membership |
| `docker_config_dir` | `/etc/docker` | |
| `docker_nvidia_runtime_path` | `nvidia-container-runtime` | `/usr/bin/nvidia-container-runtime`, already installed |
| `docker_log_driver` | `json-file` | |
| `docker_log_max_size` | `50m` | |
| `docker_log_max_file` | `3` | |

Consumed from `group_vars` / `site.yml`, not owned here:
`spark_allow_docker_restart`, `spark_training_active`.

## Verifying

```sh
docker info --format '{{json .Runtimes}}'   # must list `nvidia`
docker compose version                      # v5.0.2 from the vendor
docker ps                                   # monitoring containers back after a restart
```

Before this role, `docker info` listed `runc` and `io.containerd.runc.v2` only.
Run the playbook twice; the second run must report `changed=0`.
