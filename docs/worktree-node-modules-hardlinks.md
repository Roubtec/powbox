# Worktree `node_modules`: from copy to hardlink

Status: **implemented (Option A)** — shipped on branch `worktree-hardlinks` (PR #37);
design derived from item 1 of the orchestration-session retrospective. Verified in a
freshly built container on 2026-06-06: a worktree `pnpm install` hardlinks from the
co-located store (see *Validation* below).
Date: 2026-06-04 (design) · 2026-06-06 (implemented & verified in-container).

## TL;DR

Parallel worktrees are slow and concurrency-capped because every worktree's
`pnpm install` does a **full copy** of `node_modules` (~425 MB for a minimal
app, ~1.1 GB for a Next.js app) into a 2 GB tmpfs, instead of near-free
hardlinks from the pnpm store. The retrospective blamed "store on a different
filesystem from the tmpfs worktrees", but the real constraint is stricter and
was confirmed empirically in-container:

- **pnpm can only hardlink when the store and the target `node_modules` live
  under the *same mount*** — not merely the same device.
- The image also forces `package-import-method=copy`, so pnpm never even tries.

The fix, in any container model, is the same single principle:

> **Put the pnpm store and the `node_modules` that should hardlink from it under
> one mount, and stop forcing `copy`.**

## Evidence (measured in the powbox container, 2026-06-04)

```
# root node_modules and the pnpm store are BOTH on /dev/sde (ext4), same device id 2112:
$ stat -c '%d %n' /home/node/.local/share/pnpm/store /workspace/<proj>/node_modules
2112 /home/node/.local/share/pnpm/store
2112 /workspace/<proj>/node_modules

# yet a hardlink between them fails — they are separate bind mounts:
$ ln <store>/file <node_modules>/file
ln: failed to create hard link ...: Invalid cross-device link   # EXDEV

# package import method is hardcoded to copy:
$ pnpm config get package-import-method
copy                                  # set in docker/base/Dockerfile
```

`link(2)` returns `EXDEV` whenever source and target are on different
*mount points*, even when the underlying filesystem (`st_dev`) is identical.
Two subdirectories of the **same** Docker volume, if bind-mounted to two
places, are also two mounts → also `EXDEV`. So "same volume" is not enough;
"same mount" is the requirement. (Verified: a hardlink between two paths under
one directory on one mount succeeds and bumps the link count to 2.)

## Why the current design copies everywhere (and why that was rational)

| Thing | Backing | Mount | Persisted? | Install cost |
|---|---|---|---|---|
| pnpm store | `agent-pnpm-store` volume (ext4) | mount A | yes (shared, cross-project) | — |
| root `node_modules` | `agent-nm-<proj>` volume (ext4) | mount B | yes (per-project) | **copy** from store, once |
| subpackage `node_modules` | tmpfs | mount C… | no | **copy**, every session |
| worktree `node_modules` | tmpfs under `.worktrees` | mount D | no | **copy**, every worktree, every time |

Because store ≠ any `node_modules` mount, *every* install copies. The
persistent volumes are exactly what makes that tolerable: copy once, reuse.
The worktrees are the pain precisely because they can't persist (tmpfs) and are
RAM-capped — so they pay the full copy repeatedly and hit `ENOSPC` under
concurrency. The retrospective measured this forcing waves to run partly or
fully sequentially.

The persistent **store** is still doing real work even with `copy`: it avoids
re-downloading and re-extracting package tarballs. Only the *materialized*
`node_modules` copies are wasteful — and that waste vanishes once hardlinks
work, which is why "persisting node_modules can subside in favor of hardlinks"
is the right instinct.

## The governing principle

For near-free worktree installs, the worktree `node_modules` and the pnpm store
must be **under one mount**, and `package-import-method` must allow hardlinking
(`auto` — try clone (reflink), then hardlink, then copy; on ext4 clone is
unavailable so it lands on hardlink when same-mount, copy otherwise).

Resource note: the Docker VM's ext4 (`/dev/sde`) had **911 GB free**; RAM is the
scarce resource (the 2 GB tmpfs cap is what actually hurts). Moving worktrees
from RAM (tmpfs) to disk (a persistent ext4 volume) is therefore strictly better
for the concurrency/`ENOSPC` problem, and a Docker volume is just as
container-local and host-invisible as tmpfs (the root `node_modules` already
works this way).

## Option A — bind-mount model (incremental, ships today)

Keep today's host-bind-mount workflow; only change where worktrees + the store live.

1. **New per-project volume** `agent-wt-<proj>` mounted at
   `/workspace/<proj>/.worktrees` (ext4, persistent, container-local, shared
   between the Claude and Codex containers for the same project — volume names
   are project-keyed, not agent-keyed, exactly like `agent-nm-<proj>`).
2. **Relocate the pnpm store into that volume**:
   `store-dir = /workspace/<proj>/.worktrees/.pnpm-store`. Because the store and
   every `.worktrees/<task>/node_modules` are now under the one `.worktrees`
   mount, pnpm hardlinks. Set per-project at startup (the path depends on the
   project), e.g. the launcher passes `PNPM_STORE_DIR` and the entrypoint runs
   `pnpm config --global set store-dir "$PNPM_STORE_DIR"` (guarded, never fatal).
3. **Stop forcing copy**: set `package-import-method=auto` (Dockerfile).
4. **Retire the shared `agent-pnpm-store` volume.** The store is now per-project
   inside `agent-wt-<proj>`. Trade-off: we lose cross-*project* store dedup
   (a brand-new project re-downloads its deps) in exchange for hardlinks; disk
   is abundant and each project's store still persists across its own sessions,
   so the "repeated sessions don't re-copy" win is preserved per project.
5. **`.worktrees` tmpfs shadow becomes a no-op fallback.** When the volume is
   mounted at `.worktrees`, `shadow-mounts.sh` skips it (already a mountpoint),
   so existing project `.powbox.yml` files that list `.worktrees` keep working
   unchanged. `.claude/worktrees` and `.git/worktrees` stay tmpfs-shadowed.

### Result
- Worktree `pnpm install` → hardlink (~tens of MB of metadata) instead of
  425 MB–1.1 GB copies.
- Concurrency becomes disk-bound (effectively unlimited for normal use); the
  2 GB / `ENOSPC` cliff for worktrees is gone.
- Store persists per project; root install still copies once (separate mount) —
  fine, it is a one-time, persisted cost on the main checkout.

### Sub-decision: worktree metadata coherence (`A-simple`, recommended)
`node_modules` lives **inside** each worktree dir, so the worktrees must be on
the volume (not tmpfs) for the hardlink. That makes worktree *working dirs*
persistent, while `.git/worktrees` *metadata* stays tmpfs (ephemeral). After a
container recycle, stale `.worktrees/<owner>/<task>` dirs can be left behind
(their `.git` pointer dangles) while the valuable `.pnpm-store` persists.
Mitigation: a bootstrap cleanup step removes orphaned worktree dirs (those under
this container's own subdir that `git worktree list` doesn't know about) at
session start. This keeps the skill's "worktrees are disposable, commit + push"
model intact.

**Peer-container isolation.** The `.worktrees` volume is *project-keyed*
(`agent-wt-<proj>`), so the project's Claude and Codex containers mount the same
volume — but each keeps its own tmpfs `.git/worktrees` metadata. A peer's live
worktree therefore has no metadata in the other container and is
indistinguishable from a crash orphan, so a naive "prune everything `git
worktree list` doesn't know" would `rm -rf` the peer's active working dir and its
uncommitted work. Fix: each container namespaces its worktrees under
`.worktrees/$CONTAINER_NAME/` (`$CONTAINER_NAME` = `<agent>-<project>`, which
Docker keeps unique and which is stable across recycle) and scopes both creation
and the orphan prune to that subdir. Ownership — not liveness — is what makes
this safe: a container only ever reaps orphans it owns, so no cross-container
liveness check or lockfile is needed, and a peer's subdir is never scanned. The
shared `.pnpm-store` stays at the volume root.

*Alternative `A-coherent`*: also persist `.git/worktrees` (and
`.claude/worktrees`) on volumes so worktrees fully survive recycle. More volumes
and a real `git worktree prune` discipline; rejected for now because it fights
the "disposable worktree" model.

### Files Option A touches
`scripts/launch-agent.sh` + `scripts/launch-agent.ps1` (new volume + store env),
`compose.shared.yml` (drop `pnpm-store`), `docker/base/Dockerfile`
(`package-import-method=auto`), `docker/shared/entrypoint-core.sh` (set per-project
store-dir), `commands/prune-volumes.{sh,ps1}` (prune `agent-wt-*`), README +
the worktrees/enable-worktrees skills (tmpfs-sizing / `ENOSPC` guidance is
superseded), plus a smoke-test assertion that a worktree install hardlinks.

## Reconciliation with the self-contained "repo-in-container" direction

`docs/worktree-support.md` (branch `self-checkout`) proposes a parallel workflow
that **clones the repo onto a container-side volume** instead of bind-mounting
it from the host. In that world, `.git`, the worktrees, `node_modules`, and the
store can all live on **one Linux filesystem** — so:

- The "one mount" requirement is satisfied trivially; hardlinks work for the
  root checkout *and* worktrees.
- The host-clutter caveat (a gitignored `.worktrees` mountpoint dir appearing on
  the host bind mount) disappears.
- The cross-OS absolute-path worktree problem disappears (the whole reason that
  doc exists).

So self-checkout is the **more complete** home for this fix. The same two
levers apply there: `package-import-method=auto`, and a store-dir that sits on
the repo volume. Option A is the bind-mount-mode version of the identical
principle.

### Sequencing options
- **A-now:** ship Option A for bind-mount mode (which `self-checkout` keeps as a
  parallel mode), then apply the same store-dir + `auto` levers inside the
  repo-in-container volume when that lands. Two small wirings, both shipping the
  same principle.
- **Fold-into-self-checkout:** don't touch bind-mount mode; do the hardlink fix
  only as part of the repo-in-container volume. Cleaner/one place, but the
  bind-mount worktree-copy pain persists until self-checkout ships.
- **Common-lever-now:** land only the cross-cutting, low-risk pieces now
  (`package-import-method=auto`; treat store-dir as a single knob), and let each
  mode point it at its single-mount location. No behavior change until a mode
  unifies the mounts, but it removes the hardcoded `copy` and centralizes the knob.

## Validation

Building/launching needs a Docker daemon (host-side), but once a container is up with
the new wiring, the hardlink assertion runs **in-container** (no daemon needed).

On the host, rebuild the image so the Dockerfile/entrypoint changes take effect, then
relaunch the agent (the launcher recreates a stopped pre-change container so the new
`.worktrees` volume + `PNPM_STORE_DIR` apply):

```bash
./build.sh   # or build.ps1
```

Inside the resulting container — against any pnpm project, or a throwaway dir under
`.worktrees` if the repo isn't a node project — create a worktree, install, and assert:

```bash
git -C /workspace/<proj> worktree add .worktrees/hltest -b hltest
cd /workspace/<proj>/.worktrees/hltest && pnpm install
# a hardlinked store file has link count >= 2:
f=$(find node_modules/.pnpm -type f -name '*.js' | head -1)
stat -c '%h %n' "$f"          # expect link count >= 2
findmnt -no TARGET,FSTYPE -T node_modules   # expect the .worktrees volume, not tmpfs
du -sh node_modules           # expect tens of MB unique, not the full copy
```

### Results (freshly built image, 2026-06-06, in `claude-powbox-…`)

Confirmed in-container. The runtime wiring landed as designed:

- `PNPM_STORE_DIR=…/.worktrees/.pnpm-store`, `pnpm config get store-dir` matches, and
  `package-import-method=auto`; `.worktrees` is the `agent-wt-<proj>` ext4 volume
  (919 GB free), **not** a 2 GB tmpfs.
- A worktree install **hardlinks**: the installed file and its store entry share one
  inode (`stat` link count = 2), and `node_modules` lands on the `.worktrees` volume.
- Three worktrees installing the same deps concurrently all share the store inode
  (link count = 4 = store + 3 worktrees); total real disk for 3 worktrees + store was
  ~store size (~7 MB), i.e. N worktrees ≈ the cost of one. The old per-worktree
  425 MB–1.1 GB tmpfs copy — and its `ENOSPC`/concurrency cliff — is gone.

## Out of scope here
Docker daemon (retrospective items 2 and 5) is tracked on branch `docker-for-agents`. The
session retrospective's other items were either already satisfied
(commit/push-every-milestone discipline), intentional (`sudo` scope), upstream
(harness transport), or folded into skill tweaks (subagent task-tracker bleed;
orchestrator integration-merge blessing).
