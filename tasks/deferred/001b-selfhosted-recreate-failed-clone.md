# Task 001b — Recreate a self-hosted container whose first clone never succeeded (so a corrected --ref/--repo re-applies)

Follow-up to **Task 001** (self-hosted `--isolated` mode, PR #54). Parked in `tasks/deferred/` because the branch is defendable as-is, a manual recovery path already exists (`--reclone`), and the proper fix is a new cross-launcher mechanism (volume introspection) plus a deliberate retry-philosophy decision — too much to fold into a review-fix commit.

## Background — the trap

The self-hosted clone inputs are **frozen into the container's environment at creation** and the reuse path simply `docker start`s the existing stopped container:

- `scripts/launch-agent.sh:823-828` (and `scripts/launch-agent.ps1` equivalent) bake `POWBOX_CLONE_REPO` / `POWBOX_CLONE_REF` / `POWBOX_WORKSPACE_DIR` as `-e` env vars at `docker create`/`run` time.
- The reuse block (`scripts/launch-agent.sh:652-665`) `exec docker start`s a stopped named container in place — it never re-runs the prep/create flow, so those env vars are immutable for the container's life.

Net effect: a self-hosted instance whose **first clone failed because of a bad `--ref`** (e.g. a typo'd branch) cannot be fixed by relaunching the same `--name` with a corrected `--ref`. The old `POWBOX_CLONE_REF` is reused on `docker start`, `seed-workspace.sh` runs again with the stale ref, and it fails again — until the user knows to force a recreate. The same applies to a corrected `--repo`.

This is **P3**: the failure is loud (`seed-workspace.sh` prints the "POWBOX SELF-HOSTED CLONE FAILED" announcement and drops to a plain zsh), and it only bites a first-launch input mistake.

Review thread: https://github.com/Roubtec/powbox/pull/54#discussion_r3408901649 (codex, P3).

## Recovery path that already exists (why deferral is safe)

`--reclone` / `-Reclone` already recovers from this today: it removes the stopped container (`scripts/launch-agent.sh:480-492`), so the create flow re-runs and **freezes the corrected `POWBOX_CLONE_REF`**, then empties the volume and the entrypoint clones fresh. The gap is purely UX — the user must *know* to add `--reclone` (or `docker rm` the container) rather than just re-passing a corrected `--ref`.

## Goal

Make a corrected first-clone input apply automatically: when a **stopped** self-hosted container's workspace holds **no checkout** (the clone never succeeded), recreate it so the (possibly corrected) clone inputs re-run — without ever wiping a real checkout.

## Suggested approach (preferred: no-checkout probe; rejected: blind input-compare)

**Preferred — recreate a stopped self-hosted container that has no `.git`.**
- Extend the existing recreate-on-mismatch guard sequence (`scripts/launch-agent.sh:495-650`, the `/ctx`, `--continue`, `.worktrees`, podman-storage, and podman-device guards) with one more guard, gated on `ISOLATED == true && VOLATILE != true && CONTAINER_EXISTS == true && CONTAINER_RUNNING != true`.
- Probe the `agent-ws-*` volume for a checkout. The volume's host mountpoint is **not** portably reachable from the launcher (Docker Desktop / WSL2 / rootless Podman keep it inside a VM), so use a throwaway container — e.g. `docker run --rm -v "${WS_VOLUME}:/mnt/ws" --entrypoint /bin/sh "$IMAGE" -c '[ -e /mnt/ws/.git ]'` — and recreate (`docker rm` + `CONTAINER_EXISTS=false`) when `.git` is absent.
- **Subtlety — check `.git`, never emptiness.** The prep step seeds a fresh volume with a `.powbox-ws-init` placeholder (`scripts/launch-agent.sh:754`), and a failed clone can leave a partial tree, so the volume is frequently non-empty without a usable checkout. The probe must test specifically for `$WS/.git` (mirroring `seed-workspace.sh:123`), not `ls -A`.
- **Why not blind input-compare (`powbox.clone-ref` label vs requested `--ref`):** a successful checkout would then be wiped whenever the user re-passes a different `--ref` on reuse — violating the core invariant that *a reused container never re-wipes the agent's work* (`scripts/launch-agent.sh:818-821`). The no-checkout probe is wipe-safe by construction: a real checkout has a `.git`, so it is never touched regardless of input changes. Record-and-compare may still be layered on top later, but only ever gated behind the no-checkout condition.
- **Retry-philosophy decision to confirm with the maintainer.** `seed-workspace.sh:26-30` states there is "no clone/auth failsafe and no retry **by design**". Auto-recreating on no-checkout means a relaunch re-attempts a failed clone (desirable when the user fixed gh auth or the ref in between; a no-op cost when they didn't). Confirm this launcher-driven, user-initiated retry is acceptable — it is distinct from the in-container automatic retry the design rules out.

## Acceptance

- A self-hosted `--name foo --ref does-not-exist` whose first clone fails, then relaunched as `--name foo --ref <valid>` (no `--reclone`), recreates the container and clones the valid ref — no manual `--reclone`/`docker rm` needed.
- A self-hosted instance with a **real checkout** is **never** recreated/wiped by this guard, even when `--ref`/`--repo` differ on reuse (the existing `--reclone` remains the only wipe path).
- A currently-**running** self-hosted container is not disrupted (warn, don't recreate), matching the running-container handling of the sibling guards.
- `.sh` / `.ps1` parity preserved; the self-hosted smoke matrix (`scripts/smoke-test-selfhosted.{sh,ps1}`) gains a case covering the failed-first-clone → corrected-relaunch flow; lint clean (shellcheck + PSScriptAnalyzer).
