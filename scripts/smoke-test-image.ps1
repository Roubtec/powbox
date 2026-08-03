param(
  [Parameter(Mandatory = $true)]
  [string]$Image,
  [Parameter(Mandatory = $true)]
  [string[]]$Commands
)

$ErrorActionPreference = "Stop"

if ($Commands.Count -eq 0) {
  throw "At least one smoke-test command is required."
}

# Mirror of scripts/smoke-test-image.sh - keep the two in lockstep.
#
# Every probe is concatenated into ONE `sh -lc` script prefixed with `set -e`, and
# each is emitted as the CONDITION of its own `if`, with the failure guard on the
# NEXT line:
#
#     if <probe>
#     then :; else printf '%s\n' 'SMOKE PROBE <n> FAILED' >&2; exit 1; fi
#
# The guard is what makes a multi-clause probe binding: POSIX `set -e` exempts a
# failing element of an `&&`/`||` list that is not the FINAL element, so a bare
# `A && B && C` whose `A` or `B` fails neither exits the shell nor propagates - the
# list's non-zero status is simply discarded when the shell moves to the next line.
# A failing FINAL clause did trip `set -e` on any probe, and the whole list's status
# was observable on the last probe only (nothing followed it to discard it); every
# non-final clause of every probe, and the overall status of every probe but the
# last, were masked. With the guard, any failing clause of any probe aborts the run.
#
# The guard lives on its own LINE, not appended to the probe's line, and that is
# load-bearing rather than cosmetic. A same-line `<probe> || { ...; exit 1; }` tail
# can be consumed by the probe text itself: `false # note` becomes
# `false # note || { ...; exit 1; }`, the tail is inside the comment, and the failure
# is discarded again - exactly the masking this wrapper exists to remove. Because a
# `#` comment (and any other line-scoped construct) ends at the newline, no probe
# text can reach past it to the `then`/`else` line. Keeping `set -e` semantics
# identical is why it is an `if` condition specifically: `set -e` is suspended inside
# an `if` condition just as it is in the first element of an `||` list, so
# `A && B && C` behaves exactly as it did. That same suspension is the ONE shape
# where this form enforces LESS than before: a probe that strings commands together
# with `;` - bare, or inside a `{ ...; }` group; the braces make no difference - has
# its non-final members unenforced here, whereas both a bare `set -e` line and a
# same-line `|| { ...; exit 1; }` tail did abort on them. Verified in dash:
# `if false; true` / `then ...; else ...; fi` takes the THEN branch at rc=0, while
# `false; true` as a bare line under `set -e` exits 1. Which is exactly why the
# instruction is: write every probe as an `&&` chain. A probe ending in `&` is
# unenforced too - an async list's status is always 0 - but that is unchanged from
# before, not a new loss.
#
# The guard embeds only a probe INDEX, never the probe text. Probe strings carry
# single quotes, double quotes, `$`, backticks, backslashes, `|` and `&&`; splicing
# them into a quoted `printf` argument inside the same script would let the probe
# text be re-parsed by the container shell. An index is a bare integer and cannot be
# misparsed, and the host prints the index -> probe manifest below when the run
# fails, which also closes the old "the driver cannot say which probe failed" gap.
# The flip side is that the diagnostic quotes the probe's SOURCE text, not any
# runtime value it observed: probes that used to hand-roll a tail printing e.g. the
# offending `$DOTNET_*` values no longer do. Accepted deliberately - an
# injection-proof diagnostic is worth more than a richer one, and the manifest still
# points at the exact probe to re-run by hand.
#
# Two probe shapes are rejected up front rather than shipped as silent holes:
#   * a newline or carriage return - every line but the last would be unguarded;
#   * a trailing odd-numbered backslash run - that is a line continuation, which
#     would splice the `then`/`else` line into the probe's own line and break the
#     guard (a syntax error in practice, i.e. fail-closed, but with an opaque
#     message; rejecting it here says what is actually wrong).
# Quote balance inside a probe stays the AUTHOR's responsibility: an unterminated
# quote swallows the following line(s) into the probe's argument. ONE unbalanced
# probe fails closed - nothing later re-closes the quote, so `sh` hits EOF and the
# run dies with an (opaque, but red) syntax error. TWO do NOT: the second's quote
# re-balances the first, and the first probe's guard AND its assertion vanish inside
# the swallowed string, so a failing probe can report a PASS. Verified with probes
# `[ -n "" ] "` / `" ; true` / `true`: the one surviving `if` condition ends in
# `true`, and the run exits 0 with only a stray `[: missing ]` on stderr. So keep
# quotes balanced - a red run whose index looks wrong, and a green run you did not
# expect, are both worth a quoting check. It is not validated here because REJECTION
# must be identical in the .sh driver and the only cheap check (`sh -n`) has no
# PowerShell equivalent: a probe one driver refused and the other ran is a worse hole
# than this one. (Emission parity is not the reason - a check here emits no bytes.)
#
# Deliberately NOT `set -o pipefail`. Two reasons, neither of them "it would break
# today's probes": (1) pipefail is not POSIX - it happens to work in the image's
# dash 0.5.12, but the emitted script is otherwise plain POSIX sh; (2) it would make
# every `X | grep -q Y` probe newly sensitive to `X`'s exit status, including the
# SIGPIPE (141) `grep -q` provokes by closing the pipe on its first match - and that
# exposure is OUTPUT-SIZE dependent, so it is nondeterministic in the worst way: a
# probe whose producer one day emits enough to fill the pipe buffer flips from green
# to 141 with no code change at all. Producer-side masking stays out of scope.
$lines = @("set -e")
for ($i = 0; $i -lt $Commands.Count; $i++) {
  $probe = $Commands[$i]
  $n = $i + 1
  if ([string]::IsNullOrWhiteSpace($probe)) {
    throw "smoke-test-image.ps1: probe $n is empty; every probe must be a runnable command."
  }
  if ($probe -match "[`r`n]") {
    throw "smoke-test-image.ps1: probe $n contains a newline or carriage return; probes must be single-line so the failure wrapper guards the whole probe. Probe: $probe"
  }
  # Trailing run of backslashes; an odd count is a line continuation.
  $trailingBs = [regex]::Match($probe, '\\+$')
  if ($trailingBs.Success -and ($trailingBs.Value.Length % 2 -eq 1)) {
    throw "smoke-test-image.ps1: probe $n ends in a line continuation (odd trailing backslash); that would splice the failure guard into the probe line and break it. Probe: $probe"
  }
  $lines += "if $probe"
  $lines += "then :; else printf '%s\n' 'SMOKE PROBE $n FAILED' >&2; exit 1; fi"
}
# Trailing newline included so this is byte-identical to what the .sh driver
# builds (scripts/test-smoke-probe-wrapper.sh asserts that equality).
$script = ($lines -join "`n") + "`n"

Write-Host "Smoke testing image: $Image"
docker run --rm --entrypoint /bin/sh $Image -lc $script

if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "Smoke test FAILED (exit $LASTEXITCODE). Probe manifest - match the index in the 'SMOKE PROBE <n> FAILED' line above:"
  for ($i = 0; $i -lt $Commands.Count; $i++) {
    Write-Host ("  {0,3}  {1}" -f ($i + 1), $Commands[$i])
  }
  throw "Smoke test failed. See the 'SMOKE PROBE <n> FAILED' line in the container output above and the manifest."
}

Write-Host "Smoke test passed: all expected CLI tools were found."
