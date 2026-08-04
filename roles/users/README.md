# `users`

Accounts, GitHub keys and the setgid shared artifact tree. Declares no variables of its own.

| Variable | Default | |
|---|---|---|
| `spark_users` | `[]` | list of `{name, groups, github_keys}`; empty creates nobody |
| `spark_shared_group` | `spark` | appended to every managed account; owns the shared tree |
| `spark_shared_dir` | `/srv/spark` | created `2775`, owner `root` |
| `spark_shared_subdirs` | `[data, checkpoints, runs, dashboards]` | created beneath it, same mode and owner |

Naming an account in `github_keys` is a standing delegation: whoever controls it can log in as that
user at the next converge. `false` skips key installation.

```bash
ssh you@spark.local 'id; ls -ld /srv/spark /srv/spark/*'
```
