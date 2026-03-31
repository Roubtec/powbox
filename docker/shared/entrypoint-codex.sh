#!/usr/bin/env bash
set -euo pipefail

export AGENT_CONFIG_DIR="${CODEX_CONFIG_DIR:-/home/node/.codex}"
export AGENT_HOST_SEED_DIR="${CODEX_HOST_SEED_DIR:-/home/node/.codex-host}"
export AGENT_SETUP_HOOK="/usr/local/bin/entrypoint-codex-hook.sh"
export AGENT_NAME="Codex"
export AGENT_AUTONOMY_FLAG="--dangerously-bypass-approvals-and-sandbox"
export AGENT_INSTRUCTION_FILE="AGENTS.md"

exec /usr/local/bin/entrypoint-core.sh "$@"
