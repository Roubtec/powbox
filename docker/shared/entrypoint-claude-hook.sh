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

AGENT_TMPL="/home/node/.agent-container/agent.md.tmpl"
if [ -f "$AGENT_TMPL" ]; then
	IMAGE_EPOCH=$(cat /home/node/.agent-container/build-epoch 2>/dev/null || echo 0)
	[[ "$IMAGE_EPOCH" =~ ^[0-9]+$ ]] || IMAGE_EPOCH=0
	VOLUME_EPOCH=$(cat "$AGENT_CONFIG_DIR/.instruction-epoch" 2>/dev/null || echo 0)
	[[ "$VOLUME_EPOCH" =~ ^[0-9]+$ ]] || VOLUME_EPOCH=0
	if [ "$IMAGE_EPOCH" -ge "$VOLUME_EPOCH" ]; then
		envsubst '${AGENT_NAME} ${AGENT_AUTONOMY_FLAG} ${AGENT_CONFIG_DIR}' \
			< "$AGENT_TMPL" > "$AGENT_CONFIG_DIR/${AGENT_INSTRUCTION_FILE:?}"
		echo "$IMAGE_EPOCH" > "$AGENT_CONFIG_DIR/.instruction-epoch"
	fi
fi
