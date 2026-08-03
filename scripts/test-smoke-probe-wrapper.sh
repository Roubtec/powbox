#!/usr/bin/env bash
# Unit test for the smoke-test probe execution logic in
# scripts/smoke-test-image.sh (and, when pwsh is available, its .ps1 mirror).
#
# Hermetic: no image, no Docker daemon, no network. A fake `docker` on PATH
# captures the FULL argument vector the driver would have run, and optionally
# replays it with the host /bin/sh so the `set -e` semantics the wrapper exists
# to fix can be asserted end to end.
#
# What it pins:
#   * probes cross to the container as POSITIONAL ARGUMENTS, verbatim, and the
#     only script text `docker` ever receives is a FIXED runner that contains no
#     probe text - so adversarial probe text (quotes, $, backticks, backslashes,
#     |, &&) can never be re-parsed, injected into the diagnostic, or reach a
#     neighbouring probe;
#   * every clause of a probe is binding: a failing non-final member of an `&&`
#     chain, of a bare `;` sequence, or of a `{ ...; }` group aborts the run and
#     names the probe by index;
#   * probe text cannot CONSUME the failure guard (a trailing `#` comment used
#     to swallow a same-line `|| { ...; exit 1; }` tail whole);
#   * each probe runs in its OWN shell, so `cd`/`export`/variables do not leak
#     between probes while filesystem effects do - the deliberate behaviour
#     change the argv form buys;
#   * newline-bearing, empty and line-continuation probes are rejected before
#     docker is invoked;
#   * the .sh and .ps1 drivers hand docker a byte-identical argument vector.
#
# Section K re-tests holes the earlier `if`-condition form left open, each with
# a control proving the pre-fix form really did leak. Section L is different in
# kind: it CHARACTERIZES the one limitation that remains accepted (a probe
# ending in `&`). That assertion pins what the wrapper does, not what it should
# do - a change that closes it should flip the assertion and the prose, not be
# reverted.
# shellcheck disable=SC2016  # single-quoted probe/runner/PowerShell text is LITERAL by design here
# shellcheck disable=SC1003  # trailing backslashes in probe literals are the payload, not an escape
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRIVER_SH="${ROOT_DIR}/scripts/smoke-test-image.sh"
DRIVER_PS1="${ROOT_DIR}/scripts/smoke-test-image.ps1"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/powbox-smoke-wrapper-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

failures=0
checks=0

ok() {
	checks=$((checks + 1))
	printf '  ok    %s\n' "$1"
}

bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  FAIL  %s\n' "$1" >&2
	if [ "$#" -gt 1 ]; then
		shift
		printf '        %s\n' "$@" >&2
	fi
}

# The runner the drivers must hand `docker`, restated here independently so a
# change to it shows up as a test failure rather than being silently mirrored.
EXPECTED_RUNNER='i=0; for p in "$@"; do i=$((i + 1)); sh -ec "$p" || { printf "%s\n" "SMOKE PROBE $i FAILED" >&2; exit 1; }; done'
# Fixed argv prefix before the probes: everything up to and including the `$0`
# slot the runner's `"$@"` sits behind.
EXPECTED_PREFIX=(run --rm --entrypoint /bin/sh fake-image:latest -lc "$EXPECTED_RUNNER" smoke-probes)
# argv slot the runner occupies: second-to-last of the fixed prefix.
RUNNER_SLOT=$((${#EXPECTED_PREFIX[@]} - 2))

# ---------------------------------------------------------------------------
# Fake docker: records the FULL argv (NUL-separated, so probe bytes survive
# intact) and replays it under the host /bin/sh when SMOKE_TEST_EXEC=1. The
# driver invokes it as
#   docker run --rm --entrypoint /bin/sh <image> -lc <runner> <name> <probe>...
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<'SHIM'
#!/bin/sh
: >"$SMOKE_TEST_CAPTURE"
for a in "$@"; do printf '%s\0' "$a" >>"$SMOKE_TEST_CAPTURE"; done
# Replay `sh -lc <runner> <name> <probe>...` with the host shell. `-l` is
# dropped on purpose: the host's login profile must not colour the results.
while [ "$#" -gt 0 ] && [ "$1" != "-lc" ]; do shift; done
[ "$#" -gt 0 ] || exit 0
shift
runner="$1"
shift
if [ "${SMOKE_TEST_EXEC:-0}" = 1 ]; then
	/bin/sh -c "$runner" "$@"
	exit $?
fi
exit 0
SHIM
chmod +x "$TMP/bin/docker"
PATH="$TMP/bin:$PATH"
export PATH

CAPTURE="$TMP/capture"
export SMOKE_TEST_CAPTURE="$CAPTURE"

# run_driver <exec:0|1> <outfile> <probe>...
run_driver() {
	local exec_mode="$1" outfile="$2"
	shift 2
	rm -f "$CAPTURE"
	SMOKE_TEST_EXEC="$exec_mode" "$DRIVER_SH" fake-image:latest "$@" >"$outfile" 2>&1
	return $?
}

# Loads the captured argv into the global ARGS array, byte-exact.
ARGS=()
capture_args() {
	ARGS=()
	local a
	while IFS= read -r -d '' a; do ARGS+=("$a"); done <"$CAPTURE"
}

# ---------------------------------------------------------------------------
# Adversarial probe corpus. Nothing here resembles today's probe set by
# accident: each entry carries at least one metacharacter that a naive
# "interpolate the probe into a quoted echo" wrapper would mangle or execute.
# ---------------------------------------------------------------------------
adversarial=(
	# single quotes (breaks a single-quoted diagnostic)
	"true # it's a probe"
	# double quotes + $ expansion (breaks a double-quoted diagnostic, and the
	# $(...) would EXECUTE if the text were re-parsed)
	'x="a b" && [ "$x" = "a b" ] && printf "%s\n" "$(echo interpolated)" >/dev/null'
	# backticks - the other command-substitution syntax
	'true && printf "%s" `printf backtick` >/dev/null'
	# backslashes, including a trailing-escape shape
	'printf "a\\b\n" | grep -q "a" && printf "%s\n" "back\\slash" >/dev/null'
	# pipes and && mixed, plus ${} expansion
	'v=abc && [ "${v#a}" = bc ] && printf "%s\n" "$v" | grep -q abc'
	# a quote-closing injection attempt aimed at the diagnostic itself
	"true # '; echo PWNED_SQ; '"
	'true # "; echo PWNED_DQ; "'
	# ${IFS}, glob chars, semicolons inside quotes, redirection text
	'printf "%s\n" "a;b>c|d&e" | grep -q "a;b>c|d&e"'
	# a probe that is itself already `|| { ...; exit 1; }`-tailed (the .NET
	# shape) - the outer guard must stay compatible with it
	'[ 1 = 1 ] && [ 2 = 2 ] || { printf "%s\n" "inner tail" >&2; exit 1; }'
	# a probe whose LAST token is a comment - with a same-line tail this ate the
	# whole guard; as argv it cannot reach anything (the failing twin of this
	# shape is section C2)
	'[ 1 = 1 ] && [ 2 = 2 ] # trailing comment eats a same-line tail'
	# a comment ending in an EVEN backslash run: a literal backslash, not a line
	# continuation, so it must be accepted
	'true # even backslash run \\'
	# a `;` sequence whose members all succeed - accepted, and (section K3)
	# now binding in every member
	'true; [ 1 = 1 ]; printf "%s\n" "seq" >/dev/null'
)

printf 'A. probes cross as argv; the only script text is the FIXED runner\n'
run_driver 0 "$TMP/a.out" "${adversarial[@]}"
rc=$?
if [ "$rc" -ne 0 ]; then
	bad "driver exited $rc on the adversarial corpus" "$(cat "$TMP/a.out")"
else
	ok "driver accepted the adversarial corpus"
fi

if [ ! -s "$CAPTURE" ]; then
	bad "no argv captured from the fake docker"
else
	capture_args
	want_argc=$((${#EXPECTED_PREFIX[@]} + ${#adversarial[@]}))
	if [ "${#ARGS[@]}" -eq "$want_argc" ]; then
		ok "docker received exactly one argument per probe plus the fixed prefix (${#ARGS[@]})"
	else
		bad "argv length mismatch" "want $want_argc, got ${#ARGS[@]}" "argv: ${ARGS[*]}"
	fi

	prefix_ok=1
	for k in "${!EXPECTED_PREFIX[@]}"; do
		if [ "${ARGS[$k]:-}" != "${EXPECTED_PREFIX[$k]}" ]; then
			bad "argv slot $k differs from the expected fixed prefix" "expected: ${EXPECTED_PREFIX[$k]}" "got:      ${ARGS[$k]:-<missing>}"
			prefix_ok=0
			break
		fi
	done
	if [ "$prefix_ok" -eq 1 ]; then
		ok "docker is invoked as \`run --rm --entrypoint /bin/sh <image> -lc <runner> smoke-probes\`"
	fi

	# The runner is the ONLY argument the container shell parses as a script,
	# and it must be free of probe text - that is what makes the wrapping
	# injection-proof structurally rather than by escaping.
	runner_arg="${ARGS[$RUNNER_SLOT]:-}"
	runner_clean=1
	for probe in "${adversarial[@]}"; do
		if [ "${runner_arg#*"$probe"}" != "$runner_arg" ]; then
			bad "probe text leaked into the runner script" "probe: $probe"
			runner_clean=0
			break
		fi
	done
	[ "$runner_clean" -eq 1 ] && ok "no probe text appears anywhere in the runner script"

	# Probes must arrive verbatim, in order, after the fixed prefix.
	n=0
	verbatim_ok=1
	for probe in "${adversarial[@]}"; do
		got="${ARGS[$((${#EXPECTED_PREFIX[@]} + n))]:-}"
		if [ "$got" != "$probe" ]; then
			bad "probe $((n + 1)) was not passed verbatim" "expected: $probe" "got:      $got"
			verbatim_ok=0
		fi
		n=$((n + 1))
	done
	[ "$verbatim_ok" -eq 1 ] && ok "every probe reaches docker verbatim as its own argument"

	# The diagnostic in the runner may only ever carry the loop index.
	if [ "$runner_arg" = "$EXPECTED_RUNNER" ]; then
		ok "the runner is the expected fixed one-liner (index-only diagnostic)"
	else
		bad "the runner text changed" "expected: $EXPECTED_RUNNER" "got:      $runner_arg"
	fi

	printf '%s\n' "$runner_arg" >"$TMP/runner.sh"
	if /bin/sh -n "$TMP/runner.sh" 2>"$TMP/syntax.err"; then
		ok "runner parses under /bin/sh -n"
	else
		bad "runner is not valid /bin/sh" "$(cat "$TMP/syntax.err")"
	fi
fi

# The runner must be INDEPENDENT of the probe list: a completely different
# corpus has to produce the identical script argument.
run_driver 0 "$TMP/a2.out" "true" 'false || true'
capture_args
if [ "${ARGS[$RUNNER_SLOT]:-}" = "$EXPECTED_RUNNER" ]; then
	ok "the runner is identical for a different probe list (fixed text, not built)"
else
	bad "the runner varied with the probe list" "got: ${ARGS[$RUNNER_SLOT]:-<missing>}"
fi

printf 'B. the adversarial corpus actually RUNS green (no probe was mangled)\n'
run_driver 1 "$TMP/b.out" "${adversarial[@]}"
rc=$?
if [ "$rc" -eq 0 ] && grep -q "Smoke test passed" "$TMP/b.out"; then
	ok "all adversarial probes execute and pass through the wrapper"
else
	bad "adversarial corpus did not run green (rc=$rc)" "$(cat "$TMP/b.out")"
fi
if grep -q "PWNED_SQ\|PWNED_DQ" "$TMP/b.out"; then
	bad "probe text escaped into the shell as code (injection)" "$(cat "$TMP/b.out")"
else
	ok "no probe text was re-parsed as code"
fi

printf 'C. a failing NON-FINAL clause of a NON-FINAL probe aborts the run\n'
# `[ -n "" ]` is the middle clause: exactly the shape POSIX set -e exempts, on a
# probe that is not the last line, so its non-zero status was discarded before.
run_driver 1 "$TMP/c.out" \
	"true" \
	'[ 1 = 1 ] && [ -n "" ] && [ 2 = 2 ]' \
	"true" \
	"true"
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "masked middle clause now fails the run (rc=$rc)"
else
	bad "masked middle clause still passed" "$(cat "$TMP/c.out")"
fi
if grep -q "SMOKE PROBE 2 FAILED" "$TMP/c.out"; then
	ok "failure names the offending probe by index"
else
	bad "failure did not name probe 2" "$(cat "$TMP/c.out")"
fi
if grep -Fq '2  [ 1 = 1 ] && [ -n "" ] && [ 2 = 2 ]' "$TMP/c.out"; then
	ok "manifest maps the index back to the probe text"
else
	bad "manifest did not list probe 2 verbatim" "$(cat "$TMP/c.out")"
fi

printf 'C2. a trailing `#` comment cannot consume the failure guard\n'
# Regression for the same-line `<probe> || { ...; exit 1; }` form: `false # note`
# became `false # note || { ...; exit 1; }`, the guard was commented out, and the
# failure was discarded - the exact masking this wrapper exists to remove. The
# corpus in section A carries comment-bearing probes but only PASSING ones, which
# is why that shape slipped through; these must FAIL.
run_driver 1 "$TMP/c2.out" \
	"true" \
	"false # a trailing comment must not swallow the guard" \
	"true"
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SMOKE PROBE 2 FAILED" "$TMP/c2.out"; then
	ok "a failing comment-tailed probe fails the run and names index 2"
else
	bad "comment-tailed probe did not fail the run (rc=$rc)" "$(cat "$TMP/c2.out")"
fi

# Same thing on the shape that actually appears in the probe list: a multi-clause
# `&&` chain whose middle clause fails, with a trailing comment after it.
run_driver 1 "$TMP/c3.out" \
	"true" \
	'[ 1 = 1 ] && [ -n "" ] && [ 2 = 2 ] # note about this probe' \
	"true"
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SMOKE PROBE 2 FAILED" "$TMP/c3.out"; then
	ok "masked middle clause is still caught when the probe ends in a comment"
else
	bad "comment-tailed && chain did not fail the run (rc=$rc)" "$(cat "$TMP/c3.out")"
fi

# Guard against this test becoming a tautology, the same way D guards C: the
# same-line tail form must genuinely have masked it. Note the shape matters -
# a BARE `false # note` still tripped `set -e` on its own (the comment cost only
# the diagnostic), whereas an `&&` chain with a trailing comment lost the guard
# AND kept the `set -e` exemption, i.e. a real false PASS. That is the case
# below, and it is the shape the Stage 1 list is full of.
cat >"$TMP/old-form.sh" <<'OLDFORM'
set -e
true
[ 1 = 1 ] && [ -n "" ] && [ 2 = 2 ] # note || { printf '%s\n' 'SMOKE PROBE 2 FAILED' >&2; exit 1; }
true
OLDFORM
if /bin/sh "$TMP/old-form.sh" >"$TMP/old-form.out" 2>&1; then
	ok "the old same-line tail really was consumed by the comment (regression is real)"
else
	bad "the old same-line tail no longer masks this - C2 may be vacuous" "$(cat "$TMP/old-form.out")"
fi
# The same list WITHOUT the comment was caught by the old form - so it is the
# comment, not the chain, that made the difference.
cat >"$TMP/old-form-nc.sh" <<'OLDFORMNC'
set -e
true
[ 1 = 1 ] && [ -n "" ] && [ 2 = 2 ] || { printf '%s\n' 'SMOKE PROBE 2 FAILED' >&2; exit 1; }
true
OLDFORMNC
if /bin/sh "$TMP/old-form-nc.sh" >"$TMP/old-form-nc.out" 2>&1; then
	bad "the comment-free old form also masked - C2 is not isolating the comment"
else
	ok "the comment alone is what defeated the old same-line tail"
fi

printf 'D. the pre-fix behaviour is genuinely what C exercises\n'
# Guard against the test silently becoming a tautology: the same probe list
# joined the OLD way (bare lines under `set -e`) must still exit 0. If this ever
# stops being true, /bin/sh changed and test C proves less than it claims.
old_join=$'set -e\ntrue\n[ 1 = 1 ] && [ -n "" ] && [ 2 = 2 ]\ntrue\ntrue\n'
if /bin/sh -c "$old_join"; then
	ok "unwrapped join still masks the failure (so the wrapper is load-bearing)"
else
	bad "unwrapped join no longer masks the failure - test C may be vacuous"
fi

printf 'E. the FIRST and the LAST probe are both binding, with correct indices\n'
run_driver 1 "$TMP/e1.out" \
	'[ -n "" ] && true' \
	"true"
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SMOKE PROBE 1 FAILED" "$TMP/e1.out"; then
	ok "first probe failure is reported as index 1"
else
	bad "first-probe failure not reported correctly (rc=$rc)" "$(cat "$TMP/e1.out")"
fi
run_driver 1 "$TMP/e2.out" \
	"true" \
	"true" \
	'[ 1 = 1 ] && [ -n "" ] && [ 2 = 2 ]'
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SMOKE PROBE 3 FAILED" "$TMP/e2.out"; then
	ok "last probe failure is reported as index 3"
else
	bad "last-probe failure not reported correctly (rc=$rc)" "$(cat "$TMP/e2.out")"
fi

printf 'F. pipeline-shaped probes stay enforced (and stay producer-agnostic)\n'
run_driver 1 "$TMP/f1.out" "true" "printf 'x\n' | grep -q nope" "true"
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SMOKE PROBE 2 FAILED" "$TMP/f1.out"; then
	ok "a pipeline whose grep fails is reported"
else
	bad "failing pipeline probe not reported (rc=$rc)" "$(cat "$TMP/f1.out")"
fi
# Deliberate non-goal: pipefail is NOT enabled in the runner or in the per-probe
# shell, so a producer that fails after emitting the expected text still passes.
# Pinned so enabling pipefail becomes a conscious, test-visible decision.
run_driver 1 "$TMP/f2.out" "true" "{ printf 'x\n'; false; } | grep -q x" "true"
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "producer-side masking is unchanged (pipefail deliberately not set)"
else
	bad "pipeline producer status became binding - pipefail crept in? (rc=$rc)" "$(cat "$TMP/f2.out")"
fi

printf 'G. malformed probes are rejected before docker runs\n'
rm -f "$CAPTURE"
SMOKE_TEST_EXEC=0 "$DRIVER_SH" fake-image:latest "true" $'a\nb' "true" >"$TMP/g1.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q "single-line" "$TMP/g1.out"; then
	ok "newline-bearing probe rejected with an explanatory message"
else
	bad "newline-bearing probe not rejected (rc=$rc)" "$(cat "$TMP/g1.out")"
fi
if [ ! -e "$CAPTURE" ]; then
	ok "docker was never invoked for the rejected list"
else
	bad "docker ran despite a rejected probe"
fi

rm -f "$CAPTURE"
SMOKE_TEST_EXEC=0 "$DRIVER_SH" fake-image:latest "true" "   " >"$TMP/g2.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q "is empty" "$TMP/g2.out"; then
	ok "empty probe rejected"
else
	bad "empty probe not rejected (rc=$rc)" "$(cat "$TMP/g2.out")"
fi

rm -f "$CAPTURE"
SMOKE_TEST_EXEC=0 "$DRIVER_SH" fake-image:latest "true" $'a\rb' >"$TMP/g3.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q "carriage return" "$TMP/g3.out"; then
	ok "carriage-return-bearing probe rejected"
else
	bad "CR-bearing probe not rejected (rc=$rc)" "$(cat "$TMP/g3.out")"
fi

# A trailing ODD backslash run is a line continuation with nothing to continue:
# `sh -ec` drops it and silently runs the TRUNCATED command, so an author who
# lost the probe's second half would get a green run. Rejected up front.
rm -f "$CAPTURE"
SMOKE_TEST_EXEC=0 "$DRIVER_SH" fake-image:latest "true" 'printf x \' >"$TMP/g4.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q "line continuation" "$TMP/g4.out"; then
	ok "line-continuation probe rejected"
else
	bad "line-continuation probe not rejected (rc=$rc)" "$(cat "$TMP/g4.out")"
fi
if [ ! -e "$CAPTURE" ]; then
	ok "docker was never invoked for the line-continuation list"
else
	bad "docker ran despite a rejected line-continuation probe"
fi
# ...and the rejection is not decorative: the probe shell really does swallow it
# and pass, which is why the driver has to refuse it rather than let it through.
if /bin/sh -ec 'printf x \' >"$TMP/g4b.out" 2>&1; then
	ok "a truncated continuation really does pass under \`sh -ec\` (rejection is load-bearing)"
else
	bad "\`sh -ec 'printf x \\'\` now fails on its own - the rejection rationale needs updating" "$(cat "$TMP/g4b.out")"
fi

# ...but an EVEN run is a literal backslash and must still be accepted (covered
# green in section A/B; asserted here as the explicit boundary).
rm -f "$CAPTURE"
SMOKE_TEST_EXEC=0 "$DRIVER_SH" fake-image:latest "true" 'true # even \\' >"$TMP/g5.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "even trailing backslash run accepted (literal, not a continuation)"
else
	bad "even trailing backslash run was rejected (rc=$rc)" "$(cat "$TMP/g5.out")"
fi

printf 'H. the .ps1 driver hands docker a byte-identical argument vector\n'
if command -v pwsh >/dev/null 2>&1; then
	rm -f "$CAPTURE"
	SMOKE_TEST_EXEC=0 "$DRIVER_SH" fake-image:latest "${adversarial[@]}" >/dev/null 2>&1
	cp "$CAPTURE" "$TMP/from-sh"

	# Hand the same corpus to the PowerShell driver via a generated caller so
	# the probe strings cross the boundary unmangled (single-quoted PS literals
	# with '' escaping).
	{
		printf '$ErrorActionPreference = "Stop"\n'
		printf '& "%s" -Image fake-image:latest -Commands @(\n' "$DRIVER_PS1"
		for probe in "${adversarial[@]}"; do
			printf "  '%s'\n" "${probe//\'/\'\'}"
		done
		printf ')\n'
	} >"$TMP/call.ps1"

	rm -f "$CAPTURE"
	if pwsh -NoProfile -File "$TMP/call.ps1" >"$TMP/h.out" 2>&1; then
		if [ -s "$CAPTURE" ] && cmp -s "$TMP/from-sh" "$CAPTURE"; then
			ok ".ps1 and .sh drivers pass docker byte-identical argv (runner + probes)"
		else
			bad ".ps1 passed different arguments than .sh" "$(diff -u <(tr '\0' '\n' <"$TMP/from-sh") <(tr '\0' '\n' <"$CAPTURE") 2>&1 | head -40)"
		fi
	else
		bad "pwsh driver invocation failed" "$(cat "$TMP/h.out")"
	fi

	# Rejection parity.
	rm -f "$CAPTURE"
	cat >"$TMP/reject.ps1" <<PS
\$ErrorActionPreference = "Stop"
& "$DRIVER_PS1" -Image fake-image:latest -Commands @('true', "a\`nb")
PS
	if pwsh -NoProfile -File "$TMP/reject.ps1" >"$TMP/h2.out" 2>&1; then
		bad ".ps1 accepted a newline-bearing probe" "$(cat "$TMP/h2.out")"
	else
		if grep -q "single-line" "$TMP/h2.out"; then
			ok ".ps1 rejects a newline-bearing probe with the same rationale"
		else
			bad ".ps1 rejected the probe for the wrong reason" "$(cat "$TMP/h2.out")"
		fi
	fi

	# Line-continuation rejection parity.
	rm -f "$CAPTURE"
	cat >"$TMP/reject-bs.ps1" <<PS
\$ErrorActionPreference = "Stop"
& "$DRIVER_PS1" -Image fake-image:latest -Commands @('true', 'printf x \')
PS
	if pwsh -NoProfile -File "$TMP/reject-bs.ps1" >"$TMP/h3.out" 2>&1; then
		bad ".ps1 accepted a line-continuation probe" "$(cat "$TMP/h3.out")"
	elif grep -q "line continuation" "$TMP/h3.out"; then
		ok ".ps1 rejects a line-continuation probe with the same rationale"
	else
		bad ".ps1 rejected the continuation probe for the wrong reason" "$(cat "$TMP/h3.out")"
	fi
else
	printf '  skip  pwsh unavailable - .sh/.ps1 parity not checked here\n'
fi

printf 'I. the shipped Stage 1 probe lists are byte-identical across .sh/.ps1\n'
sh_probes="$TMP/probes.sh.txt"
ps_probes="$TMP/probes.ps1.txt"
# Stage 1 in commands/smoke-test.sh: continuation lines after the
# smoke-test-image.sh invocation, each a single-quoted or double-quoted probe.
sed -n '/scripts\/smoke-test-image\.sh" "\$IMAGE" \\$/,/^$/p' "${ROOT_DIR}/commands/smoke-test.sh" |
	sed -e '1d' -e 's/^\t//' -e 's/ \\$//' | sed -e '/^$/d' >"$sh_probes"
tr -d '\r' <"${ROOT_DIR}/commands/smoke-test.ps1" |
	sed -n '/-Commands @($/,/^  )$/p' | sed -e '1d' -e '$d' -e 's/^    //' >"$ps_probes"
# Strip the outer quoting on both sides so only the probe payload is compared.
strip_quotes() {
	sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//' "$1"
}
if [ ! -s "$sh_probes" ] || [ ! -s "$ps_probes" ]; then
	bad "could not extract the Stage 1 probe lists" "sh: $(wc -l <"$sh_probes") lines, ps1: $(wc -l <"$ps_probes") lines"
elif diff -u <(strip_quotes "$sh_probes") <(strip_quotes "$ps_probes") >"$TMP/probe.diff" 2>&1; then
	ok "Stage 1 probe payloads match ($(wc -l <"$sh_probes") probes)"
else
	bad "Stage 1 probe lists diverged between .sh and .ps1" "$(head -40 "$TMP/probe.diff")"
fi

printf 'J. each probe gets its OWN shell (the argv form deliberate consequence)\n'
# Shell state must NOT carry between probes: probes have to be self-contained.
# Pinned because the drivers' comment blocks promise it and because a probe list
# that started relying on a neighbour's `cd`/`export` would break silently.
ISO="$TMP/iso"
mkdir -p "$ISO"
run_driver 1 "$TMP/j1.out" \
	"cd $ISO && printf marker > from-first" \
	"[ ! -f from-first ]" \
	"[ -f $ISO/from-first ]"
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "a probe's \`cd\` does not carry to the next probe, but its files do"
else
	bad "probe isolation for \`cd\` did not hold (rc=$rc)" "$(cat "$TMP/j1.out")"
fi

run_driver 1 "$TMP/j2.out" \
	'export POWBOX_ISO_PROBE=leaked' \
	'[ -z "${POWBOX_ISO_PROBE:-}" ]' \
	'plain=set; [ "$plain" = set ]' \
	'[ -z "${plain:-}" ]'
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "neither an \`export\` nor a plain variable leaks into the next probe"
else
	bad "environment/variable isolation did not hold (rc=$rc)" "$(cat "$TMP/j2.out")"
fi

# ...and the isolation is genuinely new: joined into one shell (either earlier
# form) the export DID carry.
if /bin/sh -c $'set -e\nexport POWBOX_ISO_PROBE=leaked\n[ -z "${POWBOX_ISO_PROBE:-}" ]\n' 2>/dev/null; then
	bad "a single joined shell no longer carries an export - section J is vacuous"
else
	ok "a single joined shell did carry it, so the isolation is a real change"
fi

printf 'K. holes the earlier `if`-condition form left open are now CLOSED\n'
# K1. An unbalanced quote is now confined to its own probe: the probe's shell
# hits EOF inside the string, that probe fails, and the failure is ATTRIBUTED.
run_driver 1 "$TMP/k1.out" \
	'[ -n "" ] "' \
	"true"
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SMOKE PROBE 1 FAILED" "$TMP/k1.out"; then
	ok "an unbalanced probe fails closed AND names its own index (rc=$rc)"
else
	bad "unbalanced probe was not reported as probe 1 (rc=$rc)" "$(cat "$TMP/k1.out")"
fi
if grep -qi "syntax error\|unterminated" "$TMP/k1.out"; then
	ok "the failure is the probe shell's syntax error, not a downstream symptom"
else
	bad "no syntax error surfaced for the unbalanced probe" "$(cat "$TMP/k1.out")"
fi

# K2. TWO unbalanced probes used to re-balance each other ACROSS the join,
# swallowing probe 1's guard and its assertion and turning a failure into a
# PASS. As argv they cannot see each other at all.
run_driver 1 "$TMP/k2.out" \
	'[ -n "" ] "' \
	'" ; true' \
	"true"
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SMOKE PROBE 1 FAILED" "$TMP/k2.out"; then
	ok "two unbalanced probes no longer swallow each other; probe 1 is reported"
else
	bad "the two-unbalanced-probe swallow still reproduces (rc=$rc)" "$(cat "$TMP/k2.out")"
fi
# Controls for the exact triple above - both earlier join forms, so the claim
# "the `if` form CREATED this hole and this form removes it" is measured, not
# asserted. Pre-fix bare lines: aborted. `if` conditions: exited 0.
old_bare_unbal=$'set -e\n[ -n "" ] "\n" ; true\ntrue\n'
if /bin/sh -c "$old_bare_unbal" >"$TMP/k2-bare.out" 2>&1; then
	bad "the pre-fix bare-line join no longer aborts on the unbalanced triple" "$(cat "$TMP/k2-bare.out")"
else
	ok "control: the pre-fix bare-line join aborted on the same triple"
fi
old_if_unbal=$'set -e\nif [ -n "" ] "\nthen :; else exit 1; fi\nif " ; true\nthen :; else exit 1; fi\nif true\nthen :; else exit 1; fi\n'
if /bin/sh -c "$old_if_unbal" >"$TMP/k2-if.out" 2>&1; then
	ok "control: the \`if\`-condition join DID pass on it (the hole it created)"
else
	bad "the \`if\`-condition join no longer passes on the triple - K2's framing needs updating" "$(cat "$TMP/k2-if.out")"
fi

# K3. A `;` sequence: `set -e` now binds its non-final members, because the
# probe is its own shell's whole input rather than an `if` condition.
run_driver 1 "$TMP/k3.out" \
	"true" \
	'false; true' \
	"true"
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SMOKE PROBE 2 FAILED" "$TMP/k3.out"; then
	ok "a failing non-final member of a \`;\` sequence fails the run at index 2"
else
	bad "a \`;\`-sequence member is still unenforced (rc=$rc)" "$(cat "$TMP/k3.out")"
fi
# The braces are irrelevant - a `{ ...; }` group behaves identically.
run_driver 1 "$TMP/k3b.out" \
	"true" \
	'{ false; true; }' \
	"true"
rc=$?
if [ "$rc" -ne 0 ] && grep -q "SMOKE PROBE 2 FAILED" "$TMP/k3b.out"; then
	ok "same for a \`{ ...; }\` group (grouping is not what caused it)"
else
	bad "grouped \`;\` sequence behaved differently from the bare one (rc=$rc)" "$(cat "$TMP/k3b.out")"
fi
# Both halves of the claim get a control. The pre-fix bare line DID abort (so
# the `if` form was a narrowing)...
if /bin/sh -c $'set -e\ntrue\nfalse; true\ntrue\n' >"$TMP/k3-bare.out" 2>&1; then
	bad "a bare \`set -e\` line no longer aborts on \`false; true\`" "$(cat "$TMP/k3-bare.out")"
else
	ok "control: a bare \`set -e\` line aborted on it (so the \`if\` form narrowed)"
fi
# ...and the `if` condition did NOT (so closing it here is a real change).
if /bin/sh -c $'set -e\nif false; true\nthen :; else exit 1; fi\n' >"$TMP/k3-if.out" 2>&1; then
	ok "control: the \`if\`-condition form did NOT abort (so K3 is not vacuous)"
else
	bad "the \`if\`-condition form aborts on \`false; true\` - K3's framing needs updating" "$(cat "$TMP/k3-if.out")"
fi

printf 'L. CHARACTERIZATION of the one remaining accepted limitation\n'
# A probe ending in `&` backgrounds its command; POSIX says an async list's
# status is always 0, so `set -e` cannot see it and the probe can never fail.
# Inherent, not a consequence of any join form, and only reachable via a
# nonsense probe. This assertion pins what the wrapper DOES, not what it should
# do: closing it is an improvement, and the right response is to flip the
# assertion and the prose, not to revert.
run_driver 1 "$TMP/l1.out" \
	"true" \
	'false &' \
	"true"
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "ACCEPTED LIMITATION: a probe ending in \`&\` always reports success"
else
	bad "a backgrounded probe became binding (rc=$rc) - a welcome change, but update the comment blocks in scripts/smoke-test-image.{sh,ps1}, commands/smoke-test.{sh,ps1} and docs/architecture.md, then flip this assertion" "$(cat "$TMP/l1.out")"
fi
# Control: it is inherent, not something a join form introduced - the pre-fix
# bare `set -e` line did not catch it either.
if /bin/sh -c $'set -e\ntrue\nfalse &\ntrue\n' >"$TMP/l1-bare.out" 2>&1; then
	ok "control: the pre-fix bare-line join did not catch it either (inherent)"
else
	bad "a bare \`set -e\` line does abort on \`false &\` - the \"inherent\" note is wrong" "$(cat "$TMP/l1-bare.out")"
fi
# ...and the same holds one level down, in the shell the probe actually runs in.
if /bin/sh -ec 'false &' >"$TMP/l1-inner.out" 2>&1; then
	ok "control: \`sh -ec 'false &'\` exits 0, which is where the limitation lives"
else
	bad "\`sh -ec 'false &'\` now fails - the limitation may be closable" "$(cat "$TMP/l1-inner.out")"
fi

printf '\n%d check(s), %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ] || exit 1
printf 'smoke probe wrapper test: PASS\n'
