# Codex Container — Agent Notes

This file is intended for AI agents working on the Codex container harness.

## Current Architecture

- shared base image at `/workspace/docker/base/Dockerfile`
- thin Codex image at `/workspace/docker/codex/Dockerfile`
- shared Compose runtime base at `/workspace/compose.shared.yml`
- Codex runtime overlay at `/workspace/compose.codex.yml`
- shared launch and build helpers at `/workspace/scripts/`
- shared entrypoint core and hooks at `/workspace/docker/shared/`

## Key Paths

| Path | Purpose |
|------|---------|
| `/workspace` | Bind-mounted project directory |
| `/home/node/.codex` | Codex config volume (`codex-config`) |
| `/home/node/.config/gh` | Shared GitHub CLI auth volume (`agent-gh-config`) |
| `/home/node/.local/share/pnpm/store` | Shared pnpm store volume (`agent-pnpm-store`) |
| `/workspace/node_modules` | Per-project package volume (`agent-nm-<project>-<hash>`) |

## Important Behavior

- Codex authenticates through `OPENAI_API_KEY`, passed at runtime and never baked into the image.
- The shared base image includes `bubblewrap`.
- `entrypoint-core.sh` owns firewall setup, shared Git/GitHub seeding, and final command dispatch.
- `entrypoint-codex-hook.sh` owns Codex-specific config seeding, `AGENTS.md` sync, and the missing-API-key warning.
- The runtime Compose project name must stay stable across both agent launchers so the shared volumes stay first-class rather than external.

## pnpm

The pnpm store lives outside `/workspace` and uses `package-import-method=copy` because the workspace bind mount and pnpm volume are different filesystems.
