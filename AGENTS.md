# Agent Instructions

This file holds the directives every task needs. The deeper architecture/runtime detail is split into chapter docs so it does not weigh on every task's context — see [Where to read more](#where-to-read-more) and load only the chapter your task touches.

## Documentation Practices

Update [README.md](README.md) if there are any changes to the project overview, tech stack, or development practices.
When you change behavior described in a chapter doc (see the table below), update that chapter too.

Use one line per paragraph in Markdown if possible.

## Code Review Guidelines

Before doing a code review, read ALL existing review comments and threads on the PR for context before making suggestions. Findings previously delegated to follow-up work need not be re-raised unless the facts changed since the delegation.

## Git History Rewrites

Never rewrite published history with raw `git push --force`/`-f`. Use `git push --force-with-lease` (ideally the exact form `--force-with-lease=<branch>:<sha>`) so a concurrent push to the old tip is not silently clobbered.
The container sets `push.useForceIfIncludes=true` (in `docker/shared/entrypoint-core.sh`), which further requires that the remote tip you are overwriting was actually integrated locally — this only hardens `--force-with-lease` and does nothing for raw `--force`, so the no-raw-force rule above is what carries the protection. Keep one writer per PR branch; that remains the strongest safeguard against lost pushes.

## Key Paths

| Path | Purpose |
|------|---------|
| `/workspace/<project-slug>` | Project directory (working directory). Dir-mounted mode (default): a host bind mount, slug `<name>-<hash>`. Self-hosted (`--isolated`): a container-local volume, see the last row |
| `/ctx` | Optional context mount root; external folders are mounted under `/ctx/<name>` via `--ctx` or `ctx:` config |
| `/home/node/.claude` | Claude config volume (`claude-config`); always mounted regardless of primary agent |
| `/home/node/.codex` | Codex config volume (`codex-config`); always mounted regardless of primary agent |
| `/home/node/.agent-container/<agent>` | Per-agent image-baked seed assets (template, skills, statusline, build epoch); read via `AGENT_SEED_DIR` |
| `/home/node/.config/gh` | Shared GitHub CLI auth volume |
| `/workspace/<project-slug>/node_modules` | Per-container package volume (`agent-nm-<agent>-<project>`); dir-mounted JS/powbox projects only |
| `/workspace/<project-slug>/.worktrees` | Per-container worktrees volume (`agent-wt-<agent>-<project>`); also holds the durable per-worktree git metadata at `.worktrees/.gitworktrees` (bind-mounted over `.git/worktrees`, so worktrees survive container recycle), the per-container pnpm store at `.worktrees/.pnpm-store` (JS/powbox gate only), the Go caches (`.worktrees/.gomodcache`, `.worktrees/.gocache`, per-worktree `.worktrees/.golangci-cache/…`), and the opt-in ccache compiler cache (`.worktrees/.ccache`); dir-mounted JS/powbox **or** `go.mod` projects |
| `/workspace/<repo-slug>[-<name-slug>]-<instance-hash>` | Self-hosted (`--isolated`) per-instance workspace volume (`agent-ws-<container>`) — the clone plus `node_modules`, `.worktrees`, and the pnpm store / Go caches / ccache as subdirs; replaces the bind mount and the two volumes above |

Both config volumes are always mounted (not just the primary agent's) so the primary agent can invoke the other in-container; see README "Cross-Agent Delegation".

## File Conventions

- Default to LF across the repo.
- Keep Windows-specific files (`.ps1`, `.bat`, `.cmd`) in CRLF.
- Save `.ps1` files that contain non-ASCII characters as UTF-8 **with BOM**, so Windows PowerShell 5.1 does not mangle them (the CRLF rule above is orthogonal to the BOM).

## PowerShell Linting

- Lint with `pwsh -Command "Invoke-ScriptAnalyzer -Path ."`. `Invoke-ScriptAnalyzer` is a `pwsh` cmdlet, not a shell command on `PATH`.
- The repo-root `PSScriptAnalyzerSettings.psd1` is auto-applied (PSScriptAnalyzer discovers it in the analyzed directory) and is baked into the image as the house default at `/usr/local/share/powershell/PSScriptAnalyzerSettings.psd1`. It excludes rules that clash with these CLI-style scripts — see the file for the per-rule rationale.
- To override the config for a single run, pass an explicit `-Settings`: `-Settings @{}` for a full unfiltered pass against all default rules, or e.g. `-Settings @{IncludeRules=@('PSReviewUnusedParameter')}` to run one otherwise-excluded rule across the tree. Note that `-IncludeRule` alone does **not** override `ExcludeRules` — the auto-discovered config wins.

## Validating Changes

When you develop powbox from **inside** a powbox container, the validation surface is split: static checks and pure-shell tests run here, but anything that needs a built image runs on the host or in CI.

Runs in-container (do these before handing off):

- Static lint gates: `shellcheck` (Tier 0 CI blocks at `--severity=error`; run the default severity locally), `shfmt -d`, and PSScriptAnalyzer — see [PowerShell Linting](#powershell-linting).
- Pure-shell unit tests that need no image or Docker daemon, e.g. `scripts/test-sensitive-host-path.sh`, `scripts/test-detect-shadows.sh`, `scripts/test-shadow-mounts-chown.sh`, `scripts/test-pnpm-shadow-wrapper.sh`.

Needs the host or CI (cannot run here):

- Full image builds (`./build.sh base|agent|all`). The in-container `docker` is a Podman shim with no `buildx bake`, so `scripts/build-image.sh` fails fast with host-build guidance rather than emitting a confusing `unknown flag: --file`.
- `commands/smoke-test.sh` and the per-stage smokes (`scripts/smoke-test-image.sh`, `scripts/smoke-test-dirmount.sh`, `scripts/smoke-test-podman.sh`, `scripts/smoke-test-selfhosted.sh`, `scripts/smoke-test-worktree-metadata.sh`) — they need a real built image and, in some cases, a relaunchable container that the running agent container cannot provide.

When validating a change requires a rebuilt image or a smoke run, stop and ask the user to build on the host (`./build.sh all`, or `build.ps1`) and restart the container from the rebuilt image — do not attempt an in-container build. Tier 1 CI also builds and smoke-tests image-affecting PRs targeting main (unless the PR is labeled `non-code`), so such a PR is normally covered.

The gates live in `.github/workflows/native-linux-ci.yml` (Tier 0 static guards) and `.github/workflows/native-linux-build.yml` (Tier 1 build + smoke).

## Security

- Firewall rules allow loopback and block private/local networks for both IPv4 and IPv6.
- `/etc/sudoers.d/node` must stay scoped to `/usr/local/bin/init-firewall.sh`, `/usr/local/bin/shadow-mounts.sh`, `/usr/local/bin/fix-workspace-perms.sh`, and `/usr/bin/apt-get` only (mode `0440`). `fix-workspace-perms.sh` is root-owned and immutable and refuses to act outside `/workspace/`, like `shadow-mounts.sh`.
- The base image includes `bubblewrap` for sandboxing.

See README "Workspace Shadow Mounts → Security" for the `shadow-mounts.sh` / `CAP_SYS_ADMIN` rationale.

## Where to read more

The deep architecture/runtime detail lives in chapter docs under `docs/` so it does not load on every task. Read the chapter that matches what you are touching:

| When your task touches… | Read |
|---|---|
| Image layering (Codex-below-Claude), per-agent seed assets, skill/workflow seeding, the worktree-helper three-layer split, provenance, obsolete-image cleanup | [docs/architecture.md](docs/architecture.md) → "Rules the file map does not state" |
| Launch modes & container/volume naming (dir-mounted vs. `--isolated` identity) | [docs/architecture.md](docs/architecture.md) → "Project Identity" · README "Self-Hosted Mode" |
| Volumes, the pnpm store, worktree `node_modules` hardlinking | [docs/architecture.md](docs/architecture.md) → "Volumes and Stores" · [docs/worktree-node-modules-hardlinks.md](docs/worktree-node-modules-hardlinks.md) |
| Bundled PostgreSQL build rationale | [docs/architecture.md](docs/architecture.md) → "Bundled PostgreSQL" |
| Bundled Go toolchain rationale (version pinning, GOTOOLCHAIN, golangci-lint) | [docs/architecture.md](docs/architecture.md) → "Bundled Go toolchain" |
| Bundled .NET SDK rationale (band pinning, env opt-outs, first-use sentinels, NuGet cache gap) | [docs/architecture.md](docs/architecture.md) → "Bundled .NET SDK" |
| Container startup: entrypoint chain, per-agent hooks, ordering, workspace-perms healing, the mid-session pnpm/shadow wrapper, the bash/zsh split | [docs/entrypoint-and-runtime.md](docs/entrypoint-and-runtime.md) |
| The unified image spec / migration order | [docs/unified-agent-image.md](docs/unified-agent-image.md) |
| Skill refresh, ownership markers, pruning, provenance internals | [docs/skills-refresh-and-provenance.md](docs/skills-refresh-and-provenance.md) |
| Rootless Podman / nested containers / the shared image store | [docs/rootless-podman.md](docs/rootless-podman.md) · [docs/podman-shared-image-store.md](docs/podman-shared-image-store.md) |
| Adding, changing, or interpreting a smoke-test stage: what each one is for, host source vs. baked artifact, which stages need the network, the skip variables and what the partial-run banner cannot see | [docs/smoke-tests.md](docs/smoke-tests.md) |
