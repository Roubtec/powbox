# 079a — Let a project opt into or narrow the machine's egress exceptions

**Depends on:** 079, because this layers per-project selection over its machine-wide `.powbox-egress`.

## Why this task exists

Task 079 applies the machine's egress exceptions to every container that machine launches. That is the right default for a single user's machines. A user who runs very different projects side by side might instead want a rule only where it is needed, for example a LAN database reachable from one project's container only.

## When it becomes actionable

When a concrete use case shows up for scoping exceptions per project. Until then, the machine-wide file is enough.

## Direction and constraints

- The machine-wide file stays the only place a rule can be **defined**. A project may only select or narrow what the machine allows, never add to it.
- Only the user-local `.powbox.local.yml` may carry the selection. A committed `.powbox.yml` must never affect egress, because `--isolated` launches arbitrary cloned repos.
- Under `--isolated` there is no host-side workspace file, so this either needs a launcher flag or stays limited to dir-mounted mode. Decide which when the task is picked up.
- The selection has to be part of what `powbox.egress-hash` covers, so a changed selection recreates the container the way a changed rule does.
