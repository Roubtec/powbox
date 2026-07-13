# Bake ccache with a Persistent Cache Directory in the Worktrees Volume

## Why this task exists

The kalm2 task-107 assessment that motivated task `019` flagged `ccache` as "add only if the image also configures a persistent cache directory; otherwise the benefit across sessions is limited". Powbox is exactly the environment that can satisfy that condition: the per-project `.worktrees` volume already hosts the persistent Go caches (`GOMODCACHE`/`GOCACHE` — see `docs/architecture.md` "Volumes and Stores" and task `tasks/done/011-go-cache-persistence-and-worktree-scoping.md`), and a compiler cache is the same shape of asset — content-addressed, lock-safe under concurrency, and deliberately **shared across a project's worktrees** so every worktree benefits from warm objects.

Repeated large native builds (the open62541/OpenSSL class of vendored C dependency, rebuilt per worktree and per container recreation) are where this pays off; without the persistent dir, ccache's default `~/.cache/ccache` dies with the container.

## Scope

- Add the `ccache` Debian package to the base image, in (or adjacent to) the native-build apt layer introduced by task `019`.
- Point `CCACHE_DIR` at `.worktrees/.ccache` under the workspace mount, following the `GOMODCACHE`/`GOCACHE` wiring exactly.
- Keep ccache **opt-in per build**: baking the binary and the persistent dir, but NOT force-routing every compile through it (no global masquerade-dir `PATH` prepend, no global `CC`/`CXX` export). Projects activate it with `CC="ccache gcc" CXX="ccache g++"` (or `cmake -DCMAKE_C_COMPILER_LAUNCHER=ccache`), documented in the template. Rationale: silently interposing a cache into every build in the image would surprise reproducibility-sensitive pinned builds and differs from how every other baked cache here behaves (Go/pnpm caches are consulted by the tool itself, not injected).

Out of scope: distcc/sccache, per-worktree cache scoping (sharing is the point — ccache locks correctly under concurrent use, like `GOMODCACHE`), and any change to the worktrees-volume mount gates themselves.

## Context and references

- Depends on task `019` (same Dockerfile region; land it first or together).
- `scripts/launch-agent.sh` — `WT_GOMODCACHE_DIR`/`WT_GOCACHE_DIR` are defined near the other workspace-mount paths and exported gated on `[ "$ISOLATED" = true ] || [ "$MOUNT_WORKTREES_VOLUME" = true ]`. That gate is what keeps the entrypoint from mkdir-ing cache dirs **onto a host bind mount** for a non-dev dir-mounted folder — `CCACHE_DIR` must sit behind the same gate. Mirror in `scripts/launch-agent.ps1`.
- `docker/shared/entrypoint-core.sh` — the guarded warn-don't-abort `mkdir` loop over `GOMODCACHE GOCACHE`; add `CCACHE_DIR` to that list.
- A C/CMake-only project with no `package.json`/`go.mod` does not mount the worktrees volume at all, so it gets no `CCACHE_DIR` and ccache falls back to its container-lifetime default — acceptable, and worth one sentence in the docs.

## Target files or areas

- `docker/base/Dockerfile` — the `ccache` package.
- `scripts/launch-agent.sh` and `scripts/launch-agent.ps1` — `WT_CCACHE_DIR="${WORKSPACE_MOUNT}/.worktrees/.ccache"` + gated `-e CCACHE_DIR=...` (extend the existing Go-cache block and its comment rather than adding a parallel one).
- `docker/shared/entrypoint-core.sh` — extend the cache-dir pre-create loop.
- `docker/shared/container-agent.md.tmpl` — Build row: ccache is baked, cache persists in `.worktrees/.ccache`, activate via `CC="ccache gcc"`/`CMAKE_C_COMPILER_LAUNCHER=ccache`; extend the `.worktrees` filesystem-table row.
- `AGENTS.md` Key Paths `.worktrees` row and `docs/architecture.md` "Volumes and Stores" — add `.ccache` beside the pnpm store and Go caches.
- `commands/smoke-test.sh` / `commands/smoke-test.ps1` — probes: `ccache --version`, and `CCACHE_DIR=/tmp/powbox-ccache-probe ccache --show-config | grep -q /tmp/powbox-ccache-probe` (env honored), plus a functional hit check: compile a trivial `.c` twice via `ccache gcc` with a fresh `CCACHE_DIR` and assert `ccache -s` reports a cache hit.

## Implementation notes

- `.sh`/`.ps1` parity on both the launcher and the smoke driver is a review gate in this repo.
- Update the volume-content docs everywhere the Go caches are currently enumerated (grep for `.gomodcache` to find them all); half-updated tables are the likely review finding.
- Self-hosted (`--isolated`) mode needs no special casing: `.worktrees` is a subdir of the one workspace volume and the same gate already covers it.

## Acceptance criteria

- Fresh container on a JS/powbox or Go project: `ccache --show-config` reports the cache dir inside `.worktrees/.ccache`; two identical `ccache gcc` compiles produce a cache hit; the cache survives container recreation.
- Non-dev dir-mounted folder: no `CCACHE_DIR` exported, no `.ccache` litter on the host bind mount.
- Plain `gcc`/`cmake` builds are byte-for-byte unaffected (no masquerade interposition).
- Docs and both smoke drivers updated per Target files.

## Validation

- In-container: `shellcheck`/`shfmt -d` on changed shell, PSScriptAnalyzer on changed PowerShell.
- Host/CI: rebuild, run `commands/smoke-test.sh`, and manually verify cache persistence across a container stop/recreate on a dir-mounted Go project.

## Review plan

Reviewer traces the `CCACHE_DIR` value from launcher (both languages, correct gate) through entrypoint pre-create to a container process, confirms no global compiler interposition was added, and checks every doc location that enumerates `.worktrees` contents was updated consistently.
