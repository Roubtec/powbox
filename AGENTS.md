# Agent Instructions

## Documentation Practices

Update [README.md](README.md) if there are any changes to the project overview, tech stack, or development practices.

Use one line per paragraph in Markdown if possible.

## Working Tips

Suggest alternative strategies or push back on the user's ideas if there are better practices recommended or the user appears to be inconsistent.
Teach or question the user if that is in the best interest of the final product.

## Architecture

- Shared base image: `docker/base/Dockerfile`
- Thin agent images: `docker/claude/Dockerfile`, `docker/codex/Dockerfile`
- Shared Compose runtime: `compose.shared.yml`; agent overlays: `compose.claude.yml`, `compose.codex.yml`
- User-facing host commands: `commands/`
- Internal build/launch helpers: `scripts/`
- Entrypoint core and hooks: `docker/shared/`

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
- The Compose project name is `powbox` for both agents so shared volumes stay first-class.
- Codex authenticates via `OPENAI_API_KEY` passed at runtime, never baked into the image.
- Agent-specific hooks (`entrypoint-claude-hook.sh`, `entrypoint-codex-hook.sh`) own config seeding and instruction-file rendering.
- Container instructions live in a single shared template (`docker/shared/container-agent.md.tmpl`) rendered at startup via `envsubst` with agent-specific variables set in the entrypoint scripts.

## Project Identity

Per-project identity uses `basename + SHA256(full path)` (truncated to 12 chars) so container names and `node_modules` volumes do not collide across similarly named projects.

## Volumes and Stores

- `node_modules` is overlaid with a per-project Docker volume at `/workspace/<project-slug>/node_modules`.
- pnpm's store is pinned outside the workspace with `package-import-method=copy` (workspace bind mount and pnpm volume are different filesystems).

## Security

- Firewall rules allow loopback and block private/local networks for both IPv4 and IPv6.
- `/etc/sudoers.d/node` must stay scoped to `/usr/local/bin/init-firewall.sh` and `/usr/bin/apt-get` only (mode `0440`).
- The base image includes `bubblewrap` for sandboxing.

## File Conventions

- Default to LF across the repo.
- Keep Windows-specific files (`.ps1`, `.bat`, `.cmd`) in CRLF.
