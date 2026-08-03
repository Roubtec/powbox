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
# Probes are DATA, never syntax. They are handed to the container shell as
# POSITIONAL ARGUMENTS and executed by the fixed one-line runner in $runner
# below, which is the only text this driver ever builds:
#
#     docker run --entrypoint /bin/sh <image> -lc "$runner" smoke-probes <probe>...
#
#     i=0; for p in "$@"; do i=$((i + 1));
#       sh -ec "$p" || { printf "%s\n" "SMOKE PROBE $i FAILED" >&2; exit 1; }; done
#
# Two properties follow, and both are structural rather than a matter of careful
# escaping:
#
#  1. No probe's TEXT can reach the runner's syntax, a neighbouring probe's
#     syntax, or the failure message. A probe never becomes part of a script the
#     container shell parses as a whole: it arrives in `"$@"` and is parsed only
#     by its own `sh -ec`. An unbalanced quote, a trailing `#` comment, a stray
#     backslash, a `$(...)`, a backtick - none of them can swallow the failure
#     guard, splice a following line, re-balance a neighbouring probe, or be
#     re-parsed into the failure message. The message carries the probe INDEX
#     and nothing else, and the host prints the index -> probe manifest below
#     when the run fails, which is also what closes the old "the driver cannot
#     say which probe failed" gap. (Runtime effects are a separate matter: see
#     the per-probe isolation note below for what one probe can still hand the
#     next.)
#  2. A probe fails the run exactly when its own shell exits non-zero - and
#     nothing discards that status any more. Be precise about `set -e` here,
#     because this is the rule a probe author writes against, so state the
#     general rule rather than a list of shapes. POSIX (XCU 2.14) exempts a
#     failing command in several positions: a non-final member of an `&&`/`||`
#     list, a `!`-negated pipeline, and the condition of an
#     `if`/`elif`/`while`/`until`. Being the shell's whole input does NOT change
#     that - `sh -ec 'false && echo x; true'` and `sh -ec '! true; true'` both
#     run to the end and exit 0. What the exemption turns on is POSITION: an
#     exempt construct is still BINDING when it is the probe's LAST command,
#     because its own status then becomes the probe shell's exit status and the
#     runner's `||` guard sees it; it is UNENFORCED when anything follows it,
#     which overwrites that status. ("Its own status" stays POSIX: `! X`
#     inverts, and an `if` whose condition is false with no `else` is 0 by
#     definition - so an `if` condition never fails a probe in either position.)
#     Nothing outside that exempt set is suspended at all: a failing member of a
#     bare `;` sequence or of a `{ ...; }` group aborts the probe shell at that
#     member. So the `&&`-chain and pipeline shapes the probes actually use are
#     binding - a pipeline reports its LAST command's status, and producer-side
#     masking inside one is a separate matter (see the pipefail note below). The
#     shape to AVOID is an exempt construct that is NOT the probe's last
#     top-level command - `A && B; C`, or `! X; Y` - whose failure is discarded
#     exactly as it was before this change. No shipped probe has that shape.
#
# What this replaced, and why the intermediate form was not enough. The original
# join put every probe on a bare line of ONE `set -e` script. The same `&&`/`||`
# exemption applied there, but with nothing to catch the status it left behind:
# `A && B && C` whose `A` or `B` failed neither exited the shell nor propagated
# - the list's non-zero status was simply discarded when the shell moved to the
# next line. A failing FINAL clause did trip `set -e` - that aborted the script
# outright - and in the EXEMPT case, where nothing aborted, the status a probe
# left behind survived on the LAST probe only (nothing followed it to discard
# it). So what that join masked was the non-final `&&`/`||` members of every
# probe, plus the overall status of every probe but the last - NOT every clause:
# bare `;` sequences and `{ ...; }` groups were already enforced then, exactly as
# they are now, and that shape is not something this change restored. Wrapping
# each probe as the CONDITION of its own `if` made the probe's overall status
# binding, but it kept the probe inside the aggregate script's syntax, and that
# cost two things this form gets back. An `if` condition ALSO suspends `set -e`,
# so the non-final members of a `;` sequence went from enforced (a bare `set -e`
# line did abort on them) to unenforced - a regression introduced by that
# intermediate form itself, not a hole inherited from the original join. And two
# probes carrying unbalanced quotes still re-balanced each other ACROSS the
# join, swallowing the first probe's guard and its assertion, so a failing probe
# reported a pass; measured on the triple `[ -n "" ] "` / `" ; true` / `true`,
# the bare-line join aborted at rc=2 while the `if` join exited 0. Both shapes
# are closed here: neither is a hole this driver still carries.
#
# The price is real and deliberate: each probe runs in its OWN shell, so `cd`,
# `export` and plain shell variables do NOT carry from one probe to the next.
# Only filesystem effects persist (same container, probes run in order). Probes
# must therefore be self-contained, and every shipped Stage 1 probe already is -
# the ones that `cd` do their own `cd` to an absolute path, the golangci fixture
# probe hands the probes after it a DIRECTORY rather than a shell state, and the
# ccache probe's `export CCACHE_DIR` is consumed inside that same probe. The
# container shell is still a LOGIN shell (`sh -lc`), so /etc/profile and
# /etc/profile.d run exactly once and every probe's `sh -ec` inherits the
# resulting environment - PATH included, which is precisely what the
# `$HOME/go/bin` GOBIN probe is there to prove.
#
# Limitations remain, all inherent to `set -e` rather than accepted-for-now, and
# all shared with the original join rather than introduced here. Stated as one
# rule rather than a count, so it cannot go stale the next time someone finds
# another instance: ANY `set -e`-exempt construct that is not the probe's LAST
# command is unenforced, because the command after it overwrites the status -
# `A && B; C` and `! X; Y` are the instances property 2 above names. Plus one
# that is not about `set -e` at all: a probe whose last element is an ASYNC list
# (`... &`) always reports 0, because that is what POSIX says an async list's
# status is, and `set -e` cannot see it either. None of these describes a
# sensible assertion, and no shipped probe uses any of them; section L of
# scripts/test-smoke-probe-wrapper.sh pins all three with characterization
# checks, so the claim is tested rather than audited.
#
# The diagnostic names the probe's SOURCE text through the manifest, not any
# runtime value the probe observed: probes that used to hand-roll a tail
# printing e.g. the offending `$DOTNET_*` values no longer do. Accepted
# deliberately - the manifest names the exact probe to re-run by hand.
#
# Three probe shapes are still rejected up front, for three DIFFERENT reasons.
# None of them can reach another probe, the runner or the diagnostic any more -
# that is the whole point of passing probes as argv, and it is exactly what
# property 1 guarantees. But property 1 says nothing about a probe's own
# VERDICT, and the third shape below gets that wrong, so it is a correctness
# reason, not a cosmetic one. Rejection is kept identical in the .sh driver so
# a probe one driver refuses is never run by the other:
#   * an empty or whitespace-only probe - AUTHORING MISTAKE, always, and nothing
#     more subtle than that;
#   * a newline or carriage return - DIAGNOSABILITY and the Windows argument
#     path: the failure manifest prints one line per probe, and this driver
#     would have to hand `docker` a multi-line native-command argument, which is
#     the shakiest corner of PowerShell's argument quoting on Windows. Keeping
#     probes single-line keeps both simple;
#   * a trailing ODD-numbered backslash run - FALSE PASS. It is a line
#     continuation with nothing to continue, i.e. a probe that lost its second
#     half, and `sh -ec` does not error on it: it drops the backslash and runs
#     the TRUNCATED command (verified in dash 0.5.12 - `sh -ec 'printf x \'`
#     prints `x` and exits 0), so a truncated probe reports a pass it never
#     earned. That is the same defect class this whole driver exists to
#     eliminate; rejecting it is the only way it stays visible.
#
# Deliberately NOT `set -o pipefail`, in the runner or in the per-probe shell.
# Two reasons, neither of them "it would break today's probes": (1) pipefail is
# not POSIX - it happens to work in the image's dash 0.5.12, but the runner is
# otherwise plain POSIX sh; (2) it would make every `X | grep -q Y` probe newly
# sensitive to `X`'s exit status, including the SIGPIPE (141) `grep -q` provokes
# by closing the pipe on its first match - and that exposure is OUTPUT-SIZE
# dependent, so it is nondeterministic in the worst way: a probe whose producer
# one day emits enough to fill the pipe buffer flips from green to 141 with no
# code change at all. Producer-side masking stays out of scope.
for ($i = 0; $i -lt $Commands.Count; $i++) {
  $probe = $Commands[$i]
  $n = $i + 1
  if ([string]::IsNullOrWhiteSpace($probe)) {
    throw "smoke-test-image.ps1: probe $n is empty; every probe must be a runnable command."
  }
  if ($probe -match "[`r`n]") {
    throw "smoke-test-image.ps1: probe $n contains a newline or carriage return; probes must be single-line so the failure manifest stays one line per probe and this driver never hands docker a multi-line argument. Probe: $probe"
  }
  # Trailing run of backslashes; an odd count is a line continuation.
  $trailingBs = [regex]::Match($probe, '\\+$')
  if ($trailingBs.Success -and ($trailingBs.Value.Length % 2 -eq 1)) {
    throw "smoke-test-image.ps1: probe $n ends in a line continuation (odd trailing backslash) with nothing to continue; the probe shell would silently run the truncated command and pass. Probe: $probe"
  }
}

# FIXED text, byte-identical to $RUNNER in the .sh driver. The single-quoted
# PowerShell literal keeps `$@`, `$p` and `$i` for the CONTAINER shell, which is
# the only place they are expanded. scripts/test-smoke-probe-wrapper.sh asserts
# that both drivers hand `docker` a byte-identical argument vector.
$runner = 'i=0; for p in "$@"; do i=$((i + 1)); sh -ec "$p" || { printf "%s\n" "SMOKE PROBE $i FAILED" >&2; exit 1; }; done'

Write-Host "Smoke testing image: $Image"
docker run --rm --entrypoint /bin/sh $Image -lc $runner smoke-probes @Commands

if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "Smoke test FAILED (exit $LASTEXITCODE). Probe manifest - match the index in the 'SMOKE PROBE <n> FAILED' line above:"
  for ($i = 0; $i -lt $Commands.Count; $i++) {
    Write-Host ("  {0,3}  {1}" -f ($i + 1), $Commands[$i])
  }
  throw "Smoke test failed. See the 'SMOKE PROBE <n> FAILED' line in the container output above and the manifest."
}

Write-Host "Smoke test passed: all expected CLI tools were found."
