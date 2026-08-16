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
# hold back the instruction file, nor the reverse. They also compare it
# DIFFERENTLY on purpose: the statusline demands a strictly newer image (-gt)
# because it is a byte copy of a baked file, so the same epoch can only produce
# the same bytes; the instruction file accepts an equal epoch (-ge) because its
# render is an envsubst of launch-time variables that can differ between two
# starts on one image.
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
#
# TWO INVARIANTS BELOW HOLD BY CONSTRUCTION, because auditing this block command
# by command kept missing cases and each miss was a silent, permanent one:
#
#   A. EVERY PUBLISH IS ATOMIC. Nothing here writes a live path in place: each
#      write goes to a mktemp sibling in the same directory and is renamed over
#      the target. So a reader — including another powbox container, since the
#      claude-config volume is SHARED by all of them — sees either the whole old
#      file or the whole new one, never a truncated middle, and any failure
#      leaves the original exactly as it was, which is what makes the "left as
#      found" note true. In-place `cp`/`>` opens the destination with O_TRUNC, so
#      a failure AFTER that open (ENOSPC, EIO) left a corrupt statusline behind
#      while the marker still swore to the old digest — permanently reclassifying
#      an untouched file as a user customization — and let a peer container read
#      a half-written marker.
#   B. NO FAILURE CAN END STARTUP. The whole decision lives in
#      statusline_seed_step, invoked below as `(statusline_seed_step) || true`.
#      Both halves are load-bearing. The `|| true` discards the step's own exit
#      status, and bash suspends `set -e` for every command inside a function
#      run as part of an AND-OR list, so no failing command in here aborts the
#      hook part-way. The SUBSHELL covers what no status can: a fatal shell
#      error — a `set -u` read of an unset variable, a `local` outside a
#      function, an assignment to a readonly name — kills the shell it runs in
#      outright, straight through an AND-OR list, and the parentheses are what
#      make that shell a CHILD. So invariant B holds by construction rather than
#      by every future edit remembering it. This hook runs under
#      `set -euo pipefail` (line 2) and entrypoint-core.sh invokes it UNGUARDED,
#      so anything escaping this block ends container startup — no instruction
#      file, no settings.json, no CMD — over a cosmetic asset. The fork costs
#      nothing but itself, because the step's entire product is on disk: no
#      variable it sets is read below (IMAGE_EPOCH is, but it is assigned above,
#      at line 55, and the step only reads it). Out of reach of both halves: a
#      PARSE error in this file, which bash rejects before the step ever runs;
#      the guard for that is `bash -n` and the linter, not this structure.
#
# Every failure therefore resolves the same way: keep what is on disk, carry on.
STATUSLINE_SRC="$AGENT_SEED_DIR/statusline-command.sh"
STATUSLINE_DST="$AGENT_CONFIG_DIR/statusline-command.sh"
# Sidecar name mirrors seed_workflow_marker_path() in seed-skills.sh: a lone file
# has no "inside" to hold its marker, so it gets a hidden sibling.
STATUSLINE_MARKER="$AGENT_CONFIG_DIR/.statusline-command.sh.powbox-seeded"
# The statusline is powbox's OWN asset, so its `source=` names this repo rather
# than one of seed-skills.sh's Roubtec/agent-skills roots (see
# docs/skills-refresh-and-provenance.md D8 on per-call-site source roots).
STATUSLINE_SOURCE="Roubtec/powbox#docker/claude/agent-container/statusline-command.sh"

# Prints the file's sha256, or nothing when it cannot be computed (unreadable
# file, or an image without coreutils' sha256sum). Every call site is a bare
# command substitution, so "cannot compute" has to arrive as an empty value.
# The `|| true` sits on the PIPELINE rather than on sha256sum because `pipefail`
# is what would otherwise carry the left-hand failure out; invariant B already
# contains any status, but these helpers keep their own guard so they stay safe
# to call from anywhere in this hook, not only from inside the step.
statusline_digest() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true
}

# Prints one key's value from a key=value marker, or nothing when the marker
# cannot be read. Marker readers MUST parse by key, never by line number or
# count — the `.powbox-seeded` contract in docs/skills-refresh-and-provenance.md
# D8, which this marker joins. Self-guarded for the reason given above.
statusline_marker_value() {
	sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 || true
}

# statusline_publish <src> <dst> — invariant A for a file copy: land <src>'s
# bytes at <dst> or change nothing. Non-zero means <dst> was not touched.
# BOUNDED, both deliberate: the rename REPLACES the destination inode, so mode
# comes from <src> when the best-effort chmod below succeeds and stays mktemp's
# 0600 when it does not, while ownership, ACLs and xattrs are the temp's rather
# than the old file's preserved ones as `cp` would leave them — sound only
# because this is a single-uid volume and nothing in the image sets ACLs,
# xattrs or SELinux labels. And a kill between the mktemp and the rename leaves
# an unreaped `statusline-command.sh.XXXXXX` sibling; only the failure paths
# below clean up.
statusline_publish() {
	local src="$1" dst="$2" tmp rc=1
	tmp="$(mktemp "$dst.XXXXXX" 2>/dev/null || true)"
	[ -n "$tmp" ] || return 1
	if cp "$src" "$tmp" 2>/dev/null; then
		# mktemp creates 0600, so the source's mode has to be copied across or
		# the publish would quietly drop the statusline's executable bit — a
		# cosmetic loss only, since statusline-settings.json runs the file as
		# `sh <path>`. Best-effort for exactly that reason: content is worth
		# publishing even where chmod cannot follow.
		chmod --reference="$src" "$tmp" 2>/dev/null || true
		# -T: a destination that IS a directory must FAIL here rather than
		# absorb the temp. Defense in depth for THIS caller — both branches of
		# statusline_seed_step exclude a directory, and a symlink to one, before
		# reaching the publish — but the contract above is the function's, not
		# the step's. The symlink shape that DOES arrive is a link to a regular
		# file, which the rename replaces rather than writing through.
		mv -T "$tmp" "$dst" 2>/dev/null && rc=0
	fi
	[ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null
	return "$rc"
}

# statusline_write_marker <body> — invariant A for the sidecar. <body> must
# already carry its trailing newline; the marker is published whole or not at
# all, so a peer container reading it mid-rewrite can never see a marker that
# has lost `epoch=`/`sha256=`. Here `-T` is load-bearing for the STATUS: a plain
# `mv` onto a marker path that is a DIRECTORY moves the temp INSIDE it and exits
# 0, so this reported a marker published nowhere, and left a stray file behind.
statusline_write_marker() {
	local tmp rc=1
	tmp="$(mktemp "$STATUSLINE_MARKER.XXXXXX" 2>/dev/null || true)"
	[ -n "$tmp" ] || return 1
	if printf '%s' "$1" >"$tmp" 2>/dev/null; then
		mv -T "$tmp" "$STATUSLINE_MARKER" 2>/dev/null && rc=0
	fi
	[ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null
	return "$rc"
}

# statusline_note_once <message> — one non-fatal line on stderr, at most once
# per image. `notified_epoch=` records the newest image this statusline has
# already spoken about, for ANY reason (a customized file, a destination that
# could not be written): both of those branches stay true on every later start,
# since nothing publishes and `epoch=` never advances, so an unthrottled note
# nags once per start. Separate key, so `epoch=` keeps meaning "the build that
# placed this file"; a successful refresh rewrites the marker without it, and
# the next image is announced afresh. No marker means nowhere to record the
# note, so it repeats.
statusline_note_once() {
	local told kept body rc=0
	if [ -f "$STATUSLINE_MARKER" ]; then
		told="$(statusline_marker_value "$STATUSLINE_MARKER" notified_epoch)"
		[[ "$told" =~ ^[0-9]+$ ]] || told=0
		[ "$IMAGE_EPOCH" -gt "$told" ] || return 0
	fi
	echo "$1" >&2
	kept="$(grep -v '^notified_epoch=' "$STATUSLINE_MARKER" 2>/dev/null)" || rc=$?
	# grep's status is checked, never masked, and ONLY 0 may publish. 1 = no line
	# survived, which for a marker that carried `epoch=`/`sha256=` moments ago
	# can only mean a peer container on the shared volume rewrote it underneath
	# us; >=2 = it could not be read at all (or there is none). Publishing on
	# either would leave a marker holding only `notified_epoch=`, erasing
	# `epoch=`/`sha256=` and unmarking the file for good — the exact outcome this
	# rewrite exists to avoid. Abandon; the worst case is one more note.
	if [ "$rc" -eq 0 ]; then
		printf -v body '%s\nnotified_epoch=%s\n' "$kept" "$IMAGE_EPOCH"
		statusline_write_marker "$body"
	fi
	return 0
}

seed_statusline() {
	local digest commit body
	# A rename does NOT need write permission on the file it replaces, so the
	# atomic publish would happily overwrite a statusline the user made
	# read-only. That is a deliberate "leave this alone" signal the contract
	# predating invariant A honoured, so it is checked explicitly rather than
	# left to the copy's own failure. Either way the destination keeps what it
	# holds and startup continues; one non-fatal line says so, because silence
	# here is indistinguishable from a successful refresh — throttled per image,
	# since this branch stays true on every later start.
	if { [ -e "$STATUSLINE_DST" ] && [ ! -w "$STATUSLINE_DST" ]; } ||
		! statusline_publish "$STATUSLINE_SRC" "$STATUSLINE_DST"; then
		statusline_note_once "Note: could not write $STATUSLINE_DST; left as found."
		return 0
	fi
	# Digest the SOURCE, not the destination just written: the publish lands
	# <src>'s bytes verbatim, so the two are equal by construction, while
	# re-reading the live file would let a concurrent write in that window be
	# recorded as powbox's own and licence a later overwrite of the user's bytes.
	digest="$(statusline_digest "$STATUSLINE_SRC")"
	# Without a digest there is no provable identity, so publish no marker — and
	# drop any marker already there, whose `sha256=` now names bytes that have
	# just been replaced. A stale marker is worse than none: it reads as "the
	# user edited this" and nags about a file powbox itself wrote, where an
	# unmarked file is merely never refreshed. Only reachable on an image missing
	# coreutils' sha256sum.
	if [ -z "$digest" ]; then
		rm -f "$STATUSLINE_MARKER" 2>/dev/null
		return 0
	fi
	commit="$(cat "$AGENT_SEED_DIR/build-commit" 2>/dev/null || echo unknown)"
	[ -n "$commit" ] || commit=unknown
	printf -v body 'epoch=%s\ncommit=%s\nsha256=%s\nsource=%s\n' \
		"$IMAGE_EPOCH" "$commit" "$digest" "$STATUSLINE_SOURCE"
	# Same reasoning as above for a marker that cannot be published at all: leave
	# no proof rather than a false one. BOUNDED: an interruption between the
	# publish above and this rewrite leaves the new bytes under the old marker,
	# and the next start then reads powbox's own copy as customized — one note
	# per image, never refreshed — until the file is deleted. Dropping the marker
	# FIRST would make that window leave the honest unmarked state, but would
	# also unmark the file on every ORDINARY publish failure (read-only file,
	# ENOSPC), losing the refresh path and the throttle for good. The order stays.
	# The same misclassification is reachable WITHOUT a crash, between CONTAINERS:
	# each publish is atomic on its own, but the file and the marker are two
	# renames, so peers starting from different newer images can interleave them
	# and leave one peer's bytes under the other's marker. Deliberately not
	# serialized: an flock like the DETACHED plugin bootstrap's (run_locked in
	# seed-claude-plugins.sh, which can wait patiently) would sit on the
	# SYNCHRONOUS startup path here, and would still not bind a peer running an
	# older hook. Same self-announcing, delete-to-recover outcome as above.
	if ! statusline_write_marker "$body"; then
		rm -f "$STATUSLINE_MARKER" 2>/dev/null
	fi
}

# statusline_seed_step — the entire statusline decision. See invariant B: this
# is called as `(statusline_seed_step) || true` and MUST stay called that way,
# parentheses included — they are what contain a fatal shell error.
statusline_seed_step() {
	local epoch want have
	[ -f "$STATUSLINE_SRC" ] || return 0
	if [ ! -e "$STATUSLINE_DST" ] && [ ! -L "$STATUSLINE_DST" ]; then
		seed_statusline
		return 0
	fi
	# `-f` RESOLVES symlinks: a marked symlink to a regular file counts as regular
	# here, and a refresh then REPLACES the link with a real file rather than
	# writing through it as the `cp` this grew out of did. Deliberate — a rename
	# cannot be redirected into an arbitrary path — and stated in the README for
	# anyone linking this into a dotfiles checkout. The shapes that DO fall
	# through untouched: a directory, a FIFO or socket, a dangling symlink, and
	# any unmarked file (the pre-marker upgrade path). `-e || -L` rather than `-f`
	# on the seed branch above so those are never resolved through or copied INTO.
	[ -f "$STATUSLINE_DST" ] && [ -f "$STATUSLINE_MARKER" ] || return 0
	epoch="$(statusline_marker_value "$STATUSLINE_MARKER" epoch)"
	[[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
	[ "$IMAGE_EPOCH" -gt "$epoch" ] || return 0
	want="$(statusline_marker_value "$STATUSLINE_MARKER" sha256)"
	have="$(statusline_digest "$STATUSLINE_DST")"
	if [ -z "$want" ] || [ -z "$have" ]; then
		# No proof either way: a marker carrying no `sha256=` key, or a digest
		# that could not be computed. Answer as for an unmarked file — keep it,
		# say nothing. A note here would assert a difference powbox has not
		# established, and offer a deletion that could destroy an untouched file.
		return 0
	fi
	# BOUNDED, and the sharpest residual in this block: the proof above and the
	# rename that acts on it are two steps, so a writer that changes the file in
	# between has its bytes replaced, and seed_statusline then records the SOURCE
	# digest — the marker certifies the overwrite as powbox's own, so nothing is
	# said and nothing is recoverable. Every other residual here is cosmetic and
	# self-announcing; this one destroys the user's work. Task 002h does not close
	# it: that lock binds powbox's publishers, and the writer here is an arbitrary
	# one (an editor in a peer container on this SHARED volume) that takes no lock.
	# Left standing rather than half-guarded because rename(2) has no conditional
	# form, so a re-check narrows the gap while reading as though it closed it;
	# task 002i settles which of narrowing, recovery or acceptance this should be.
	# The same gap sits between the fresh-seed branch's existence test above and
	# its publish, where `ln`'s EEXIST could close it outright.
	if [ "$have" = "$want" ]; then
		seed_statusline
		return 0
	fi
	# The user made it theirs. Say so once per image, not once per start; the
	# throttle and its `notified_epoch=` bookkeeping live in statusline_note_once.
	statusline_note_once "Note: this image ships a newer statusline, but $STATUSLINE_DST differs from the copy powbox seeded, so it was kept. Delete it to take the new one."
	return 0
}

(statusline_seed_step) || true

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
