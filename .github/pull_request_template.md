## What this changes

<!-- The failure mode you are fixing or preventing, not just the diff. -->

## How it was verified

<!-- Delete what does not apply. CI runs `make offline`; say what you ran beyond it. -->

- [ ] `make offline` passes locally
- [ ] Ran against a real DGX Spark
- [ ] `make idempotence` passes (paste the second-run recap below)

```
PLAY RECAP
```

## Checklist

- [ ] Any task I added is idempotent: a second run reports `changed=0`
- [ ] Box-specific values go in `host_vars`, not `group_vars`; role-local ones are prefixed with the
      role name
- [ ] I updated the role's README if I changed what the role does
- [ ] No secrets, and no mutable image tags or unchecksummed downloads
- [ ] Nothing new is destructive by default

## Anything that contradicts the docs

<!-- Most of this repo was measured on one box on one day. If your machine disagrees with what a
     doc claims, say so here. That is a feature of the report, not a digression. -->
