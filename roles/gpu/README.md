# `gpu`

Installs the NVIDIA container toolkit, writes and keeps the CDI spec current, and proves a GPU
container works.

| Variable | Default | |
|---|---|---|
| `gpu_toolkit_packages` | `[nvidia-container-toolkit]` | `state: present`, unpinned |
| `gpu_cdi_spec_path` | `/etc/cdi/nvidia.yaml` | the single CDI spec; `/var/run` is tmpfs |
| `gpu_cdi_refresh_env_file` | `/etc/nvidia-container-toolkit/nvidia-cdi-refresh.env` | redirected to the path above |
| `gpu_smoke_test` | `true` | skipped in `--check`; it pulls an image |
| `gpu_smoke_test_image` | `nvidia/cuda:13.0.3-base-ubuntu24.04` | CUDA 13, `linux/arm64` |

```sh
docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi
```
