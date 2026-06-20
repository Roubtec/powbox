# Task 001 — Self-contained container mode (internal cloned checkout, no host bind mount)

## Goal

Add a second, opt-in launch mode ("self-hosted") in which a container fetches the repo **itself** into an internal workspace volume instead of bind-mounting a host directory.

This lets us run **many containers for the same repo at once**, each on its own private checkout — isolation stronger than git worktrees, with no host filesystem shared between containers.

The existing "dir-mounted" mode (bind-mount the host working dir, identity = `basename + SHA256(host path)`) is unchanged and remains the default for live local development where the human watches and co-edits.

## The two modes at a glance

| Aspect | Dir-mounted (today, unchanged) | Self-hosted (new) |
|---|---|---|
| Workspace source | Host bind mount at `/workspace/<slug>` | `git clone` into a per-instance volume |
| Identity discriminator | `SHA256(host path)` | `--name <label>` if given, else a timestamp |
| Multiple per repo | No (same path → same container) | Yes (each `--name`/timestamp is a new instance) |
| How work leaves | Host sees edits live | `git push` / open a PR via the container's gh auth |
| node_modules / .worktrees | Separate shadow volumes (`agent-nm-*`, `agent-wt-*`) | Plain subdirs of the one workspace volume |
| Session history isolation | Per host path | Per instance (distinct cwd slug) |

## Locked design decisions (from the planning session)

### 1. Opt-in; dir-mounted stays the default

Self-hosted is selected by a new flag (proposed `--isolated`). Without it, the launcher behaves exactly as today.
The dir-mounted identity calculation (`basename + SHA256(path)`) is **not** touched.

### 2. Identity & naming

In self-hosted mode the repo is a **required** input (the container must know what to clone) — an `owner/repo` slug or a clone URL.
As a convenience, if the flag is given with no repo while standing inside a git repo, the launcher may infer it from `git remote get-url origin`; an explicit repo is still the contract.

The **instance discriminator** is `--name <label>` if supplied, otherwise a timestamp (with enough resolution / a short random suffix to avoid same-second collisions).

Reuse the existing name shape: `PROJECT_NAME = <repo-slug>-<instance-hash>` where `instance-hash = SHA256(label-or-timestamp)[:12]`, so:
- container name = `claude-<repo-slug>-<instance-hash>` (same `${AGENT}-${PROJECT_NAME}` pattern as today)
- workspace mount = `/workspace/<repo-slug>-<instance-hash>`

**Named → deterministic → reusable** (same clone + same session history across launches; amortizes the clone cost — this is the "reuse a container longer" habit).
**Unnamed → timestamp → fresh every launch** (inherently single-session).

### 3. One workspace volume replaces three mounts

The workspace itself becomes a per-instance named volume `agent-ws-<container>` mounted at `/workspace/<slug>`, holding the clone plus `node_modules`, `.worktrees`, and the pnpm store as ordinary subdirectories.
This **drops** the separate `agent-nm-*` and `agent-wt-*` mounts for this mode (no host FS underneath means nothing to shadow).
Bonus: because the pnpm store, the worktrees, and the root `node_modules` now share **one** mount, pnpm hardlinks everywhere — including the root `node_modules`, which in dir-mounted mode falls back to copying (separate mount → `EXDEV`).

### 4. Keep git worktrees inside the bubble

Worktree-based parallelism (subagents fanning tasks into `.worktrees/<task>` via `wf-address-tasks` / the worktree-running skills) is a first-class use case and stays.
It costs nothing extra here and actually hardlinks better (decision 3). The `.worktrees` convention, the `wt-bootstrap`/`wt-enter`/`wt-remove` helpers, and `PNPM_STORE_DIR` all keep working, just rooted in the one workspace volume.

### 5. Shared auth/skills, isolated workspace (via the cwd slug)

Config volumes (`claude-config`, `codex-config`, `agent-gh-config`, `agent-zsh-history`) stay **globally shared** — no re-auth per container, skills seeded once.
Session-history isolation comes entirely from the **workspace mount path** being distinct per instance (Claude derives `~/.claude/projects/<slug>` from the cwd). It is the *path* that must vary, not merely the container name.
Podman storage (`agent-podman-<container>`) and the read-only image store remain as today.

### 6. Egress = push / PR; gh auth must be ready before the clone

The deliverable is a pushed branch / PR, since the host never sees the working tree.
The clone (and private-repo access) depends on gh credentials, so the entrypoint must establish gh auth **before** attempting the clone (today `gh auth setup-git` runs in `entrypoint-core.sh`; the clone step must come after it).

We deliberately **do not build clone/auth failsafes** — gh auth is a one-time manual setup that holds until the token expires. If gh isn't authenticated when a self-hosted launch needs to clone, **announce it loudly to the user** (clear, unmissable message) stating the three remedies and drop to a plain `zsh` rather than execing the agent into an empty workspace:
1. use normal (dir-mounted) mode instead, or
2. fix it once in this plain shell (`gh auth login`), or
3. seed the shared `agent-gh-config` volume from another machine.

No retry loop, no half-state recovery, no re-trigger plumbing — just the announcement plus a usable shell. The fix is done once and never again until the token expires.

### 7. Reuse semantics

Clone **once** on first creation. On `docker start` of an existing (named) container, leave the tree exactly as the agent left it — the agent owns its branches/worktrees. Detect an existing `.git` in the workspace and skip re-cloning.
Provide an explicit `--reclone`/`--fresh` escape hatch to wipe and re-seed.
Default checkout = the repo's default branch; allow `--ref <branch>` to start elsewhere. The agent creates its own task branch.

### 8. Lifecycle / GC

Self-hosted containers (and their `agent-ws-*` + `agent-podman-*` volumes) accumulate, especially unnamed/timestamped ones.
Do **not** auto-`--rm` by default (an ephemeral container removed before the agent pushes would lose work). Instead make teardown easy: extend the prune tooling to drop orphaned `agent-ws-*` volumes whose container is gone, alongside the existing `agent-nm-*` pruning, and surface self-hosted containers in the `*-list` helpers.

## Work items by area

### Launcher — `scripts/launch-agent.sh` + `scripts/launch-agent.ps1`

- Add `--isolated` (mode switch), repo input (positional re-interpreted as repo spec in this mode, or `--repo`), `--name <label>`, `--ref <branch>`, `--reclone`.
- Branch the identity block: dir-mounted keeps `SHA256(path)`; self-hosted computes `instance-hash = SHA256(label-or-timestamp)[:12]` and `repo-slug` from the repo spec (basename, strip `.git`, lowercase, sanitize — mirror current `PROJECT_BASENAME` handling).
- Replace the workspace bind mount with `agent-ws-<container>:/workspace/<slug>`; **omit** the `agent-nm-*` and `agent-wt-*` mounts in this mode; keep config volumes, `agent-podman-*`, and the RO image store.
- Pass the clone inputs through as env (e.g. `POWBOX_CLONE_REPO`, `POWBOX_CLONE_REF`, a mode marker) and point `PNPM_STORE_DIR` inside the workspace volume.
- Keep the existing host-gitconfig and gh-config read-only seed mounts (needed for identity + clone auth); `/ctx` stays optional.
- Keep all the existing "recreate a stopped container when a frozen attribute changed" guards coherent with the new mode (the workspace volume identity is part of the container identity now).

### Entrypoint — `docker/shared/entrypoint-core.sh` (and `entrypoint-agent.sh` if a hook fits better)

- After gh auth setup, before the shadow/pnpm steps and the final `exec "$@"`, add a guarded **seed-workspace** step: if mode = self-hosted and `/workspace/<slug>/.git` is absent (or `--reclone`), `git clone` the repo at the requested ref into the workspace; on success continue, on failure print guidance and `exec zsh`.
- **Skip** `shadow-mounts.sh` in self-hosted mode (no host FS to shadow; tmpfs would break hardlinking). Keep `safe.directory` registration and `core.filemode` handling as-is (harmless on a clone).
- Keep the `PNPM_STORE_DIR` co-location logic; it now lands inside the single workspace volume.

### Compose — `compose.shared.yml` / `compose.agent.yml`

- The workspace mount differs per mode (bind vs named volume). Decide between a small self-hosted compose overlay (mirrors the `compose.fuse.yml`/`compose.netdev.yml` pattern) or driving it entirely from launcher `-v` args. Prefer whichever keeps the frozen-attribute recreate logic simplest.

### Shell helpers — `shell/powbox.sh` (+ `.ps1`)

- Surface the new flags through `cc`/`cx` (note the positional in self-hosted mode is the repo, not a path — `_powbox_should_cd` must not try to `cd` into a repo slug).
- Extend prune (`commands/prune-volumes.*`, `agent-prune-*`) to GC orphaned `agent-ws-*` volumes.
- Make `*-list` show self-hosted containers clearly (they already match the `claude-`/`codex-` name prefixes).

### Skills / workflows

- Confirm the `.worktrees/<container>/<slug>` convention and the `wt-*` helpers work unchanged when the workspace is a volume rather than a bind mount (expected yes; verify the root-safety and orphan-prune checks).
- No skill prose should hard-code "host bind mount" assumptions.

### Docs

- New README section for self-hosted mode (when to use, egress = PR, named vs ephemeral, lifecycle/prune).
- Update `AGENTS.md` "Project Identity" / "Volumes and Stores" / "Entrypoint and Runtime" to describe the second mode and the single-workspace-volume collapse.
- Drop a line from `docs/future-plans.md` once shipped.

### Smoke tests

- Extend `scripts/smoke-test-*` to cover: clone-on-first-run, reuse-skips-clone, named reuse re-attaches the same session slug, unnamed gives a fresh slug, unauthenticated-clone announces loudly and drops to a shell, and pnpm hardlinks into both `.worktrees/<task>` and the root `node_modules`.

## Open questions / to confirm during implementation

- Exact CLI surface: `--isolated <repo>` (positional) vs `--repo <spec>` — pick one and keep `.sh`/`.ps1` identical.
- Local-only repos with no fetchable remote are unsupported in this mode (state as a known limitation).
- Whether `--reclone` should also reset the `agent-ws-*` volume or just re-clone into a cleaned dir.

## Acceptance criteria

- `cc --isolated <repo> --name foo` clones the repo into a private volume, runs the agent, and a second `--name bar` runs concurrently on an independent checkout of the same repo.
- Re-launching `--name foo` reuses the clone and the prior Claude session history; an unnamed launch gets a fresh checkout and fresh history.
- No `agent-nm-*` / `agent-wt-*` volume is created in self-hosted mode; `pnpm install` hardlinks in both a worktree and the root `node_modules`.
- An unauthenticated/failed clone loudly announces the three remedies and drops to a usable shell rather than execing the agent.
- Dir-mounted mode is byte-for-byte unchanged in behavior.
- Prune tooling removes orphaned `agent-ws-*` volumes.

## Out of scope

- Changing dir-mounted identity or its shadow-volume design.
- Bidirectional host⇄container sync (explicitly rejected — defeats the isolation goal; egress is push/PR).
- Auto-removing ephemeral containers (risk of losing unpushed work).
