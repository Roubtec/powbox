#!/usr/bin/env bash
set -euo pipefail

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:?AGENT_CONFIG_DIR must be set}"
AGENT_HOST_SEED_DIR="${AGENT_HOST_SEED_DIR:-/home/node/.claude-host}"

# Seed the persistent Claude config volume from a host config directory on the
# first run only. Subsequent runs keep the Docker-managed state untouched.
if [ -d "$AGENT_HOST_SEED_DIR" ] &&
	[ -n "$(find "$AGENT_HOST_SEED_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] &&
	[ ! -f "$AGENT_CONFIG_DIR/.credentials.json" ]; then
	cp -an "$AGENT_HOST_SEED_DIR"/. "$AGENT_CONFIG_DIR"/
	chmod 700 "$AGENT_CONFIG_DIR" || true
	if [ -f "$AGENT_CONFIG_DIR/.credentials.json" ]; then
		chmod 600 "$AGENT_CONFIG_DIR/.credentials.json" || true
	fi
fi

if [ -f /home/node/.claude-container/CLAUDE.md ]; then
	cp /home/node/.claude-container/CLAUDE.md "$AGENT_CONFIG_DIR/CLAUDE.md"
fi
