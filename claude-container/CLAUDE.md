# CLAUDE.md

## Purpose

Docker container setup for running Claude Code with full autonomy inside an isolated environment. Primary host is Windows with Docker Desktop.

## Read first

Use [README.md](README.md) for setup, usage, mounts, auth persistence, included tooling, smoke tests, and troubleshooting. Keep this file limited to repo-specific implementation hints.

## Agent-relevant hints

- `entrypoint.sh` is a wrapper ENTRYPOINT, not just a shell bootstrap. `docker compose run` command passthrough depends on `exec "$@"` working correctly.
- `gh auth setup-git` must not assume `/workspace` is a git repo; it should run from `$HOME` and remain non-fatal.
- Per-project identity uses `basename + SHA256(full path)` so container names and `node_modules` volumes do not collide across similarly named projects.
- `node_modules` is intentionally overlaid with a per-project Docker volume at `/workspace/node_modules` to keep Linux packages separate from host packages.
- pnpm's store is intentionally pinned outside `/workspace` with `package-import-method=copy` because the workspace bind mount and the pnpm store volume are different filesystems.
- Firewall rules should continue to allow loopback and block private/local networks for both IPv4 and IPv6. Do not add a blanket port 53 allow rule.
- `/etc/sudoers.d/node` must stay scoped to `/usr/local/bin/init-firewall.sh` only and remain mode `0440`.

## File conventions

- Default to LF across the repo.
- Keep Windows-specific script files such as `.ps1`, `.bat`, and `.cmd` in CRLF.
