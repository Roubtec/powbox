#!/usr/bin/env bash
# seed-claude-plugins.sh — bring the shared Claude skills into a container via the
# SAME channel colleagues use: the `dev-skills@roubtec` plugin, served from the
# Roubtec/agent-skills marketplace. Task 015b stopped baking those 8 skills into
# the image; this script is what brings them back, NAMESPACED (they arrive as
# `/dev-skills:<name>`, e.g. `/dev-skills:address-review` — the model-side
# Skill-tool matching by description is unaffected, only the slash-command muscle
# memory changes; see task 015d docs).
#
# INVOCATION MODEL — entrypoint-core.sh runs this DETACHED (setsid, stdin
# </dev/null, stdout/stderr to the bootstrap log) immediately AFTER
# init-firewall.sh, for EVERY launch, whether Claude is the primary agent or not.
# Nothing plugin-related ever runs on the entrypoint's critical path. That is a
# CORRECTNESS requirement, not just latency hygiene: the claude CLI HANGS
# (SIGTERM-immune; only `timeout --kill-after`'s SIGKILL ends it) when invoked
# with the container TTY as stdin, so even the read-only `claude plugin list
# --json` routing query the previous synchronous model (task 015g) ran in the
# foreground burned its full LIST_TIMEOUT+KILL_AFTER bound on EVERY warm
# primary-Claude start — and the synchronous cold install it was routing to never
# survived a TTY launch either (it hung the same way, timed out, and deferred to
# the background self-heal, so first-session skill availability was paid for but
# never delivered). Hence: callers SHOULD detach and redirect stdin away from the
# TTY; a manual run is best done the same way
# (`bash /usr/local/bin/seed-claude-plugins.sh </dev/null`). As DEFENSE IN DEPTH
# the script also swaps a TTY stdin for /dev/null itself (see below), so an
# ad-hoc run or a future call site that forgets to detach cannot reintroduce the
# hang — correctness must not hinge on every caller remembering the redirect.
#
# The entrypoint pairs the detached run with a BOUNDED, marker-based wait just
# before it execs the agent (see POWBOX_PLUGIN_DONE_FILE below): a warm refresh
# typically finishes within that window, so updated skills usually apply THIS
# session. Past the cap the session simply starts on the volume's current state:
# a COLD (fresh) claude-config volume's install usually outlives the cap, so its
# first session lacks the /dev-skills:* skills until a /reload-plugins or
# restart, and a slow warm refresh lands one session late (Claude enumerates
# plugins once at startup). A deliberately DISABLED plugin is respected, never
# re-enabled.
#
# The agent-skills repo is PUBLIC, so `claude plugin marketplace add` clones it
# ANONYMOUSLY over HTTPS — no git credential helper, no dependency on the
# entrypoint's `gh auth setup-git` step, and hence no auth-ordering race.
#
# BEST-EFFORT CONTRACT: every step is bounded by a timeout and tolerant of failure.
# Nothing here ever exits non-zero to a caller that could abort startup, and
# `set -e` is deliberately NOT used so one failed step cannot skip the "will retry
# next start" logging.

set -uo pipefail

# DEFENSE IN DEPTH against the TTY hang: the claude CLI hangs (SIGTERM-immune)
# when its stdin is the container TTY, and every `claude` child below inherits
# OUR stdin. Callers should detach with `</dev/null` (see the invocation model
# above), but the hang must not be reachable through a forgetful call site or an
# ad-hoc manual run — so if stdin is (still) a TTY, replace it with /dev/null
# ourselves. Nothing in this script reads stdin.
if [ -t 0 ]; then
	exec </dev/null
fi

MARKETPLACE_REPO="Roubtec/agent-skills"
MARKETPLACE_NAME="roubtec"
PLUGIN_ID="dev-skills@${MARKETPLACE_NAME}"

# Where the whole bootstrap logs its debug trail. The entrypoint points this at
# $CLAUDE_CONFIG_DIR/.powbox-plugin-bootstrap.log (i.e. ~/.claude/...); the
# default keeps a standalone run self-contained. EVERYTHING goes here — this run
# is detached from any terminal, so the log is the only diagnostic surface.
PLUGIN_BOOTSTRAP_LOG="${POWBOX_PLUGIN_LOG:-$HOME/.claude/.powbox-plugin-bootstrap.log}"

# Completion marker for the entrypoint's bounded wait. The caller passes a
# container-local path and POLLS it rather than waiting on this process (the
# entrypoint must never wait ON the claude CLI — see the TTY-hang note above —
# and a poll is also immune to `setsid` re-forking, which would break a
# wait-on-pid). Touched via the EXIT trap so EVERY exit path — success, skip,
# lock-miss, failure — releases the waiter; only a SIGKILL skips it, and then
# the waiter's own cap covers us.
if [ -n "${POWBOX_PLUGIN_DONE_FILE:-}" ]; then
	trap ': >"$POWBOX_PLUGIN_DONE_FILE" 2>/dev/null || true' EXIT
fi

# Bounds.
NET_TIMEOUT="${POWBOX_PLUGIN_NET_TIMEOUT:-120}"  # per network op (add/install/update)
LIST_TIMEOUT="${POWBOX_PLUGIN_LIST_TIMEOUT:-30}" # per local `plugin list`

# SIGKILL grace for EVERY bounded op. Plain `timeout N` only sends SIGTERM at N; the
# claude CLI demonstrably survives SIGTERM in exactly the hang case that matters (see the
# invocation-model note above), so without the follow-up SIGKILL a hung op would leak a
# detached process that holds the cross-container lock for LOCK_WAIT against every peer.
# `timeout --kill-after=<grace>` gives each op a HARD wall-clock ceiling of its bound +
# this grace.
KILL_AFTER="${POWBOX_PLUGIN_KILL_AFTER:-5}"

# Cross-container serialization. The claude-config volume is a SINGLE global named
# volume mounted into EVERY powbox container (scripts/launch-agent.sh
# SHARED_VOLUMES), so ~/.claude/plugins is state SHARED across concurrently
# running containers — not per-container. Two containers booting at once would
# otherwise both observe `absent` (cold volume) or both run `plugin update` (warm
# volume) and race `marketplace add`/`plugin install`/update against the same
# on-disk cache, corrupting plugin metadata or failing one bootstrap. We serialize
# the whole check-then-mutate with an flock on a lockfile that lives ON that shared
# volume, so every container locks the same host inode and the advisory lock
# actually serializes them (see run_locked). Waiting the full LOCK_WAIT is fine —
# this run is detached, so a patient wait never delays any container's prompt.
LOCK_FILE="${POWBOX_PLUGIN_LOCK_FILE:-$HOME/.claude/.powbox-plugin-bootstrap.lock}"
LOCK_WAIT="${POWBOX_PLUGIN_LOCK_WAIT:-300}" # wait for a peer container's bootstrap

# Never hang on an interactive git credential prompt. The agent-skills repo is public
# so the clone is anonymous and needs no credentials — this stays as a fail-fast
# belt-and-suspenders guard so any UNEXPECTED credential prompt (e.g. a transient
# redirect to an auth'd endpoint) fails immediately and the bounded timeout, not a
# wedged clone, is the worst case.
export GIT_TERMINAL_PROMPT=0

# Preserve the marketplace clone when a refresh fails offline. `marketplace
# update`/`add` runs a `git pull` under the hood; by default a FAILED pull makes
# the CLI DELETE the stale clone, which — on the persistent, shared claude-config
# volume — would strip the marketplace listing (and orphan the installed plugin's
# provenance) rather than simply leaving the old skills in place. The CLI keeps
# the existing clone on pull failure only when this is truthy (its env-boolean
# helper accepts 1/true/yes/on). So a start with GitHub unreachable now no-ops
# the refresh and keeps the already-installed skills, instead of losing the
# marketplace state until the next successful online start.
export CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE=1

# Debug channel: appends to the bootstrap log, never a terminal.
log() {
	printf '%s dev-skills-plugin: %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo '-')" "$*" \
		>>"$PLUGIN_BOOTSTRAP_LOG" 2>/dev/null || true
}

# One of: enabled | disabled | absent | unknown. Prefers `claude plugin list
# --json` (reports enable status) over installed_plugins.json, which only proves
# registration, not enablement.
plugin_state() {
	local out
	# --kill-after because the claude CLI can survive SIGTERM (see KILL_AFTER): a hung
	# `plugin list` must not hold the cross-container lock past its bound.
	out="$(timeout --kill-after="$KILL_AFTER" "$LIST_TIMEOUT" claude plugin list --json 2>/dev/null)" || {
		echo unknown
		return
	}
	# Guard against non-JSON / empty output before handing it to jq.
	if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
		echo unknown
		return
	fi
	# NOTE: do NOT collapse this with jq's `//` alternative operator — `//` treats
	# BOTH null AND false as empty, so `.enabled // "absent"` would report a
	# genuinely DISABLED plugin (enabled:false) as absent and trigger a reinstall
	# that re-enables it, silently overriding a deliberate user disable. Test
	# presence and the boolean separately instead.
	local state
	state="$(printf '%s' "$out" | jq -r --arg id "$PLUGIN_ID" '
		map(select(.id == $id)) as $m
		| if ($m | length) == 0 then "absent"
			elif ($m[0].enabled == true) then "enabled"
			else "disabled" end' 2>/dev/null)"
	case "$state" in
	enabled | disabled | absent) echo "$state" ;;
	*) echo unknown ;;
	esac
}

run_bounded() {
	# run_bounded <timeout-secs> <label> <cmd...> — bounded, quiet-on-success, logs
	# on failure. CAPTURE the command's combined stdout+stderr so a FAILURE can
	# surface its underlying cause (offline vs CLI error) in the bootstrap log — this
	# log is the script's only diagnostic surface, so a bare "step failed" line
	# without the command's own message makes bootstraps hard to debug. On SUCCESS we
	# discard the output to honor the quiet-on-success contract.
	local secs="$1" label="$2"
	shift 2
	local out _line
	if out="$(timeout --kill-after="$KILL_AFTER" "$secs" "$@" 2>&1)"; then
		return 0
	fi
	log "step failed or timed out: $label"
	if [ -n "$out" ]; then
		while IFS= read -r _line; do
			log "  | $_line"
		done <<<"$out"
	fi
	return 1
}

# install_plugin_ops <deadline-epoch> — the two idempotent install steps, each bounded
# by the time REMAINING until <deadline-epoch>, so the overall install honors a single
# wall-clock budget. `marketplace add` no-ops if already declared; `plugin install`
# auto-enables. Returns 0 only if both steps succeed within budget.
install_plugin_ops() {
	local deadline="$1" rem
	rem=$((deadline - $(date +%s 2>/dev/null || echo 0)))
	if [ "$rem" -le 0 ]; then
		log "install budget exhausted before 'marketplace add'"
		return 1
	fi
	run_bounded "$rem" "marketplace add ${MARKETPLACE_REPO}" \
		claude plugin marketplace add "$MARKETPLACE_REPO" || return 1
	rem=$((deadline - $(date +%s 2>/dev/null || echo 0)))
	if [ "$rem" -le 0 ]; then
		log "install budget exhausted before 'plugin install'"
		return 1
	fi
	run_bounded "$rem" "plugin install ${PLUGIN_ID}" \
		claude plugin install "$PLUGIN_ID" || return 1
	return 0
}

run_locked() {
	# run_locked <wait-secs> <fn> — run <fn> holding an exclusive flock on the SHARED
	# claude-config volume, so concurrent containers cannot race the check-then-mutate
	# on ~/.claude/plugins. Best-effort like everything else here:
	#   - no flock binary         -> run unlocked (degrade, never fail the bootstrap),
	#   - lockfile can't be opened -> run unlocked,
	#   - lock still held past     -> return 99 WITHOUT running: the holder is a peer
	#     <wait-secs>                 container's bootstrap converging the SAME shared
	#                                 state for us, so skipping is convergent.
	# Otherwise returns <fn>'s own exit status.
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
	log "another container holds the plugin bootstrap lock after ${lwait}s; not running the check-then-mutate this pass (the holder is converging the shared state)"
	return 99
}

main() {
	# The plugin state lives on the persistent claude-config volume, so this is a
	# once-per-volume install and a per-start keep-current — cheap on warm volumes.
	if ! command -v claude >/dev/null 2>&1; then
		log "claude CLI not found; skipping (this is not the agent image?)"
		return 0
	fi
	if ! command -v timeout >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
		log "timeout/jq unavailable; skills plugin unavailable, will retry next start"
		return 0
	fi
	run_locked "$LOCK_WAIT" converge_plugin_state
	return 0
}

# converge_plugin_state — the check-then-mutate that run_locked serializes across
# containers sharing the claude-config volume (see LOCK_FILE rationale above). The
# `plugin_state` query and every mutating branch below run while we hold the lock, so a
# concurrent container cannot slip its own install/update between our state check and the
# action we take on it.
converge_plugin_state() {
	case "$(plugin_state)" in
	enabled)
		converge_keep_current
		;;
	disabled)
		# RESPECT a deliberate user disable. enabled:false could mean "user turned
		# it off" or "registered but never enabled"; we cannot distinguish them, so
		# we choose the SAFE default and never re-enable. Re-enable manually via
		# `/plugin` or `claude plugin enable dev-skills@roubtec`.
		log "installed but DISABLED — respecting the user's choice, not re-enabling (re-enable via /plugin or 'claude plugin enable ${PLUGIN_ID}')"
		;;
	absent)
		converge_install
		;;
	unknown | *)
		log "could not query plugin state; skills plugin unavailable, will retry next start"
		;;
	esac
	return 0
}

# converge_keep_current — warm-volume refresh.
converge_keep_current() {
	# KEEP-CURRENT fast path. agent-skills manifests carry no version field, so
	# every new commit on main is a new SHA-version. Keeping current takes TWO
	# distinct CLI steps — the CLI deliberately separates them (plugins-reference):
	#   1. `plugin marketplace update <name>` refreshes the marketplace CATALOG
	#      (makes the new commit-SHA version visible), and
	#   2. `plugin update <id>` pulls that new version into the INSTALLED plugin
	#      cache (~/.claude/plugins/cache).
	# `marketplace update` alone only refreshes listings; without the follow-up
	# `plugin update` a new agent-skills commit would show in the catalog while
	# the container kept running the OLD cached skills until a manual update.
	# Both are the only network ops on a warm volume and both are best-effort: a
	# failed refresh just leaves the already-installed skills in place, and
	# `plugin update` no-ops ("already at the latest version") when the cached
	# SHA already matches. Updates apply at the NEXT session start (a restart) —
	# this one-session staleness is accepted (plugins load once at startup).
	#
	# Per-marketplace AUTO-UPDATE (updates at session start without these calls)
	# is OFF by default for third-party marketplaces and its on-disk schema is
	# undocumented — we do NOT enable it programmatically (guessing the schema
	# could corrupt plugin state). A user can opt in once per volume via
	# `/plugin` → Marketplaces; this startup refresh makes that optional.
	log "present and enabled; refreshing marketplace '${MARKETPLACE_NAME}' + plugin '${PLUGIN_ID}' (keep-current)"
	if run_bounded "$NET_TIMEOUT" "marketplace update ${MARKETPLACE_NAME}" \
		claude plugin marketplace update "$MARKETPLACE_NAME"; then
		if run_bounded "$NET_TIMEOUT" "plugin update ${PLUGIN_ID}" \
			claude plugin update "$PLUGIN_ID"; then
			log "keep-current complete (updates apply next session start)"
		else
			log "plugin update unavailable, will retry next start"
		fi
	else
		log "marketplace refresh unavailable, will retry next start"
	fi
}

# converge_install — the cold-volume install. Full NET_TIMEOUT per op, log-only; a
# persistently offline volume just logs "will retry next start". Skills land for the
# NEXT session (or after /reload-plugins in the current one).
converge_install() {
	local deadline
	deadline=$(($(date +%s 2>/dev/null || echo 0) + NET_TIMEOUT * 2))
	log "not installed; installing: adding marketplace '${MARKETPLACE_REPO}' + installing '${PLUGIN_ID}'"
	if install_plugin_ops "$deadline"; then
		log "installed '${PLUGIN_ID}' (skills available as /dev-skills:<name> next session, or via /reload-plugins)"
	else
		log "skills plugin unavailable, will retry next start"
	fi
}

main "$@"
