param(
    [string]$ClaudeImage = 'powbox-claude:latest',
    [string]$CodexImage  = 'powbox-codex:latest',
    [string]$BaseImage   = 'powbox-agent-base:latest'
)

$ErrorActionPreference = 'Stop'

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

function Get-ImageLabel([string]$Image, [string]$Label) {
    $val = docker image inspect $Image --format "{{index .Config.Labels `"$Label`"}}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $val) { return $null }
    return $val.Trim()
}

function Get-RegistryDigest([string]$Image) {
    $digest = docker buildx imagetools inspect $Image --format '{{.Manifest.Digest}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $digest) {
        Write-Warning "Could not fetch registry digest for ${Image} (registry unreachable?)."
        return $null
    }
    return $digest.Trim()
}

function Format-ShortDigest([string]$Digest) {
    if ($Digest -match '^sha256:([0-9a-f]{12})') { return $Matches[1] }
    return $null
}

function Write-BaseComparison([string]$Baked, [string]$Latest) {
    $b = Format-ShortDigest $Baked
    $l = Format-ShortDigest $Latest
    if (-not $Baked -or -not $Latest) {
        $bStr = if ($b) { $b } else { '(unknown)' }
        $lStr = if ($l) { $l } else { '(unknown)' }
        Write-Host ("  {0,-8}  baked: {1,-14}  latest: {2}" -f 'Base', $bStr, $lStr)
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
        $latestStr = if ($Latest) { $Latest } else { '(unknown)' }
        Write-Host ("  {0,-8}  baked: {1,-14}  latest: {2}" -f $Agent, '(unknown)', $latestStr)
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
    Write-Host "Image $ClaudeImage not found — Claude baked version will be shown as (unknown)."
}

if (Test-ImageExists $CodexImage) {
    $codexBaked = Get-BakedCodexVersion $CodexImage
} else {
    Write-Host "Image $CodexImage not found — Codex baked version will be shown as (unknown)."
}

if (Test-ImageExists $BaseImage) {
    $baseSource = Get-ImageLabel $BaseImage 'powbox.base.source'
    $baseBaked  = Get-ImageLabel $BaseImage 'powbox.base.source.digest'
} else {
    Write-Host "Image $BaseImage not found — base will be shown as (unknown)."
}

$claudeLatest = $null
$codexLatest  = $null

if (Get-Command npm -ErrorAction SilentlyContinue) {
    $claudeLatest = Get-LatestNpmVersion '@anthropic-ai/claude-code'
    $codexLatest  = Get-LatestNpmVersion '@openai/codex'
} else {
    Write-Warning 'npm not found — latest agent versions will be shown as (unknown).'
}

if ($baseSource) {
    $baseLatest = Get-RegistryDigest $baseSource
}

# -------------------------------------------------------------------
# Report
# -------------------------------------------------------------------

Write-Host ''
Write-Host 'Agent update check:'
if ($baseBaked   -or $baseLatest)   { Write-BaseComparison $baseBaked $baseLatest }
if ($claudeBaked -or $claudeLatest) { Write-Comparison 'Claude' $claudeBaked $claudeLatest }
if ($codexBaked  -or $codexLatest)  { Write-Comparison 'Codex'  $codexBaked  $codexLatest  }
Write-Host ''
