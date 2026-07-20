#!/usr/bin/env bash
set -uo pipefail

# Hermetic unit test for the peer-review-run helper (docker/shared/peer-review-run).
#
# No real providers, no image, no network: fake `claude` and `codex` binaries on
# a per-case PATH stand in for the peers. Each fake records the argv it was given
# and the stdin it received, so the test can prove the argument construction,
# literal (never shell-eval'd) prompt handling, read-only permission flags, JSON
# normalization, Codex progress forwarding, timeout/retry policy, process-group
# reaping, and path containment — in BOTH directions (Claude reviewing, Codex
# reviewing), not one shared happy path.
#
# Covered:
#   (1) codex passed + live --json progress forwarded to stderr
#   (2) claude passed, buffered (liveProgress:false), read-only argv asserted,
#       literal prompt delivered on stdin verbatim
#   (3) issues verdict (both providers)
#   (4) unavailable — missing binary, and an auth/usage message (no retry)
#   (5) timeout — deadline enforced, process TREE reaped (grandchild sleeper gone)
#   (6) malformed provider response (exit 0, unparseable) → failed, NOT a pass
#   (7) forfeited — exit 0 with empty / no-verdict output (never a false pass)
#   (8) retry — transient failure retried ONCE with a NEW attempt dir; a clean
#       retry recovers; two failures → failed (retry exhausted)
#   (9) codex without --json support → buffered (liveProgress:false), still runs
#  (10) containment/usage — artifact-root inside the worktree rejected, bad
#       flags exit 64, 0700 attempt dirs, prompt copied into the attempt dir
#
# Runs directly against the repo copy of the helper; the smoke test overrides
# PEER_REVIEW_RUN with the baked /usr/local/bin/peer-review-run to exercise the
# installed artifact.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${PEER_REVIEW_RUN:-${ROOT_DIR}/docker/shared/peer-review-run}"

[ -x "$HELPER" ] || {
	echo "test-peer-review-run: helper not found or not executable: $HELPER" >&2
	exit 1
}
command -v jq >/dev/null || {
	echo "test-peer-review-run: jq is required" >&2
	exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/peer-review-run-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fails=0
checks=0

assert_eq() {
	checks=$((checks + 1))
	if [ "$2" != "$3" ]; then
		fails=$((fails + 1))
		printf 'FAIL [%s]: got %q, want %q\n' "$1" "$2" "$3" >&2
	fi
}
assert_contains() {
	checks=$((checks + 1))
	case "$2" in
	*"$3"*) ;;
	*)
		fails=$((fails + 1))
		printf 'FAIL [%s]: %q does not contain %q\n' "$1" "$2" "$3" >&2
		;;
	esac
}
assert_not_contains() {
	checks=$((checks + 1))
	case "$2" in
	*"$3"*)
		fails=$((fails + 1))
		printf 'FAIL [%s]: %q unexpectedly contains %q\n' "$1" "$2" "$3" >&2
		;;
	*) ;;
	esac
}

jqf() { jq -r "$2" <<<"$1"; }

# --- per-case scaffolding ----------------------------------------------------
# new_case → a fresh dir holding bin/ (fake providers), a worktree, an
# artifact-root, and a prompt file. Echoes the dir. The bin/ dir contains ONLY
# the fakes the case installs, so a "missing binary" case is just an empty bin/.
# mktemp (not a counter) keeps each case unique even though new_case runs in a
# command-substitution subshell where a shared counter would never advance in
# the parent.
new_case() {
	local d
	d="$(mktemp -d "$WORK/case-XXXXXX")"
	mkdir -p "$d/bin" "$d/wt" "$d/artifacts"
	printf 'Please review the diff and end with a VERDICT line.\n' >"$d/prompt.txt"
	printf '%s' "$d"
}

# run <case-dir> <helper args...> — PATH is bin/ PLUS the real tools the helper
# needs (jq/awk/sed/coreutils), but NOT the system claude/codex, so only the
# fakes this case installs are visible. Sets RUN_OUT/RUN_RC/RUN_ERR/RUN_RESULT
# (RESULT = the final stdout line, the JSON object).
run() {
	local d="$1"
	shift
	set +e
	RUN_OUT="$(PATH="$d/bin:/usr/bin:/bin" "$HELPER" "$@" 2>"$d/err")"
	RUN_RC=$?
	set -e 2>/dev/null || true
	RUN_ERR="$(cat "$d/err" 2>/dev/null || true)"
	# stdout carries ONLY the final result JSON (progress goes to stderr), so the
	# whole captured stdout IS the parseable result object.
	RUN_RESULT="$RUN_OUT"
}

# Standard successful helper args for a case dir.
std_args() {
	local d="$1" provider="$2"
	printf -- '--provider %s --worktree %s/wt --prompt-file %s/prompt.txt --artifact-root %s/artifacts --timeout %s' \
		"$provider" "$d" "$d" "$d" "${3:-10}"
}

# ============================================================================
# (1) codex passed + live --json progress forwarded
# ============================================================================
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "options: --json  emit jsonl events"; exit 0; fi
printf '%s\n' "$@" >>"$ARGV_LOG"
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >"$STDIN_LOG"
printf '{"event":"agent_start"}\n'
printf '{"event":"progress","note":"reading files"}\n'
printf 'No problems.\nVERDICT: PASS\n' >"$last"
exit 0
EOF
chmod +x "$d/bin/codex"
ARGV_LOG="$d/argv" STDIN_LOG="$d/stdin"
export ARGV_LOG STDIN_LOG
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "1: helper exit 0" "$RUN_RC" 0
assert_eq "1: outcome passed" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "1: verdict pass" "$(jqf "$RUN_RESULT" .verdict)" pass
assert_eq "1: provider codex" "$(jqf "$RUN_RESULT" .provider)" codex
assert_eq "1: schema" "$(jqf "$RUN_RESULT" .schema)" "powbox.peer-review-run/v1"
assert_eq "1: exitStatus 0" "$(jqf "$RUN_RESULT" .exitStatus)" 0
assert_eq "1: liveProgress true" "$(jqf "$RUN_RESULT" .liveProgress)" true
assert_eq "1: attempts 1" "$(jqf "$RUN_RESULT" .attempts)" 1
# read-only sandbox + no MCP leak + prompt on stdin (argv is `-`, never the text)
assert_contains "1: codex read-only sandbox" "$(cat "$d/argv")" "--sandbox
read-only"
assert_contains "1: codex mcp disabled" "$(cat "$d/argv")" "mcp_servers={}"
assert_contains "1: codex --json when supported" "$(cat "$d/argv")" "--json"
assert_contains "1: codex --cd worktree" "$(cat "$d/argv")" "$d/wt"
assert_contains "1: prompt read from stdin (argv has -)" "$(cat "$d/argv")" "-"
assert_eq "1: literal prompt on stdin" "$(cat "$d/stdin")" "Please review the diff and end with a VERDICT line."
assert_not_contains "1: prompt text NOT on argv" "$(cat "$d/argv")" "VERDICT line"
# live progress forwarded to stderr
assert_contains "1: forwarded agent_start event" "$RUN_ERR" '"event":"progress","provider":"codex"'
assert_contains "1: forwarded the raw provider line" "$RUN_ERR" "agent_start"
unset ARGV_LOG STDIN_LOG

# ============================================================================
# (2) claude passed, buffered, read-only argv, literal prompt via stdin
# ============================================================================
d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ARGV_LOG"
cat >"$STDIN_LOG"
jq -n '{type:"result",subtype:"success",is_error:false,result:"Looks correct.\nVERDICT: PASS"}'
EOF
chmod +x "$d/bin/claude"
ARGV_LOG="$d/argv" STDIN_LOG="$d/stdin"
export ARGV_LOG STDIN_LOG
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "2: outcome passed" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "2: verdict pass" "$(jqf "$RUN_RESULT" .verdict)" pass
assert_eq "2: provider claude" "$(jqf "$RUN_RESULT" .provider)" claude
assert_eq "2: liveProgress false (buffered)" "$(jqf "$RUN_RESULT" .liveProgress)" false
assert_contains "2: buffered honesty note on stderr" "$RUN_ERR" '"liveProgress":false'
# read-only headless: -p, json output, allow/deny lists, add-dir; NO --dangerously-skip-permissions
assert_contains "2: claude headless -p" "$(cat "$d/argv")" "-p"
assert_contains "2: claude json output" "$(cat "$d/argv")" "--output-format
json"
assert_contains "2: claude allowlist includes Read" "$(cat "$d/argv")" "Read Grep Glob"
assert_contains "2: claude disallows Write/Edit" "$(cat "$d/argv")" "Write Edit"
assert_contains "2: claude --add-dir worktree" "$(cat "$d/argv")" "$d/wt"
assert_not_contains "2: claude NOT skip-permissions" "$(cat "$d/argv")" "--dangerously-skip-permissions"
assert_eq "2: literal prompt on stdin" "$(cat "$d/stdin")" "Please review the diff and end with a VERDICT line."
unset ARGV_LOG STDIN_LOG

# ============================================================================
# (3) issues verdict, both providers
# ============================================================================
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >/dev/null
printf 'Found a null-deref.\nVERDICT: ISSUES\n' >"$last"; exit 0
EOF
chmod +x "$d/bin/codex"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "3a: codex issues outcome" "$(jqf "$RUN_RESULT" .outcome)" issues
assert_eq "3a: codex issues verdict" "$(jqf "$RUN_RESULT" .verdict)" issues

d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
jq -n '{type:"result",is_error:false,result:"There is a bug.\nVERDICT: request changes"}'
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "3b: claude issues outcome" "$(jqf "$RUN_RESULT" .outcome)" issues
assert_eq "3b: claude issues verdict" "$(jqf "$RUN_RESULT" .verdict)" issues

# ============================================================================
# (4) unavailable — missing binary and auth/usage message (no retry)
# ============================================================================
d="$(new_case)" # empty bin/ → provider not on PATH
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "4a: missing binary → unavailable" "$(jqf "$RUN_RESULT" .outcome)" unavailable
assert_eq "4a: exitStatus null" "$(jqf "$RUN_RESULT" .exitStatus)" null
assert_eq "4a: attempts 1 (no retry)" "$(jqf "$RUN_RESULT" .attempts)" 1
assert_eq "4a: helper still exits 0" "$RUN_RC" 0

d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
cat >/dev/null
echo "Error: usage limit reached. Please try again later." >&2
exit 1
EOF
chmod +x "$d/bin/codex"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "4b: usage exhaustion → unavailable" "$(jqf "$RUN_RESULT" .outcome)" unavailable
assert_eq "4b: NOT retried (auth is non-transient)" "$(jqf "$RUN_RESULT" .attempts)" 1
assert_eq "4b: retried false" "$(jqf "$RUN_RESULT" .retried)" false

# ============================================================================
# (5) timeout — deadline enforced, process TREE reaped
# ============================================================================
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
cat >/dev/null
# spawn a grandchild sleeper in the same process group; record its pid
sleep 60 &
echo $! >"$SLEEPER_PID"
wait
EOF
chmod +x "$d/bin/codex"
SLEEPER_PID="$d/sleeper.pid"
export SLEEPER_PID
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex 1)
assert_eq "5: outcome timeout" "$(jqf "$RUN_RESULT" .outcome)" timeout
assert_eq "5: exitStatus null on timeout" "$(jqf "$RUN_RESULT" .exitStatus)" null
sp="$(cat "$SLEEPER_PID" 2>/dev/null || echo)"
checks=$((checks + 1))
if [ -n "$sp" ] && kill -0 "$sp" 2>/dev/null; then
	fails=$((fails + 1))
	printf 'FAIL [5: sleeper reaped]: pid %s still alive after timeout\n' "$sp" >&2
	kill -9 "$sp" 2>/dev/null || true
fi
unset SLEEPER_PID

# ============================================================================
# (6) malformed provider response (exit 0, unparseable) → failed, NOT a pass
# ============================================================================
d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "this is not json at all"
exit 0
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "6: malformed → failed" "$(jqf "$RUN_RESULT" .outcome)" failed
assert_not_contains "6: malformed is never a pass" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "6: not retried (deterministic)" "$(jqf "$RUN_RESULT" .attempts)" 1

# ============================================================================
# (7) forfeited — exit 0 with empty output, and exit 0 with no VERDICT token
# ============================================================================
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >/dev/null
: >"$last"   # empty final message
exit 0
EOF
chmod +x "$d/bin/codex"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "7a: empty output → forfeited" "$(jqf "$RUN_RESULT" .outcome)" forfeited
assert_eq "7a: verdict none" "$(jqf "$RUN_RESULT" .verdict)" none

d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
jq -n '{type:"result",is_error:false,result:"I looked at it and it seems okay to me."}'
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "7b: no VERDICT token → forfeited (never a false pass)" "$(jqf "$RUN_RESULT" .outcome)" forfeited
assert_eq "7b: verdict none" "$(jqf "$RUN_RESULT" .verdict)" none

# ============================================================================
# (8) retry — transient failure retried once (new dir); recover; exhaust → failed
# ============================================================================
# 8a: fail once (marker), then pass on retry.
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >/dev/null
if [ ! -f "$MARK" ]; then : >"$MARK"; echo "transient crash" >&2; exit 1; fi
printf 'VERDICT: PASS\n' >"$last"; exit 0
EOF
chmod +x "$d/bin/codex"
MARK="$d/mark"
export MARK
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "8a: transient recovers → passed" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "8a: attempts 2" "$(jqf "$RUN_RESULT" .attempts)" 2
assert_eq "8a: retried true" "$(jqf "$RUN_RESULT" .retried)" true
# two DISTINCT attempt dirs were created (never reused)
attempt_dirs="$(find "$d/artifacts" -maxdepth 1 -type d -name 'peer-review-*' | wc -l | tr -d ' ')"
assert_eq "8a: two separate attempt dirs" "$attempt_dirs" 2
unset MARK

# 8b: fail twice → failed (retry exhausted).
d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "crash" >&2
exit 7
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "8b: exhausted → failed" "$(jqf "$RUN_RESULT" .outcome)" failed
assert_eq "8b: attempts 2" "$(jqf "$RUN_RESULT" .attempts)" 2
assert_eq "8b: retried true" "$(jqf "$RUN_RESULT" .retried)" true

# ============================================================================
# (9) codex WITHOUT --json support → buffered, still runs (liveProgress false)
# ============================================================================
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "options: --sandbox --cd"; exit 0; fi   # no --json advertised
printf '%s\n' "$@" >>"$ARGV_LOG"
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >/dev/null
printf 'VERDICT: PASS\n' >"$last"; exit 0
EOF
chmod +x "$d/bin/codex"
ARGV_LOG="$d/argv"
export ARGV_LOG
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "9: still passes without --json" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "9: liveProgress false when unsupported" "$(jqf "$RUN_RESULT" .liveProgress)" false
assert_not_contains "9: --json omitted when unsupported" "$(cat "$d/argv")" "--json"
unset ARGV_LOG

# ============================================================================
# (10) containment + usage + artifact hygiene
# ============================================================================
# 10a: artifact-root inside the worktree is rejected (exit 64, no JSON).
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
[ "$1" = exec ] && [ "$2" = --help ] && { echo "--json"; exit 0; }
exit 0
EOF
chmod +x "$d/bin/codex"
run "$d" --provider codex --worktree "$d/wt" --prompt-file "$d/prompt.txt" --artifact-root "$d/wt/inside" --timeout 5
assert_eq "10a: artifact-root inside worktree rejected (exit 64)" "$RUN_RC" 64
assert_contains "10a: explains the containment error" "$RUN_ERR" "OUTSIDE"

# 10b: unknown provider rejected.
d="$(new_case)"
run "$d" --provider gpt5 --worktree "$d/wt" --prompt-file "$d/prompt.txt" --artifact-root "$d/artifacts"
assert_eq "10b: bad provider exit 64" "$RUN_RC" 64

# 10c: relative worktree rejected.
d="$(new_case)"
run "$d" --provider codex --worktree wt --prompt-file "$d/prompt.txt" --artifact-root "$d/artifacts"
assert_eq "10c: relative worktree rejected" "$RUN_RC" 64

# 10d: missing prompt file rejected.
d="$(new_case)"
run "$d" --provider codex --worktree "$d/wt" --prompt-file "$d/nope.txt" --artifact-root "$d/artifacts"
assert_eq "10d: missing prompt file rejected" "$RUN_RC" 64

# 10e: a successful run leaves a 0700 attempt dir with the prompt copied in.
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >/dev/null
printf 'VERDICT: PASS\n' >"$last"; exit 0
EOF
chmod +x "$d/bin/codex"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
adir="$(jqf "$RUN_RESULT" .artifactDir)"
assert_contains "10e: artifactDir under artifact-root" "$adir" "$d/artifacts/"
mode="$(stat -c '%a' "$adir" 2>/dev/null || stat -f '%Lp' "$adir" 2>/dev/null)"
assert_eq "10e: attempt dir is owner-only 0700" "$mode" 700
checks=$((checks + 1))
if [ ! -f "$adir/prompt.txt" ]; then
	fails=$((fails + 1))
	printf 'FAIL [10e: prompt copied into attempt dir]: %s/prompt.txt missing\n' "$adir" >&2
fi
assert_eq "10e: copied prompt is the literal prompt" "$(cat "$adir/prompt.txt")" "Please review the diff and end with a VERDICT line."

# 10f: -h prints usage and exits 0.
d="$(new_case)"
run "$d" -h
assert_eq "10f: -h exit 0" "$RUN_RC" 0
assert_contains "10f: -h prints usage" "$RUN_OUT" "peer-review-run"

if [ "$fails" -ne 0 ]; then
	echo "peer-review-run unit test: $fails/$checks checks FAILED." >&2
	exit 1
fi
echo "peer-review-run unit test passed ($checks checks)."
