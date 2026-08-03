#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: smoke-test-image.sh <image> <primary-command> [extra command ...]}"
shift

if [ "$#" -eq 0 ]; then
	echo "At least one command must be provided for smoke testing." >&2
	exit 1
fi

# Every probe is concatenated into ONE `sh -lc` script prefixed with `set -e`, and
# each is emitted as the CONDITION of its own `if`, with the failure guard on the
# NEXT line:
#
#     if <probe>
#     then :; else printf '%s\n' 'SMOKE PROBE <n> FAILED' >&2; exit 1; fi
#
# The guard is what makes a multi-clause probe binding: POSIX `set -e` exempts a
# failing element of an `&&`/`||` list that is not the FINAL element, so a bare
# `A && B && C` whose `A` or `B` fails neither exits the shell nor propagates — the
# list's non-zero status is simply discarded when the shell moves to the next line.
# A failing FINAL clause did trip `set -e` on any probe, and the whole list's status
# was observable on the last probe only (nothing followed it to discard it); every
# non-final clause of every probe, and the overall status of every probe but the
# last, were masked. With the guard, any failing clause of any probe aborts the run.
#
# The guard lives on its own LINE, not appended to the probe's line, and that is
# load-bearing rather than cosmetic. A same-line `<probe> || { …; exit 1; }` tail can
# be consumed by the probe text itself: `false # note` becomes
# `false # note || { …; exit 1; }`, the tail is inside the comment, and the failure is
# discarded again — exactly the masking this wrapper exists to remove. Because a `#`
# comment (and any other line-scoped construct) ends at the newline, no probe text can
# reach past it to the `then`/`else` line. Keeping `set -e` semantics identical is why
# it is an `if` condition specifically: `set -e` is suspended inside an `if` condition
# just as it is in the first element of an `||` list, so `A && B && C` behaves exactly
# as it did — but a probe that strings commands together with `;` inside a `{ …; }`
# group still has its non-final members unenforced. Write such a probe as an `&&`
# chain instead.
#
# The guard embeds only a probe INDEX, never the probe text. Probe strings carry
# single quotes, double quotes, `$`, backticks, backslashes, `|` and `&&`; splicing
# them into a quoted `printf` argument inside the same script would let the probe
# text be re-parsed by the container shell (mangled diagnostics at best, arbitrary
# execution at worst). An index is a bare integer and cannot be misparsed, and the
# host prints the index -> probe manifest below when the run fails, which also
# closes the old "the driver cannot say which probe failed" gap. The flip side is
# that the diagnostic quotes the probe's SOURCE text, not any runtime value it
# observed: probes that used to hand-roll a tail printing e.g. the offending
# `$DOTNET_*` values no longer do. Accepted deliberately — an injection-proof
# diagnostic is worth more than a richer one, and the manifest still points at the
# exact probe to re-run by hand.
#
# Two probe shapes are rejected up front rather than shipped as silent holes:
#   * a newline or carriage return — every line but the last would be unguarded;
#   * a trailing odd-numbered backslash run — that is a line continuation, which
#     would splice the `then`/`else` line into the probe's own line and break the
#     guard (a syntax error in practice, i.e. fail-closed, but with an opaque
#     message; rejecting it here says what is actually wrong).
# Quote balance inside a probe stays the AUTHOR's responsibility: an unterminated
# quote swallows the following line(s) into the probe's argument. That always fails
# closed — it can never turn a failure into a pass — but it can misattribute the
# reported index, so a red run whose index looks wrong is worth a quoting check. It
# is not validated here because the only cheap check (`sh -n`) has no equivalent in
# the .ps1 mirror, and the two drivers must emit byte-identical scripts.
#
# Deliberately NOT `set -o pipefail`. Two reasons, neither of them "it would break
# today's probes": (1) pipefail is not POSIX — it happens to work in the image's
# dash 0.5.12, but the emitted script is otherwise plain POSIX sh; (2) it would make
# every `X | grep -q Y` probe newly sensitive to `X`'s exit status, including the
# SIGPIPE (141) `grep -q` provokes by closing the pipe on its first match — and that
# exposure is OUTPUT-SIZE dependent, so it is nondeterministic in the worst way: a
# probe whose producer one day emits enough to fill the pipe buffer flips from green
# to 141 with no code change at all. Producer-side masking stays out of scope.
NL=$'\n'
SCRIPT=$'set -e\n'
idx=0
for cmd in "$@"; do
	idx=$((idx + 1))
	if [ -z "${cmd//[[:space:]]/}" ]; then
		printf 'smoke-test-image.sh: probe %d is empty; every probe must be a runnable command.\n' "$idx" >&2
		exit 1
	fi
	case "$cmd" in
	*"$NL"* | *$'\r'*)
		printf 'smoke-test-image.sh: probe %d contains a newline or carriage return; probes must be single-line so the failure wrapper guards the whole probe.\n' "$idx" >&2
		printf '  probe: %s\n' "$cmd" >&2
		exit 1
		;;
	esac
	# Trailing run of backslashes; an odd count is a line continuation.
	trailing_bs="${cmd##*[!\\]}"
	if [ $((${#trailing_bs} % 2)) -eq 1 ]; then
		printf 'smoke-test-image.sh: probe %d ends in a line continuation (odd trailing backslash); that would splice the failure guard into the probe line and break it.\n' "$idx" >&2
		printf '  probe: %s\n' "$cmd" >&2
		exit 1
	fi
	SCRIPT+="if ${cmd}"$'\n'
	SCRIPT+="then :; else printf '%s\n' 'SMOKE PROBE ${idx} FAILED' >&2; exit 1; fi"$'\n'
done

echo "Smoke testing image: $IMAGE"
rc=0
docker run --rm --entrypoint /bin/sh "$IMAGE" -lc "$SCRIPT" || rc=$?
if [ "$rc" -ne 0 ]; then
	{
		printf '\nSmoke test FAILED (exit %d). Probe manifest - match the index in the "SMOKE PROBE <n> FAILED" line above:\n' "$rc"
		i=0
		for cmd in "$@"; do
			i=$((i + 1))
			printf '  %3d  %s\n' "$i" "$cmd"
		done
	} >&2
	exit "$rc"
fi
echo "Smoke test passed: all expected CLI tools were found."
