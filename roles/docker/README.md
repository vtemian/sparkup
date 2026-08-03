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
