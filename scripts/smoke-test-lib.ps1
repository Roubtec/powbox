# Helpers dot-sourced by commands/smoke-test.ps1: the layer-set probe stage
# (Stage 1b), the capability gate that decides whether Stages 2 and 3 apply to
# the image, Stage 3's check that the image's powbox.podman label agrees with
# its podman binary, and the end-of-run banner. Mirror of
# scripts/smoke-test-lib.sh - keep the two in lockstep, case for case and
# message for message. This file is ASCII-only, so it uses a hyphen wherever the
# .sh uses an em dash (a non-ASCII byte would force a UTF-8 BOM, AGENTS.md ->
# "File Conventions").
#
# They live here rather than inline so scripts/test-smoke-probe-wrapper.sh can
# drive them against a fake `docker`, which reaches every case without a built
# image: the lean and browser images reach the not-applicable paths for real,
# but only an image of a set that installs Podman (full) reaches the others,
# and CI builds no such image.
#
# The callers own two lists these functions append to: $skipped (whole or
# partial stages that did not run, which make the run PARTIAL) and
# $notApplicable (stages the image has no tool for, which do not).

# The set-name rule scripts/layers-select.ps1 enforces on .powbox-layers. The
# label comes from the image, not from the selector, so it is checked again
# before it is used to build a path into the working tree.
$script:SmokeLayerSetPattern = '^[a-z0-9][a-z0-9._-]*\z'

# The committed layer sets. Their probe file is what fails an image of the set
# that lost a tool, so for these sets neither a missing directory nor a missing
# smoke-probes.txt may soften into a note or a skip. The .sh mirror keeps the
# same list.
$script:SmokeCommittedLayerSets = @('full', 'browser')

# The label's value, empty when the image does not carry it. Throws when the
# image cannot be inspected, so an unreadable image is never mistaken for an
# unlabelled (lean) one. Only line breaks are trimmed, as the .sh's command
# substitution does, so a label the .sh would reject is rejected here too.
#
# The label name goes into the template as a Go raw string (`...`), not a
# "..." one: Windows PowerShell 5.1 strips double quotes embedded in a native
# argument, which would leave docker an invalid template and fail every run.
# The single-quoted PowerShell strings keep the backticks literal.
function Get-SmokeImageLabel {
  param([string]$Image, [string]$Label)
  if ($Label -cnotmatch '^[A-Za-z0-9._-]+\z') { throw "invalid label name '$Label'" }
  $v = docker image inspect $Image --format ('{{ index .Config.Labels `' + $Label + '` }}') 2>$null
  if ($LASTEXITCODE -ne 0) { throw "could not inspect image '$Image'" }
  $v = (@($v) -join "`n").TrimEnd("`r", "`n")
  if ($v -eq '<no value>') { $v = '' }
  return $v
}

# The probes of a layer set's smoke-probes.txt, in file order.
#
# One probe per line, split on LF only. A trailing CR is stripped; a leading
# UTF-8 BOM is dropped. Blank lines (spaces and tabs only) and lines whose first
# non-space, non-tab character is `#` are ignored. Nothing else is interpreted:
# every other line reaches scripts/smoke-test-image.ps1 unchanged, so the
# driver's own checks (empty, multi-line, trailing line continuation) still
# apply to it. The file is decoded as UTF-8 with a STRICT decoder - the ANSI
# codepage Windows PowerShell 5.1 would otherwise use mangles a non-ASCII probe,
# and a lenient one turns an invalid byte into U+FFFD where the .sh keeps the
# byte - and a NUL byte is refused because the .sh's `read` drops it. Both
# reject such a file rather than run different probes.
function Read-SmokeProbeFile {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  try {
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
  }
  catch [System.Text.DecoderFallbackException] {
    throw "$Path is not valid UTF-8."
  }
  if ($text.Contains([string][char]0)) { throw "$Path contains a NUL byte." }
  if ($text.StartsWith([string][char]0xFEFF, [System.StringComparison]::Ordinal)) { $text = $text.Substring(1) }
  $probes = [System.Collections.Generic.List[string]]::new()
  foreach ($line in $text.Split([char]"`n")) {
    if ($line.EndsWith("`r", [System.StringComparison]::Ordinal)) { $line = $line.Substring(0, $line.Length - 1) }
    $trimmed = $line.TrimStart([char[]]@(' ', "`t"))
    if ($trimmed -eq '' -or $trimmed.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
    $probes.Add($line)
  }
  return , $probes.ToArray()
}

# $true when $Tool is on the image's login-shell PATH (the PATH every probe
# runs with), $false when it is not, $null when the check gave no answer. The
# container prints an explicit word rather than relying on `command -v`'s
# status, so a docker failure cannot read as "absent" and turn a broken run into
# a not-applicable stage. $Tool is a plain token, passed as a positional
# argument and left unquoted in the script so the text carries no double quote
# for native-argument quoting to mangle.
function Test-SmokeImageHas {
  param([string]$Image, [string]$Tool)
  if ($Tool -cnotmatch '^[A-Za-z0-9._-]+\z') { return $null }
  $out = docker run --rm --entrypoint /bin/sh $Image -lc 'if command -v $1 >/dev/null 2>&1; then echo present; else echo absent; fi' smoke-gate $Tool 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  $last = (@($out) -join "`n").TrimEnd("`r", "`n").Split([char]"`n")[-1]
  if ($last -ceq 'present') { return $true }
  if ($last -ceq 'absent') { return $false }
  return $null
}

# 'na' when the image has no $Tool, otherwise 'skip' when -SkipRequested and
# 'run' when not. The capability check comes first, so an explicit skip on an
# image without the tool is still not applicable rather than a skip. Throws
# when the check cannot tell.
function Get-SmokeGate {
  param([string]$Image, [string]$Tool, [switch]$SkipRequested)
  $has = Test-SmokeImageHas -Image $Image -Tool $Tool
  if ($null -eq $has) {
    throw "could not tell whether image '$Image' has $Tool on its PATH: the capability check did not answer present or absent."
  }
  if (-not $has) { return 'na' }
  if ($SkipRequested) { return 'skip' }
  return 'run'
}

# Stage 3's label check. $Gate is Get-SmokeGate's answer for podman: 'na'
# when the image has no podman on its PATH, 'run' or 'skip' when it has. Throws
# when the image's powbox.podman label and its podman binary disagree, or when
# the labels cannot be read. scripts/launch-agent.{sh,ps1} start the shared
# image-store writer only for an image that carries the label (with any value
# but an empty one), so an image with Podman but no label silently loses the
# shared image store, and one with the label but no Podman starts a writer with
# nothing to run. It reads only the image's labels, so it runs whatever the
# stage's skip controls say.
function Assert-SmokePodmanLabel {
  param([string]$Image, [string]$Gate)
  try {
    $label = Get-SmokeImageLabel -Image $Image -Label 'powbox.podman'
  }
  catch {
    throw "could not read the labels of image '$Image' to compare its powbox.podman label with its podman binary."
  }
  if ($Gate -eq 'na') {
    if ($label) {
      throw "image '$Image' carries the powbox.podman label but has no podman on its PATH, so the launcher would start an image-store writer on every launch with nothing to run. Declare the label only in the block that installs Podman."
    }
    Write-Host "Stage 3 label check: image '$Image' has neither podman nor the powbox.podman label."
  }
  else {
    if (-not $label) {
      throw "image '$Image' has podman on its PATH but no powbox.podman label, so the launcher would never seed the shared image store for its containers. Declare LABEL powbox.podman=`"1`" in the block that installs Podman."
    }
    Write-Host "Stage 3 label check: image '$Image' has podman and the powbox.podman label."
  }
}

# Warns when the image's powbox.layers.digest label differs from the working
# tree's digest of $Rel, the set directory; -Then, when given, ends the
# warning. An image whose set lost every probe, or its probe file, since the
# build is stale too, so this runs before the stage returns with nothing to
# run.
function Write-SmokeLayerStaleWarning {
  param([string]$Image, [string]$Root, [string]$Rel, [string]$Then = '')
  $tail = if ($Then) { " $Then" } else { '' }
  $bakedDigest = ''
  try { $bakedDigest = Get-SmokeImageLabel -Image $Image -Label 'powbox.layers.digest' } catch { $bakedDigest = '' }
  $treeDigest = ''
  $rc = 0
  try {
    $treeDigest = & (Join-Path $Root 'scripts/layers-digest.ps1') (Join-Path $Root $Rel)
    $rc = $LASTEXITCODE
  }
  catch {
    $rc = 1
  }
  $treeDigest = (@($treeDigest) -join "`n").Trim()
  if ($rc -ne 0) {
    Write-Warning "could not compute the digest of $Rel/ (layers-digest exit $rc), so whether image '$Image' is stale relative to this set is unknown.$tail"
  }
  elseif ($treeDigest -cne $bakedDigest) {
    $shown = if ($bakedDigest) { $bakedDigest } else { '<no digest label>' }
    Write-Warning "image '$Image' was built from $Rel/ at $shown, but the working tree is at ${treeDigest}: the image is stale relative to this set.$tail"
  }
}

# Stage 1b. Reads the layer set the IMAGE was built from (its powbox.layers.set
# label, not .powbox-layers: the smoke test describes the image it was given)
# and runs docker/layers/<set>/smoke-probes.txt from the working tree through
# scripts/smoke-test-image.ps1. Throws when the run must fail; appends to
# $Skipped when the stage cannot run. docs/smoke-tests.md ("Layer-set probes")
# lists the cases.
function Invoke-SmokeLayerStage {
  param([string]$Image, [string]$Root, [System.Collections.Generic.List[string]]$Skipped)
  try {
    $set = Get-SmokeImageLabel -Image $Image -Label 'powbox.layers.set'
  }
  catch {
    throw "could not read the labels of image '$Image' to find its layer set."
  }
  if (-not $set) {
    Write-Host "Stage 1b does not apply: image '$Image' carries no powbox.layers.set label (a lean image)."
    return
  }
  if ($set -cnotmatch $script:SmokeLayerSetPattern) {
    throw "image '$Image' names an invalid layer set '$set' in its powbox.layers.set label (must match ^[a-z0-9][a-z0-9._-]*`$)."
  }
  $rel = "docker/layers/$set"
  $dir = Join-Path $Root $rel
  $file = Join-Path $dir 'smoke-probes.txt'
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    if ($script:SmokeCommittedLayerSets -ccontains $set) {
      throw "image '$Image' was built from the committed '$set' layer set, but $rel/ is missing from this working tree; its smoke-probes.txt is what fails a $set image that lost a tool."
    }
    if ($env:POWBOX_SMOKE_REQUIRE_IMAGE) {
      throw "image '$Image' was built from layer set '$set', but $rel/ is not in this working tree, and POWBOX_SMOKE_REQUIRE_IMAGE is set - refusing to skip its probes."
    }
    Write-Warning "image '$Image' was built from layer set '$set', but $rel/ is not in this working tree; skipping its probes."
    $Skipped.Add("Stage 1b: layer-set probes for set $set ($rel/ is not in this working tree)")
    return
  }
  $item = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) {
    if ($script:SmokeCommittedLayerSets -ccontains $set) {
      throw "image '$Image' was built from the committed '$set' layer set, but $rel/smoke-probes.txt is missing from this working tree; it is what fails a $set image that lost a tool."
    }
    Write-SmokeLayerStaleWarning -Image $Image -Root $Root -Rel $rel
    Write-Host "Note: layer set '$set' ships no $rel/smoke-probes.txt; Stage 1b has nothing to run."
    return
  }
  if ($item.PSIsContainer -or $item.LinkType) {
    throw "$rel/smoke-probes.txt is not a regular file."
  }
  $probes = Read-SmokeProbeFile -Path $file
  if ($probes.Count -eq 0) {
    Write-SmokeLayerStaleWarning -Image $Image -Root $Root -Rel $rel
    Write-Host "Note: $rel/smoke-probes.txt holds no probe line; Stage 1b has nothing to run."
    return
  }
  Write-SmokeLayerStaleWarning -Image $Image -Root $Root -Rel $rel -Then 'Running its probes anyway; rebuild it if a probe fails for that reason.'
  Write-Host "Running Stage 1b - layer-set probes ($set): $($probes.Count) probe(s) from $rel/smoke-probes.txt ..."
  & (Join-Path $Root 'scripts/smoke-test-image.ps1') -Image $Image -Commands $probes
}

# The end-of-run summary.
#
# Entries reach the skipped list from two different places - whole stages that
# never ran, and stages that ran with only a portion self-skipped - so nothing
# here may assert that a listed stage produced no coverage, or prescribe a
# switch as the remedy for a host-decided partial that no switch governs. A
# not-applicable stage is neither: the image has no tool for it to test, so it
# is reported as information and never makes the run partial.
function Write-SmokeBanner {
  param([System.Collections.Generic.List[string]]$Skipped, [System.Collections.Generic.List[string]]$NotApplicable)
  if ($NotApplicable.Count -gt 0) {
    Write-Host ""
    Write-Host "Not applicable to this image - it does not ship the tool these"
    Write-Host "stages test, so they did not run and the run is not partial:"
    foreach ($s in $NotApplicable) { Write-Host "  - $s" }
  }
  if ($Skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "============== SMOKE TEST: SKIPPED OR PARTIAL =============="
    foreach ($s in $Skipped) { Write-Host "  - $s" }
    Write-Host "This was a PARTIAL smoke test - each entry above either did not"
    Write-Host "run at all, or ran only in part."
    Write-Host "Entries naming a -Skip* switch or an environment variable were"
    Write-Host "skipped on request: drop or unset it to run them, and pass"
    Write-Host "-RequireImage to also fail on a missing image. The rest were"
    Write-Host "decided at runtime by the host or the working tree - nothing was"
    Write-Host "set to skip them, and dropping a switch or unsetting a variable"
    Write-Host "will not recover them: on a host without /dev/net/tun, for example,"
    Write-Host "Stage 3's nested half self-skips. See docs/smoke-tests.md."
    Write-Host "==========================================================="
  }
  elseif ($NotApplicable.Count -gt 0) {
    Write-Host "Smoke test complete (every stage that applies to this image ran)."
  }
  else {
    Write-Host "Smoke test complete (all stages ran)."
  }
}
