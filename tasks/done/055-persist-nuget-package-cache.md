# Task 055 — Persist the NuGet package cache and gate the worktrees volume on .NET repos

## Why this task exists

The base image now bakes the .NET SDK (see `docs/architecture.md` → "Bundled .NET SDK"), but its package cache is container-lifetime only, so the toolchain is a second-class citizen next to Go and pnpm:

- `~/.nuget/packages` sits **outside every volume**. Measured at ~260 MB after a single restore of a small two-project solution; every container recreate cold-downloads all of it again. This is precisely the problem `GOMODCACHE`/`GOCACHE` already solve for Go and `.worktrees/.pnpm-store` solves for pnpm.
- A **.NET-only repo mounts no worktrees volume at all.** The launcher's wider gate (`scripts/launch-agent.sh`, the `MOUNT_WORKTREES_VOLUME` block) recognizes `package.json`/`pnpm-workspace.yaml`/`.powbox.yml` for `MOUNT_WORKSPACE_VOLUMES`, plus `go.mod` as the one wider trigger. A repo whose only build system is a `.sln`/`.csproj` therefore gets neither volume — no persistent worktrees, no cache target. A .NET project that happens to also be a JS monorepo is covered today only by accident.

Both gaps were known and deliberately excluded from the SDK-baking PR to keep that layer reviewable; this task closes them.

## Scope

- Export `NUGET_PACKAGES=<workspace>/.worktrees/.nuget` from the launcher behind the `MOUNT_WORKTREES_VOLUME` gate, exactly as `GOMODCACHE`/`GOCACHE`/`CCACHE_DIR` are exported today.
- Pre-create the dir in `entrypoint-core.sh`'s existing guarded cache loop by adding `NUGET_PACKAGES` to the `for _cache_var in GOMODCACHE GOCACHE CCACHE_DIR` list — inheriting the established warn-and-unset-on-failure behavior so a bad value degrades to the image default instead of aborting container start.
- Add a **.NET trigger to the worktrees-volume gate**, beside `go.mod`, so a .NET-only repo gets `agent-wt-*` (persistent cache + worktrees) but **not** `agent-nm-*` — no empty `node_modules/` litter in the host folder, the same shape as the go.mod-only case. Decide and document the detection predicate: a root `*.sln`/`*.slnx` is unambiguous, but many repos keep projects in subdirs with no root solution file, so a bounded search (e.g. root plus one level for `*.csproj`/`*.fsproj`) may be needed. Prefer the cheapest predicate that is not obviously wrong, and state the choice in the PR.
- Keep `PNPM_STORE_DIR` keyed to the narrower JS/powbox gate, unchanged — the pnpm wrapper's host-litter warning must still fire for a stray root `pnpm install` in a .NET-only repo.

Out of scope:

- Bumping or adding an SDK band.
- Any NuGet **HTTP cache**/`~/.local/share/NuGet` handling beyond whatever falls out naturally; the global packages folder is the expensive one.
- A worktree-scoped cache. Unlike golangci-lint's analysis cache, the NuGet global packages folder is content-addressed and designed for concurrent access, so it should be **shared** across a project's worktrees like `GOMODCACHE` — confirm this holds rather than assuming it.

## Context and references

- `docs/architecture.md` → "Bundled Go toolchain" — the cache-persistence pattern this mirrors, including the shared-vs-per-worktree reasoning.
- `docs/architecture.md` → "Bundled .NET SDK" — states this gap explicitly; update it when the gap closes.
- `scripts/launch-agent.sh` — the `WT_*_DIR` definitions (~line 1142-1158), the `MOUNT_WORKTREES_VOLUME` gate (~line 1132), the `-e` env list (~line 1793), and the **mount-mismatch messaging** (~lines 1441-1488) which enumerates project kinds in user-facing text and will need a .NET case.
- `docker/shared/entrypoint-core.sh` — the guarded cache-dir loop (~line 432).
- `AGENTS.md` "Key Paths" and `docker/shared/container-agent.md.tmpl` "Filesystem layout" — both enumerate what lives under `.worktrees`; the tmpl's `.NET` tooling row currently states the cache does **not** persist and must be corrected.
- `README.md` (~line 237) — the `agent-wt-<agent>-<project>` volume description enumerates the caches it holds.

## Target files or areas

- `scripts/launch-agent.sh`
- `docker/shared/entrypoint-core.sh`
- `docker/shared/container-agent.md.tmpl`, `AGENTS.md`, `README.md`, `docs/architecture.md`
- Whichever smoke/identity fixtures pin the volume-gate shapes (the self-hosted smoke's four-shape fixture matrix and `POWBOX_PRINT_IDENTITY` output both assert on the gate flags).

## Implementation notes

- No base-image rebuild is required for the launcher/entrypoint half — but `entrypoint-core.sh` **is** a base-layer COPY (`scripts/base-source-files.txt`), so editing it does trip the `powbox.base.recipe.digest` staleness check and will want a base rebuild on the host.
- The .NET gate addition changes container identity for repos that previously mounted nothing; expect the existing "container does not match this repo's expected mounts" relaunch path to fire once for such a project, and check the message reads sensibly for a .NET-only repo.

## Acceptance criteria

- A `dotnet restore` in a dir-mounted project writes into `.worktrees/.nuget`, and a container stop/recreate followed by the same restore resolves from cache with no network downloads.
- A repo with only `.sln`/`.csproj` and no `package.json` launches with `agent-wt-*` mounted and **no** `agent-nm-*`, and no `node_modules/` dir appears in the host folder.
- A JS-only and a go.mod-only repo's gate behavior are both unchanged.
- The docs above no longer claim the NuGet cache is container-lifetime.

## Validation

- In-container: `shellcheck` and `shfmt -d` on the touched shell files; any pure-shell unit tests covering the gate.
- Host/CI: a base + agent rebuild, then the dir-mount and self-hosted smokes. Add or extend a fixture so the .NET-only gate shape is pinned rather than manually verified once.

## Review plan

Reviewer checks that the .NET detection predicate is stated and defensible (not a repo-wide recursive scan), that `PNPM_STORE_DIR` stayed on the narrower gate, that the cache dir is shared-across-worktrees on purpose with the reasoning written down, and that every doc surface enumerating `.worktrees` contents was updated together — including the tmpl row that currently advertises the opposite.
