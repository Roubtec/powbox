#!/usr/bin/env bash
# seed-claude-plugins.sh — bring the shared Claude skills into a container via the
# SAME channel colleagues use: the `dev-skills@roubtec` plugin, served from the
# Roubtec/agent-skills marketplace. Task 015b stopped baking those 8 skills into
# the image; this script is what brings them back, NAMESPACED (they arrive as
# `/dev-skills:<name>`, e.g. `/dev-skills:address-review` — the model-side
# Skill-tool matching by description is unaffected, only the slash-command muscle
# memory changes; see task 015d docs).
#
# INVOCATION MODEL — this runs fully DETACHED in the background (see
# entrypoint-claude-hook.sh), so it never delays the container prompt and never
# writes to the agent's TUI stderr. All progress/failure lines go to stdout,
# which the hook captures to $AGENT_CONFIG_DIR/.powbox-plugin-bootstrap.log. Run
# it by hand any time to see the full flow: `bash /usr/local/bin/seed-claude-plugins.sh`.
#
# WHY BACKGROUNDED + WHY IT WAITS FOR AUTH: the private agent-skills repo is
# cloned over HTTPS by `claude plugin marketplace add`, which needs git's gh
# credential helper. That helper is configured by entrypoint-core.sh's
# `gh auth setup-git` step, which runs AFTER this Claude hook fires (the hook is
# the primary agent's AGENT_SETUP_HOOK, invoked early in entrypoint-core.sh, and
# earlier still — in entrypoint-agent.sh — when Claude is the non-primary agent).
# Rather than reorder the entrypoint, this job backgrounds itself and briefly
# waits for the credential helper to appear before it touches the network, so a
# cold volume converges on THIS start once auth is ready, while an offline start
# just logs a skip and self-heals on a later online start.
#
# BEST-EFFORT CONTRACT: every step is bounded by a timeout and tolerant of
# failure. Nothing here ever exits non-zero to a caller that could abort startup
# (the hook backgrounds it and does not wait), and `set -e` is deliberately NOT
# used so one failed step cannot skip the "will retry next start" logging.

set -uo pipefail

MARKETPLACE_REPO="Roubtec/agent-skills"
MARKETPLACE_NAME="roubtec"
PLUGIN_ID="dev-skills@${MARKETPLACE_NAME}"

# Bounds. These are generous (a real clone is several seconds) BECAUSE the whole
# job is off the critical path — a longer bound never delays the prompt, it only
# gives a slow network a chance to finish. Overridable for tests.
AUTH_WAIT="${POWBOX_PLUGIN_AUTH_WAIT:-25}"       # seconds to wait for gh git auth
NET_TIMEOUT="${POWBOX_PLUGIN_NET_TIMEOUT:-120}"  # per network op (add/install/update)
LIST_TIMEOUT="${POWBOX_PLUGIN_LIST_TIMEOUT:-30}" # per local `plugin list`

# Never hang on an interactive git credential prompt (private repo, no creds):
# fail fast so the bounded timeout is the worst case, not a wedged clone.
export GIT_TERMINAL_PROMPT=0

log() { printf '%s dev-skills-plugin: %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo '-')" "$*"; }

# Detect the gh git-credential helper that entrypoint-core.sh registers via
# `gh auth setup-git` (only when `gh auth status` succeeds — i.e. auth exists AND
# GitHub is reachable). Its presence is our single readiness signal: it implies
# both that the same-boot ordering race is resolved and that we have working
# GitHub auth. Read-only, so it never races the entrypoint's git-config writes.
gh_git_helper_ready() {
	git config --global --get-regexp 'credential\..*\.helper' 2>/dev/null |
		grep -q 'gh auth git-credential'
}

# Wait up to AUTH_WAIT for the helper. Returns 0 if seen, 1 on timeout — but the
# caller proceeds either way: on timeout we still ATTEMPT (covers a future public
# repo needing no auth) and simply let the bounded op fail + self-heal next start.
wait_for_github_auth() {
	local waited=0
	while [ "$waited" -lt "$AUTH_WAIT" ]; do
		if gh_git_helper_ready; then
			return 0
		fi
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

# One of: enabled | disabled | absent | unknown. Prefers `claude plugin list
# --json` (reports enable status) over installed_plugins.json, which only proves
# registration, not enablement.
plugin_state() {
	local out
	out="$(timeout "$LIST_TIMEOUT" claude plugin list --json 2>/dev/null)" || {
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
	# run_bounded <label> <cmd...> — bounded, quiet-on-success, logs on failure.
	local label="$1"
	shift
	if timeout "$NET_TIMEOUT" "$@" >/dev/null 2>&1; then
		return 0
	fi
	log "step failed or timed out: $label"
	return 1
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

	if wait_for_github_auth; then
		log "GitHub git auth detected; proceeding"
	else
		log "GitHub git auth not detected after ${AUTH_WAIT}s; attempting anyway (self-heals next start if offline)"
	fi

	case "$(plugin_state)" in
	enabled)
		# KEEP-CURRENT fast path. agent-skills manifests carry no version field, so
		# every new commit on main is a new SHA-version → `marketplace update`
		# pulls it. This is the ONLY network op on a warm volume, and it is
		# best-effort: a failed refresh just leaves the already-installed skills in
		# place. Applied at the NEXT session start (plugin updates need a restart).
		#
		# Per-marketplace AUTO-UPDATE (updates at session start without this call)
		# is OFF by default for third-party marketplaces and its on-disk schema is
		# undocumented — we do NOT enable it programmatically (guessing the schema
		# could corrupt plugin state). A user can opt in once per volume via
		# `/plugin` → Marketplaces; this startup refresh makes that optional.
		log "present and enabled; refreshing marketplace '${MARKETPLACE_NAME}' (keep-current)"
		if run_bounded "marketplace update ${MARKETPLACE_NAME}" \
			claude plugin marketplace update "$MARKETPLACE_NAME"; then
			log "marketplace refresh complete (updates apply next session start)"
		else
			log "marketplace refresh unavailable, will retry next start"
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
		# INSTALL-IF-ABSENT. Both steps are idempotent: `marketplace add` no-ops if
		# already declared, and `plugin install` auto-enables. Half-installed state
		# (marketplace added but plugin missing) also lands here and self-heals.
		log "not installed; adding marketplace '${MARKETPLACE_NAME}' + installing '${PLUGIN_ID}'"
		if ! run_bounded "marketplace add ${MARKETPLACE_REPO}" \
			claude plugin marketplace add "$MARKETPLACE_REPO"; then
			log "skills plugin unavailable (marketplace add failed), will retry next start"
			return 0
		fi
		if ! run_bounded "plugin install ${PLUGIN_ID}" \
			claude plugin install "$PLUGIN_ID"; then
			log "skills plugin unavailable (install failed), will retry next start"
			return 0
		fi
		log "installed '${PLUGIN_ID}' (skills available as /dev-skills:<name> next session)"
		;;
	unknown | *)
		log "could not query plugin state; skills plugin unavailable, will retry next start"
		;;
	esac
	return 0
}

main "$@"
