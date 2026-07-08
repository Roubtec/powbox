#!/usr/bin/env bash
# seed-claude-plugins.sh — bring the shared Claude skills into a container via the
# SAME channel colleagues use: the `dev-skills@roubtec` plugin, served from the
# Roubtec/agent-skills marketplace. Task 015b stopped baking those 8 skills into
# the image; this script is what brings them back, NAMESPACED (they arrive as
# `/dev-skills:<name>`, e.g. `/dev-skills:address-review` — the model-side
# Skill-tool matching by description is unaffected, only the slash-command muscle
# memory changes; see task 015d docs).
#
# INVOCATION MODEL (task 015g) — the entrypoint hook now calls this SYNCHRONOUSLY,
# and this script decides sync-vs-async per plugin state so ONLY the cold case
# blocks startup, and only briefly:
#   - absent (cold, fresh claude-config volume) -> install in the FOREGROUND,
#     bounded, BEFORE the hook returns and the entrypoint `exec`s claude, so the
#     eight /dev-skills:* skills are live in the FIRST session (Claude enumerates
#     plugins once at startup; a plugin that appears after that is invisible until
#     /reload-plugins). On timeout/lock-miss the remaining work is detached to a
#     background self-heal and the entrypoint proceeds — start is NEVER wedged.
#     The foreground path is GATED on POWBOX_PLUGIN_ALLOW_SYNC_COLD, which the hook
#     sets only when Claude is the PRIMARY agent. When Claude is NON-PRIMARY (e.g.
#     PRIMARY_AGENT=codex) this hook runs during entrypoint-agent.sh's non-primary
#     seeding — BEFORE init-firewall.sh runs and BEFORE the primary (Codex) prompt —
#     so the cold install is BACKGROUNDED instead: keeping it off the SYNCHRONOUS
#     critical path so it never delays a Codex prompt that never uses these skills.
#     NOTE: backgrounding here keeps the work off the prompt's critical path but does
#     NOT by itself order it after the firewall — the detached run still races
#     init-firewall.sh, so a non-primary cold/keep-current network op can fire before
#     the firewall is up. That residual ordering gap is tracked in
#     tasks/deferred/015h-plugin-bootstrap-firewall-ordering.md (public repo, hardcoded
#     GitHub target, so low practical risk today).
#   - enabled (warm keep-current) -> self-forked to the BACKGROUND so a warm start
#     adds no latency. A keep-current that pulls a newer commit applies next
#     session (accepted one-session staleness — plugins load once at startup).
#   - disabled -> respected, never re-enabled.
# The background runs re-exec this script with POWBOX_PLUGIN_BACKGROUND=1 (see
# spawn_background); they are patient (full NET/lock bounds), quiet (log only), and
# never re-spawn, so there is no respawn loop. Run it by hand to see the full flow:
# `bash /usr/local/bin/seed-claude-plugins.sh`.
#
# The agent-skills repo is PUBLIC, so `claude plugin marketplace add` clones it
# ANONYMOUSLY over HTTPS — no git credential helper, no dependency on the entrypoint's
# `gh auth setup-git` step, and hence no auth-ordering race. (Historically this whole
# job was detached and waited for that helper because the repo was private; that
# scaffolding is gone as of task 015g.)
#
# BEST-EFFORT CONTRACT: every step is bounded by a timeout and tolerant of failure.
# Nothing here ever exits non-zero to a caller that could abort startup (the hook
# guards the call with `|| true`), and `set -e` is deliberately NOT used so one
# failed step cannot skip the "will retry next start" logging.

set -uo pipefail

# spawn_background re-execs this script by path (`bash "$SELF"`), which must resolve from
# ANY working directory. BASH_SOURCE/$0 can be a bare `seed-claude-plugins.sh` (PATH
# invocation) or a CWD-relative path; a detached background run whose CWD differs from the
# launcher's would then fail to find it. Absolutize up front: keep an already-absolute
# path; else prefer a `command -v` PATH lookup that resolves to an absolute path; else
# fall back to dirname+pwd for a CWD-relative source. Best-effort — if none resolves,
# spawn_background simply fails to launch (the foreground already did what it could).
SELF="${BASH_SOURCE[0]:-$0}"
case "$SELF" in
/*) ;; # already absolute — nothing to do
*)
	if _abs="$(command -v "$SELF" 2>/dev/null)" && [ "${_abs#/}" != "$_abs" ]; then
		SELF="$_abs"
	elif [ -e "$SELF" ]; then
		SELF="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)/$(basename "$SELF")" || true
	fi
	unset _abs
	;;
esac

MARKETPLACE_REPO="Roubtec/agent-skills"
MARKETPLACE_NAME="roubtec"
PLUGIN_ID="dev-skills@${MARKETPLACE_NAME}"

# Where the whole bootstrap logs its debug trail. The hook points this at
# $AGENT_CONFIG_DIR/.powbox-plugin-bootstrap.log (which for Claude is ~/.claude/...);
# the default keeps a standalone run self-contained. Only the cold foreground path
# prints to the terminal, and only a few concise status lines (an "installing…" line
# then a terminal "ready…"/"still installing…" line; see status_line); EVERYTHING
# else — every debug detail, and all background-run output — goes here.
PLUGIN_BOOTSTRAP_LOG="${POWBOX_PLUGIN_LOG:-$HOME/.claude/.powbox-plugin-bootstrap.log}"

# Bounds.
NET_TIMEOUT="${POWBOX_PLUGIN_NET_TIMEOUT:-120}"  # per network op (add/install/update)
LIST_TIMEOUT="${POWBOX_PLUGIN_LIST_TIMEOUT:-30}" # per local `plugin list`

# SIGKILL grace for EVERY bounded op. Plain `timeout N` only sends SIGTERM at N; a CLI (or
# a child git process) that traps/blocks SIGTERM could then run PAST N, which on the cold
# FOREGROUND path would push container start beyond COLD_INSTALL_BOUND and break the
# never-wedged contract. `timeout --kill-after=<grace>` follows the TERM with a SIGKILL
# after the grace, giving each op a HARD wall-clock ceiling of its bound + this grace.
# Kept short so the extra worst-case slack per op is negligible.
KILL_AFTER="${POWBOX_PLUGIN_KILL_AFTER:-5}"

# COLD FOREGROUND bounds — these keep the synchronous first-boot install off the
# critical path for more than a bounded moment. The install must finish before the
# hook returns and the entrypoint `exec`s claude, so unlike the background bounds
# these directly cap how long container start can wait:
#   - COLD_INSTALL_BOUND caps the whole cold marketplace-add + plugin-install window
#     (a real clone is a few seconds; the generous default absorbs a slow network),
#   - COLD_LOCK_WAIT caps how long we wait for a PEER container's lock before giving
#     up the foreground and letting the background self-heal converge instead.
# On either bound we detach the remaining work to the background and proceed, so the
# worst case is exactly today's behavior (skills arrive a session late), never a
# wedged prompt.
# The full foreground worst case also includes the two bounded `claude plugin list`
# state queries — the unlocked routing query in main() plus the authoritative one inside
# the lock in converge_plugin_state — each capped by LIST_TIMEOUT, plus a short per-op
# KILL_AFTER SIGKILL grace on every bounded op. So the true ceiling is
# ~COLD_INSTALL_BOUND + COLD_LOCK_WAIT + 2*LIST_TIMEOUT (+ a few KILL_AFTER graces), not
# the install+lock bound alone.
COLD_INSTALL_BOUND="${POWBOX_PLUGIN_COLD_INSTALL_BOUND:-50}" # total foreground install budget
COLD_LOCK_WAIT="${POWBOX_PLUGIN_COLD_LOCK_WAIT:-15}"         # foreground wait for a peer's lock

# Gate for the SYNCHRONOUS cold-foreground path. That path is only worthwhile — and only
# SAFE — when Claude is the PRIMARY agent: its hook then runs from entrypoint-core.sh
# AFTER init-firewall.sh, and the session being launched is the Claude one whose FIRST
# prompt benefits from the skills being live. When Claude is NON-PRIMARY
# (PRIMARY_AGENT=codex) the hook runs from entrypoint-agent.sh's non-primary seeding,
# BEFORE the firewall is initialized and BEFORE the primary (Codex) prompt, so a
# foreground cold install would run network ops ahead of the firewall and delay Codex
# startup for a plugin set that session never uses. The hook passes
# POWBOX_PLUGIN_ALLOW_SYNC_COLD=1 only in the primary-Claude case; the default 1 keeps a
# by-hand run (no hook, no PRIMARY_AGENT) doing the immediate foreground install.
ALLOW_SYNC_COLD="${POWBOX_PLUGIN_ALLOW_SYNC_COLD:-1}"

# Cross-container serialization. The claude-config volume is a SINGLE global named
# volume mounted into EVERY powbox container (scripts/launch-agent.sh
# SHARED_VOLUMES), so ~/.claude/plugins is state SHARED across concurrently
# running containers — not per-container. Two containers booting at once would
# otherwise both observe `absent` (cold volume) or both run `plugin update` (warm
# volume) and race `marketplace add`/`plugin install`/update against the same
# on-disk cache, corrupting plugin metadata or failing one bootstrap. We serialize
# the whole check-then-mutate with an flock on a lockfile that lives ON that shared
# volume, so every container locks the same host inode and the advisory lock
# actually serializes them (see run_locked). The background self-heal waits the full
# LOCK_WAIT; the synchronous cold path waits only the short COLD_LOCK_WAIT so a peer
# bootstrap can never block THIS container's startup (on timeout it defers to the
# background, which then waits patiently).
LOCK_FILE="${POWBOX_PLUGIN_LOCK_FILE:-$HOME/.claude/.powbox-plugin-bootstrap.lock}"
LOCK_WAIT="${POWBOX_PLUGIN_LOCK_WAIT:-300}" # background wait for a peer container's bootstrap

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
# helper accepts 1/true/yes/on). So a warm start with GitHub unreachable now
# no-ops the refresh and keeps the already-installed skills, instead of losing the
# marketplace state until the next successful online start.
export CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE=1

# Debug channel: appends to the bootstrap log, never the terminal.
log() {
	printf '%s dev-skills-plugin: %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo '-')" "$*" \
		>>"$PLUGIN_BOOTSTRAP_LOG" 2>/dev/null || true
}

# User channel: one concise line PER CALL on the REAL terminal (this runs synchronously
# in the foreground before Claude grabs the alternate screen buffer, so stdout is
# visible). Also mirrored into the log. Only the cold foreground path calls this, and it
# calls it more than once — an "installing…" line then a terminal "ready…"/"still
# installing…" line; background runs redirect stdout to the log and never emit one.
status_line() {
	printf 'dev-skills plugin: %s\n' "$*"
	log "[status] $*"
}

# One of: enabled | disabled | absent | unknown. Prefers `claude plugin list
# --json` (reports enable status) over installed_plugins.json, which only proves
# registration, not enablement.
plugin_state() {
	local out
	# --kill-after gives this foreground-critical state query the same hard ceiling as the
	# install ops (see KILL_AFTER): a `plugin list` that ignores SIGTERM cannot stall start.
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
# by the time REMAINING until <deadline-epoch> (so the overall install honors a single
# wall-clock budget whether that budget is the tight cold-foreground one or the patient
# background one). `marketplace add` no-ops if already declared; `plugin install`
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
	#   - no flock binary        -> run unlocked (degrade, never block startup),
	#   - lockfile can't be opened-> run unlocked,
	#   - lock still held past    -> return 99 WITHOUT running; the caller decides what
	#     <wait-secs>                to do (the background path just skips — the holder
	#                                is converging the shared state for us; the cold
	#                                foreground path detaches to the background).
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
	log "another container holds the plugin bootstrap lock after ${lwait}s; not running the check-then-mutate this pass"
	return 99
}

# spawn_background — detach a patient, quiet self-heal / keep-current run that finishes
# the work WITHOUT blocking the foreground. It re-execs this script with
# POWBOX_PLUGIN_BACKGROUND=1 so the re-exec takes the background branch (full bounds, no
# status line, no further spawn — so there is no respawn loop). `setsid` reparents it to
# init so it survives the entrypoint's `exec claude` and never becomes a zombie; its
# stdio goes to the bootstrap log, never the agent's TUI. Called either because the warm
# path routes keep-current to the background, or because the cold foreground install hit
# its time/lock bound and hands off the remainder.
spawn_background() {
	if command -v setsid >/dev/null 2>&1; then
		POWBOX_PLUGIN_BACKGROUND=1 setsid bash "$SELF" </dev/null >>"$PLUGIN_BOOTSTRAP_LOG" 2>&1 &
	else
		# Fallback if setsid is somehow unavailable: still detach from the TUI.
		POWBOX_PLUGIN_BACKGROUND=1 bash "$SELF" </dev/null >>"$PLUGIN_BOOTSTRAP_LOG" 2>&1 &
	fi
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

	# BACKGROUND branch — a self-forked run (warm keep-current, or a cold self-heal
	# after the foreground bound). Converge patiently under the full lock wait; quiet
	# (log only); never spawns again.
	if [ "${POWBOX_PLUGIN_BACKGROUND:-0}" = 1 ]; then
		run_locked "$LOCK_WAIT" converge_plugin_state
		return 0
	fi

	# FOREGROUND routing. A cheap read-only state query (unlocked — it only routes;
	# converge_plugin_state re-queries authoritatively under the lock) decides which
	# of the three cases we are in, so ONLY the cold case ever runs synchronously:
	case "$(plugin_state)" in
	enabled)
		# Warm keep-current: background it so a warm start adds no latency. It takes
		# the lock itself in the background.
		log "present and enabled; backgrounding keep-current (no start latency)"
		spawn_background
		;;
	disabled)
		# Respect a deliberate user disable (no lock, no mutation — pure observation).
		log "installed but DISABLED — respecting the user's choice, not re-enabling (re-enable via /plugin or 'claude plugin enable ${PLUGIN_ID}')"
		;;
	absent)
		if [ "$ALLOW_SYNC_COLD" != 1 ]; then
			# Claude is NON-PRIMARY (e.g. PRIMARY_AGENT=codex): the foreground cold path is
			# neither wanted nor safe here — this hook runs during entrypoint-agent.sh's
			# non-primary seeding, BEFORE the firewall is initialized and BEFORE the primary
			# prompt, and a foreground install would BLOCK the Codex prompt. Background the
			# install so it self-heals like the pre-015g detached model; the skills land in
			# the next (i.e. first real) Claude session. CAVEAT: backgrounding keeps this off
			# the Codex prompt's critical path but does NOT guarantee it runs after
			# init-firewall.sh — the detached run races the firewall (residual ordering gap
			# tracked in tasks/deferred/015h-plugin-bootstrap-firewall-ordering.md).
			log "cold volume, but foreground install not authorized (non-primary Claude session); backgrounding install"
			spawn_background
		else
			# COLD case: install synchronously in the foreground, bounded, before the
			# entrypoint `exec`s claude, so the skills are live THIS session. A short lock
			# wait keeps a peer bootstrap from blocking our startup; on lock-miss we detach
			# to the background self-heal and proceed.
			PLUGIN_SYNC_COLD=1
			status_line "installing dev-skills plugin…"
			if ! run_locked "$COLD_LOCK_WAIT" converge_plugin_state; then
				log "peer holds the bootstrap lock after ${COLD_LOCK_WAIT}s; deferring cold install to background self-heal"
				status_line "still installing in the background; run /reload-plugins shortly (or restart) if /dev-skills:* commands are missing"
				spawn_background
			fi
		fi
		;;
	unknown | *)
		# Could not confirm state (CLI hiccup). Don't spend foreground time on an
		# uncertain state — let a patient background run sort it out / retry.
		log "could not query plugin state in the foreground; deferring to background self-heal"
		spawn_background
		;;
	esac
	return 0
}

# converge_plugin_state — the check-then-mutate that run_locked serializes across
# containers sharing the claude-config volume (see LOCK_FILE rationale above). The
# `plugin_state` query and every mutating branch below run while we hold the lock, so a
# concurrent container cannot slip its own install/update between our state check and the
# action we take on it. PLUGIN_SYNC_COLD=1 marks the cold FOREGROUND pass (tight bounds,
# status line, degrade-to-background); otherwise this runs in a patient BACKGROUND pass.
converge_plugin_state() {
	local sync="${PLUGIN_SYNC_COLD:-0}"
	case "$(plugin_state)" in
	enabled)
		if [ "$sync" = 1 ]; then
			# A peer installed it between our routing query and the lock. Do NOT run a
			# (potentially slow) keep-current in the foreground — hand it to the
			# background so startup is not delayed.
			log "already enabled (a peer installed it); deferring keep-current to background"
			spawn_background
		else
			converge_keep_current
		fi
		;;
	disabled)
		# RESPECT a deliberate user disable. enabled:false could mean "user turned
		# it off" or "registered but never enabled"; we cannot distinguish them, so
		# we choose the SAFE default and never re-enable. Re-enable manually via
		# `/plugin` or `claude plugin enable dev-skills@roubtec`.
		log "installed but DISABLED — respecting the user's choice, not re-enabling (re-enable via /plugin or 'claude plugin enable ${PLUGIN_ID}')"
		;;
	absent)
		if [ "$sync" = 1 ]; then
			converge_cold_install
		else
			converge_bg_install
		fi
		;;
	unknown | *)
		log "could not query plugin state; skills plugin unavailable, will retry next start"
		;;
	esac
	return 0
}

# converge_keep_current — warm-volume refresh. Runs only in a BACKGROUND pass (the
# foreground routes `enabled` straight to spawn_background), so its network ops never add
# start latency.
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

# converge_cold_install — the SYNCHRONOUS first-boot install, bounded by
# COLD_INSTALL_BOUND so it cannot hold container start for more than that budget. On
# success the skills are live THIS session; on timeout/failure it detaches the remaining
# work to the background self-heal and returns so the entrypoint proceeds.
converge_cold_install() {
	local deadline
	deadline=$(($(date +%s 2>/dev/null || echo 0) + COLD_INSTALL_BOUND))
	log "not installed; cold FOREGROUND install (budget ${COLD_INSTALL_BOUND}s): marketplace add '${MARKETPLACE_REPO}' + install '${PLUGIN_ID}'"
	if install_plugin_ops "$deadline"; then
		log "installed '${PLUGIN_ID}' (skills available as /dev-skills:<name> THIS session)"
		status_line "ready — /dev-skills:* commands available this session"
		return 0
	fi
	log "cold install did not finish within ${COLD_INSTALL_BOUND}s (or failed); handing remaining work to background self-heal"
	status_line "still installing in the background; run /reload-plugins shortly (or restart) if /dev-skills:* commands are missing"
	spawn_background
	return 0
}

# converge_bg_install — the PATIENT background install (self-heal). Full NET_TIMEOUT per
# op, log-only, and — crucially — never spawns another background run, so a persistently
# offline volume just logs "will retry next start" instead of forking forever.
converge_bg_install() {
	local deadline
	deadline=$(($(date +%s 2>/dev/null || echo 0) + NET_TIMEOUT * 2))
	log "not installed; background install: adding marketplace '${MARKETPLACE_REPO}' + installing '${PLUGIN_ID}'"
	if install_plugin_ops "$deadline"; then
		log "installed '${PLUGIN_ID}' (skills available as /dev-skills:<name> next session)"
	else
		log "skills plugin unavailable, will retry next start"
	fi
}

main "$@"
