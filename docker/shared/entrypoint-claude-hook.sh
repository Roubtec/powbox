#!/usr/bin/env bash
set -euo pipefail

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:?AGENT_CONFIG_DIR must be set}"

# Merge two JSON files (jq deep merge: base * overlay) into dst.
# Best-effort: logs a warning and leaves dst untouched on any failure.
merge_json_files() {
	local base="$1" overlay="$2" dst="$3"
	local tmp="${dst}.tmp"
	rm -f "$tmp"
	if ! jq -e . "$base" >/dev/null 2>&1; then
		echo "Warning: invalid JSON in $base; leaving $dst untouched." >&2
		return
	fi
	if ! jq -e . "$overlay" >/dev/null 2>&1; then
		echo "Warning: invalid JSON in $overlay; leaving $dst untouched." >&2
		return
	fi
	if jq -s '.[0] * .[1]' "$base" "$overlay" > "$tmp"; then
		mv "$tmp" "$dst"
	else
		echo "Warning: failed to merge $overlay into $dst; leaving existing settings untouched." >&2
		rm -f "$tmp"
	fi
}

# Host config is intentionally not seeded; the container grows its own Claude ecosystem
# (plugins, settings, sessions, projects) independent of the host. Only the image-baked
# statusline and instruction file below are applied.
chmod 700 "$AGENT_CONFIG_DIR" 2>/dev/null || true

# Seed the statusline script (no-clobber: preserves user customizations on the
# volume; delete the file to pick up the latest version on next container start).
STATUSLINE_SRC="/home/node/.agent-container/statusline-command.sh"
if [ -f "$STATUSLINE_SRC" ] && [ ! -f "$AGENT_CONFIG_DIR/statusline-command.sh" ]; then
	cp "$STATUSLINE_SRC" "$AGENT_CONFIG_DIR/statusline-command.sh"
fi

AGENT_TMPL="/home/node/.agent-container/agent.md.tmpl"
if [ -f "$AGENT_TMPL" ]; then
	IMAGE_EPOCH=$(cat /home/node/.agent-container/build-epoch 2>/dev/null || echo 0)
	[[ "$IMAGE_EPOCH" =~ ^[0-9]+$ ]] || IMAGE_EPOCH=0
	VOLUME_EPOCH=$(cat "$AGENT_CONFIG_DIR/.instruction-epoch" 2>/dev/null || echo 0)
	[[ "$VOLUME_EPOCH" =~ ^[0-9]+$ ]] || VOLUME_EPOCH=0
	if [ "$IMAGE_EPOCH" -ge "$VOLUME_EPOCH" ]; then
		# envsubst needs literal ${VAR} names, not shell-expanded values
		# shellcheck disable=SC2016
		envsubst '${AGENT_NAME} ${AGENT_AUTONOMY_FLAG} ${AGENT_CONFIG_DIR}' \
			< "$AGENT_TMPL" > "$AGENT_CONFIG_DIR/${AGENT_INSTRUCTION_FILE:?}"

		# Merge the statusLine key into settings.json (preserves all other keys).
		STATUSLINE_JSON="/home/node/.agent-container/statusline-settings.json"
		SETTINGS_FILE="$AGENT_CONFIG_DIR/settings.json"
		if [ -f "$STATUSLINE_JSON" ]; then
			if [ -f "$SETTINGS_FILE" ]; then
				merge_json_files "$SETTINGS_FILE" "$STATUSLINE_JSON" "$SETTINGS_FILE"
			else
				cp "$STATUSLINE_JSON" "$SETTINGS_FILE"
			fi
		fi

		# Seed image-baked slash commands (no-clobber: preserves user-modified versions;
		# delete the file to pick up the latest image version on next container start).
		# Per-repo .claude/commands/ still takes precedence at invoke time.
		COMMANDS_SRC="/home/node/.agent-container/commands"
		if [ -d "$COMMANDS_SRC" ]; then
			mkdir -p "$AGENT_CONFIG_DIR/commands"
			for cmd in "$COMMANDS_SRC"/*.md; do
				[ -e "$cmd" ] || continue
				dest="$AGENT_CONFIG_DIR/commands/$(basename "$cmd")"
				[ -f "$dest" ] && continue
				if ! cp "$cmd" "$dest"; then
					echo "Warning: failed to seed $(basename "$cmd") into commands dir" >&2
				fi
			done
		fi

		echo "$IMAGE_EPOCH" > "$AGENT_CONFIG_DIR/.instruction-epoch"
	fi
fi

# Per-container ephemeral overlay: when AGENT_SETTINGS_EPHEMERAL=1, shadow
# settings.json with a /dev/shm copy so interactive /model and /effort edits
# do not leak into other containers sharing the claude-config volume.  The
# underlying volume file keeps its pre-shadow baseline; the bind mount is
# torn down when the container stops.
if [ "${AGENT_SETTINGS_EPHEMERAL:-0}" = "1" ]; then
	SETTINGS_FILE="$AGENT_CONFIG_DIR/settings.json"
	SHADOW_DIR="/dev/shm/agent-shadow"
	SHADOW_FILE="$SHADOW_DIR/claude-settings.json"
	mkdir -p "$SHADOW_DIR"
	chmod 700 "$SHADOW_DIR"
	[ -f "$SETTINGS_FILE" ] || echo "{}" > "$SETTINGS_FILE"
	cp -p "$SETTINGS_FILE" "$SHADOW_FILE"
	if ! sudo /usr/local/bin/shadow-agent-config.sh "$SHADOW_FILE" "$SETTINGS_FILE"; then
		echo "Warning: failed to shadow $SETTINGS_FILE; per-container settings will leak across containers." >&2
	fi
fi
