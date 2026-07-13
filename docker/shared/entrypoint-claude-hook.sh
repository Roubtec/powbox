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

		# No-clobber default settings: fill only the keys the user has not set.
		# Reuse the deep-merge helper with the operands SWAPPED (baked defaults
		# as the base, the existing volume settings as the winning overlay) so a
		# user override always survives. This is the OPPOSITE precedence from the
		# statusLine seed above (which the image re-asserts each start); a workflow
		# preference such as respondToBashCommands must stay user-owned once set.
		SETTINGS_DEFAULTS_JSON="$AGENT_SEED_DIR/settings-defaults.json"
		if [ -f "$SETTINGS_DEFAULTS_JSON" ]; then
			if [ -f "$SETTINGS_FILE" ]; then
				merge_json_files "$SETTINGS_DEFAULTS_JSON" "$SETTINGS_FILE" "$SETTINGS_FILE"
			else
				cp "$SETTINGS_DEFAULTS_JSON" "$SETTINGS_FILE"
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
		# seed_workflows records provenance with a hidden per-file sidecar marker
		# (`.<name>.powbox-seeded`) instead of the in-folder marker skills use, but
		# the no-clobber semantics are identical: an existing file on the volume is
		# preserved (user edits survive), delete it to pick up the image version on
		# the next container start, and per-repo `.claude/workflows/` still wins at
		# invoke time. The marker is what lets a future `agent-update-skills`
		# refresh/prune workflows the same way it does skills.
		seed_workflows "$AGENT_SEED_DIR/workflows" "$AGENT_CONFIG_DIR/workflows" noclobber "$AGENT_SEED_DIR" ||
			echo "Warning: one or more Claude workflows failed to seed; continuing." >&2

		echo "$IMAGE_EPOCH" > "$AGENT_CONFIG_DIR/.instruction-epoch"
	fi
fi

# The dev-skills@roubtec plugin (the 8 shared Claude skills; task 015b stopped
# baking them) is deliberately NOT converged here on current images.
# entrypoint-core.sh does it for EVERY launch — after init-firewall.sh (network
# ordering) and fully DETACHED, because the claude CLI hangs (SIGTERM-immune)
# when invoked with the container TTY as stdin, so no `claude plugin …` call may
# ever run on the entrypoint's critical path (see seed-claude-plugins.sh for the
# full rationale). A core that owns the bootstrap announces it by exporting
# POWBOX_PLUGIN_BOOTSTRAP=core before invoking this hook.
#
# BUILD-SKEW SHIM. entrypoint-core.sh is baked into the BASE image; this hook is
# baked into the AGENT layer. The common `cc --build` path rebuilds only the
# agent layer over an existing base, so this hook can run under an OLDER core
# that converges the plugin only for NON-primary Claude — primary Claude was
# this hook's job in that generation. Without a fallback, that combination
# silently stops converging the plugin on primary-Claude launches (the common
# case). So: when the handshake is absent and Claude is primary, launch the same
# detached, best-effort bootstrap the new core would have. Ordering holds — as
# primary Claude's setup hook we are invoked BY core AFTER init-firewall.sh.
# (Non-primary Claude's hook run happens pre-firewall from entrypoint-agent.sh,
# but there PRIMARY_AGENT != claude, so the gate below skips it and the old core
# still converges non-primary Claude itself, post-firewall.) The writer guard is
# defense-in-depth: the launcher clears AGENT_SETUP_HOOK for that role, so this
# hook should never run there at all. No done-marker/bounded wait here: the old
# core has no waiter, so a refresh simply lands next session — the shim restores
# convergence, not the same-session wait. Harmless if ever run redundantly or
# standalone: the seeder is detached, bounded, flock-serialized, idempotent, and
# self-defends its stdin against a TTY.
if [ "${POWBOX_PLUGIN_BOOTSTRAP:-}" != core ] && [ "${PRIMARY_AGENT:-claude}" = claude ] &&
	[ "${POWBOX_IMAGE_STORE_ROLE:-}" != "writer" ] &&
	command -v claude >/dev/null 2>&1 && [ -x /usr/local/bin/seed-claude-plugins.sh ]; then
	# For primary Claude, AGENT_CONFIG_DIR IS Claude's config dir, so this is the
	# same shared-volume log the core path appends to. APPEND, never truncate
	# (see the core block: the claude-config volume is shared by every powbox
	# container, so truncation would wipe a peer's in-progress bootstrap log).
	_claude_plugin_log="$AGENT_CONFIG_DIR/.powbox-plugin-bootstrap.log"
	# stderr first: a failed open of the log itself must stay silent too
	# (redirections apply left-to-right).
	{
		echo "===== $(date -u +%FT%TZ 2>/dev/null || echo '-') claude-hook build-skew plugin bootstrap (${CONTAINER_NAME:-${HOSTNAME:-?}}) ====="
		echo "[claude-hook] dev-skills@roubtec plugin: no core handshake (older base image?); converging post-firewall, detached (log: $_claude_plugin_log)"
	} 2>/dev/null >>"$_claude_plugin_log" || true
	# SC2094: POWBOX_PLUGIN_LOG and the stdio redirect name the same path, but the
	# script only appends to it (never reads), so there is no read/write conflict.
	# stderr first on the launch too: a failed open of the log must stay silent (the
	# spawn is then skipped); on success the trailing 2>&1 re-points the seeder's
	# stderr back into the log.
	if command -v setsid >/dev/null 2>&1; then
		# shellcheck disable=SC2094
		POWBOX_PLUGIN_LOG="$_claude_plugin_log" \
			setsid bash /usr/local/bin/seed-claude-plugins.sh </dev/null 2>/dev/null >>"$_claude_plugin_log" 2>&1 &
	else
		# Fallback if setsid is somehow unavailable: still detach from the hook.
		# shellcheck disable=SC2094
		POWBOX_PLUGIN_LOG="$_claude_plugin_log" \
			bash /usr/local/bin/seed-claude-plugins.sh </dev/null 2>/dev/null >>"$_claude_plugin_log" 2>&1 &
	fi
	unset _claude_plugin_log
fi
