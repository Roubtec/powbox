# Task 011 — Persist Go caches across container recreation; scope the golangci-lint cache per worktree

Follow-up to PR #75 (bake Go toolchain + golangci-lint into the base image). Parked in `tasks/deferred/` because it builds on that PR's layer; move to `tasks/` once #75 merges.

Source: agent session learnings 2026-07-02 ("Agent Session Learnings - 2026-07-02 00:21 UTC", a Claude retrospective from a long-running kalm2 session in a powbox container). The relevant findings are restated in full below so this task stands alone.

## Background — what PR #75 ships and what it doesn't

PR #75 bakes `go` 1.26.4 (sha256-pinned, `/usr/local/go`) and `golangci-lint` v2.12.2 (sha256-pinned tarball, `/usr/local/bin`) into the base image, with `GOTOOLCHAIN=auto` and `~/go/bin` on `PATH`. That covers the toolchain itself. It deliberately does **not** touch cache handling, which the session learnings flag as the remaining ergonomics/correctness gap for real Go work:

1. **Go caches are container-ephemeral.** `GOMODCACHE` (default `~/go/pkg/mod`) and `GOCACHE` (default `~/.cache/go-build`) live in the container filesystem — no volume covers `/home/node/go` or `/home/node/.cache` (see `compose.shared.yml` volumes and the per-agent `agent-nm-*`/`agent-wt-*` volumes in `scripts/launch-agent.sh`). Every container recreation (image update, relaunch) cold-downloads all modules and rebuilds everything. The learnings doc: "Persist/pre-warm `GOMODCACHE` (`~/go/pkg/mod`) + `GOCACHE` (`~/.cache/go-build`) as a volume (as `node_modules` already is) so `go build`/`go test ./...` don't cold-download each session."
2. **golangci-lint's analysis cache bleeds across parallel worktrees.** Its cache (default `~/.cache/golangci-lint`) is shared per-home, and parallel `address-tasks`/`address-reviews` runs in sibling worktrees can surface phantom findings from a sibling's tree state (a standing observation from kalm2 sessions; CI avoids it by keying the cache on `go.sum` + `.golangci.yml`). The learnings doc: "Scope the golangci-lint + go-build caches per worktree (or ship a wrapper) so parallel Go runs don't show phantom sibling findings."

## The nuance — share the safe caches, isolate the unsafe one

These two pulls go opposite directions, and the split is:

- `GOMODCACHE` is content-addressed with its own locking, and `GOCACHE` is designed for concurrent builds — both are **safe and desirable to share** across worktrees of the same project (warm cache = the whole point).
- The **golangci-lint analysis cache** is the one with observed cross-worktree bleed — it should be **per-worktree** (`GOLANGCI_LINT_CACHE` env, which golangci-lint honors).

## Suggested approach

- **Persistence:** co-locate the Go caches inside the existing per-agent `.worktrees` volume rather than adding new volumes — the exact precedent is the pnpm store at `.worktrees/.pnpm-store` (`scripts/launch-agent.sh:430`, `WT_STORE_DIR`), which was placed there so worktree installs hardlink from the same mount. E.g. `GOMODCACHE=<workspace>/.worktrees/.gomodcache`, `GOCACHE=<workspace>/.worktrees/.gocache`, exported by the entrypoint/profile the same way the pnpm store dir is wired. This honors the maintainer preference for reusing existing native volumes over adding new ones, and keeps the caches per-agent + per-project (no cross-agent clobber, consistent with the per-agent volume split).
- **Self-hosted mode:** the single `agent-ws-*` workspace volume already persists everything under the workspace — but the Go defaults (`~/go`, `~/.cache`) are *outside* it, so the same env override is what makes self-hosted persistence work too. Same setting covers both modes.
- **Lint-cache scoping:** set `GOLANGCI_LINT_CACHE` per worktree — `wt-bootstrap`/`wt-enter` are the natural owners (they already own per-worktree conventions), e.g. `<worktree>/.golangci-cache` (gitignored) or a per-worktree subdir under the `.worktrees` volume. Decide whether the repo-root (non-worktree) checkout also gets a scoped cache for symmetry.
- **Dir-mounted non-dev folders:** the entrypoint/launcher must not mkdir cache dirs in folders that get no `.worktrees` mount (same litter concern the pnpm store wiring already handles — `scripts/launch-agent.sh:962`).
- Do **not** bake `java` alongside (explicitly rejected in the learnings doc: no Avro/jar tooling referenced by the observed Go projects; confirm a concrete need first).

## Acceptance

- `go build ./...` in a Go repo, then recreate the container (relaunch after an image rebuild): the second build does not re-download modules (`GOMODCACHE` survived) and gets build-cache hits (`GOCACHE` survived).
- Two parallel worktrees of the same repo running `golangci-lint run` do not see findings caused by the sibling's tree state (distinct `GOLANGCI_LINT_CACHE` paths, verified via `golangci-lint cache status`).
- Launching in a non-dev dir-mounted folder leaves no new cache-dir litter in the host folder.
- Self-hosted (`--isolated`) mode: caches land inside the workspace volume and survive container recreation there too.
- `.sh`/`.ps1` parity where launcher/profile code is touched; shellcheck + PSScriptAnalyzer clean; container docs (`docker/shared/container-agent.md.tmpl`, `docs/architecture.md` "Bundled Go toolchain") updated to state the cache locations.
