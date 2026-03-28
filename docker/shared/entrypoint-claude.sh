#!/usr/bin/env bash
set -euo pipefail

export AGENT_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/home/node/.claude}"
export AGENT_HOST_SEED_DIR="${CLAUDE_HOST_SEED_DIR:-/home/node/.claude-host}"
export AGENT_SETUP_HOOK="/usr/local/bin/entrypoint-claude-hook.sh"

exec /usr/local/bin/entrypoint-core.sh "$@"
