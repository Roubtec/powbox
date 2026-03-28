#!/usr/bin/env bash
set -euo pipefail

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:?AGENT_CONFIG_DIR must be set}"
AGENT_HOST_SEED_DIR="${AGENT_HOST_SEED_DIR:-/home/node/.codex-host}"

# Seed the persistent Codex config volume from a host config directory on the
# first run only. Subsequent runs keep the Docker-managed state untouched.
if [ -d "$AGENT_HOST_SEED_DIR" ] &&
	[ -n "$(find "$AGENT_HOST_SEED_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] &&
	[ ! -f "$AGENT_CONFIG_DIR/config.toml" ]; then
	rsync -a --no-owner --no-group --ignore-existing \
		--exclude '/tmp/' \
		--exclude '/.tmp/' \
		--exclude '/cache/' \
		--exclude '/log/' \
		--exclude '/sessions/' \
		--exclude '*.sqlite' \
		--exclude '*.sqlite-shm' \
		--exclude '*.sqlite-wal' \
		--exclude 'history.jsonl' \
		--exclude 'sandbox.log' \
		"$AGENT_HOST_SEED_DIR"/ "$AGENT_CONFIG_DIR"/
	chmod 700 "$AGENT_CONFIG_DIR" || true
	if [ -f "$AGENT_CONFIG_DIR/config.toml" ]; then
		chmod 600 "$AGENT_CONFIG_DIR/config.toml" || true
	fi
fi

if [ -f /home/node/.codex-container/AGENTS.md ]; then
	cp /home/node/.codex-container/AGENTS.md "$AGENT_CONFIG_DIR/AGENTS.md"
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
	echo "Warning: OPENAI_API_KEY is not set. Codex CLI will not be able to authenticate with OpenAI." >&2
	echo "Pass it via: -e OPENAI_API_KEY=\$OPENAI_API_KEY when launching the container." >&2
fi
