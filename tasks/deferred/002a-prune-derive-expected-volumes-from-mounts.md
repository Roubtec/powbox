# Task 002a — Derive prune's expected nm/wt volumes from actual container mounts

Generic follow-up from the PR #59 review (per-agent volume isolation). Parked in `tasks/deferred/` because the current prune behavior is **fail-safe** (it over-protects, never over-deletes) and the proper fix expands `prune-volumes.{sh,ps1}` in both languages plus re-validation, while the branch is defendable as-is.

Review threads:
- https://github.com/Roubtec/powbox/pull/59#discussion_r3437981137 (codex, P3) — over-protection.
- https://github.com/Roubtec/powbox/pull/59#discussion_r3439823388 (codex, P3) — under-protection of legacy mounts (re-raised on the follow-up review round; same mount-derivation fix resolves both).

## Background — the gap

`prune-volumes.sh` / `prune-volumes.ps1` build the "expected" (protected) volume set by **name construction**: for every existing `claude-*`/`codex-*` container it adds `agent-{nm,wt,ws,podman}-<container-name>` unconditionally, purely because the container exists (`commands/prune-volumes.sh:65-78`, `commands/prune-volumes.ps1:31-54`).

That is correct for a normal dir-mounted JS/powbox container (which really does mount `agent-nm-*`/`agent-wt-*`), but it over-expects for containers that do **not** mount those volumes:

- a **dir-mounted** folder relaunched after it lost its `package.json`/`pnpm-workspace.yaml`/ `.powbox.yml` — `MOUNT_WORKSPACE_VOLUMES=false`, so the launcher mounts no `nm`/`wt`; and
- a **self-hosted** (`--isolated`) container — its data lives in `agent-ws-<name>`, not `nm`/`wt`.

For such a container, any *leftover* `agent-nm-<name>`/`agent-wt-<name>` volume (e.g. from a prior launch when the folder still had a `package.json`) is marked "expected" and therefore **never listed as an orphan**, even though Docker could remove it and the current launcher would not mount it. Net effect: a slice of stale disk usage that prune silently misses.

The **inverse** gap exists too, for containers created **before the per-agent volume rename** (when nm/wt were keyed per *project*): their actual mounts are still `agent-nm-<project>` / `agent-wt-<project>`, but the name-constructed expected set now only protects the new `agent-{nm,wt}-<container>` names. So prune marks those genuinely-mounted legacy volumes as orphan candidates: `--dry-run`/`-WhatIf` reports them (a misleading preview), and a confirmed run tries to remove them and Docker refuses ("volume in use") — harmless but noisy. This bites hardest for a *running* pre-rename container, which the launcher only warns about and cannot migrate; a *stopped* one is recreated (migrated) on its next launch by the name-comparison guard, but until then prune still mislists its legacy mounts.

Both directions are the conservative failure mode (prune never removes a volume that is in use, and Docker is the backstop), which is why this is P3 and deferrable — but the first undercounts reclaimable space and the second produces inaccurate previews / failed-then-skipped removals.

## Goal

Make prune's expected set reflect what containers **actually mount** (or were created to mount), so leftover `nm`/`wt` volumes for non-mounting containers are correctly reported as orphans, without ever marking a genuinely-mounted volume as removable.

## Suggested approach (pick one)

**A. Derive expected from real mounts (preferred).** For each existing `claude-*`/`codex-*` container, `docker inspect` its mounts and add the actual mounted volume **names** matching `agent-(nm|wt|ws|podman)-*` to the expected set, instead of constructing the four names from the container name. A container that mounts no `nm`/`wt` then protects none, so leftovers become orphans.
- Mind the `POWBOX_PRUNE_REMOVED_CONTAINERS` interaction: containers `agent-prune` is removing this run are already gone from `docker ps -a` (real run) — they can't be inspected, which is fine (their volumes *should* become orphans), but the `--dry-run`/`-WhatIf` preview passes their names in that env var and must still treat them as removed (today it skips them by name; a mount-derived version has nothing to inspect for them, so keep skipping by name).
- Keep `agent-podman-imagestore` always-expected (shared infra), as today.
- Mirror the change in **both** `prune-volumes.sh` and `prune-volumes.ps1`, and re-run the Step 6 "prune keying" smoke check (old project-keyed volumes listed as orphans; running containers' per-agent volumes not listed).

**B. Creation-time label (narrower).** Stamp the launcher-created volumes (or the container) with a label recording which workspace volumes it owns, and have prune read that label. More moving parts than A and only helps containers created after the label ships, so A is preferred.

## Acceptance

- A dir-mounted container relaunched without `package.json` (no `nm`/`wt` mounts) leaves any leftover `agent-nm-<name>`/`agent-wt-<name>` listed as orphans by `--dry-run`/`-WhatIf`.
- A normal dir-mounted JS container's mounted `nm`/`wt` volumes are still protected (not listed).
- A pre-rename container still mounting `agent-nm-<project>`/`agent-wt-<project>` has those legacy volumes **protected** (not listed by `--dry-run`/`-WhatIf`) while it exists, since it actually mounts them — eliminating the misleading preview / failed-removal noise.
- A self-hosted container protects only its `agent-ws-*`/`agent-podman-*`, not phantom `nm`/`wt`.
- `agent-prune`'s removed-container preview still reports the to-be-removed containers' volumes as orphans (no regression in the `POWBOX_PRUNE_REMOVED_CONTAINERS` path).
- Behavior identical in `prune-volumes.sh` and `prune-volumes.ps1`.
