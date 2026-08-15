#!/usr/bin/env bash
set -euo pipefail

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:?AGENT_CONFIG_DIR must be set}"
# Directory holding this agent's image-baked seed assets (instruction template,
# statusline, skills, build epoch). Defaults to the legacy shared path so the
# hook still works if run standalone; the unified entrypoint points it at the
# per-agent subdirectory /home/node/.agent-container/<agent>.
AGENT_SEED_DIR="${AGENT_SEED_DIR:-/home/node/.agent-container}"

# Directory holding the detached bootstrap scripts the build-skew shim launches
# (seed-claude-plugins.sh, sync-codex-skills.sh). Production leaves it at the baked
# /usr/local/bin; overridable ONLY so scripts/test-claude-hook-skew.sh can point it
# at a stub dir and exercise the marker-gating without root-writable paths.
POWBOX_BOOT_BIN="${POWBOX_BOOT_BIN:-/usr/local/bin}"

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
	if jq -s '.[0] * .[1]' "$base" "$overlay" >"$tmp"; then
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

# Read once, above BOTH epoch-gated steps below (the statusline refresh and the
# instruction/settings render), because the statusline block now needs it and
# runs first. The two steps stay INDEPENDENT: each compares this value against
# its OWN recorded epoch (the statusline's sidecar marker vs. .instruction-epoch)
# and stamps only its own, so a statusline held back for being customized cannot
# hold back the instruction file, nor the reverse.
IMAGE_EPOCH=$(cat "$AGENT_SEED_DIR/build-epoch" 2>/dev/null || echo 0)
[[ "$IMAGE_EPOCH" =~ ^[0-9]+$ ]] || IMAGE_EPOCH=0

# --- Statusline seeding -------------------------------------------------------
# The baked statusline is deliberately opinionated and users are expected to edit
# it, so a newer image may replace only a copy powbox can PROVE is still its own.
# A running container holds no copy of the previous image's file, so that proof
# has to be a digest recorded at seed time: the sidecar marker carries the sha256
# of exactly what was written. A file that no longer matches is the user's, and a
# file with no marker at all — every volume predating this mechanism — cannot be
# proven either way and is likewise left alone; it adopts the mechanism the first
# time the file is deleted and re-seeded.
STATUSLINE_SRC="$AGENT_SEED_DIR/statusline-command.sh"
STATUSLINE_DST="$AGENT_CONFIG_DIR/statusline-command.sh"
# Sidecar name mirrors seed_workflow_marker_path() in seed-skills.sh: a lone file
# has no "inside" to hold its marker, so it gets a hidden sibling.
STATUSLINE_MARKER="$AGENT_CONFIG_DIR/.statusline-command.sh.powbox-seeded"
# The statusline is powbox's OWN asset, so its `source=` names this repo rather
# than one of seed-skills.sh's Roubtec/agent-skills roots (see
# docs/skills-refresh-and-provenance.md D8 on per-call-site source roots).
STATUSLINE_SOURCE="Roubtec/powbox#docker/claude/agent-container/statusline-command.sh"

# Prints the file's sha256, or nothing when it cannot be computed.
statusline_digest() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# Prints one key's value from a key=value marker. Marker readers MUST parse by
# key, never by line number or count — the `.powbox-seeded` contract in
# docs/skills-refresh-and-provenance.md D8, which this marker joins.
statusline_marker_value() {
	sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}

# Copy the baked statusline over the destination and stamp the marker.
seed_statusline() {
	local digest commit
	cp "$STATUSLINE_SRC" "$STATUSLINE_DST"
	digest="$(statusline_digest "$STATUSLINE_DST")"
	# Without a digest there is no provable identity, so write no marker at all:
	# an unmarked file is never refreshed, which is the safe direction. Only
	# reachable on an image missing coreutils' sha256sum.
	[ -n "$digest" ] || return 0
	commit="$(cat "$AGENT_SEED_DIR/build-commit" 2>/dev/null || echo unknown)"
	[ -n "$commit" ] || commit=unknown
	printf 'epoch=%s\ncommit=%s\nsha256=%s\nsource=%s\n' \
		"$IMAGE_EPOCH" "$commit" "$digest" "$STATUSLINE_SOURCE" \
		>"$STATUSLINE_MARKER" || true
}

if [ -f "$STATUSLINE_SRC" ]; then
	if [ ! -f "$STATUSLINE_DST" ]; then
		seed_statusline
	elif [ -f "$STATUSLINE_MARKER" ]; then
		_sl_epoch="$(statusline_marker_value "$STATUSLINE_MARKER" epoch)"
		[[ "$_sl_epoch" =~ ^[0-9]+$ ]] || _sl_epoch=0
		if [ "$IMAGE_EPOCH" -gt "$_sl_epoch" ]; then
			_sl_want="$(statusline_marker_value "$STATUSLINE_MARKER" sha256)"
			_sl_have="$(statusline_digest "$STATUSLINE_DST")"
			if [ -n "$_sl_want" ] && [ "$_sl_have" = "$_sl_want" ]; then
				seed_statusline
			else
				# The user made it theirs. Say so ONCE PER IMAGE, not once per
				# start: `notified_epoch=` records the newest image whose offer
				# was already declined. It is a separate key precisely so
				# `epoch=` keeps meaning "the build that placed this file".
				_sl_told="$(statusline_marker_value "$STATUSLINE_MARKER" notified_epoch)"
				[[ "$_sl_told" =~ ^[0-9]+$ ]] || _sl_told=0
				if [ "$IMAGE_EPOCH" -gt "$_sl_told" ]; then
					echo "Note: this image ships a newer statusline, but $STATUSLINE_DST differs from the copy powbox seeded, so it was kept. Delete it to take the new one." >&2
					if {
						grep -v '^notified_epoch=' "$STATUSLINE_MARKER" || true
						printf 'notified_epoch=%s\n' "$IMAGE_EPOCH"
					} >"$STATUSLINE_MARKER.tmp" 2>/dev/null; then
						mv "$STATUSLINE_MARKER.tmp" "$STATUSLINE_MARKER" 2>/dev/null || true
					fi
					rm -f "$STATUSLINE_MARKER.tmp" 2>/dev/null || true
				fi
				unset _sl_told
			fi
			unset _sl_want _sl_have
		fi
		unset _sl_epoch
	fi
fi

AGENT_TMPL="$AGENT_SEED_DIR/agent.md.tmpl"
if [ -f "$AGENT_TMPL" ]; then
	VOLUME_EPOCH=$(cat "$AGENT_CONFIG_DIR/.instruction-epoch" 2>/dev/null || echo 0)
	[[ "$VOLUME_EPOCH" =~ ^[0-9]+$ ]] || VOLUME_EPOCH=0
	if [ "$IMAGE_EPOCH" -ge "$VOLUME_EPOCH" ]; then
		# envsubst needs literal ${VAR} names, not shell-expanded values
		# shellcheck disable=SC2016
		envsubst '${AGENT_NAME} ${AGENT_AUTONOMY_FLAG} ${AGENT_CONFIG_DIR} ${AGENT_PEERS}' \
			<"$AGENT_TMPL" >"$AGENT_CONFIG_DIR/${AGENT_INSTRUCTION_FILE:?}"

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

		# No baked Claude skills or workflows are seeded here anymore: powbox
		# forfeited its Claude skills (enable-worktrees, session-learnings) and the
		# wf-* dynamic workflows to Roubtec/agent-skills, so every Claude skill and
		# workflow now arrives through the dev-skills@roubtec plugin channel
		# (namespaced, e.g. /dev-skills:session-learnings, /dev-skills:wf-address-tasks;
		# see seed-claude-plugins.sh below). Previously-seeded copies on the volume
		# (marked .powbox-seeded, in-folder for skills / sidecar for workflows) are
		# classified as orphans and retired by `agent-update-skills --prune` — the
		# updater's orphan sweep runs even though the baked source dirs are gone.
		echo "$IMAGE_EPOCH" >"$AGENT_CONFIG_DIR/.instruction-epoch"
	fi
fi

# The dev-skills@roubtec plugin (every Claude skill and wf-* workflow; task 015b
# stopped baking the shared skills and the forfeit moved the rest) is
# deliberately NOT converged here on current images.
# entrypoint-core.sh does it for EVERY launch — after init-firewall.sh (network
# ordering) and fully DETACHED, because the claude CLI hangs (SIGTERM-immune)
# when invoked with the container TTY as stdin, so no `claude plugin …` call may
# ever run on the entrypoint's critical path (see seed-claude-plugins.sh for the
# full rationale). A core that owns a bootstrap announces it by exporting the
# matching handshake before invoking this hook.
#
# BUILD-SKEW SHIM. entrypoint-core.sh is baked into the BASE image; this hook is
# baked into the AGENT layer. The common `cc --build` path rebuilds only the agent
# layer over an existing base, so this hook can run under an OLDER core that failed
# to perform one — OR BOTH — of two independent detached convergence duties this
# hook must then cover for primary Claude:
#   1. the dev-skills@roubtec plugin bootstrap, and
#   2. the Codex shared-skill sync (task 021).
# Each duty has its OWN handshake marker from a core that owns it —
# POWBOX_PLUGIN_BOOTSTRAP=core and POWBOX_CODEX_SYNC_BOOTSTRAP=core — and is gated
# INDEPENDENTLY on its marker being absent. Separate markers are ESSENTIAL: the
# current-main base core already sets the PLUGIN marker (it runs
# seed-claude-plugins.sh) but does NOT chain the Codex sync (that landed with task
# 021), so a single reused marker would make an agent-only rebuild over that base
# read "core owns it" and skip the sync entirely — silently stopping Codex
# convergence for the common `cc --build` / agent-version-bump case. With split
# markers: a NEW core sets both, so this hook skips both (no double-run); the
# CURRENT base sets only the plugin marker, so this hook still runs the sync; an
# ANCIENT base sets neither, so this hook runs both (plugin first, so the sync then
# reads the just-refreshed clone).
#
# Ordering holds — as primary Claude's setup hook we are invoked BY core AFTER
# init-firewall.sh. (Non-primary Claude's hook run happens pre-firewall from
# entrypoint-agent.sh, but there PRIMARY_AGENT != claude, so the gate below skips
# it and the old core still converges non-primary Claude itself, post-firewall.)
# The writer guard is defense-in-depth: the launcher clears AGENT_SETUP_HOOK for
# that role, so this hook should never run there at all. No done-marker/bounded
# wait here: the old core has no waiter, so a refresh simply lands next session —
# the shim restores convergence, not the same-session wait. Harmless if ever run
# redundantly or standalone: both scripts are detached, bounded, flock-serialized,
# idempotent, and self-defend their stdin against a TTY.
#
# RESIDUAL GAP (Codex-PRIMARY, agent-only rebuild over the current base): this hook
# only fires for PRIMARY_AGENT=claude. On a Codex-primary launch it runs pre-firewall
# as non-primary Claude's seeding (PRIMARY_AGENT != claude), so the sync-fallback is
# skipped — and the old base core does not chain the sync either — so the Codex sync
# runs nowhere until a full base rebuild picks up the new core (which chains it for
# every launch, primary-agnostic). This mirrors the plugin's own non-primary handling
# and is bounded by the same best-effort contract: it self-heals on the next base
# rebuild or any Claude-primary start on this base. It is not cleanly closable from the
# Claude hook (wrong PRIMARY_AGENT, wrong firewall phase), so it is documented here
# rather than papered over.
_do_plugin_bootstrap=false
if [ "${POWBOX_PLUGIN_BOOTSTRAP:-}" != core ]; then
	_do_plugin_bootstrap=true
fi
_do_codex_sync=false
if [ "${POWBOX_CODEX_SYNC_BOOTSTRAP:-}" != core ] && [ -x "$POWBOX_BOOT_BIN/sync-codex-skills.sh" ]; then
	_do_codex_sync=true
fi
if { [ "$_do_plugin_bootstrap" = true ] || [ "$_do_codex_sync" = true ]; } &&
	[ "${PRIMARY_AGENT:-claude}" = claude ] &&
	[ "${POWBOX_IMAGE_STORE_ROLE:-}" != "writer" ] &&
	command -v claude >/dev/null 2>&1 && [ -x "$POWBOX_BOOT_BIN/seed-claude-plugins.sh" ]; then
	# For primary Claude, AGENT_CONFIG_DIR IS Claude's config dir, so this is the
	# same shared-volume log the core path appends to. APPEND, never truncate
	# (see the core block: the claude-config volume is shared by every powbox
	# container, so truncation would wipe a peer's in-progress bootstrap log).
	_claude_plugin_log="$AGENT_CONFIG_DIR/.powbox-plugin-bootstrap.log"
	# stderr first: a failed open of the log itself must stay silent too
	# (redirections apply left-to-right).
	{
		echo "===== $(date -u +%FT%TZ 2>/dev/null || echo '-') claude-hook build-skew convergence (${CONTAINER_NAME:-${HOSTNAME:-?}}) ====="
		echo "[claude-hook] no core handshake for one or more duties (older base image?); converging post-firewall, detached (plugin=$_do_plugin_bootstrap codex-sync=$_do_codex_sync; log: $_claude_plugin_log)"
	} 2>/dev/null >>"$_claude_plugin_log" || true
	# SC2094: POWBOX_PLUGIN_LOG and the stdio redirect name the same path, but the
	# scripts only append to it (never read), so there is no read/write conflict.
	# stderr first on the launch too: a failed open of the log must stay silent (the
	# spawn is then skipped); on success the trailing 2>&1 re-points the sequence's
	# stderr back into the log.
	#
	# The detached sequence runs whichever duties this hook must cover, in order:
	# the plugin bootstrap (refreshes the marketplace clone) FIRST, then the Codex
	# sync reads that freshest clone. Each step is gated by a flag passed positionally
	# to the inner `bash -c` ($2 = do-plugin, $3 = do-sync) so the single-quoted body
	# stays static; $1 is the shared log and $4 the boot-script dir, both expanded by
	# the inner shell, not here. The Codex step re-checks the script's presence for
	# defense in depth.
	# shellcheck disable=SC2016
	_plugin_boot_seq='
			if [ "$2" = true ]; then
				POWBOX_PLUGIN_LOG="$1" \
					bash "$4/seed-claude-plugins.sh" </dev/null
			fi
			if [ "$3" = true ] && [ -x "$4/sync-codex-skills.sh" ]; then
				POWBOX_CODEX_SYNC_LOG="$1" \
					bash "$4/sync-codex-skills.sh" </dev/null
			fi
	'
	if command -v setsid >/dev/null 2>&1; then
		# shellcheck disable=SC2094
		setsid bash -c "$_plugin_boot_seq" _ "$_claude_plugin_log" \
			"$_do_plugin_bootstrap" "$_do_codex_sync" "$POWBOX_BOOT_BIN" \
			</dev/null 2>/dev/null >>"$_claude_plugin_log" 2>&1 &
	else
		# Fallback if setsid is somehow unavailable: still detach from the hook.
		# shellcheck disable=SC2094
		bash -c "$_plugin_boot_seq" _ "$_claude_plugin_log" \
			"$_do_plugin_bootstrap" "$_do_codex_sync" "$POWBOX_BOOT_BIN" \
			</dev/null 2>/dev/null >>"$_claude_plugin_log" 2>&1 &
	fi
	unset _claude_plugin_log _plugin_boot_seq
fi
unset _do_plugin_bootstrap _do_codex_sync
