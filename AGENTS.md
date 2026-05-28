# Agent Instructions

## Documentation Practices

Update [README.md](README.md) if there are any changes to the project overview, tech stack, or development practices.

Use one line per paragraph in Markdown if possible.

## Working Tips

Suggest alternative strategies or push back on the user's ideas if there are better practices recommended or the user appears to be inconsistent.
Teach or question the user if that is in the best interest of the final product.

## Architecture

See README "Layout" for the repo file map. Rules that map does not state:

- Image-baked Claude slash commands in `docker/claude/agent-container/commands/` are seeded into `$CLAUDE_CONFIG_DIR/commands/` at startup; a per-repo `.claude/commands/` overrides on name collision.
- Entrypoint scripts all live in `docker/shared/`, but only `entrypoint-core.sh` is baked by the base image. The agent-specific shims and hooks (`entrypoint-{claude,codex}.sh`, `entrypoint-{claude,codex}-hook.sh`) are baked by their respective agent images, so editing a hook only requires rebuilding that agent — not the base.

## Key Paths

| Path | Purpose |
|------|---------|
| `/workspace/<project-slug>` | Bind-mounted project directory (working directory; slug is `<name>-<hash>`) |
| `/ctx` | Optional read-only context volume (`--ctx`) |
| `/home/node/.claude` | Claude config volume |
| `/home/node/.codex` | Codex config volume |
| `/home/node/.config/gh` | Shared GitHub CLI auth volume |
| `/home/node/.local/share/pnpm/store` | Shared pnpm store volume |
| `/workspace/<project-slug>/node_modules` | Per-project package volume |

## Entrypoint and Runtime

- `entrypoint-core.sh` is a wrapper-style entrypoint that must end with `exec "$@"`.
- `gh auth setup-git` runs from `$HOME` (not the workspace) and failure is non-fatal.
- Agent-specific hooks (`entrypoint-claude-hook.sh`, `entrypoint-codex-hook.sh`) own config seeding and instruction-file rendering; the shared instruction template is rendered via `envsubst` with agent-specific variables set in the entrypoint shims.
- Workspace shadow mounts run after git setup, so any shadow logic must not assume an earlier ordering.

## Project Identity

Per-project identity uses `basename + SHA256(full path)` (truncated to 12 chars) so container names and `node_modules` volumes do not collide across similarly named projects.

## Volumes and Stores

See README "Workspace Shadow Mounts" and "Runtime" for volume behavior. The non-obvious constraint: pnpm's store is pinned outside the workspace with `package-import-method=copy` because the workspace bind mount and the pnpm volume are different filesystems.

## Security

- Firewall rules allow loopback and block private/local networks for both IPv4 and IPv6.
- `/etc/sudoers.d/node` must stay scoped to `/usr/local/bin/init-firewall.sh`, `/usr/local/bin/shadow-mounts.sh`, and `/usr/bin/apt-get` only (mode `0440`).
- The base image includes `bubblewrap` for sandboxing.

See README "Workspace Shadow Mounts → Security" for the `shadow-mounts.sh` / `CAP_SYS_ADMIN` rationale.

## File Conventions

- Default to LF across the repo.
- Keep Windows-specific files (`.ps1`, `.bat`, `.cmd`) in CRLF.
- Save `.ps1` files that contain non-ASCII characters as UTF-8 **with BOM**, so Windows PowerShell 5.1 does not mangle them (the CRLF rule above is orthogonal to the BOM).

## PowerShell Linting

- Lint with `pwsh -Command "Invoke-ScriptAnalyzer -Path ."`. `Invoke-ScriptAnalyzer` is a `pwsh` cmdlet, not a shell command on `PATH`.
- The repo-root `PSScriptAnalyzerSettings.psd1` is auto-applied (PSScriptAnalyzer discovers it in the analyzed directory) and is baked into the image as the house default at `/usr/local/share/powershell/PSScriptAnalyzerSettings.psd1`. It excludes rules that clash with these CLI-style scripts — see the file for the per-rule rationale.
- To override the config for a single run, pass an explicit `-Settings`: `-Settings @{}` for a full unfiltered pass against all default rules, or e.g. `-Settings @{IncludeRules=@('PSReviewUnusedParameter')}` to run one otherwise-excluded rule across the tree. Note that `-IncludeRule` alone does **not** override `ExcludeRules` — the auto-discovered config wins.
