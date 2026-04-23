#!/usr/bin/env bash
set -euo pipefail

export AGENT_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/home/node/.claude}"
export AGENT_SETUP_HOOK="/usr/local/bin/entrypoint-claude-hook.sh"
export AGENT_NAME="Claude"
export AGENT_AUTONOMY_FLAG="--dangerously-skip-permissions"
export AGENT_INSTRUCTION_FILE="CLAUDE.md"

exec /usr/local/bin/entrypoint-core.sh "$@"
