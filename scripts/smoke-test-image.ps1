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
# each is wrapped in an explicit `|| { ...; exit 1; }` tail. The tail is what makes
# a multi-clause probe binding: POSIX `set -e` exempts a failing element of an
# `&&`/`||` list that is not the FINAL element, so a bare `A && B && C` whose `A` or
# `B` fails neither exits the shell nor propagates - the list's non-zero status is
# simply discarded when the shell moves to the next line. Only the very last probe
# in the script escaped that discard. With the tail, any failing clause of any probe
# aborts the run.
#
# The tail embeds only a probe INDEX, never the probe text. Probe strings carry
# single quotes, double quotes, `$`, backticks, backslashes, `|` and `&&`; splicing
# them into a quoted `printf` argument inside the same script would let the probe
# text be re-parsed by the container shell. An index is a bare integer and cannot be
# misparsed, and the host prints the index -> probe manifest below when the run
# fails, which also closes the old "the driver cannot say which probe failed" gap.
#
# Probes must therefore be single-line: a newline inside a probe would leave every
# line but the last unguarded, silently reintroducing the very masking this wrapper
# removes. That is rejected up front rather than shipped as a silent hole.
#
# One consequence of the tail: the probe becomes the first element of an `||` list,
# so `set -e` is suspended INSIDE it. For the `A && B && C` shape that is exactly
# equivalent to before (a failing `C` still makes the list non-zero, and the tail
# turns that into an exit) - but a probe that strings commands together with `;`
# inside a `{ ...; }` group would have its non-final members unenforced. Write such
# a probe as an `&&` chain instead.
#
# Deliberately NOT `set -o pipefail`: the pipeline-shaped probes (`X | grep -q Y`)
# already report grep's status - the real assertion - and a plain failing line does
# trip `set -e`, so they are enforced today. Turning on pipefail would instead make
# them newly sensitive to the producer's status, including the SIGPIPE (141) that
# `grep -q` provokes by closing the pipe on its first match. Producer-side masking
# stays out of scope.
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
  $lines += "$probe || { printf '%s\n' 'SMOKE PROBE $n FAILED' >&2; exit 1; }"
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
