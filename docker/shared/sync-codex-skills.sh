#!/usr/bin/env bash
# sync-codex-skills.sh — give Codex a START-TIME refresh of the 8 SHARED dev-skills
# so both agents converge on `Roubtec/agent-skills` main at the SAME cadence.
#
# THE FETCH ALREADY HAPPENED. Claude's plugin bootstrap (seed-claude-plugins.sh)
# keeps a full clone of the agent-skills marketplace on the shared claude-config
# volume at $CLAUDE_CONFIG_DIR/plugins/marketplaces/roubtec/, and refreshes it
# (`marketplace update` = git pull) on EVERY container start. That clone carries
# codex/dev-skills/skills/ — the Codex copies of the same 8 skills. So this is a
# LOCAL sync from that clone into the codex-config volume's skill dir: NO network
# op of its own, and it inherits the plugin channel's freshness. Codex's two
# powbox-specific skills (enable-worktrees, session-learnings) are NOT in the
# clone, so iterating the clone's names can only ever touch the 8 shared skills —
# those two stay exclusively bake-owned.
#
# INVOCATION MODEL — entrypoint-core.sh chains this DIRECTLY AFTER the detached
# seed-claude-plugins.sh run (same post-firewall `setsid` detach, stdin </dev/null,
# stdio → the bootstrap log), ordered AFTER the clone refresh and as a SEPARATE
# process from the plugin converge, so:
#   - the sync never touches the entrypoint's critical path (fully detached), and
#   - it never gates Claude's bounded plugin wait: that wait polls the plugin
#     run's OWN done-marker, which fires when seed-claude-plugins.sh exits, BEFORE
#     this sync starts. Unlike Claude (plugins enumerate once at session start),
#     Codex observes skill-file changes LIVE, so a refresh landing mid-session is
#     picked up with no wait needed.
#
# BEST-EFFORT CONTRACT: every step tolerates failure and this script NEVER exits
# non-zero into a caller that could abort startup. A missing clone (cold
# claude-config volume, plugin disabled, or a failed bootstrap) logs a skip and
# leaves the baked Codex copies in place. `set -e` is deliberately NOT used.
#
# CHURN AVOIDANCE (SHA-gated no-op): Codex warns loudly when skill files change
# under a running session, so an UNCHANGED palette must be a byte-for-byte no-op.
# Each refreshed marker records the agent-skills commit SHA actually synced; a
# start where the clone's HEAD already matches the recorded SHA writes nothing.
#
# OWNERSHIP: reuses seed-skills.sh's marker semantics. Only a skill whose
# .powbox-seeded marker is present (powbox owns that copy) is overwritten; a
# marker-less (user-adopted) skill is never touched. Provenance in the marker is
# the SYNCED agent-skills SHA (source=plugin-clone), so agent-update-skills and
# humans can see which channel last wrote the copy — see
# docs/skills-refresh-and-provenance.md for the precedence with the bake+seed
# refresher (last-writer-wins; the next start re-syncs forward as a cheap no-op).

set -uo pipefail

# Defense in depth: nothing here reads stdin, but a detached run should never
# inherit the container TTY as stdin. Swap a TTY for /dev/null ourselves so an
# ad-hoc manual run (`bash /usr/local/bin/sync-codex-skills.sh`) is safe too.
if [ -t 0 ]; then
	exec </dev/null
fi

# The shared seed primitives (marker semantics + atomic per-skill copy). Sourced,
# not reinvented, so this and the entrypoint hooks / updater never drift. Path is
# overridable for out-of-container unit testing.
POWBOX_SEED_SKILLS_LIB="${POWBOX_SEED_SKILLS_LIB:-/usr/local/bin/seed-skills.sh}"

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# The marketplace clone the Claude plugin bootstrap maintains, and the Codex-skill
# subtree within it. Overridable for tests.
CLONE_DIR="${POWBOX_CODEX_SKILL_CLONE:-$CLAUDE_CONFIG_DIR/plugins/marketplaces/roubtec}"
CLONE_SKILLS_DIR="$CLONE_DIR/codex/dev-skills/skills"

# The Codex on-volume skill dir (the ~/.agents/skills symlink target). Hardcoded
# default like update-skills-incontainer.sh — this detached run inherits the
# PRIMARY agent's env, which may be Claude's, so AGENT_CONFIG_DIR is unreliable
# here. Overridable for tests.
CODEX_SKILLS_DEST="${POWBOX_CODEX_SKILLS_DEST:-$HOME/.codex/agents/skills}"

# The Codex image-baked seed meta dir (build-epoch/build-commit), for the marker's
# epoch/commit baseline. Missing metadata degrades to placeholders in seed-skills.sh.
CODEX_SEED_META="${POWBOX_CODEX_SEED_META:-/home/node/.agent-container/codex}"

# Log to the SAME bootstrap log the Claude plugin run uses (entrypoint-core.sh
# passes it), so one boot's skill convergence — plugin + Codex sync — reads as one
# block. APPEND only; the log lives on the shared claude-config volume.
SYNC_LOG="${POWBOX_CODEX_SYNC_LOG:-${POWBOX_PLUGIN_LOG:-$CLAUDE_CONFIG_DIR/.powbox-plugin-bootstrap.log}}"

# Cross-container serialization on the SHARED codex-config volume. Like the
# claude-config volume, ~/.codex is a single global named volume mounted into
# every powbox container, so two containers booting at once would otherwise race
# the check-then-mutate on the same on-disk skill dir. Serialize with an flock on
# a lockfile that lives ON that volume (see run_locked), mirroring
# seed-claude-plugins.sh. Waiting the full LOCK_WAIT is fine — this run is
# detached, nothing is on any prompt's critical path.
LOCK_FILE="${POWBOX_CODEX_SYNC_LOCK_FILE:-$HOME/.codex/.powbox-codex-skill-sync.lock}"
LOCK_WAIT="${POWBOX_CODEX_SYNC_LOCK_WAIT:-300}"

# Never hang on an interactive git credential prompt: the only git op here is a
# read-only `rev-parse HEAD` on the LOCAL clone (no network), but keep this as a
# fail-fast guard so any unexpected prompt fails immediately.
export GIT_TERMINAL_PROMPT=0

# Debug channel: appends to the bootstrap log, never a terminal. stderr silenced
# FIRST so even a failed open of the log itself stays quiet (redirections apply
# left-to-right).
log() {
	printf '%s codex-skill-sync: %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo '-')" "$*" \
		2>/dev/null >>"$SYNC_LOG" || true
}

# codex_recorded_sha <dest_skill_dir> -> prints the agent-skills SHA recorded in the
# skill's .powbox-seeded marker, or nothing when absent/unrecorded. This is the
# SHA-gate's memory: an unchanged palette (recorded == clone HEAD) writes nothing.
codex_recorded_sha() {
	local marker="$1/$POWBOX_SEED_MARKER"
	[ -f "$marker" ] || return 0
	# Match a full `agent_skills_commit=<sha>` line; the SHA carries no `=`, so
	# cut -f2 is exact. head -1 guards a (malformed) duplicate.
	grep -a '^agent_skills_commit=' "$marker" 2>/dev/null | head -n1 | cut -d= -f2
}

run_locked() {
	# run_locked <wait-secs> <fn> — run <fn> holding an exclusive flock on the SHARED
	# codex-config volume, so concurrent containers cannot race the check-then-mutate.
	# Best-effort, mirroring seed-claude-plugins.sh:
	#   - no flock binary        -> run unlocked (degrade, never fail),
	#   - lockfile can't be opened -> run unlocked,
	#   - lock still held past    -> return 99 WITHOUT running: the holder is a peer
	#     <wait-secs>                container converging the SAME shared state for us.
	local lwait="$1"
	shift
	if ! command -v flock >/dev/null 2>&1; then
		"$@"
		return
	fi
	mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
	if ! exec 9>"$LOCK_FILE"; then
		log "could not open lock file $LOCK_FILE; proceeding without cross-container lock"
		"$@"
		return
	fi
	local rc
	if flock -w "$lwait" 9; then
		"$@"
		rc=$?
		flock -u 9
		exec 9>&- # release the lockfile fd
		return "$rc"
	fi
	exec 9>&-
	log "another container holds the codex-skill-sync lock after ${lwait}s; not running this pass (the holder is converging the shared state)"
	return 99
}

# converge_codex_skills — the check-then-mutate that run_locked serializes across
# containers sharing the codex-config volume. Reads the clone HEAD once, then for
# each of the clone's shared skills: skip user-owned copies (unmarked / non-dir),
# skip when the recorded SHA already matches (byte-for-byte no-op), else atomically
# replace + re-stamp with the synced SHA.
converge_codex_skills() {
	if [ ! -d "$CLONE_SKILLS_DIR" ]; then
		log "clone skills dir absent ($CLONE_SKILLS_DIR); leaving baked Codex copies in place (cold claude-config volume, plugin disabled, or bootstrap not run yet)"
		return 0
	fi

	# The agent-skills commit actually being synced — the marker's provenance and
	# the SHA-gate's key. Overridable for tests; otherwise read HEAD off the clone.
	local clone_sha="${POWBOX_CODEX_SKILL_CLONE_SHA:-}"
	if [ -z "$clone_sha" ]; then
		clone_sha="$(git -C "$CLONE_DIR" rev-parse HEAD 2>/dev/null)" || clone_sha=""
	fi
	if [ -z "$clone_sha" ]; then
		log "could not resolve clone HEAD in $CLONE_DIR; skipping (baked copies intact)"
		return 0
	fi

	# Marker body: the image bake's epoch/commit baseline (kept coherent with the
	# updater's marker) PLUS the channel provenance — the synced agent-skills SHA
	# and source=plugin-clone, so a human / agent-update-skills can see which
	# channel last wrote this copy.
	local marker
	marker="$(printf '%s\nagent_skills_commit=%s\nsource=plugin-clone\n' \
		"$(seed_marker_content "$CODEX_SEED_META")" "$clone_sha")"

	mkdir -p "$CODEX_SKILLS_DEST" 2>/dev/null || true

	local name target synced=0 skipped=0 rc=0
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		target="$CODEX_SKILLS_DEST/$name"
		# An existing entry may only be refreshed when it is a directory WE placed
		# (carries the marker). An unmarked dir, or any non-directory collision
		# (file/symlink), is user-adopted and never touched. -e misses dangling
		# symlinks, so test -L too.
		if [ -e "$target" ] || [ -L "$target" ]; then
			if ! { [ -d "$target" ] && seed_is_marked "$target"; }; then
				log "skip '$name': user-owned (unmarked or not a directory)"
				skipped=$((skipped + 1))
				continue
			fi
			# SHA-gate: an unchanged palette is a byte-for-byte no-op.
			if [ "$(codex_recorded_sha "$target")" = "$clone_sha" ]; then
				skipped=$((skipped + 1))
				continue
			fi
		fi
		# Absent, or marked-and-stale: atomic stage + rename (seed_skill), stamping
		# the synced-SHA marker. Keeps the mid-session write window minimal.
		if seed_skill "$CLONE_SKILLS_DIR/$name" "$target" "$marker"; then
			synced=$((synced + 1))
		else
			log "failed to sync '$name'"
			rc=1
		fi
	done < <(seed_skill_names "$CLONE_SKILLS_DIR")

	log "sync complete at agent-skills ${clone_sha}: ${synced} written, ${skipped} unchanged/skipped"
	return "$rc"
}

main() {
	if [ ! -r "$POWBOX_SEED_SKILLS_LIB" ]; then
		log "seed-skills.sh not found at $POWBOX_SEED_SKILLS_LIB; cannot sync (this is not the agent image?)"
		return 0
	fi
	# shellcheck source=docker/shared/seed-skills.sh
	# shellcheck disable=SC1090
	. "$POWBOX_SEED_SKILLS_LIB"
	run_locked "$LOCK_WAIT" converge_codex_skills
	return 0
}

# Run main only when executed, never when sourced — so the helpers above can be
# unit-tested in isolation (mirrors update-skills-incontainer.sh).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	main "$@"
	exit 0
fi
