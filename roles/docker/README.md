# `docker`

Installs Docker, owns `/etc/docker/daemon.json` and registers `nvidia` as a named runtime.

A `daemon.json` change needs a dockerd restart, which stops every running container. If a GPU
compute process is active the play fails instead: the new file is already on disk, so re-running
once the box is free is all it takes.

| Variable | Default | |
|---|---|---|
| `docker_packages` | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` | always `state: present` |
| `docker_group` | `docker` | existence only; membership belongs to `users` |
| `docker_config_dir` | `/etc/docker` | holds the templated `daemon.json` |
| `docker_nvidia_runtime_path` | `nvidia-container-runtime` | a named runtime, never the default |
| `docker_log_driver` | `json-file` | |
| `docker_log_max_size` | `50m` | with `max-file`, caps each container at 150 MB |
| `docker_log_max_file` | `3` | |

```sh
docker info --format '{{json .Runtimes}}'   # must list nvidia
```
