param(
    [string]$ClaudeImage = 'powbox-claude:latest',
    [string]$CodexImage  = 'powbox-codex:latest',
    [string]$BaseImage   = 'powbox-agent-base:latest',
    # Suppress human-readable output and instead emit just the names of the
    # stale build targets (base|claude|codex), one per line, for agent-update
    # to consume. A target is stale when a latest version is known and differs
    # from what is baked in (a missing image counts as stale).
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

function Test-Stale([string]$Baked, [string]$Latest) {
    if (-not $Latest) { return $false }
    return $Baked -ne $Latest
}

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

function Test-ImageExists([string]$Image) {
    docker image inspect $Image >$null 2>&1
    return $LASTEXITCODE -eq 0
}

function Get-BakedClaudeVersion([string]$Image) {
    $raw = docker run --rm --entrypoint claude $Image --version 2>$null | Select-Object -First 1
    if ($raw -match '^([\d.]+)') { return $Matches[1] }
    return $null
}

function Get-BakedCodexVersion([string]$Image) {
    $raw = docker run --rm --entrypoint codex $Image --version 2>$null | Select-Object -First 1
    if ($raw -match '([\d.]+)') { return $Matches[1] }
    return $null
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

if (Test-ImageExists $ClaudeImage) {
    $claudeBaked = Get-BakedClaudeVersion $ClaudeImage
} else {
    Write-Note "Image $ClaudeImage not found — Claude baked version will be shown as (unknown)."
}

if (Test-ImageExists $CodexImage) {
    $codexBaked = Get-BakedCodexVersion $CodexImage
} else {
    Write-Note "Image $CodexImage not found — Codex baked version will be shown as (unknown)."
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
# Porcelain: emit stale target names only, in build order (base first).
# -------------------------------------------------------------------

if ($Porcelain) {
    if (Test-Stale $baseBaked   $baseLatest)   { 'base' }
    if (Test-Stale $claudeBaked $claudeLatest) { 'claude' }
    if (Test-Stale $codexBaked  $codexLatest)  { 'codex' }
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
if ($claudeBaked -or $claudeLatest) { Write-Comparison 'Claude' $claudeBaked $claudeLatest }
if ($codexBaked  -or $codexLatest)  { Write-Comparison 'Codex'  $codexBaked  $codexLatest  }
Write-Host ''
