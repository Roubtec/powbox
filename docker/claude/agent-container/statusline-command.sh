#!/bin/sh

# ── helpers ────────────────────────────────────────────────────────────────────
# ANSI color codes — use printf so variables hold actual escape bytes.
# (Single-quoted '\033' stays literal; printf interprets it into a real ESC char.)
RED=$(printf '\033[0;31m')
YEL=$(printf '\033[0;33m')
GRN=$(printf '\033[0;32m')
CYN=$(printf '\033[0;36m')
BLU=$(printf '\033[0;34m')
MAG=$(printf '\033[0;35m')
DIM=$(printf '\033[2m')
RST=$(printf '\033[0m')

# Build a 10-char block progress bar: ████████░░  (filled/empty)
bar() {
    pct="$1"          # 0–100 integer
    width=10
    filled=$(( pct * width / 100 ))
    empty=$(( width - filled ))
    # pick colour based on percentage
    if [ "$pct" -ge 85 ]; then
        col="$RED"
    elif [ "$pct" -ge 60 ]; then
        col="$YEL"
    else
        col="$GRN"
    fi
    # build the bar string
    bar_str=""
    i=0
    while [ $i -lt $filled ]; do bar_str="${bar_str}█"; i=$(( i + 1 )); done
    i=0
    while [ $i -lt $empty ];  do bar_str="${bar_str}░"; i=$(( i + 1 )); done
    printf "${col}%s${RST}" "$bar_str"
}

# Format seconds → "Xh Ym" or "Ym" or "now"
fmt_remaining() {
    resets_at="$1"
    now=$(date +%s)
    diff=$(( resets_at - now ))
    if [ "$diff" -le 0 ]; then
        printf "now"
        return
    fi
    hours=$(( diff / 3600 ))
    mins=$(( (diff % 3600) / 60 ))
    if [ "$hours" -gt 0 ]; then
        printf "%dh %dm" "$hours" "$mins"
    else
        printf "%dm" "$mins"
    fi
}

# ── parse input (single jq call) ──────────────────────────────────────────────
eval "$(cat | jq -r '
  @sh "cwd=\(.cwd // .workspace.current_dir // "")",
  @sh "model=\(.model.display_name // .model.id // "unknown")",
  @sh "used_pct=\(.context_window.used_percentage // "")",
  @sh "rem_pct=\(.context_window.remaining_percentage // "")",
  @sh "five_pct=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "five_resets=\(.rate_limits.five_hour.resets_at // "")",
  @sh "seven_pct=\(.rate_limits.seven_day.used_percentage // "")",
  @sh "api_dur_ms=\(.cost.total_api_duration_ms // "")"
' | tr '\n' ' ')"

# effort is not in the JSON input; read it from settings as a static label
effort=$(jq -r '.effortLevel // empty' /home/node/.claude/settings.json 2>/dev/null)

# ── line 1: directory + optional api duration ──────────────────────────────────
if [ -n "$api_dur_ms" ] && [ "$api_dur_ms" != "0" ]; then
    dur_int=$(printf '%.0f' "$api_dur_ms")
    if [ "$dur_int" -lt 10000 ]; then
        dur_str="${dur_int}ms"
    elif [ "$dur_int" -lt 60000 ]; then
        dur_s=$(( dur_int / 1000 ))
        dur_str="${dur_s}s"
    else
        dur_m=$(( dur_int / 60000 ))
        dur_s=$(( (dur_int % 60000) / 1000 ))
        dur_str="${dur_m}m ${dur_s}s"
    fi
    printf "${BLU}dir${RST}  ${CYN}%s${RST}  ${DIM}%s${RST}\n" "$cwd" "$dur_str"
else
    printf "${BLU}dir${RST}  ${CYN}%s${RST}\n" "$cwd"
fi

# ── line 2: model + effort + context window (single line) ──────────────────────
# Build model+effort segment
if [ -n "$effort" ]; then
    model_seg=$(printf "${BLU}model${RST} ${MAG}%s${RST}  ${DIM}effort:${RST} %s" "$model" "$effort")
else
    model_seg=$(printf "${BLU}model${RST} ${MAG}%s${RST}" "$model")
fi

# Build context segment and append on the same line
if [ -n "$used_pct" ]; then
    used_int=$(printf '%.0f' "$used_pct")
    rem_int=0
    [ -n "$rem_pct" ] && rem_int=$(printf '%.0f' "$rem_pct")
    printf "%s    ${BLU}ctx${RST} " "$model_seg"
    bar "$used_int"
    printf "  ${DIM}%d%% used / %d%% left${RST}\n" "$used_int" "$rem_int"
else
    printf "%s    ${BLU}ctx${RST} ${DIM}no data yet${RST}\n" "$model_seg"
fi

# ── line 3: rate limits ───────────────────────────────────────────────────────
rate_line=""

if [ -n "$five_pct" ]; then
    five_int=$(printf '%.0f' "$five_pct")
    rate_line="${BLU}5h${RST} "
    rate_line="${rate_line}$(bar "$five_int")"
    rate_line="${rate_line}$(printf "  ${DIM}%d%% used${RST}" "$five_int")"
    if [ -n "$five_resets" ]; then
        remaining=$(fmt_remaining "$five_resets")
        rate_line="${rate_line}$(printf "  ${DIM}resets in${RST} ${YEL}%s${RST}" "$remaining")"
    fi
fi

if [ -n "$seven_pct" ]; then
    seven_int=$(printf '%.0f' "$seven_pct")
    if [ -n "$rate_line" ]; then
        rate_line="${rate_line}    "
    fi
    rate_line="${rate_line}${BLU}7d${RST} "
    rate_line="${rate_line}$(bar "$seven_int")"
    rate_line="${rate_line}$(printf "  ${DIM}%d%% used${RST}" "$seven_int")"
fi

if [ -n "$rate_line" ]; then
    printf "%s\n" "$rate_line"
fi
