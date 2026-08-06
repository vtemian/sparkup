# queue

Runs the sparks job queue, so that submitting a training run and then closing
your laptop is a thing you can do.

One container, one job at a time, first in first out. A job is a directory under
`/srv/spark/queue` holding the submitter's data and a pre-built image tag; the
container ENTRYPOINT is `fire`, which pulls that image, starts the training
command, and records how it ended.

## What this role puts on the box

| Path | What it is |
|---|---|
| `/opt/queue/compose.yml` | The runner service, its own compose project |
| `/srv/spark/queue` | The job spool: `3775`, group `spark` |
| `/usr/local/bin/sparks` | The queue client, which is the runner's image run as you |

## Why the queue is not in monitoring's compose project

The runner supervises a training job from inside its own container, so
restarting it interrupts whatever is running. Monitoring's compose file is
re-rendered and restarted whenever a scrape interval or a dashboard changes.
Sharing a project would make every Grafana tweak abort somebody's six-hour run.

Interruption is survivable rather than silent: when the runner starts it
reconciles anything left mid-flight, marking it failed with a reason and
removing the container that outlived it. `sparks retry` puts the job back.

## The Docker socket

This is the only container on the box given `/var/run/docker.sock`, which is
root on the host by any other name. Two things keep it honest, and both live in
sparks rather than here:

- every flag a job's container gets is chosen by the runner, never by the job,
  so a job cannot ask for `--privileged` or mount `/`
- the runner drops to the submitter's own uid before starting anything, and a
  job's owner is the uid that owns its files -- not a field inside them, which
  anyone could write

## The client

`/usr/local/bin/sparks` is the runner's own image, run as the calling user. It
is a wrapper rather than an installed package so that the client and the runner
can never be different builds reading the same job files.

It does not launch training locally; that would run inside the client's own
container, which has none of your dependencies. Queue work with
`sparks submit` from a laptop (or this wrapper), and let `fire` pull and run it.

## Checking on it

```sh
sparks queue                 # what is running and what is waiting
docker logs -f spark-queue-runner-1
```

The runner publishes `sparks_queue.prom` into the node_exporter textfile
directory on every pass, including a heartbeat. A queue that has stopped
processing shows up as a heartbeat that stops advancing, which is what the
`SparksQueueRunnerStuck` alert watches for.
