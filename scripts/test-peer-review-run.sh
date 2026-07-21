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
#   (6) malformed/error-envelope response → forfeited (distinct from failed),
#       NEVER a pass — a pass token in an error/non-result envelope is rejected
#   (7) forfeited — exit 0 with empty / no-verdict output (never a false pass)
#   (8) retry policy is a TRANSIENT ALLOWLIST — a POSITIVELY transient failure
#       (network/5xx/timeout) is retried ONCE with a NEW attempt dir and recovers;
#       two transient failures → failed (retry exhausted); a deterministic
#       bad-flag/usage failure is NOT retried; an UNCLASSIFIED non-zero exit
#       (no transient signal) is NOT retried either (8d); and elapsedSeconds is
#       the TOTAL across both attempts, not the final attempt alone (8e)
#   (9) codex without --json support → buffered (liveProgress:false), still runs
#  (10) containment/usage — artifact-root inside the worktree rejected, bad
#       flags exit 64, 0700 attempt dirs, prompt copied into the attempt dir,
#       and an invalid --timeout exits 64 BEFORE the session dir is created
#       (a usage error never litters the artifact root)
#  (11) failure-path reaping (non-timeout stray reaped), a stubborn TERM-ignoring
#       descendant escalated to KILL and actually dies, sibling isolation proven
#       BEHAVIORALLY AND HONESTLY (a fake provider probes a sibling's planted
#       secret two ways: through HANDED paths — argv/stdin/--cd/--output-last-message
#       — where it comes up empty, AND by DELIBERATE ../.. traversal to the shared
#       artifact-root where a same-UID reader with no mount-namespace sandbox CAN
#       reach it; the test asserts the by-default guarantee without pretending the
#       nesting is traversal-proof), anchored verdict + ISSUES-precedence (no
#       example-token false-pass; a MIXED verdict line — pass token then issue
#       token, e.g. "APPROVED, CHANGES REQUIRED", including one whose pass token
#       is itself a negated alias, "NO ISSUES, CHANGES REQUIRED" — resolves to
#       issues, while negated pass language like "no issues found" still
#       passes), and the
#       read-only tool-set / no-persistence flags for both providers (Claude
#       restricted to native read tools passed one-rule-per-argv-element, no
#       Bash; Codex config/hook isolation — --ignore-user-config /
#       --ignore-rules / --disable hooks / --ask-for-approval never — asserted
#       present when the CLI advertises them, omitted when not (see case 9),
#       with the version-independent -c approval_policy=never and
#       -c project_doc_max_bytes=0 overrides passed unconditionally)
#  (11f) a descendant that LEAVES the validated process group (setsid) is still
#       reaped: the group signal cannot reach it, so the poll-tick descendant
#       snapshot plus the start-time-verified per-PID sweep must
#  (12) FAIL-SAFE unvalidated-PGID fallback: a captured descendant PID whose
#       baseline /proc start time was empty/unreadable at capture is treated as
#       NON-matching — never counted alive, never signalled — so a recycled PID
#       cannot be TERM/KILL'd; and a LIVE WALK is refused once the walk root no
#       longer matches its captured baseline, so a recycled LEADER PID can never
#       have an unrelated process's children captured for the sweep (driving the
#       real supervision functions directly)
#  (13) the codex help probe cannot hang: a background child of `--help` that
#       inherits stdout must not hold the capture open past the probe timeout
#       (file-based capture, no pipe)
#
# Runs directly against the repo copy of the helper; the smoke test overrides
# PEER_REVIEW_RUN with the baked /usr/local/bin/peer-review-run to exercise the
# installed artifact.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${PEER_REVIEW_RUN:-${ROOT_DIR}/docker/shared/peer-review-run}"

# Invoked via `bash "$HELPER"` below, so readability (not the exec bit) is what
# matters — the in-tree copies of these baked helpers are committed 0644 and rely
# on the Dockerfile's COPY --chmod=755 for the installed artifact.
[ -r "$HELPER" ] || {
	echo "test-peer-review-run: helper not found or not readable: $HELPER" >&2
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
	# The harness runs under `set -uo pipefail` WITHOUT -e, so a non-zero helper
	# exit lands in RUN_RC without any errexit toggling. (An earlier version
	# bracketed this with `set +e` / `set -e`, but that ENABLED errexit globally
	# from the first run() call onward — the script never turns it on — changing
	# control flow so an unexpected non-zero status could abort the harness
	# instead of being recorded as a failed assertion.)
	RUN_OUT="$(PATH="$d/bin:/usr/bin:/bin" bash "$HELPER" "$@" 2>"$d/err")"
	RUN_RC=$?
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
# Version-independent -c overrides ride unconditionally: approvals can never
# stall a headless run, and the reviewed worktree's AGENTS.md is not read as
# instructions (the code under review must not steer its own reviewer).
assert_contains "1: codex approvals forced off" "$(cat "$d/argv")" "approval_policy=never"
assert_contains "1: codex project docs (AGENTS.md) disabled" "$(cat "$d/argv")" "project_doc_max_bytes=0"
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
# Permission rules ride as SEPARATE argv elements (one rule per value, the
# documented permission-rule syntax) — the argv log prints one line per arg, so
# consecutive lines prove distinct arguments, and a single space-joined
# "Read Grep Glob" value (one line) must NOT appear: a strict rule parser would
# read that as one unmatched rule and approve nothing.
assert_contains "2: claude allow rules are separate args" "$(cat "$d/argv")" "--allowedTools
Read
Grep
Glob"
assert_not_contains "2: allow rules NOT one space-joined value" "$(cat "$d/argv")" "Read Grep Glob"
assert_contains "2: claude disallows Write/Edit as separate args" "$(cat "$d/argv")" "Write
Edit"
assert_contains "2: claude --add-dir worktree" "$(cat "$d/argv")" "$d/wt"
assert_not_contains "2: claude NOT skip-permissions" "$(cat "$d/argv")" "--dangerously-skip-permissions"
# Read-only is enforced by the TOOL SET, not allowlisted read commands: the Bash
# tool is restricted out entirely (so there is no shell to redirect-write with)
# and only the native read tools remain. --tools carries exactly those.
assert_contains "2: claude --tools restricts to native read tools" "$(cat "$d/argv")" "Read,Grep,Glob"
assert_contains "2: claude disallow names Bash first" "$(cat "$d/argv")" "--disallowedTools
Bash
Write
Edit"
assert_not_contains "2: no Bash(cat) read-shim (redirection write vector)" "$(cat "$d/argv")" "Bash(cat"
assert_not_contains "2: no Bash(git ...) read-shim" "$(cat "$d/argv")" "Bash(git"
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

# 4c: a SUCCESSFUL review (exit 0, pass verdict) that merely DISCUSSES rate
# limits must stay passed — the auth/usage scan only applies on a non-zero exit.
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >/dev/null
printf 'The new rate limit / 429 backoff handling looks correct.\nVERDICT: PASS\n' >"$last"
exit 0
EOF
chmod +x "$d/bin/codex"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "4c: exit-0 review discussing rate limits stays passed" "$(jqf "$RUN_RESULT" .outcome)" passed

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
# (6) malformed provider response (exit 0, unparseable) → forfeited, NOT a pass,
#     and a DISTINCT outcome from retry-exhausted `failed` (see 8b).
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
assert_eq "6: malformed → forfeited (distinct from failed)" "$(jqf "$RUN_RESULT" .outcome)" forfeited
assert_not_contains "6: malformed is never a pass" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "6: verdict none" "$(jqf "$RUN_RESULT" .verdict)" none
assert_eq "6: not retried (deterministic clean exit)" "$(jqf "$RUN_RESULT" .attempts)" 1

# 6b: an ERROR envelope (is_error:true) or non-result type that CONTAINS a pass
# token must NOT become passed — the envelope is honored, so this is forfeited.
d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
jq -n '{type:"result",is_error:true,result:"All good.\nVERDICT: PASS"}'
exit 0
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "6b: error envelope w/ pass token → forfeited" "$(jqf "$RUN_RESULT" .outcome)" forfeited
assert_not_contains "6b: error envelope is never a pass" "$(jqf "$RUN_RESULT" .outcome)" passed

# 6c: a non-"result" type envelope carrying a pass token is likewise not a pass.
d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
jq -n '{type:"error",subtype:"max_turns",result:"VERDICT: PASS"}'
exit 0
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "6c: non-result type w/ pass token → forfeited" "$(jqf "$RUN_RESULT" .outcome)" forfeited

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
# First attempt fails with a POSITIVELY transient signal (network reset); the
# retry allowlist recognizes it and retries once, then it passes.
if [ ! -f "$MARK" ]; then : >"$MARK"; echo "error sending request: connection reset by peer" >&2; exit 1; fi
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
# two DISTINCT attempt dirs were created (never reused); both nested under the
# single per-invocation session dir (attempt dirs are not direct children of the
# artifact-root — see case 11c for the sibling-isolation rationale).
attempt_dirs="$(find "$d/artifacts" -type d -name 'peer-review-*' | wc -l | tr -d ' ')"
assert_eq "8a: two separate attempt dirs" "$attempt_dirs" 2
unset MARK

# 8c: a DETERMINISTIC failure (bad flag / usage error) must NOT be retried —
# retrying a deterministic failure just wastes time and quota. Distinct from the
# transient 8a/8b crashes above.
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
cat >/dev/null
echo "error: unknown flag '--frobnicate'" >&2
echo "usage: codex exec [OPTIONS]" >&2
exit 2
EOF
chmod +x "$d/bin/codex"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "8c: deterministic failure → failed" "$(jqf "$RUN_RESULT" .outcome)" failed
assert_eq "8c: NOT retried (deterministic)" "$(jqf "$RUN_RESULT" .attempts)" 1
assert_eq "8c: retried false" "$(jqf "$RUN_RESULT" .retried)" false

# 8b: a TRANSIENT failure on BOTH attempts → failed (retry exhausted). Both emit
# a positively transient signal, so the allowlist retries once then exhausts.
d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "error: network is unreachable (ECONNREFUSED)" >&2
exit 7
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "8b: exhausted → failed" "$(jqf "$RUN_RESULT" .outcome)" failed
assert_eq "8b: attempts 2" "$(jqf "$RUN_RESULT" .attempts)" 2
assert_eq "8b: retried true" "$(jqf "$RUN_RESULT" .retried)" true

# 8d: an UNCLASSIFIED non-zero exit — no transient signal, no auth/usage phrase —
# must NOT be retried. This proves the retry policy is a transient ALLOWLIST
# (retry only positively-identified transient failures), not a denylist that
# retries every unknown non-zero exit.
d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "boom: the model produced an internal assertion we do not recognize" >&2
exit 5
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "8d: unknown failure → failed" "$(jqf "$RUN_RESULT" .outcome)" failed
assert_eq "8d: NOT retried (unknown is not transient)" "$(jqf "$RUN_RESULT" .attempts)" 1
assert_eq "8d: retried false" "$(jqf "$RUN_RESULT" .retried)" false
assert_eq "8d: exitStatus preserved" "$(jqf "$RUN_RESULT" .exitStatus)" 5

# 8e: elapsedSeconds on a retried run is the TOTAL across BOTH attempts, not the
# final attempt overwritten in place. Each fake attempt sleeps ≥0.6s, so two
# attempts must report ≥1.1s — a single final-attempt value (~0.6s) would fail.
# (Lower-bound only: sleep never returns early, so this cannot flake fast.)
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >/dev/null
sleep 0.6
if [ ! -f "$MARK" ]; then : >"$MARK"; echo "error sending request: connection reset by peer" >&2; exit 1; fi
printf 'VERDICT: PASS\n' >"$last"; exit 0
EOF
chmod +x "$d/bin/codex"
MARK="$d/mark"
export MARK
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "8e: transient recovers → passed" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "8e: attempts 2" "$(jqf "$RUN_RESULT" .attempts)" 2
elapsed="$(jqf "$RUN_RESULT" .elapsedSeconds)"
checks=$((checks + 1))
if ! awk -v e="$elapsed" 'BEGIN{exit !(e>=1.1)}'; then
	fails=$((fails + 1))
	printf 'FAIL [8e: elapsedSeconds totals both attempts]: got %s, want >= 1.1\n' "$elapsed" >&2
fi
unset MARK

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
# The probed isolation flags degrade the same way: an older CLI that does not
# advertise them is invoked without them (mcp-only isolation), never with an
# unknown flag it would reject.
assert_not_contains "9: --ignore-user-config omitted when unsupported" "$(cat "$d/argv")" "--ignore-user-config"
assert_not_contains "9: --ignore-rules omitted when unsupported" "$(cat "$d/argv")" "--ignore-rules"
assert_not_contains "9: --disable hooks omitted when unsupported" "$(cat "$d/argv")" "--disable"
assert_not_contains "9: --ask-for-approval omitted when unsupported" "$(cat "$d/argv")" "--ask-for-approval"
# The -c overrides are NOT probed flags: they must survive an older CLI too
# (an unrecognized config key is ignored without --strict-config).
assert_contains "9: approval_policy=never still passed on an older CLI" "$(cat "$d/argv")" "approval_policy=never"
assert_contains "9: project_doc_max_bytes=0 still passed on an older CLI" "$(cat "$d/argv")" "project_doc_max_bytes=0"
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
# The rejection must NOT have mutated the read-only review target: the rejected
# in-worktree artifact-root is never created (containment is checked before mkdir).
checks=$((checks + 1))
if [ -e "$d/wt/inside" ]; then
	fails=$((fails + 1))
	printf 'FAIL [10a: rejected in-worktree root not created]: %s exists\n' "$d/wt/inside" >&2
fi

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

# 10g: an invalid --timeout is a usage error (exit 64) that must be caught
# BEFORE the session dir is created — an argument error must not litter the
# artifact root with an empty prr-* directory.
d="$(new_case)"
run "$d" --provider codex --worktree "$d/wt" --prompt-file "$d/prompt.txt" --artifact-root "$d/artifacts" --timeout nope
assert_eq "10g: invalid --timeout rejected (exit 64)" "$RUN_RC" 64
leftover="$(find "$d/artifacts" -mindepth 1 | wc -l | tr -d ' ')"
assert_eq "10g: no session dir created on a usage error" "$leftover" 0

# 10f: -h prints usage and exits 0.
d="$(new_case)"
run "$d" -h
assert_eq "10f: -h exit 0" "$RUN_RC" 0
assert_contains "10f: -h prints usage" "$RUN_OUT" "peer-review-run"

# ============================================================================
# (11) failure-path & stubborn-descendant reaping, sibling isolation, anchored
#      verdict, and the read-only / no-persistence flag set
# ============================================================================

# 11a: FAILURE-path (not timeout) reaping — a provider that EXITS non-zero while
# leaving a stray grandchild behind in its group must have that grandchild reaped
# too (the existing case 5 only covers the timeout path).
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
cat >/dev/null
sleep 60 &                 # grandchild in the provider's own group
echo $! >"$SLEEPER_PID"
echo "error: unknown flag '--x'" >&2   # deterministic → single attempt
exit 2
EOF
chmod +x "$d/bin/codex"
SLEEPER_PID="$d/sleeper.pid"
export SLEEPER_PID
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "11a: deterministic failure → failed" "$(jqf "$RUN_RESULT" .outcome)" failed
sp="$(cat "$SLEEPER_PID" 2>/dev/null || echo)"
checks=$((checks + 1))
if [ -n "$sp" ] && kill -0 "$sp" 2>/dev/null; then
	fails=$((fails + 1))
	printf 'FAIL [11a: failure-path sleeper reaped]: pid %s still alive after exit\n' "$sp" >&2
	kill -9 "$sp" 2>/dev/null || true
fi
unset SLEEPER_PID

# 11b: a STUBBORN descendant that ignores TERM must be escalated to KILL and
# actually die — proves reap_tree's grace→KILL escalation, not just a lone TERM.
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
cat >/dev/null
# grandchild traps (ignores) TERM; only KILL can stop it. It records its own pid.
bash -c 'trap "" TERM; echo $$ >"$STUBBORN_PID"; while :; do sleep 0.2; done' &
wait
EOF
chmod +x "$d/bin/codex"
STUBBORN_PID="$d/stubborn.pid"
export STUBBORN_PID
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex 1)
assert_eq "11b: outcome timeout" "$(jqf "$RUN_RESULT" .outcome)" timeout
# give KILL escalation a beat to complete, then confirm the stubborn child is gone
stub=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
	stub="$(cat "$STUBBORN_PID" 2>/dev/null || echo)"
	[ -n "$stub" ] && ! kill -0 "$stub" 2>/dev/null && break
	sleep 0.2
done
checks=$((checks + 1))
if [ -n "$stub" ] && kill -0 "$stub" 2>/dev/null; then
	fails=$((fails + 1))
	printf 'FAIL [11b: stubborn descendant KILLed]: pid %s survived TERM+KILL\n' "$stub" >&2
	kill -9 "$stub" 2>/dev/null || true
fi
unset STUBBORN_PID

# 11c: sibling-attempt isolation, proven BEHAVIORALLY and HONESTLY. Two invocations
# share ONE artifact-root. Each fake provider PLANTS a secret sentinel in its own
# attempt dir, then runs TWO probes:
#
#   Probe A — HANDED PATHS ONLY (the guarantee the helper actually makes): search
#     the paths the runner handed it — its own attempt dir (via
#     --output-last-message) and its cwd (--cd, the worktree). A sibling must NOT
#     appear here: the runner nests every attempt under a per-invocation,
#     unpredictably-named session dir and hands the provider only paths inside its
#     OWN session, so a sibling's artifacts are never handed on argv/stdin/--cd/
#     --output-last-message, nor are they a neighbour of the handed attempt dir.
#
#   Probe B — DELIBERATE ../.. TRAVERSAL (the documented residual): climb out of
#     the handed attempt dir to the shared artifact-root and search it. This is
#     NOT read-only-namespaced in this hermetic harness (nor under the providers'
#     real read-only sandboxes, which are permission/read-only, not a private
#     mount namespace), so a determined SAME-UID reader that manually walks up CAN
#     reach a sibling. The test asserts this HONESTLY rather than pretending the
#     nesting is traversal-proof: filesystem permissions alone cannot stop a
#     same-UID reader, and complete isolation would need a filesystem sandbox
#     (bubblewrap / private mount namespace) — out of scope for this helper. What
#     the helper guarantees is that it never HANDS a sibling/parent path and a
#     normal review never encounters one (Probe A); it does NOT claim a hostile
#     provider cannot manually traverse to one (Probe B).
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
printf '%s\n' "$@" >"$ARGV_LOG"     # overwrite: capture THIS invocation's argv only
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >"$STDIN_LOG"
mydir="$(dirname "$last")"
own="$mydir/SIBLING-SECRET.txt"
printf 'TOP-SECRET\n' >"$own"
# Probe A: HANDED paths only (own attempt dir + cwd), no climbing out. Our own
# sentinel is excluded, so any hit means a sibling leaked into a HANDED path.
handed=NOLEAK
while IFS= read -r hit; do
	[ "$hit" -ef "$own" ] && continue
	handed="LEAK:$hit"
done < <(find "$mydir" "$PWD" -name SIBLING-SECRET.txt 2>/dev/null)
printf '%s\n' "$handed" >"$HANDED_LOG"
# Probe B: DELIBERATE upward traversal to the shared artifact-root (../.. out of
# the handed attempt dir → session dir → artifact-root). Records whether a
# same-UID reader with no mount-namespace sandbox CAN reach a sibling this way.
trav=NONE
while IFS= read -r hit; do
	[ "$hit" -ef "$own" ] && continue
	trav="REACHED:$hit"
done < <(find "$mydir/../.." -name SIBLING-SECRET.txt 2>/dev/null)
printf '%s\n' "$trav" >"$TRAV_LOG"
printf 'VERDICT: PASS\n' >"$last"; exit 0
EOF
chmod +x "$d/bin/codex"
ARGV_LOG="$d/argv" STDIN_LOG="$d/stdin" HANDED_LOG="$d/handed" TRAV_LOG="$d/trav"
export ARGV_LOG STDIN_LOG HANDED_LOG TRAV_LOG
# invocation A: plants secret A (its own upward-traversal finds no sibling yet)
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
adir1="$(jqf "$RUN_RESULT" .artifactDir)"
sess1="$(dirname "$adir1")"
# invocation B: plants secret B, then probes for A's secret both ways
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
adir2="$(jqf "$RUN_RESULT" .artifactDir)"
sess2="$(dirname "$adir2")"
# (a) THE GUARANTEE: B could NOT read A's sentinel through any HANDED path.
assert_eq "11c: handed-path probe finds no sibling (the by-default guarantee)" "$(cat "$d/handed")" NOLEAK
# The runner never handed B a path referencing A's session, on argv or stdin.
assert_not_contains "11c: sibling session path not on B's argv" "$(cat "$d/argv")" "$sess1"
assert_not_contains "11c: sibling session path not on B's stdin" "$(cat "$d/stdin")" "$sess1"
# --cd is the worktree under review, NOT the artifact root/session (artifacts stay
# out of the reviewed tree, and the provider is rooted at the tree, not at them).
cd_val="$(awk '/^--cd$/{getline; print; exit}' "$d/argv")"
assert_eq "11c: --cd is EXACTLY the worktree under review" "$cd_val" "$(realpath "$d/wt")"
assert_not_contains "11c: --cd is NOT the artifact root/session" "$cd_val" "/artifacts"
# --output-last-message points strictly inside B's OWN attempt dir — the ONLY
# artifact path handed to the provider — never a sibling/parent.
olm_val="$(awk '/^--output-last-message$/{getline; print; exit}' "$d/argv")"
assert_eq "11c: --output-last-message is inside B's own attempt dir" "$olm_val" "$adir2/codex-last-message.txt"
assert_not_contains "11c: --output-last-message does not point at the sibling session" "$olm_val" "$sess1"
# (b) THE RESIDUAL, asserted honestly: a manual ../.. traversal by a same-UID
# provider DOES reach the sibling here (no mount-namespace sandbox). The helper is
# NOT traversal-proof and the test must not pretend otherwise; complete isolation
# would require a filesystem sandbox (bubblewrap / private mount namespace).
assert_contains "11c: manual ../.. traversal CAN reach a sibling (documented residual, not traversal-proof)" "$(cat "$d/trav")" "REACHED:"
# Structural backing: distinct per-invocation session dirs, nested under the
# artifact-root (never a direct child), each holding only its own attempt.
assert_eq "11c: artifactDir parent is the artifact-root's child (session)" "$(dirname "$sess1")" "$d/artifacts"
checks=$((checks + 1))
if [ "$sess1" = "$sess2" ]; then
	fails=$((fails + 1))
	printf 'FAIL [11c: distinct per-invocation session dirs]: both used %s\n' "$sess1" >&2
fi
direct_attempts="$(find "$d/artifacts" -mindepth 1 -maxdepth 1 -type d -name 'peer-review-*' | wc -l | tr -d ' ')"
assert_eq "11c: no attempt dir directly under artifact-root" "$direct_attempts" 0
own_only="$(find "$sess1" -maxdepth 1 -type d -name 'peer-review-*' | wc -l | tr -d ' ')"
assert_eq "11c: session dir holds only its own invocation's attempt" "$own_only" 1
unset ARGV_LOG STDIN_LOG HANDED_LOG TRAV_LOG

# 11d: anchored verdict + ISSUES precedence. A body that QUOTES an example pass
# token inline but renders a real ISSUES verdict must resolve to issues; and when
# both verdict lines appear, ISSUES wins over PASS — never a false pass.
d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
body=$'For reference, reviewers end with a VERDICT: PASS line when clean.\nVERDICT: ISSUES'
jq -n --arg r "$body" '{type:"result",is_error:false,result:$r}'
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: inline example pass + real issues line → issues" "$(jqf "$RUN_RESULT" .outcome)" issues
assert_eq "11d: verdict issues (no false pass)" "$(jqf "$RUN_RESULT" .verdict)" issues

d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
body=$'VERDICT: PASS\nVERDICT: ISSUES'
jq -n --arg r "$body" '{type:"result",is_error:false,result:$r}'
EOF
chmod +x "$d/bin/claude"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: both verdict lines → ISSUES precedence" "$(jqf "$RUN_RESULT" .outcome)" issues

# 11d-boundary: the PASS token needs a TRAILING boundary so a longer word cannot
# false-pass, and the literal contract enumeration line must never pass.
emit_verdict_case() {
	# emit_verdict_case <case-dir> <body> — a claude fake whose final message is the
	# given body verbatim.
	cat >"$1/bin/claude" <<EOF
#!/usr/bin/env bash
cat >/dev/null
jq -n --arg r $(printf '%q' "$2") '{type:"result",is_error:false,result:\$r}'
EOF
	chmod +x "$1/bin/claude"
}

# (i) VERDICT: PASSING must NOT be read as a pass — no trailing boundary would let
# `pass` match the prefix of `PASSING`.
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: PASSING"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_not_contains "11d: VERDICT: PASSING is never a pass" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "11d: VERDICT: PASSING → verdict none (forfeited)" "$(jqf "$RUN_RESULT" .verdict)" none

# (ii) The literal contract template line `VERDICT: PASS | ISSUES` enumerates both
# options — it is not a real verdict and must resolve to issues (ISSUES present),
# never a false pass.
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: PASS | ISSUES"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_not_contains "11d: contract line 'VERDICT: PASS | ISSUES' never passes" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "11d: 'VERDICT: PASS | ISSUES' → issues (ISSUES present)" "$(jqf "$RUN_RESULT" .verdict)" issues

# (iii) A bare `VERDICT: PASS` alone still passes — the boundary fix must not
# regress the ordinary clean verdict.
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: PASS"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: bare 'VERDICT: PASS' still passes" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "11d: bare 'VERDICT: PASS' → verdict pass" "$(jqf "$RUN_RESULT" .verdict)" pass

# (iv) A MIXED verdict line — an approval token followed by an issue token on the
# SAME line, beyond the `|`/`/` template separators — must resolve to issues,
# never pass: the verdict value is scanned as a whole.
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: APPROVED, CHANGES REQUIRED"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_not_contains "11d: 'APPROVED, CHANGES REQUIRED' never passes" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "11d: 'APPROVED, CHANGES REQUIRED' → issues" "$(jqf "$RUN_RESULT" .verdict)" issues

d="$(new_case)"
emit_verdict_case "$d" "VERDICT: PASS but changes required in a follow-up"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: 'PASS but changes required' → issues" "$(jqf "$RUN_RESULT" .verdict)" issues

# (v) A NEGATED issue phrase is pass language, not a mixed signal: the whole-line
# scan must not turn "no issues found" into an issues verdict.
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: PASS — no issues found"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: 'PASS — no issues found' still passes" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "11d: 'PASS — no issues found' → verdict pass" "$(jqf "$RUN_RESULT" .verdict)" pass

# ...and an ordinary word merely CONTAINING an issue token ("unchanged") does not
# trip the mixed-line scan either (both-side boundary check).
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: PASS (the API surface is unchanged)"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: 'PASS (… unchanged)' still passes" "$(jqf "$RUN_RESULT" .outcome)" passed

# ...and further negated-phrase pass shapes stay passes: the scrub tolerates one
# intervening word ("no blocking changes") and the other negation words ("zero").
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: PASSED with no blocking changes"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: 'PASSED with no blocking changes' still passes" "$(jqf "$RUN_RESULT" .outcome)" passed
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: PASS with zero failures"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: 'PASS with zero failures' still passes" "$(jqf "$RUN_RESULT" .outcome)" passed

# (vi) A `no issues`-style alias AT the verdict value is the pass token there —
# the negation scrub must not delete it and hide a mixed line: an issue token
# following it on the same line must resolve to issues, never a false pass.
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: NO ISSUES, CHANGES REQUIRED"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_not_contains "11d: 'NO ISSUES, CHANGES REQUIRED' never passes" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "11d: 'NO ISSUES, CHANGES REQUIRED' → issues" "$(jqf "$RUN_RESULT" .verdict)" issues

# ...while the alias stays a real pass when nothing mixed follows it — bare, with
# trailing prose, or with a further NEGATED issue phrase (still pass language).
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: NO ISSUES"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: bare 'VERDICT: NO ISSUES' still passes" "$(jqf "$RUN_RESULT" .outcome)" passed
assert_eq "11d: bare 'VERDICT: NO ISSUES' → verdict pass" "$(jqf "$RUN_RESULT" .verdict)" pass
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: no issues found"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: 'no issues found' still passes" "$(jqf "$RUN_RESULT" .outcome)" passed
d="$(new_case)"
emit_verdict_case "$d" "VERDICT: NO ISSUES - no changes needed"
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_eq "11d: 'NO ISSUES - no changes needed' still passes" "$(jqf "$RUN_RESULT" .outcome)" passed

# 11f: a descendant that LEAVES the validated process group must still be
# reaped. `set -m` isolates the provider into its own group and the group signal
# reaps that group — but a provider tool that starts a NEW session/process group
# (setsid) has left the group, so only the poll-tick descendant snapshot plus
# the start-time-verified per-PID sweep can reach it. The fake provider setsids
# a sleeper (still its child, so the live walk sees it), stays alive long enough
# for a poll tick to snapshot it, then exits cleanly — a clean pass must NOT
# leave the escapee running.
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json"; exit 0; fi
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >/dev/null
# a descendant in a NEW session/process group — outside the validated group
setsid sleep 60 >/dev/null 2>&1 &
echo $! >"$ESCAPEE_PID"
sleep 1   # stay alive so the poll loop (100ms ticks) snapshots the escapee
printf 'VERDICT: PASS\n' >"$last"; exit 0
EOF
chmod +x "$d/bin/codex"
ESCAPEE_PID="$d/escapee.pid"
export ESCAPEE_PID
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
assert_eq "11f: outcome passed" "$(jqf "$RUN_RESULT" .outcome)" passed
esc="$(cat "$ESCAPEE_PID" 2>/dev/null || echo)"
# give the post-exit sweep a beat, then the escapee must be gone
for _ in 1 2 3 4 5; do
	[ -n "$esc" ] && ! kill -0 "$esc" 2>/dev/null && break
	sleep 0.2
done
checks=$((checks + 1))
if [ -z "$esc" ] || kill -0 "$esc" 2>/dev/null; then
	fails=$((fails + 1))
	printf 'FAIL [11f: setsid group-escapee reaped]: pid %s still alive (or unrecorded) after a clean exit\n' "${esc:-<none>}" >&2
	[ -n "$esc" ] && kill -9 "$esc" 2>/dev/null
fi
unset ESCAPEE_PID

# 11e: read-only / no-persistence flag set is locked in for both providers. (The
# real write/read enforcement is the provider's own sandbox and is verifiable
# only in the live smoke; here we assert the enforcing flags are actually passed.)
d="$(new_case)"
cat >"$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ARGV_LOG"
cat >/dev/null
jq -n '{type:"result",is_error:false,result:"VERDICT: PASS"}'
EOF
chmod +x "$d/bin/claude"
ARGV_LOG="$d/argv"
export ARGV_LOG
# shellcheck disable=SC2046
run "$d" $(std_args "$d" claude)
assert_contains "11e: claude --safe-mode (customizations off)" "$(cat "$d/argv")" "--safe-mode"
assert_contains "11e: claude --no-session-persistence" "$(cat "$d/argv")" "--no-session-persistence"
assert_contains "11e: claude --tools restricts the built-in tool set" "$(cat "$d/argv")" "Read,Grep,Glob"
# Permission rules are one-per-argv-element (see case 2) — never a space-joined
# single value a strict rule parser would treat as one unmatched rule.
assert_not_contains "11e: allow rules never one space-joined value" "$(cat "$d/argv")" "Read Grep Glob"
# No Bash tool at all → no allowlisted read command can redirect-write. Assert no
# `Bash(...)` command-prefix shim survives anywhere in the argv.
assert_not_contains "11e: no Bash(...) command-prefix read-shim" "$(cat "$d/argv")" "Bash("
assert_not_contains "11e: claude NOT skip-permissions" "$(cat "$d/argv")" "--dangerously-skip-permissions"
unset ARGV_LOG

d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then echo "--json --ignore-user-config --ignore-rules --disable <FEATURE> --ask-for-approval <APPROVAL_POLICY>"; exit 0; fi
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
assert_contains "11e: codex --sandbox read-only" "$(cat "$d/argv")" "--sandbox
read-only"
assert_contains "11e: codex --ephemeral (no session persistence)" "$(cat "$d/argv")" "--ephemeral"
assert_contains "11e: codex mcp disabled" "$(cat "$d/argv")" "mcp_servers={}"
# Config/hook isolation (the Codex analog of --safe-mode): when the CLI
# advertises them, user config (and with it persisted project trust), execpolicy
# rules, and the hooks feature are all switched off, so the reviewed worktree's
# project-local config/hooks cannot steer its own reviewer.
assert_contains "11e: codex --ignore-user-config (drops project trust)" "$(cat "$d/argv")" "--ignore-user-config"
assert_contains "11e: codex --ignore-rules (no execpolicy rules)" "$(cat "$d/argv")" "--ignore-rules"
assert_contains "11e: codex hooks feature disabled" "$(cat "$d/argv")" "--disable
hooks"
# Approvals can never stall the headless run: the probed flag spelling is added
# when the CLI advertises it, and the -c override rides unconditionally.
assert_contains "11e: codex --ask-for-approval never when advertised" "$(cat "$d/argv")" "--ask-for-approval
never"
assert_contains "11e: codex approval_policy=never override" "$(cat "$d/argv")" "approval_policy=never"
# The reviewed worktree's AGENTS.md is not loaded as reviewer instructions.
assert_contains "11e: codex project docs disabled (AGENTS.md not read)" "$(cat "$d/argv")" "project_doc_max_bytes=0"
unset ARGV_LOG

# ============================================================================
# (12) FAIL-SAFE empty/unreadable baseline start time on the unvalidated-PGID
#      fallback. A captured descendant PID whose baseline start time could NOT be
#      read at capture (empty) must be treated as NON-matching: never counted alive,
#      never TERM/KILL'd — otherwise a PID the kernel recycled after a failed /proc
#      read could be signalled, hitting an unrelated same-UID process. These drive
#      the helper's REAL supervision functions directly (extracted verbatim), since
#      the fallback path is not reachable through the full-helper harness (set -m
#      normally isolates the child into its own group → the validated-PGID path).
# ============================================================================

# Extract a shell function's definition verbatim from the helper. Every supervision
# function opens with `name() {` at column 1 and closes with `}` at column 1.
extract_fn() {
	awk -v fn="$1" 'index($0, fn"() {")==1{g=1} g{print} g && /^}/{exit}' "$HELPER"
}
eval "$(
	for f in proc_starttime pid_matches descendant_pids captured_start capture_descendants group_alive signal_tree; do
		extract_fn "$f"
	done
)"

# (a) pid_matches: an EMPTY baseline is non-matching (fail safe); a real baseline
# for a live process still matches (the fix must not break the normal match).
myst="$(proc_starttime $$)"
checks=$((checks + 1))
if pid_matches $$ ""; then
	fails=$((fails + 1))
	printf 'FAIL [12a: empty baseline must be NON-matching (fail safe)]\n' >&2
fi
checks=$((checks + 1))
if ! pid_matches $$ "$myst"; then
	fails=$((fails + 1))
	printf 'FAIL [12a: a correct non-empty baseline must still match]\n' >&2
fi

# (b) group_alive on the fallback: a LIVE captured PID with an empty baseline must
# NOT be counted alive (it cannot be positively re-identified).
sleep 30 &
victim=$!
CAPTURED_DESC=" ${victim}: "
checks=$((checks + 1))
if group_alive "$victim" ""; then
	fails=$((fails + 1))
	printf 'FAIL [12b: empty-baseline captured PID must NOT count as alive]\n' >&2
fi

# (c) signal_tree on the fallback: an empty-baseline captured PID must NOT be
# signalled — the live victim survives a TERM sweep.
CAPTURED_DESC=" ${victim}: "
signal_tree TERM "$victim" ""
checks=$((checks + 1))
if ! kill -0 "$victim" 2>/dev/null; then
	fails=$((fails + 1))
	printf 'FAIL [12c: empty-baseline captured PID must NOT be signalled]\n' >&2
fi

# (d) CONTROL: with the CORRECT baseline the SAME captured PID IS reached and TERM'd
# — proving the skip in (c) is due to the empty baseline, not a broken sweep.
# shellcheck disable=SC2034  # read as a global inside the eval'd signal_tree
CAPTURED_DESC=" ${victim}:$(proc_starttime "$victim") "
signal_tree TERM "$victim" ""
w=0
while kill -0 "$victim" 2>/dev/null && [ "$w" -lt 30 ]; do
	sleep 0.1
	w=$((w + 1))
done
checks=$((checks + 1))
if kill -0 "$victim" 2>/dev/null; then
	fails=$((fails + 1))
	printf 'FAIL [12d: matched-baseline captured PID must BE signalled]\n' >&2
	kill -9 "$victim" 2>/dev/null || true
fi
# (e) RECAPTURE GUARD: a live walk is refused once the walk root no longer
# matches its captured baseline. A stale/wrong baseline for the root simulates a
# leader whose PID the kernel recycled for an unrelated process — walking it
# would capture a STRANGER's children with fresh, valid start times and hand
# them to the sweep. The root's live child must NOT be captured then; with the
# CORRECT baseline the same walk DOES capture it (control).
sleep 30 &
kid=$!
CAPTURED_DESC=" $$:1 " # wrong baseline for the walk root (this shell)
capture_descendants $$
checks=$((checks + 1))
case "$CAPTURED_DESC" in
*" ${kid}:"*)
	fails=$((fails + 1))
	printf 'FAIL [12e: stale-root live walk must NOT capture (recycled-leader hazard)]\n' >&2
	;;
esac
CAPTURED_DESC=" $$:$(proc_starttime $$) " # control: correct baseline
capture_descendants $$
checks=$((checks + 1))
case "$CAPTURED_DESC" in
*" ${kid}:"*) ;;
*)
	fails=$((fails + 1))
	printf 'FAIL [12e: matched-root live walk must still capture the child]\n' >&2
	;;
esac
kill "$kid" 2>/dev/null || true
wait "$kid" 2>/dev/null || true
unset CAPTURED_DESC

# ============================================================================
# (13) the codex help probe must not hang when `--help` leaves a background
#      child that INHERITED stdout: with a pipe-based $(...) capture the read
#      would block on EOF until that child exits (~60s here), long after
#      `timeout` killed the probe itself; the file-based capture has no pipe
#      reader, so the run completes promptly.
# ============================================================================
d="$(new_case)"
cat >"$d/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = exec ] && [ "$2" = --help ]; then
	# background child inheriting stdout/stderr — the write end a pipe capture
	# would wait on; setsid keeps it clear of the probe's own process group
	setsid sleep 60 &
	echo $! >"$PROBE_STRAY"
	echo "--json"
	exit 0
fi
last=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) last="$2"; shift 2;; *) shift;; esac; done
cat >/dev/null
printf 'VERDICT: PASS\n' >"$last"; exit 0
EOF
chmod +x "$d/bin/codex"
PROBE_STRAY="$d/probe-stray.pid"
export PROBE_STRAY
t0=$(date +%s)
# shellcheck disable=SC2046
run "$d" $(std_args "$d" codex)
t1=$(date +%s)
assert_eq "13: run still passes with a stray probe child" "$(jqf "$RUN_RESULT" .outcome)" passed
checks=$((checks + 1))
if [ $((t1 - t0)) -ge 30 ]; then
	fails=$((fails + 1))
	printf 'FAIL [13: probe capture must not hang on the stray child]: run took %ss\n' "$((t1 - t0))" >&2
fi
stray="$(cat "$PROBE_STRAY" 2>/dev/null || echo)"
[ -n "$stray" ] && kill -9 "$stray" 2>/dev/null
unset PROBE_STRAY

if [ "$fails" -ne 0 ]; then
	echo "peer-review-run unit test: $fails/$checks checks FAILED." >&2
	exit 1
fi
echo "peer-review-run unit test passed ($checks checks)."
