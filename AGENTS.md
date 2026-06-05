# Agent Instructions

## Documentation Practices

Update [README.md](README.md) if there are any changes to the project overview, tech stack, or development practices.

Use one line per paragraph in Markdown if possible.

## Working Tips

Suggest alternative strategies or push back on the user's ideas if there are better practices recommended or the user appears to be inconsistent.
Teach or question the user if that is in the best interest of the final product.

## Architecture

See README "Layout" for the repo file map. Rules that map does not state:

- There is one unified agent image `powbox-agent:latest` (`docker/agent/Dockerfile`) built on `powbox-agent-base:latest`. It installs both agent binaries — Codex below Claude so a Claude version bump (the common case) busts only the Claude layer plus the cheap asset/entrypoint layers above it; a Codex bump rebuilds the Claude layer on top too (accepted). The old per-agent images (`powbox-claude`, `powbox-codex`) and Dockerfiles are gone.
- Each agent's image-baked seed assets live under a per-agent directory `/home/node/.agent-container/<agent>` (e.g. `docker/claude/agent-container/` → `/home/node/.agent-container/claude/`), read by that agent's hook via the `AGENT_SEED_DIR` variable so the two agents' templates, skills, statusline, and build epoch never collide.
- Image-baked skills are seeded into each agent's user-level skills directory at startup (`$CLAUDE_CONFIG_DIR/skills/` for Claude, `~/.agents/skills/` for Codex), no-clobber at the skill-directory level; a per-repo `.claude/skills/` (or `.agents/skills/`) still takes precedence at invoke time.
- Entrypoint scripts all live in `docker/shared/`, but only `entrypoint-core.sh` is baked by the base image. The unified entrypoint `entrypoint-agent.sh` and both per-agent hooks (`entrypoint-{claude,codex}-hook.sh`) are baked by the agent image, so editing the entrypoint or a hook only requires rebuilding the agent image — not the base. The old per-agent entrypoint shims (`entrypoint-{claude,codex}.sh`) are gone, replaced by `entrypoint-agent.sh` plus its in-script agent registry.
- After cutover the obsolete `powbox-claude` / `powbox-codex` images can be removed with `docker image rm powbox-claude powbox-codex` — non-destructive to the `claude-config` / `codex-config` volumes.

## Key Paths

| Path | Purpose |
|------|---------|
| `/workspace/<project-slug>` | Bind-mounted project directory (working directory; slug is `<name>-<hash>`) |
| `/ctx` | Optional read-only context volume (`--ctx`) |
| `/home/node/.claude` | Claude config volume (`claude-config`); always mounted regardless of primary agent |
| `/home/node/.codex` | Codex config volume (`codex-config`); always mounted regardless of primary agent |
| `/home/node/.agent-container/<agent>` | Per-agent image-baked seed assets (template, skills, statusline, build epoch); read via `AGENT_SEED_DIR` |
| `/home/node/.config/gh` | Shared GitHub CLI auth volume |
| `/home/node/.local/share/pnpm/store` | Shared pnpm store volume |
| `/workspace/<project-slug>/node_modules` | Per-project package volume |

Both config volumes are always mounted (not just the primary agent's) so the primary agent can invoke the other in-container; see README "Cross-Agent Delegation".

## Entrypoint and Runtime

- `entrypoint-agent.sh` is the image ENTRYPOINT. It reads `PRIMARY_AGENT` (`claude` | `codex`, defaulting to `claude` for an unknown value), holds the agent registry (`agent_env` maps each agent to its `AGENT_CONFIG_DIR`, `AGENT_SETUP_HOOK`, `AGENT_SEED_DIR`, name, binary, autonomy flag, instruction file, and label), then seeds every agent and execs `entrypoint-core.sh` for the primary. Adding a harness = extend `agent_env` and `ALL_AGENTS`.
- It seeds in two passes: each non-primary agent is seeded directly (export its `AGENT_*` vars, run its hook); the primary agent's env is exported and handed to `entrypoint-core.sh`, which runs the primary's hook (so it is not run twice) alongside firewall/git/shadow setup before execing the CMD.
- Each per-agent hook (`entrypoint-claude-hook.sh`, `entrypoint-codex-hook.sh`) is run in full for every agent. Each writes only into its own config dir (`~/.claude` vs `~/.codex`/`~/.agents`), so there is no conflict; hooks are idempotent, no-clobber, and build-epoch-gated, and read their baked assets from `AGENT_SEED_DIR`.
- `entrypoint-core.sh` is a wrapper-style entrypoint that must end with `exec "$@"` and is unchanged by the unification (still runs the single `AGENT_SETUP_HOOK`).
- The shared instruction template is rendered via `envsubst` with agent-specific variables (including `${AGENT_PEERS}`, the registry-derived peer list for the "Delegating to another agent" section).
- `gh auth setup-git` runs from `$HOME` (not the workspace) and failure is non-fatal. On success it also adds a container-global `url."https://github.com/".insteadOf "git@github.com:"` rewrite (written to the ephemeral `GIT_CONFIG_GLOBAL`, never the host) so SSH-form `origin` remotes push/fetch over HTTPS+gh without rewriting the host repo.
- Workspace shadow mounts run after git setup, so any shadow logic must not assume an earlier ordering.

## Project Identity

Per-project identity uses `basename + SHA256(full path)` (truncated to 12 chars) so container names and `node_modules` volumes do not collide across similarly named projects.

## Volumes and Stores

See README "Workspace Shadow Mounts" and "Runtime" for volume behavior. The non-obvious constraint: pnpm's store is pinned outside the workspace with `package-import-method=copy` because the workspace bind mount and the pnpm volume are different filesystems.

## Bundled PostgreSQL

- The base image installs the PostgreSQL 16 server + client + contrib from the official PGDG apt repo (`docker/base/Dockerfile`), version-matched to the `postgres:16.x` images projects pin so integration suites don't hit behavior drift from Debian's stock 15.
- No daemon is started at build or runtime. `docker/shared/pg-dev-up` (baked to `/usr/local/bin/pg-dev-up`) stands up a throwaway loopback cluster on demand under `$PGDATA` (default `/tmp/pgdata`), as the unprivileged `node` user with trust auth — so it needs **no** sudoers entry. Credentials/port/db are env-overridable; see the script header.
- The server binaries live off `PATH` at `/usr/lib/postgresql/<major>/bin`; `pg-dev-up` resolves the newest installed major itself, so a future PG bump needs no path edit.

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
