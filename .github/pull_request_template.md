## What this changes

## How it was verified

- [ ] `make offline` passes locally
- [ ] `shellcheck tests/*.sh` passes, a CI gate `make offline` does not run
- [ ] Ran against a real DGX Spark
- [ ] `make idempotence` passes (paste the second-run recap below)

```
PLAY RECAP
```

## Checklist

- [ ] Any task I added is idempotent: a second run reports `changed=0`
- [ ] Box-specific values go in `host_vars`, not `group_vars`; role-local ones are prefixed with the
      role name
- [ ] I updated the role's README if I changed a variable, a default or what the role does
- [ ] No secrets, and no mutable image tags or unchecksummed downloads
- [ ] Nothing new is destructive by default

## Anything that contradicts the docs
