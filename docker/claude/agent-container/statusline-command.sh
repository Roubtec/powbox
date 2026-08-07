#!/bin/sh

# ── helpers ────────────────────────────────────────────────────────────────────
# ANSI color codes — use printf so variables hold actual escape bytes.
# (Single-quoted '\033' stays literal; printf interprets it into a real ESC char.)
RED=$(printf '\033[0;31m')
YEL=$(printf '\033[0;33m')
GRN=$(printf '\033[0;32m')
ORG=$(printf '\033[38;5;208m')
GRY=$(printf '\033[38;5;250m')
CYN=$(printf '\033[0;36m')
BLU=$(printf '\033[0;34m')
MAG=$(printf '\033[0;35m')
DIM=$(printf '\033[2m')
RST=$(printf '\033[0m')

# Context percentage color: <=15 green, <=75 yellow, <=90 orange, >90 red
pct_color_ctx() {
	pct="$1"
	if [ "$pct" -le 15 ]; then
		printf '%s' "$GRN"
	elif [ "$pct" -le 75 ]; then
		printf '%s' "$YEL"
	elif [ "$pct" -le 90 ]; then
		printf '%s' "$ORG"
	else
		printf '%s' "$RED"
	fi
}

# Usage (rate-limit) percentage color: <=75 green, <=90 orange, >90 red
pct_color_usage() {
	pct="$1"
	if [ "$pct" -le 75 ]; then
		printf '%s' "$GRN"
	elif [ "$pct" -le 90 ]; then
		printf '%s' "$ORG"
	else
		printf '%s' "$RED"
	fi
}

# Format epoch seconds (resets_at) → remaining time as "H:MM"
fmt_hhmm() {
	resets_at="$1"
	now=$(date +%s)
	diff=$((resets_at - now))
	[ "$diff" -lt 0 ] && diff=0
	hours=$((diff / 3600))
	mins=$(((diff % 3600) / 60))
	printf "%d:%02d" "$hours" "$mins"
}

# ── parse input (single jq call) ──────────────────────────────────────────────
eval "$(cat | jq -r '
  @sh "cwd=\(.cwd // .workspace.current_dir // "")",
  @sh "model=\(.model.display_name // .model.id // "unknown")",
  @sh "used_pct=\(.context_window.used_percentage // "")",
  @sh "five_pct=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "five_resets=\(.rate_limits.five_hour.resets_at // "")",
  @sh "seven_pct=\(.rate_limits.seven_day.used_percentage // "")",
  @sh "api_dur_ms=\(.cost.total_api_duration_ms // "")",
  @sh "session_id=\(.session_id // "")"
' | tr '\n' ' ')"

# effort is not in the JSON input; read it from settings as a static label
effort=$(jq -r '.effortLevel // empty' /home/node/.claude/settings.json 2>/dev/null)

# The account is not in the JSON input either — so ASK, rather than guess from
# `.claude.json`'s cached oauthAccount. That cache is not proof of the credential
# in use: an env credential (ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY /
# CLAUDE_CODE_OAUTH_TOKEN) and a settings.json apiKeyHelper all outrank the
# stored login, so the cached name can point at an account this session is not
# using. `auth status` reports the winner directly, and it declines to guess:
# measured with a stray ANTHROPIC_API_KEY set it returns `email: null` — the
# stored login's address is withheld rather than misattributed — alongside
# `apiKeySource` naming the credential actually in play ("ANTHROPIC_API_KEY").
# So: show the address when there is one, else name the source. An API-key
# session has no locally knowable account NAME (an opaque key maps to no
# identity without a network round trip), but the SOURCE is knowable and is the
# useful thing to surface. Nothing at all is shown if neither resolves.
# Note `"" | split("@")` is [] in jq, not [""], so `[0]` on it yields a literal
# "null" — hence sub() rather than split() for the local part.
auth_label() {
	# `timeout` bounds a hung CLI; any failure yields empty, which omits the
	# segment rather than printing something untrue. jq's exit status is checked
	# deliberately: given valid JSON followed by trailing garbage it prints the
	# parsed value and THEN fails, so an unchecked pipeline would display — and
	# cache — a name harvested from a malformed probe.
	_j=$(timeout 10 claude --safe-mode auth status --json 2>/dev/null) || return 0
	_out=$(printf '%s' "$_j" | jq -r '
        if .loggedIn != true then empty
        elif (.email // "") != "" then (.email | sub("@.*"; ""))
        elif (.apiKeySource // "") == "apiKeyHelper" then "key helper"
        elif (.apiKeySource // "") == "/login managed key" then "managed key"
        elif (.apiKeySource // "") != "" then
            (.apiKeySource | sub("^ANTHROPIC_"; "") | ascii_downcase | gsub("_"; " "))
        elif (.authMethod // "") == "oauth_token" then "env token"
        else empty end' 2>/dev/null) || return 0
	printf '%s' "$_out"
}

# ~0.55s per call and this script re-runs on every assistant message, so cache it.
# Two invalidations, matching how the answer can actually change:
#   - keyed on session_id (stable for a session's lifetime), so a new or resumed
#     session always refetches — a re-login between sessions is picked up free;
#   - a 10-minute mtime TTL, for a re-auth inside one long session.
# On disk because Claude Code spawns this script FRESH per render: there is no
# in-memory state to keep it in. A backgrounded refresh was considered and
# rejected — Claude Code cancels an in-flight statusline script when a new update
# arrives and child reaping is undocumented, so a detached refresh could be
# killed mid-write, for no gain over a cost paid once per session.
# A failed probe is cached too (as empty): otherwise a CLI without `auth status`
# would spawn a subprocess on EVERY render instead of one per TTL.
account=""
auth_cache_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-')
if [ -z "$auth_cache_id" ]; then
	# No session_id in the payload: use a stable key, or every render re-probes
	# forever. Fold in which credentials are present so two session-less renders
	# sharing this container cannot serve each other a wrong answer.
	auth_cache_id="no-session"
	[ -n "${ANTHROPIC_API_KEY:-}" ] && auth_cache_id="${auth_cache_id}k"
	[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && auth_cache_id="${auth_cache_id}a"
	[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && auth_cache_id="${auth_cache_id}o"
fi
auth_cache_dir="${TMPDIR:-/tmp}/claude-statusline-auth"
# The `s-`/`c-` prefixes are containment, not decoration: a session_id that
# sanitizes to "." or ".." would otherwise name the cache dir or its PARENT.
auth_cache="$auth_cache_dir/s-$auth_cache_id" # the value; its mtime is its true age
auth_claim="$auth_cache_dir/c-$auth_cache_id" # in-flight marker, separate on purpose
if [ -n "$(find "$auth_cache" -mmin -10 2>/dev/null)" ]; then
	account=$(cat "$auth_cache" 2>/dev/null)
elif [ -n "$(find "$auth_claim" -mmin -1 2>/dev/null)" ]; then
	# A refresh started within the last minute and never wrote a value — Claude
	# Code cancels an in-flight statusline script when a new update arrives, so
	# during a busy turn every render would otherwise respawn the ~0.55s probe.
	# Serve the last known value instead of stampeding, and retry in a minute.
	account=$(cat "$auth_cache" 2>/dev/null)
elif mkdir -p "$auth_cache_dir" 2>/dev/null && touch "$auth_claim" 2>/dev/null; then
	# The claim `touch` doubles as the writability test: `mkdir -p` returns 0 for
	# an existing directory whatever its mode, so it cannot tell us that on its
	# own. Marking the claim rather than the value file is what keeps the value's
	# mtime honest — touching the value would restart its TTL without refreshing
	# it, so repeated cancellations could serve stale data indefinitely.
	# Two residuals, both accepted deliberately for a statusline:
	#   - the claim is advisory, not exclusive. `touch` is not atomic, so truly
	#     simultaneous cold renders can both claim and both probe (measured: 2 of
	#     12 got through; 1 of 8 at a realistic render cadence). A lock would cost
	#     more than the stampede it prevents here.
	#   - while refreshes keep failing — cancelled, or the dir turned unwritable —
	#     the last successfully probed value keeps being served past its TTL. That
	#     is the intended trade: a known-slightly-old account beats a blank one,
	#     and one completed probe corrects it.
	account=$(auth_label)
	# Braces so the redirect failure itself is silenced: `>file 2>/dev/null` sets
	# up the redirect BEFORE stderr is diverted, so an unwritable cache dir would
	# otherwise print "cannot create ..." into the terminal.
	{ printf '%s' "$account" >"$auth_cache"; } 2>/dev/null
	# Reap abandoned entries. Only runs on a refresh, never per render.
	find "$auth_cache_dir" -type f -mmin +1440 -delete 2>/dev/null
else
	# Nowhere to store an answer, so do not probe: ~0.55s and a large short-lived
	# process on EVERY render is a worse trade than an absent segment.
	account=$(cat "$auth_cache" 2>/dev/null)
fi

# ── line 1: dir + model + effort ────────────────────────────────────────────────
if [ -n "$effort" ]; then
	line1=$(printf "${BLU}dir${RST}  ${CYN}%s${RST}  ${BLU}model${RST} ${MAG}%s${RST} %s" "$cwd" "$model" "$effort")
else
	line1=$(printf "${BLU}dir${RST}  ${CYN}%s${RST}  ${BLU}model${RST} ${MAG}%s${RST}" "$cwd" "$model")
fi

printf "%s\n" "$line1"

# ── line 2: ctx + 5h (+ reset time) + 7d + wall-time duration ──────────────────
if [ -n "$used_pct" ]; then
	used_int=$(printf '%.0f' "$used_pct")
	col=$(pct_color_ctx "$used_int")
	ctx_seg=$(printf "${BLU}ctx${RST} ${col}%d%%${RST}" "$used_int")
else
	ctx_seg=$(printf '%s' "${BLU}ctx${RST} ${DIM}no data yet${RST}")
fi

five_seg=""
if [ -n "$five_pct" ]; then
	five_int=$(printf '%.0f' "$five_pct")
	col=$(pct_color_usage "$five_int")
	five_seg=$(printf "${BLU}5h${RST} ${col}%d%%${RST}" "$five_int")
	if [ -n "$five_resets" ]; then
		time_str=$(fmt_hhmm "$five_resets")
		five_seg="${five_seg}$(printf " ${GRY}%s${RST}" "$time_str")"
	fi
fi

seven_seg=""
if [ -n "$seven_pct" ]; then
	seven_int=$(printf '%.0f' "$seven_pct")
	col=$(pct_color_usage "$seven_int")
	seven_seg=$(printf "${BLU}7d${RST} ${col}%d%%${RST}" "$seven_int")
fi

line2="$ctx_seg"
[ -n "$five_seg" ] && line2="${line2}  ${five_seg}"
[ -n "$seven_seg" ] && line2="${line2}  ${seven_seg}"

if [ -n "$api_dur_ms" ] && [ "$api_dur_ms" != "0" ]; then
	dur_int=$(printf '%.0f' "$api_dur_ms")
	if [ "$dur_int" -lt 10000 ]; then
		dur_str="${dur_int}ms"
	elif [ "$dur_int" -lt 60000 ]; then
		dur_s=$((dur_int / 1000))
		dur_str="${dur_s}s"
	else
		dur_m=$((dur_int / 60000))
		dur_s=$(((dur_int % 60000) / 1000))
		dur_str="${dur_m}m ${dur_s}s"
	fi
	line2="${line2}$(printf "  ${GRY}%s${RST}" "$dur_str")"
fi

[ -n "$account" ] && line2="${line2}$(printf "  ${GRY}%s${RST}" "$account")"

printf "%s\n" "$line2"
