# 084 — Drop the unreachable `--volatile` guards in the launchers

**Relates to:** PR #190 (`--volatile` now replaces a stopped container and refuses a running one), `scripts/launch-agent.sh`, `scripts/launch-agent.ps1`, and `scripts/test-launcher-volatile.sh`.

## Why this task exists

Since #190, a `--volatile` launch removes any stopped container of the same name, and refuses a running one, before the reuse and recreate checks run. So by the time those checks run under `--volatile`, `CONTAINER_EXISTS` / `$containerExists` is already false. The `VOLATILE != true` / `-not $Volatile` conjuncts on them can no longer change the outcome. #190 kept them to keep its diff small. They now mislead readers into thinking volatile launches take a different path through those checks, and every new creation-time check copies them.

## Goal

Both launchers express the volatile decision once, where it is made. The later checks guard only on container existence and state.

## Direction and constraints

- Behaviour must not change. `scripts/test-launcher-volatile.sh` pins the volatile outcomes under bash and `pwsh`. Let it, the other launcher suites and a diff of the launchers' user-facing messages confirm that, rather than reasoning about it case by case.
- Two conjuncts are not mere repetition and need checking before removal: the self-hosted `--reclone` removal and the final `--rm` / `--detach` / `--persist` selection both consult volatile for their own reasons.
- Keep the bash and PowerShell twins in step, in one change.
