# Agent Instructions

This file holds the directives every task needs. The deeper architecture/runtime detail is split into chapter docs so it does not weigh on every task's context — see [Where to read more](#where-to-read-more) and load only the chapter your task touches.

## Documentation Practices

Update [README.md](README.md) if there are any changes to the project overview, tech stack, or development practices.
When you change behavior described in a chapter doc (see the table below), update that chapter too.

Use one line per paragraph in Markdown if possible.

## Working Tips

Suggest alternative strategies or push back on the user's ideas if there are better practices recommended or the user appears to be inconsistent.
Teach or question the user if that is in the best interest of the final product.

## Key Paths

| Path | Purpose |
|------|---------|
| `/workspace/<project-slug>` | Bind-mounted project directory (working directory; slug is `<name>-<hash>`) |
| `/ctx` | Optional read-only context volume (`--ctx`) |
| `/home/node/.claude` | Claude config volume (`claude-config`); always mounted regardless of primary agent |
| `/home/node/.codex` | Codex config volume (`codex-config`); always mounted regardless of primary agent |
| `/home/node/.agent-container/<agent>` | Per-agent image-baked seed assets (template, skills, statusline, build epoch); read via `AGENT_SEED_DIR` |
| `/home/node/.config/gh` | Shared GitHub CLI auth volume |
| `/workspace/<project-slug>/node_modules` | Per-container package volume (`agent-nm-<agent>-<project>`); dir-mounted mode only |
| `/workspace/<project-slug>/.worktrees` | Per-container worktrees volume (`agent-wt-<agent>-<project>`); also holds the per-container pnpm store at `.worktrees/.pnpm-store`; dir-mounted mode only |
| `/workspace/<repo-slug>-<instance-hash>` | Self-hosted (`--isolated`) per-instance workspace volume (`agent-ws-<container>`) — the clone plus `node_modules`, `.worktrees`, and the pnpm store as subdirs; replaces the bind mount and the two volumes above |

Both config volumes are always mounted (not just the primary agent's) so the primary agent can invoke the other in-container; see README "Cross-Agent Delegation".

## File Conventions

- Default to LF across the repo.
- Keep Windows-specific files (`.ps1`, `.bat`, `.cmd`) in CRLF.
- Save `.ps1` files that contain non-ASCII characters as UTF-8 **with BOM**, so Windows PowerShell 5.1 does not mangle them (the CRLF rule above is orthogonal to the BOM).

## PowerShell Linting

- Lint with `pwsh -Command "Invoke-ScriptAnalyzer -Path ."`. `Invoke-ScriptAnalyzer` is a `pwsh` cmdlet, not a shell command on `PATH`.
- The repo-root `PSScriptAnalyzerSettings.psd1` is auto-applied (PSScriptAnalyzer discovers it in the analyzed directory) and is baked into the image as the house default at `/usr/local/share/powershell/PSScriptAnalyzerSettings.psd1`. It excludes rules that clash with these CLI-style scripts — see the file for the per-rule rationale.
- To override the config for a single run, pass an explicit `-Settings`: `-Settings @{}` for a full unfiltered pass against all default rules, or e.g. `-Settings @{IncludeRules=@('PSReviewUnusedParameter')}` to run one otherwise-excluded rule across the tree. Note that `-IncludeRule` alone does **not** override `ExcludeRules` — the auto-discovered config wins.

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
| Container startup: entrypoint chain, per-agent hooks, ordering, workspace-perms healing, the mid-session pnpm/shadow wrapper, the bash/zsh split | [docs/entrypoint-and-runtime.md](docs/entrypoint-and-runtime.md) |
| The unified image spec / migration order | [docs/unified-agent-image.md](docs/unified-agent-image.md) |
| Skill refresh, ownership markers, pruning, provenance internals | [docs/skills-refresh-and-provenance.md](docs/skills-refresh-and-provenance.md) |
| Rootless Podman / nested containers / the shared image store | [docs/rootless-podman.md](docs/rootless-podman.md) · [docs/podman-shared-image-store.md](docs/podman-shared-image-store.md) |
