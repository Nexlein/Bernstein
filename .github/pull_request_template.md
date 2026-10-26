Closes #

## What

<!-- What changes, and why. One line per file or concern. -->

## Verified

<!-- Commands run and their results. Say what was NOT verified. -->

## Checklist

- [ ] Linked to its issue (`Closes #N`), with the issue's "Done when" criteria met
- [ ] Tested where it matters: `kubectl kustomize k8s/`, and on AKS for anything that changes the cluster (cluster stopped afterwards)
- [ ] Decision recorded or updated in an ADR (`doc/adr/`, from `0000-template.md`, indexed in its README) if a choice was made
- [ ] `doc/defense/k8s-study-guide.md` updated if a manifest line, an object or a measured behaviour changed
- [ ] No secret, password or cloud credential committed
- [ ] `npm run format:check` passes; conventional commit title for the squash merge
