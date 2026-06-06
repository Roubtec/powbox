param(
    [string]$AgentImage = 'powbox-agent:latest',
    [string]$BaseImage  = 'powbox-agent-base:latest',
    # Suppress human-readable output and instead print one tab-separated row per
    # component for agent-update to consume:
    #
    #     base    <ok|stale|unknown>  <baked-digest|->   <latest-digest|->
    #     claude  <ok|stale|unknown>  <baked-version|->  <latest-version|->
    #     codex   <ok|stale|unknown>  <baked-version|->  <latest-version|->
    #
    # A component is stale when a latest value is known and differs from what is
    # baked in (a missing image counts as stale); unknown means the latest could
    # not be determined (npm/registry unreachable) and must never force a
    # rebuild. The baked/latest versions let agent-update pin each binary so
    # Docker rebuilds only the layers that actually changed.
    [switch]$Porcelain
)

$ErrorActionPreference = 'Stop'

# Porcelain output must stay machine-clean, so silence the human-facing warnings
# (npm/registry unreachable, etc.) the helpers emit alongside their return value.
if ($Porcelain) { $WarningPreference = 'SilentlyContinue' }

# Emit informational text only in human mode so -Porcelain output stays clean.
function Write-Note([string]$Message) {
    if (-not $Porcelain) { Write-Host $Message }
}

# Classify a baked/latest pair as ok | stale | unknown. A latest value that
# could not be determined (npm/registry unreachable) is "unknown" and must never
# force a rebuild; an empty baked value (missing/unknown image) with a known
# latest counts as "stale" so agent-update will build it.
function Get-ComponentStatus([string]$Baked, [string]$Latest) {
    if (-not $Latest) { return 'unknown' }
    if ($Baked -ne $Latest) { return 'stale' }
    return 'ok'
}

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

function Test-ImageExists([string]$Image) {
    docker image inspect $Image >$null 2>&1
    return $LASTEXITCODE -eq 0
}

# Read both agents' baked versions in a SINGLE container start (the unified
# image carries both binaries). The container prints two tagged lines so each
# can be parsed back regardless of either command's own output quirks:
#   CLAUDE:<raw claude --version line>
#   CODEX:<raw codex --version line>
# The claude line strips a trailing " (...)" suffix; the codex line strips a
# leading "codex-cli " prefix — matching the baked_versions_raw parsing in
# commands/check-updates.sh.
function Get-BakedAgentVersions([string]$Image) {
    # Build with explicit LF joins (single-quoted lines so PowerShell leaves the
    # shell $() substitutions literal). A here-string would inherit this file's
    # CRLF endings (.gitattributes pins *.ps1 to eol=crlf), and the stray ^M can
    # break parsing under `sh -c` on a Windows checkout.
    $script = @(
      'printf "CLAUDE:%s\n" "$(claude --version 2>/dev/null | head -1)"'
      'printf "CODEX:%s\n" "$(codex --version 2>/dev/null | head -1)"'
    ) -join "`n"
    $raw = docker run --rm --entrypoint sh $Image -c $script 2>$null
    $claude = $null
    $codex = $null
    foreach ($line in @($raw)) {
        if ($line -like 'CLAUDE:*') {
            $claude = ($line.Substring(7) -replace ' *\(.*', '').Trim()
        } elseif ($line -like 'CODEX:*') {
            $codex = ($line.Substring(6) -replace '^codex-cli *', '').Trim()
        }
    }
    return [PSCustomObject]@{ Claude = $claude; Codex = $codex }
}

function Get-LatestNpmVersion([string]$Package) {
    $ver = npm view $Package version 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ver) {
        Write-Warning "Could not fetch latest version for ${Package} (registry unreachable?)."
        return $null
    }
    return $ver.Trim()
}

# Docker renders a missing label as the literal "<no value>" when the image
# carries no labels map at all; normalize that to $null so unlabeled images fall
# through to the default-source fallback and staleness logic instead of looking
# like a set-but-bogus value.
function Get-ImageLabel([string]$Image, [string]$Label) {
    $val = docker image inspect $Image --format "{{index .Config.Labels `"$Label`"}}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $val) { return $null }
    $val = $val.Trim()
    if ($val -eq '<no value>') { return $null }
    return $val
}

function Get-RegistryDigest([string]$Image) {
    $digest = docker buildx imagetools inspect $Image --format '{{.Manifest.Digest}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $digest) {
        Write-Warning "Could not fetch registry digest for ${Image} (registry unreachable?)."
        return $null
    }
    return $digest.Trim()
}

# Upstream image the base is built FROM, parsed from the base Dockerfile (the
# same source the build scripts use). Used as a fallback when the local base
# image is absent or unlabeled, so a missing base can still be compared against
# the registry and reported stale. Returns $null if the Dockerfile can't be read.
function Get-DefaultBaseSource() {
    $dockerfile = Join-Path (Split-Path $PSScriptRoot -Parent) 'docker/base/Dockerfile'
    if (-not (Test-Path $dockerfile)) { return $null }
    $from = Select-String -Path $dockerfile -Pattern '^FROM\s+(\S+)' | Select-Object -First 1
    if ($from) { return $from.Matches[0].Groups[1].Value }
    return $null
}

function Format-ShortDigest([string]$Digest) {
    if ($Digest -match '^sha256:([0-9a-f]{12})') { return $Matches[1] }
    return $null
}

# The marker emitted here must mirror Test-Stale: a known latest with a missing
# or unlabeled (empty) baked value is stale and needs a build, so it is flagged
# just like a version mismatch. This keeps the human report consistent with the
# porcelain output that agent-update consumes. An unknown latest (registry/npm
# unreachable) is undeterminable and is never flagged.
function Write-BaseComparison([string]$Baked, [string]$Latest) {
    $b = Format-ShortDigest $Baked
    $l = Format-ShortDigest $Latest
    if (-not $Baked) {
        # Image missing or unlabeled: a build is needed when the upstream is known.
        if ($Latest) {
            Write-Host ("  {0,-8}  baked: {1,-14}  latest: {2}  ** update available **" -f 'Base', '(unknown)', $l)
        } else {
            Write-Host ("  {0,-8}  baked: {1,-14}  latest: {2}" -f 'Base', '(unknown)', '(unknown)')
        }
        return
    }
    if (-not $Latest) {
        Write-Host ("  {0,-8}  baked: {1,-14}  latest: {2}" -f 'Base', $b, '(unknown)')
        return
    }
    if ($Baked -eq $Latest) {
        Write-Host ("  {0,-8}  {1}  (up to date)" -f 'Base', $b)
    } else {
        Write-Host ("  {0,-8}  {1} -> {2}  ** update available **" -f 'Base', $b, $l)
    }
}

function Write-Comparison([string]$Agent, [string]$Baked, [string]$Latest) {
    if (-not $Baked) {
        # Image missing: a build is needed when the upstream is known.
        if ($Latest) {
            Write-Host ("  {0,-8}  baked: {1,-14}  latest: {2}  ** update available **" -f $Agent, '(unknown)', $Latest)
        } else {
            Write-Host ("  {0,-8}  baked: {1,-14}  latest: {2}" -f $Agent, '(unknown)', '(unknown)')
        }
        return
    }
    if (-not $Latest) {
        Write-Host ("  {0,-8}  {1}  latest: (unknown)" -f $Agent, $Baked)
        return
    }
    if ($Baked -eq $Latest) {
        Write-Host ("  {0,-8}  {1}  (up to date)" -f $Agent, $Baked)
    } else {
        Write-Host ("  {0,-8}  {1} -> {2}  ** update available **" -f $Agent, $Baked, $Latest)
    }
}

# -------------------------------------------------------------------
# Gather versions
# -------------------------------------------------------------------

$claudeBaked = $null
$codexBaked  = $null
$baseSource  = $null
$baseBaked   = $null
$baseLatest  = $null

if (Test-ImageExists $AgentImage) {
    $bakedVersions = Get-BakedAgentVersions $AgentImage
    $claudeBaked = $bakedVersions.Claude
    $codexBaked  = $bakedVersions.Codex
} else {
    Write-Note "Image $AgentImage not found — baked agent versions will be shown as (unknown)."
}

if (Test-ImageExists $BaseImage) {
    $baseSource = Get-ImageLabel $BaseImage 'powbox.base.source'
    $baseBaked  = Get-ImageLabel $BaseImage 'powbox.base.source.digest'
} else {
    Write-Note "Image $BaseImage not found — base will be shown as (unknown)."
}

$claudeLatest = $null
$codexLatest  = $null

if (Get-Command npm -ErrorAction SilentlyContinue) {
    $claudeLatest = Get-LatestNpmVersion '@anthropic-ai/claude-code'
    $codexLatest  = Get-LatestNpmVersion '@openai/codex'
} else {
    Write-Warning 'npm not found — latest agent versions will be shown as (unknown).'
}

# When the local base image is absent (or carries no source label) we can't read
# the upstream it was built from, but a missing base should still count as stale.
# Fall back to the Dockerfile's upstream so $baseLatest can be resolved. If the
# registry is then unreachable, $baseLatest stays $null and Test-Stale treats the
# base as not-stale — an unreachable registry must not force a rebuild.
if (-not $baseSource) { $baseSource = Get-DefaultBaseSource }

if ($baseSource) {
    $baseLatest = Get-RegistryDigest $baseSource
}

# -------------------------------------------------------------------
# Porcelain: one tab-separated row per component (see header comment).
# -------------------------------------------------------------------

if ($Porcelain) {
    # '-' is the empty marker agent-update treats as unset.
    function Format-PorcelainValue([string]$Value) {
        if ($Value) { return $Value }
        return '-'
    }

    # Base staleness compares short digests (like the .sh) so a registry digest
    # and a baked digest that share the same 12-char prefix compare equal.
    $baseStatus = Get-ComponentStatus (Format-ShortDigest $baseBaked) (Format-ShortDigest $baseLatest)
    $tab = "`t"
    'base' + $tab + $baseStatus + $tab + (Format-PorcelainValue $baseBaked) + $tab + (Format-PorcelainValue $baseLatest)
    'claude' + $tab + (Get-ComponentStatus $claudeBaked $claudeLatest) + $tab + (Format-PorcelainValue $claudeBaked) + $tab + (Format-PorcelainValue $claudeLatest)
    'codex' + $tab + (Get-ComponentStatus $codexBaked $codexLatest) + $tab + (Format-PorcelainValue $codexBaked) + $tab + (Format-PorcelainValue $codexLatest)
    $global:LASTEXITCODE = 0
    return
}

# -------------------------------------------------------------------
# Report
#
# The "** update available **" marker emitted below is parsed by agent-update
# (shell/powbox.*) to decide whether to prompt — keep that phrase stable.
# -------------------------------------------------------------------

Write-Host ''
Write-Host 'Agent update check:'
if ($baseBaked   -or $baseLatest)   { Write-BaseComparison $baseBaked $baseLatest }
# Codex before Claude: Codex updates less often and the Claude layer is built on
# top of it, so the report mirrors the Docker layer stacking (base -> codex -> claude).
if ($codexBaked  -or $codexLatest)  { Write-Comparison 'Codex'  $codexBaked  $codexLatest  }
if ($claudeBaked -or $claudeLatest) { Write-Comparison 'Claude' $claudeBaked $claudeLatest }
Write-Host ''
$global:LASTEXITCODE = 0
