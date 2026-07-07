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

# Bring the shared Claude skills in through the SAME channel colleagues use — the
# `dev-skills@roubtec` plugin (Roubtec/agent-skills marketplace) — rather than the
# image bake (task 015b stopped baking them). Skills arrive NAMESPACED as
# `/dev-skills:<name>` (e.g. `/dev-skills:address-review`); model-side Skill-tool
# matching by description is unaffected, only the slash-command muscle memory.
#
# Run OUTSIDE the epoch gate above: keep-current must run on EVERY start, not just
# when the image is newer than the volume.
#
# DETACHED + BACKGROUNDED, by design (see seed-claude-plugins.sh for the full
# rationale). Container start must NEVER be blocked or failed by plugin work, and
# — critically — the private repo is cloned over HTTPS, which needs git's gh
# credential helper. That helper is configured by `gh auth setup-git` in
# entrypoint-core.sh, which runs AFTER this hook (this hook is the primary agent's
# AGENT_SETUP_HOOK, fired early in entrypoint-core.sh; earlier still, in
# entrypoint-agent.sh, when Claude is the non-primary agent). So we do NOT run the
# install inline here — it would race/precede auth. Instead we detach the helper
# with `setsid`, which briefly waits for the credential helper before touching the
# network. `setsid … </dev/null` reparents it to init (no zombie under the exec'd
# agent) and its stdout/stderr go to a LOG FILE, never the agent's TUI stderr.
# Read the log to see what happened: cat "$AGENT_CONFIG_DIR/.powbox-plugin-bootstrap.log".
if command -v claude >/dev/null 2>&1 && [ -x /usr/local/bin/seed-claude-plugins.sh ]; then
	PLUGIN_BOOTSTRAP_LOG="$AGENT_CONFIG_DIR/.powbox-plugin-bootstrap.log"
	: >"$PLUGIN_BOOTSTRAP_LOG" 2>/dev/null || true
	# Announce to the LOG FILE, not the agent's TUI stderr: the contract above is
	# that this bootstrap "stays quiet" — nothing from it should reach the exec'd
	# agent's terminal, so even this one status line goes to the log.
	echo "[claude-hook] dev-skills@roubtec plugin: bootstrapping in background (log: $PLUGIN_BOOTSTRAP_LOG)" >>"$PLUGIN_BOOTSTRAP_LOG" 2>/dev/null || true
	# Best-effort spawn: this hook runs under `set -e`, so guard the whole launch
	# with a trailing `|| true`. Plugin work is strictly off the critical path;
	# a failure to spawn the background job must NEVER abort container startup.
	if command -v setsid >/dev/null 2>&1; then
		setsid bash /usr/local/bin/seed-claude-plugins.sh </dev/null >>"$PLUGIN_BOOTSTRAP_LOG" 2>&1 &
	else
		# Fallback if setsid is somehow unavailable: still detach from the TUI.
		bash /usr/local/bin/seed-claude-plugins.sh </dev/null >>"$PLUGIN_BOOTSTRAP_LOG" 2>&1 &
	fi || true
	# Do not `wait`; the job is intentionally fire-and-forget.
fi
