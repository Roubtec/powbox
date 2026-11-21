# 081a — Close the path-swap races in `shadow-mounts.sh`

**Relates to:** task 081 (the narrowed `apt-get` grant), which closed the one-command route to root and left these races as the known remaining route through a sudo-allowed helper. Also `docker/shared/shadow-mounts.sh`, its hermetic suite `scripts/test-shadow-mounts-chown.sh`, and the Stage 6 smoke (`scripts/smoke-test-worktree-metadata.sh`).

## Why this task exists

`node` may run `sudo shadow-mounts.sh <path>` at any time with any path. The helper validates each target with `realpath` and a `/workspace/` containment check, then uses the same path string for `mkdir -p`, the ownership `chown -h` of the components it created, and the tmpfs or durable `.git/worktrees` bind `mount`. Every component of that path below `/workspace/<slug>` is node-writable, so between the check and each later step `node` can swap a component it owns (or a component that does not exist yet) for a symlink:

- the `mount` then lands outside `/workspace`, for example a node-owned tmpfs over `/usr/local/bin`, after which `sudo init-firewall.sh` runs whatever `node` put there;
- the `chown -h` follows a swapped intermediate component and re-owns a file outside the tree to the checkout's owner;
- `mkdir -p` creates root-owned directories wherever the symlink points.

Before task 081 these were accepted because `sudo apt-get -o …` already gave root in one command. The re-validation added for the chown narrows its window, but no path check can close a race against a path the attacker controls. Winning any of them takes a deliberately written loop, so the firewall's accident-guard model tolerates them for now; they are still the cheapest remaining way past it.

## Goal

A swapped component can no longer redirect the helper's `mkdir`, `chown` or `mount` outside the validated workspace, while every legitimate shadow (nested `node_modules`, `bin`/`obj`, `.powbox.yml` literals, `.worktrees`, the durable `.git/worktrees` bind) behaves exactly as today, created-mountpoint ownership included.

## Context and landmines

- The fix has to act relative to directories the helper already holds, not re-check paths: resolve and enter each component without following symlinks, then create, chown and mount relative to that, and keep util-linux `mount` from canonicalizing the target back into an absolute path.
- The durable `.git/worktrees` bind has a source path inside the node-writable `.worktrees` volume as well as a target, so both ends need the same treatment.
- Created mountpoints must still inherit the deepest existing ancestor's owner before the mount goes on, and a failed chown must stay non-fatal with one warning per run (Windows/FUSE bind mounts).
- `scripts/test-shadow-mounts-chown.sh` asserts the emitted chown/mount sequence through PATH shims, so a change of call shape changes what it must assert; keep it able to tell a relocated mount from a correct one.
- A hermetic test of the race itself is worth having: a target whose component becomes a symlink between validation and use must end with nothing mounted or chowned outside the workspace root.

## Acceptance criteria

- No interleaving of symlink swaps under `/workspace/<slug>` makes the helper mount, chown or create anything outside `/workspace`.
- `scripts/test-shadow-mounts-chown.sh` and the Stage 6 ownership assertions still pass, and the hermetic suite covers a swapped component.
- The race paragraph in `docs/entrypoint-and-runtime.md` and the matching comment in `shadow-mounts.sh` describe the closed state.
