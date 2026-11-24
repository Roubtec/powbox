# 081b — Make the `SHADOW_TMPFS_SIZE` override reach `shadow-mounts.sh`, or drop it

**Relates to:** task 081, whose review of the sudo-allowed helpers found this. Also `docker/shared/shadow-mounts.sh`, its two callers `docker/shared/entrypoint-core.sh` and `docker/shared/shadow-refresh.sh`, and README "Workspace Shadow Mounts → Configuration".

## Why this task exists

The README says exporting `SHADOW_TMPFS_SIZE` before launching raises the per-mount tmpfs cap, and that both callers pass `sudo --preserve-env=SHADOW_TMPFS_SIZE` so the helper sees it. Neither half holds:

- The launchers and compose files do not pass the variable into the container, so a host-side export never arrives.
- When it is set inside the container, sudo refuses the whole command (`sorry, you are not allowed to set the following environment variables`), because the grant carries no `SETENV` and no `env_keep` entry for it. An agent that exports it and runs `shadow-refresh.sh` gets no shadow mounts at all rather than bigger ones.

So today the override is inert at best and breaks mid-session shadowing at worst.

## Goal

Either the documented override works end to end, or it is removed from the callers, the helper and the README.

## Landmines

- If it is kept, the value lands in the helper's `mount -o` option string as root, so the helper must validate it as a size and nothing else (no commas), and any sudoers `env_keep` must be scoped to `shadow-mounts.sh` alone, never global. Task 079 relies on `init-firewall.sh` seeing none of the caller's environment.
- The launcher pair (`launch-agent.sh` and its `.ps1` twin) would both need the passthrough.

## Acceptance criteria

- Setting the override as documented changes the tmpfs size of a new shadow, or the override no longer exists anywhere.
- With the variable set in an agent session, `shadow-refresh.sh` still mounts its shadows.
