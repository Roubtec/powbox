#!/usr/bin/env bash
set -euo pipefail

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:?AGENT_CONFIG_DIR must be set}"
# Directory holding this agent's image-baked seed assets (instruction template,
# statusline, skills, build epoch). Defaults to the legacy shared path so the
# hook still works if run standalone; the unified entrypoint points it at the
# per-agent subdirectory /home/node/.agent-container/<agent>.
AGENT_SEED_DIR="${AGENT_SEED_DIR:-/home/node/.agent-container}"

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
STATUSLINE_SRC="$AGENT_SEED_DIR/statusline-command.sh"
if [ -f "$STATUSLINE_SRC" ] && [ ! -f "$AGENT_CONFIG_DIR/statusline-command.sh" ]; then
	cp "$STATUSLINE_SRC" "$AGENT_CONFIG_DIR/statusline-command.sh"
fi

AGENT_TMPL="$AGENT_SEED_DIR/agent.md.tmpl"
if [ -f "$AGENT_TMPL" ]; then
	IMAGE_EPOCH=$(cat "$AGENT_SEED_DIR/build-epoch" 2>/dev/null || echo 0)
	[[ "$IMAGE_EPOCH" =~ ^[0-9]+$ ]] || IMAGE_EPOCH=0
	VOLUME_EPOCH=$(cat "$AGENT_CONFIG_DIR/.instruction-epoch" 2>/dev/null || echo 0)
	[[ "$VOLUME_EPOCH" =~ ^[0-9]+$ ]] || VOLUME_EPOCH=0
	if [ "$IMAGE_EPOCH" -ge "$VOLUME_EPOCH" ]; then
		# envsubst needs literal ${VAR} names, not shell-expanded values
		# shellcheck disable=SC2016
		envsubst '${AGENT_NAME} ${AGENT_AUTONOMY_FLAG} ${AGENT_CONFIG_DIR} ${AGENT_PEERS}' \
			< "$AGENT_TMPL" > "$AGENT_CONFIG_DIR/${AGENT_INSTRUCTION_FILE:?}"

		# Merge the statusLine key into settings.json (preserves all other keys).
		STATUSLINE_JSON="$AGENT_SEED_DIR/statusline-settings.json"
		SETTINGS_FILE="$AGENT_CONFIG_DIR/settings.json"
		if [ -f "$STATUSLINE_JSON" ]; then
			if [ -f "$SETTINGS_FILE" ]; then
				merge_json_files "$SETTINGS_FILE" "$STATUSLINE_JSON" "$SETTINGS_FILE"
			else
				cp "$STATUSLINE_JSON" "$SETTINGS_FILE"
			fi
		fi

		# Seed image-baked skills (no-clobber at the skill-directory level:
		# preserves user-modified versions; delete the skill folder to pick up the
		# latest image version on next container start, or run `agent-update-skills`
		# to force a refresh). Per-repo .claude/skills/ still takes precedence at
		# invoke time. The copy logic and the .powbox-seeded ownership marker live
		# in the shared seed-skills.sh so this and the updater never drift.
		# shellcheck source=docker/shared/seed-skills.sh
		. /usr/local/bin/seed-skills.sh
		seed_skills "$AGENT_SEED_DIR/skills" "$AGENT_CONFIG_DIR/skills" noclobber "$AGENT_SEED_DIR" ||
			echo "Warning: one or more Claude skills failed to seed; continuing." >&2

		# Seed image-baked dynamic workflows (Claude-only — Codex has no workflow
		# runtime). Workflows are flat `.js` files under ~/.claude/workflows/, so
		# unlike skills (folders with a `.powbox-seeded` marker) this is a simple
		# no-clobber file copy: an existing file on the volume is preserved, so
		# user edits survive; delete the file to pick up the image version on the
		# next container start. Per-repo `.claude/workflows/` still wins at invoke
		# time. (Refresh parity with `agent-update-skills` is a follow-up.)
		WF_SRC="$AGENT_SEED_DIR/workflows"
		if [ -d "$WF_SRC" ]; then
			mkdir -p "$AGENT_CONFIG_DIR/workflows"
			for wf in "$WF_SRC"/*.js; do
				[ -e "$wf" ] || continue
				dest="$AGENT_CONFIG_DIR/workflows/$(basename "$wf")"
				[ -e "$dest" ] || cp "$wf" "$dest" ||
					echo "Warning: failed to seed Claude workflow $(basename "$wf"); continuing." >&2
			done
		fi

		echo "$IMAGE_EPOCH" > "$AGENT_CONFIG_DIR/.instruction-epoch"
	fi
fi
