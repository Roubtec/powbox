# Codex Container — Agent Notes

This file is intended for AI agents working inside the container. It describes
the architecture and key conventions so agents can orient themselves quickly.

## What this is

A Docker harness that runs [OpenAI Codex CLI](https://github.com/openai/codex)
with full autonomous permissions (`--dangerously-bypass-approvals-and-sandbox`)
inside a sandboxed container. The container provides filesystem isolation and a
network firewall that blocks private/local networks while allowing public
internet access.

## Key paths

| Path | Purpose |
|------|---------|
| `/workspace` | Bind-mounted project directory (read-write) |
| `/home/node/.codex` | Codex CLI config (Docker volume: `codex-config`) |
| `/home/node/.config/gh` | GitHub CLI auth (Docker volume: `claude-gh-config`, shared) |
| `/home/node/.local/share/pnpm/store` | pnpm cache (Docker volume: `claude-pnpm-store`, shared) |
| `/workspace/node_modules` | Per-project packages (Docker volume: `agent-nm-<project>-<hash>`, shared) |

## Auth

Codex CLI authenticates via the `OPENAI_API_KEY` environment variable, which is
passed through at container launch time. It is never baked into the image.

Config preferences live in `~/.codex/config.toml` and are seeded from the host
`~/.codex` directory on first run only.

## Shared volumes

Some Docker volumes are shared with the sibling `claude-container/` harness:
- `claude-gh-config` — GitHub CLI auth
- `claude-pnpm-store` — pnpm content-addressable store
- `claude-zsh-history` — shell history and `cid` alias
- `agent-nm-<project>-<hash>` — per-project node_modules

This means switching between Claude and Codex on the same project reuses
installed packages and credentials without reinstalling.

## Firewall

The init-firewall.sh script runs at container start and blocks all private
network ranges (10.x, 172.16.x, 192.168.x, link-local) while allowing
loopback and public internet. This is enforced via iptables and requires
NET_ADMIN and NET_RAW capabilities.

## Non-root user

The container runs as `node:node`. Sudo access is restricted to
`/usr/local/bin/init-firewall.sh` only.

## pnpm

The pnpm store is at `/home/node/.local/share/pnpm/store` (a Docker volume,
not under `/workspace`). The global pnpm config uses `package-import-method=copy`
because `/workspace` (bind mount) and the pnpm store (Docker volume) are
different filesystems, so hard links would fail.
