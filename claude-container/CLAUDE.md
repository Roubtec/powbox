# CLAUDE.md

## Purpose

Repo-specific implementation notes for the Claude container harness.

Use [README.md](README.md) for end-user setup and runtime behavior.

## Current Architecture

- shared image build graph at the repo root
- shared Compose runtime base at the repo root
- thin Claude wrapper scripts in `claude-container/`
- shared shell logic in `scripts/`
- shared entrypoint core and hooks in `docker/shared/`

## Agent-Relevant Hints

- `entrypoint-core.sh` must stay a wrapper-style entrypoint that ends with `exec "$@"`.
- `gh auth setup-git` must not assume the workspace is a git repo; run it from `$HOME` and keep failure non-fatal.
- Per-project identity uses `basename + SHA256(full path)` so container names and `node_modules` volumes do not collide across similarly named projects.
- Each project mounts at `/workspace/<project-slug>` (e.g. `/workspace/myapp-a1b2c3d4e5f6`) so tools that key on absolute paths keep per-project state separate.
- `node_modules` is intentionally overlaid with a per-project Docker volume at `/workspace/<project-slug>/node_modules`.
- pnpm's store is intentionally pinned outside the workspace with `package-import-method=copy`.
- Firewall rules should continue to allow loopback and block private/local networks for both IPv4 and IPv6.
- `/etc/sudoers.d/node` must stay scoped to `/usr/local/bin/init-firewall.sh` only and remain mode `0440`.

## File Conventions

- Default to LF across the repo.
- Keep Windows-specific script files such as `.ps1`, `.bat`, and `.cmd` in CRLF.
