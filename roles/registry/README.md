# registry

A local Docker Registry (`registry:2`) on the box, so training images are built
on laptops and pulled by the queue — never built on the box.

No authentication. The trust boundary is the same people who already have SSH
to the box (LAN trust = ssh trust). The registry speaks plain HTTP, so every
Docker daemon that pushes or pulls — laptop and box — must list the host:port
under `insecure-registries`.

## What this role puts on the box

| Path | What it is |
|---|---|
| `/opt/registry/compose.yml` | The registry service, its own compose project |
| named volume `spark-registry_registry-data` | Persisted image blobs and tags |

| Variable | Default | |
|---|---|---|
| `registry_dir` | `/opt/registry` | compose project directory |
| `registry_project_name` | `spark-registry` | namespaces the named volume |
| `registry_image` | `registry:2` | |
| `registry_port` | `5000` | published on all interfaces |
| `registry_host` | `{{ spark_hostname }}.local` | the name clients and `box.toml` use |

## Checking on it

```sh
curl -s http://spark.local:5000/v2/_catalog
docker logs -f spark-registry-registry-1
```
