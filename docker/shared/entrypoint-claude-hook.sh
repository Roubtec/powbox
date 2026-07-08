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
# SYNCHRONOUS, but bounded — and only the COLD case actually runs work in the
# foreground (see seed-claude-plugins.sh for the full rationale). The agent-skills
# repo is PUBLIC, so `claude plugin marketplace add` clones it anonymously with no
# git credential helper — there is no dependency on `gh auth setup-git` and hence no
# auth-ordering race, which is what previously forced this whole job to detach and
# wait for that helper. So we call the script inline:
#   - on a COLD (fresh) claude-config volume the script installs the plugin in the
#     FOREGROUND — bounded by ~COLD_INSTALL_BOUND + COLD_LOCK_WAIT plus the two
#     LIST_TIMEOUT-bounded `claude plugin list` state queries (the routing query and
#     the authoritative one under the lock), i.e. a worst case of ~COLD_INSTALL_BOUND +
#     COLD_LOCK_WAIT + 2*LIST_TIMEOUT — before we return and the entrypoint `exec`s
#     claude, so the /dev-skills:* skills are live in the FIRST session; on
#     timeout/lock-miss it detaches the remainder to a background self-heal and returns,
#     so start is never wedged. This foreground cold path is taken ONLY when Claude is
#     the PRIMARY agent (we pass POWBOX_PLUGIN_ALLOW_SYNC_COLD below): a non-primary
#     Claude backgrounds the install so it never runs network ops ahead of the firewall
#     or delays the primary (Codex) prompt for skills that session never uses;
#   - on a WARM volume the script self-backgrounds the cheap keep-current and returns
#     immediately, adding no start latency.
# stdout is left attached to the terminal so the script's single concise status line
# is visible before Claude grabs the alternate screen buffer; stderr and all debug go
# to the LOG FILE. Read it to see what happened: cat the log path below.
if command -v claude >/dev/null 2>&1 && [ -x /usr/local/bin/seed-claude-plugins.sh ]; then
	PLUGIN_BOOTSTRAP_LOG="$AGENT_CONFIG_DIR/.powbox-plugin-bootstrap.log"
	# Authorize the SYNCHRONOUS cold foreground install ONLY when Claude is the PRIMARY
	# agent. When Claude is primary this hook runs from entrypoint-core.sh — AFTER
	# init-firewall.sh — and the launching session is the Claude one whose first prompt
	# wants the skills live. When Claude is NON-PRIMARY (PRIMARY_AGENT=codex) this hook
	# runs during entrypoint-agent.sh's non-primary seeding, BEFORE the firewall is up and
	# BEFORE the primary (Codex) prompt; a foreground cold install there would run network
	# ops ahead of the firewall and delay Codex startup for a plugin set that session never
	# uses. So the non-primary case backgrounds the install (self-heals into the next, i.e.
	# first real, Claude session). Default-primary when PRIMARY_AGENT is unset (hand runs).
	if [ "${PRIMARY_AGENT:-claude}" = claude ]; then
		PLUGIN_ALLOW_SYNC_COLD=1
		PLUGIN_COLD_MODE="synchronous (primary Claude)"
	else
		PLUGIN_ALLOW_SYNC_COLD=0
		PLUGIN_COLD_MODE="backgrounded (non-primary Claude)"
	fi
	# APPEND, never truncate. This log lives on the claude-config volume, which is a
	# SINGLE named volume shared by EVERY powbox container (see seed-claude-plugins.sh's
	# cross-container note). A `: >` truncation on each start would wipe a PEER
	# container's in-progress bootstrap log, making concurrent-bootstrap debugging
	# unreliable. Prepend a dated, container-tagged separator so each boot's block
	# stays easy to find in the appended file instead.
	{
		echo "===== $(date -u +%FT%TZ 2>/dev/null || echo '-') claude-hook plugin bootstrap (${CONTAINER_NAME:-${HOSTNAME:-?}}) ====="
		echo "[claude-hook] dev-skills@roubtec plugin: converging (cold install ${PLUGIN_COLD_MODE}, warm keep-current backgrounded; log: $PLUGIN_BOOTSTRAP_LOG)"
	} >>"$PLUGIN_BOOTSTRAP_LOG" 2>/dev/null || true
	# Best-effort: this hook runs under `set -e`, so guard the call with a trailing
	# `|| true`. Plugin work is strictly off the critical path — a failure here must
	# NEVER abort container startup, and the script itself is bounded so a synchronous
	# call cannot wedge the prompt. POWBOX_PLUGIN_LOG points the script's debug log at
	# the same shared file; stderr is folded into it while stdout stays on the terminal.
	# SC2094: the env var and the stderr redirect name the same path, but the script
	# does not read that file — it only appends — so there is no read/write conflict.
	# shellcheck disable=SC2094
	POWBOX_PLUGIN_LOG="$PLUGIN_BOOTSTRAP_LOG" \
		POWBOX_PLUGIN_ALLOW_SYNC_COLD="$PLUGIN_ALLOW_SYNC_COLD" \
		bash /usr/local/bin/seed-claude-plugins.sh 2>>"$PLUGIN_BOOTSTRAP_LOG" || true
fi
