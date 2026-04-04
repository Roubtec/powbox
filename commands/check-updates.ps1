param(
    [string]$ClaudeImage = 'powbox-claude:latest',
    [string]$CodexImage  = 'powbox-codex:latest'
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

$claudeLatest = $null
$codexLatest  = $null

if (Get-Command npm -ErrorAction SilentlyContinue) {
    $claudeLatest = Get-LatestNpmVersion '@anthropic-ai/claude-code'
    $codexLatest  = Get-LatestNpmVersion '@openai/codex'
} else {
    Write-Warning 'npm not found — latest versions will be shown as (unknown).'
}

# -------------------------------------------------------------------
# Report
# -------------------------------------------------------------------

Write-Host ''
Write-Host 'Agent update check:'
if ($claudeBaked -or $claudeLatest) { Write-Comparison 'Claude' $claudeBaked $claudeLatest }
if ($codexBaked  -or $codexLatest)  { Write-Comparison 'Codex'  $codexBaked  $codexLatest  }
Write-Host ''
