#!/usr/bin/env bash
# Unit test for the smoke-test probe join/wrapping logic in
# scripts/smoke-test-image.sh (and, when pwsh is available, its .ps1 mirror).
#
# Hermetic: no image, no Docker daemon, no network. A fake `docker` on PATH
# captures the joined script the driver would have run, and optionally executes
# it with the host /bin/sh so the `set -e` semantics the wrapper exists to fix
# can be asserted end to end.
#
# What it pins:
#   * every probe is emitted VERBATIM, followed by a fixed index-only failure
#     tail - so adversarial probe text (quotes, $, backticks, backslashes, |,
#     &&) can never be re-parsed or injected into the diagnostic;
#   * a failing NON-FINAL clause of a NON-FINAL probe aborts the run (the
#     original defect) and names the probe by index;
#   * newline-bearing and empty probes are rejected before docker is invoked;
#   * the .sh and .ps1 drivers emit byte-identical scripts.
# shellcheck disable=SC2016  # single-quoted probe/PowerShell text is LITERAL by design here
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

# ---------------------------------------------------------------------------
# Fake docker: records the joined script (always) and runs it under /bin/sh
# when SMOKE_TEST_EXEC=1. The driver invokes it as
#   docker run --rm --entrypoint /bin/sh <image> -lc <script>
# so the script is simply the last argument.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<'SHIM'
#!/bin/sh
script=""
for a in "$@"; do script="$a"; done
printf '%s' "$script" >"$SMOKE_TEST_CAPTURE"
if [ "${SMOKE_TEST_EXEC:-0}" = 1 ]; then
	/bin/sh -c "$script"
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

# The exact tail the driver must append. Kept here as an independent
# restatement so a change to the driver's wrapping shape shows up as a test
# failure rather than being silently mirrored.
tail_for() {
	printf "|| { printf '%%s\\\\n' 'SMOKE PROBE %s FAILED' >&2; exit 1; }" "$1"
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
	# shape) - double-wrapping must stay syntactically valid
	'[ 1 = 1 ] && [ 2 = 2 ] || { printf "%s\n" "inner tail" >&2; exit 1; }'
)

printf 'A. verbatim emission + index-only tail (adversarial probes)\n'
run_driver 0 "$TMP/a.out" "${adversarial[@]}"
rc=$?
if [ "$rc" -ne 0 ]; then
	bad "driver exited $rc on the adversarial corpus" "$(cat "$TMP/a.out")"
else
	ok "driver accepted the adversarial corpus"
fi

if [ ! -s "$CAPTURE" ]; then
	bad "no script captured from the fake docker"
else
	first_line="$(head -n1 "$CAPTURE")"
	if [ "$first_line" = "set -e" ]; then
		ok "emitted script still starts with 'set -e'"
	else
		bad "first emitted line is not 'set -e'" "got: $first_line"
	fi

	n=0
	for probe in "${adversarial[@]}"; do
		n=$((n + 1))
		expected="${probe} $(tail_for "$n")"
		if grep -Fxq -- "$expected" "$CAPTURE"; then
			ok "probe $n emitted verbatim with its index-only tail"
		else
			bad "probe $n was not emitted verbatim" "expected: $expected" "captured script:" "$(cat "$CAPTURE")"
		fi
	done

	# The diagnostic must never contain probe text - that is what makes the
	# wrapping injection-proof rather than merely escaped.
	if grep -n "SMOKE PROBE" "$CAPTURE" | grep -qvE "SMOKE PROBE [0-9]+ FAILED' >&2; exit 1; }$"; then
		bad "a SMOKE PROBE diagnostic carries something other than a bare index"
	else
		ok "every emitted diagnostic is 'SMOKE PROBE <n> FAILED' and nothing else"
	fi

	# One line per probe plus the leading `set -e`.
	want_lines=$((${#adversarial[@]} + 1))
	got_lines="$(wc -l <"$CAPTURE")"
	if [ "$got_lines" -eq "$want_lines" ]; then
		ok "emitted script has exactly one line per probe ($got_lines)"
	else
		bad "emitted line count mismatch" "want $want_lines, got $got_lines"
	fi

	# The emitted script must be syntactically valid for /bin/sh even with all
	# of the above spliced in.
	if /bin/sh -n "$CAPTURE" 2>"$TMP/syntax.err"; then
		ok "emitted script parses under /bin/sh -n"
	else
		bad "emitted script is not valid /bin/sh" "$(cat "$TMP/syntax.err")"
	fi
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
# Deliberate non-goal: pipefail is NOT enabled, so a producer that fails after
# emitting the expected text still passes. Pinned so enabling pipefail becomes a
# conscious, test-visible decision rather than an accident.
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

printf 'H. the .ps1 driver emits a byte-identical script\n'
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
			ok ".ps1 and .sh drivers emit byte-identical scripts"
		else
			bad ".ps1 emitted a different script than .sh" "$(diff -u "$TMP/from-sh" "$CAPTURE" 2>&1 | head -40)"
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

printf '\n%d check(s), %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ] || exit 1
printf 'smoke probe wrapper test: PASS\n'
