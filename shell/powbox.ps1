# PowBox shell helpers (PowerShell).
#
# Dot-source this file from your $PROFILE:
#
#     . "C:\Code\powbox\shell\powbox.ps1"
#
# $env:POWBOX_ROOT is auto-detected from the location of this file. If that
# fails, set it explicitly before dot-sourcing:
#
#     $env:POWBOX_ROOT = "C:\Code\powbox"
#     . "$env:POWBOX_ROOT\shell\powbox.ps1"
#
# Behavior toggles (set before dot-sourcing, or before calling the function):
#
#   $env:POWBOX_CD_AFTER_LAUNCH  1 (default) = Set-Location into the project
#                                dir after `cc`/`cx` returns when an explicit
#                                path was given
#                                0           = stay in the original directory
#
# All other behavior is controlled by flags on the underlying commands.

if (-not $env:POWBOX_ROOT) {
    if ($PSScriptRoot) {
        $env:POWBOX_ROOT = Split-Path -Parent $PSScriptRoot
    }
}

if (-not $env:POWBOX_ROOT) {
    Write-Error "powbox: POWBOX_ROOT is not set and could not be auto-detected. Set `$env:POWBOX_ROOT to your checkout before dot-sourcing shell/powbox.ps1."
    return
}

function _Powbox-ShouldCd {
    $val = $env:POWBOX_CD_AFTER_LAUNCH
    if ($null -eq $val -or $val -eq '') { return $true }
    switch ($val.ToLowerInvariant()) {
        '0'     { return $false }
        'false' { return $false }
        'no'    { return $false }
        'off'   { return $false }
        default { return $true }
    }
}

function cc {
    param(
        [string]$ProjectPath = (Get-Location).Path,
        [switch]$Build,
        [switch]$Detach,
        [switch]$Shell,
        [switch]$Persist,
        [switch]$Resume,
        [switch]$Continue,
        [switch]$Volatile,
        [string]$Ctx = ""
    )
    & "$env:POWBOX_ROOT\commands\claude-container.ps1" `
        -ProjectPath $ProjectPath `
        -Build:$Build -Detach:$Detach -Shell:$Shell `
        -Persist:$Persist -Resume:$Resume -Continue:$Continue -Volatile:$Volatile `
        -Ctx $Ctx
    if ($PSBoundParameters.ContainsKey('ProjectPath') -and $? -and (_Powbox-ShouldCd)) {
        Set-Location -LiteralPath $ProjectPath
    }
}

function cx {
    param(
        [string]$ProjectPath = (Get-Location).Path,
        [switch]$Build,
        [switch]$Detach,
        [switch]$Shell,
        [switch]$Persist,
        [switch]$Resume,
        [switch]$Continue,
        [switch]$Volatile,
        [string]$Exec = "",
        [string]$Ctx = ""
    )
    & "$env:POWBOX_ROOT\commands\codex-container.ps1" `
        -ProjectPath $ProjectPath `
        -Build:$Build -Detach:$Detach -Shell:$Shell `
        -Persist:$Persist -Resume:$Resume -Continue:$Continue -Volatile:$Volatile `
        -Exec $Exec -Ctx $Ctx
    if ($PSBoundParameters.ContainsKey('ProjectPath') -and $? -and (_Powbox-ShouldCd)) {
        Set-Location -LiteralPath $ProjectPath
    }
}

function agent-prune-volumes {
    & "$env:POWBOX_ROOT\commands\prune-volumes.ps1" @args
}

function agent-prune-stopped {
    $claudeNames = docker ps -a --format "{{.Names}}" --filter "status=exited" --filter "name=claude-"
    if ($claudeNames) {
        docker rm $claudeNames
    }
    $codexNames = docker ps -a --format "{{.Names}}" --filter "status=exited" --filter "name=codex-"
    if ($codexNames) {
        docker rm $codexNames
    }
}

function agent-prune {
    agent-prune-stopped
    # Forward any flags (e.g. -WhatIf/-Force) on to prune-volumes.ps1.
    agent-prune-volumes @args
}

function agent-check-updates {
    & "$env:POWBOX_ROOT\commands\check-updates.ps1" @args
}

function agent-reset-claude-history {
    & "$env:POWBOX_ROOT\commands\reset-claude-history.ps1" @args
}

# Read the machine-readable update table once (one container start reads both
# baked agent versions). Each row is: name<TAB>status<TAB>baked<TAB>latest.
function _Powbox-AgentPorcelain {
    & "$env:POWBOX_ROOT\commands\check-updates.ps1" -Porcelain
}

function _Powbox-InvokeBuild {
    param(
        [ValidateSet("base", "agent", "all")]
        [string]$Target,
        [string]$ClaudeVersion = "",
        [string]$CodexVersion = "",
        [switch]$Pull,
        [switch]$NoCache,
        [object[]]$ExtraArgs = @()
    )
    $buildParams = @{ Target = $Target }
    if ($ClaudeVersion) { $buildParams["ClaudeVersion"] = $ClaudeVersion }
    if ($CodexVersion)  { $buildParams["CodexVersion"] = $CodexVersion }
    if ($Pull)          { $buildParams["Pull"] = $true }
    if ($NoCache)       { $buildParams["NoCache"] = $true }

    for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
        $arg = [string]$ExtraArgs[$i]
        switch ($arg.ToLowerInvariant()) {
            '-target' {
                if ($i + 1 -ge $ExtraArgs.Count) { throw "Missing value for -Target" }
                $i++
                $buildParams["Target"] = [string]$ExtraArgs[$i]
            }
            '-claudeversion' {
                if ($i + 1 -ge $ExtraArgs.Count) { throw "Missing value for -ClaudeVersion" }
                $i++
                $buildParams["ClaudeVersion"] = [string]$ExtraArgs[$i]
            }
            '-codexversion' {
                if ($i + 1 -ge $ExtraArgs.Count) { throw "Missing value for -CodexVersion" }
                $i++
                $buildParams["CodexVersion"] = [string]$ExtraArgs[$i]
            }
            '-pull' {
                $buildParams["Pull"] = $true
            }
            '-nocache' {
                $buildParams["NoCache"] = $true
            }
            default {
                throw "Unsupported build argument for agent-update: $arg"
            }
        }
    }

    & "$env:POWBOX_ROOT\build.ps1" @buildParams
}

# Build the unified agent image from a porcelain table, pinning each binary so
# Docker rebuilds only the layers that actually changed.
#   -Table        porcelain table rows (array of TAB-separated strings)
#   -Force        agents to force to their latest version (array of names)
#   -Target       build target (agent|all)
#   @ExtraArgs    extra args forwarded to build.ps1
# Agents not in the force list are pinned to their currently baked version so
# Docker reuses that layer. Because Codex sits below Claude in the image, a
# Claude-only update rebuilds just the Claude layer; a Codex update also
# rebuilds the Claude layer above it (the accepted, rarer cost).
function _Powbox-BuildFromTable {
    param(
        [string[]]$Table,
        [string[]]$Force,
        [ValidateSet("agent", "all")]
        [string]$Target = "agent",
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$ExtraArgs
    )
    $claudeVer = ""
    $codexVer = ""
    foreach ($row in $Table) {
        if (-not $row) { continue }
        $fields = $row -split "`t"
        $name = $fields[0]
        if (-not $name -or $name -eq 'base') { continue }
        $baked = if ($fields.Count -gt 2) { $fields[2] } else { "" }
        $latest = if ($fields.Count -gt 3) { $fields[3] } else { "" }
        # Forced: install latest. Otherwise: pin baked so Docker reuses the layer.
        $ver = if ($Force -contains $name) { $latest } else { $baked }
        # '-' is the porcelain's empty marker (unknown/missing); leave unpinned so
        # the build falls back to the `latest` tag for that binary.
        if ($ver -eq '-') { $ver = "" }
        switch ($name) {
            'claude' { $claudeVer = $ver }
            'codex'  { $codexVer = $ver }
        }
    }
    _Powbox-InvokeBuild -Target $Target -ClaudeVersion $claudeVer -CodexVersion $codexVer -ExtraArgs $ExtraArgs
}

function agent-update-claude {
    $table = _Powbox-AgentPorcelain
    if ($LASTEXITCODE -ne 0) {
        Write-Error "agent-update-claude: update check failed"
        return
    }
    _Powbox-BuildFromTable -Table @($table) -Force @("claude") @args
}

function agent-update-codex {
    $table = _Powbox-AgentPorcelain
    if ($LASTEXITCODE -ne 0) {
        Write-Error "agent-update-codex: update check failed"
        return
    }
    _Powbox-BuildFromTable -Table @($table) -Force @("codex") @args
}

function agent-update-base {
    # A new base means the whole agent image should be rebuilt on top of it.
    $table = _Powbox-AgentPorcelain
    if ($LASTEXITCODE -eq 0) {
        _Powbox-BuildFromTable -Table @($table) -Force @("claude", "codex") -Target all -Pull -NoCache @args
        return
    }
    _Powbox-InvokeBuild -Target all -Pull -NoCache -ExtraArgs $args
}

# Show the full update report, then (if anything is stale) ask for confirmation
# before rebuilding. On confirmation we re-check rather than reusing the first
# result, so an update approved in another terminal while this prompt was waiting
# is still picked up. A stale base image is upstream of everything, so it triggers
# a full -Pull -NoCache rebuild of base + the agent image; otherwise only the
# stale agents are forced to latest and the unified image is rebuilt with minimal
# layers (the unchanged binary's layer is reused). Extra args go to build.ps1.
function agent-update {
    # check-updates.ps1 writes its report via Write-Host (the information
    # stream); 6>&1 captures it so we can both display it and scan it for the
    # "update available" marker without a second network round-trip. Keep this
    # marker in sync with commands/check-updates.ps1.
    $report = & "$env:POWBOX_ROOT\commands\check-updates.ps1" 6>&1 | ForEach-Object { $_.ToString() }
    $report | ForEach-Object { Write-Host $_ }

    if (-not ($report -match 'update available')) {
        Write-Host "All agent images are up to date."
        return
    }

    $reply = Read-Host 'Proceed with the update? [y/N]'
    if ($reply -notmatch '^(y|yes)$') {
        Write-Host "Update cancelled."
        return
    }

    # Re-read the porcelain table on confirmation so an update applied elsewhere
    # while this prompt was waiting is still picked up.
    $table = @(_Powbox-AgentPorcelain | Where-Object { $_ -and $_.Trim() })
    if ($table.Count -eq 0) {
        Write-Error "agent-update: update check failed"
        return
    }

    # A stale base is upstream of the agent image: rebuild base (with -Pull,
    # -NoCache) and the agent image on top. Otherwise force only the stale
    # agents to latest and rebuild the agent image with minimal layers.
    $baseStale = $false
    $stale = @()
    foreach ($row in $table) {
        $fields = $row -split "`t"
        $name = $fields[0]
        $status = if ($fields.Count -gt 1) { $fields[1] } else { "" }
        if ($name -eq 'base' -and $status -eq 'stale') { $baseStale = $true }
        if (($name -eq 'claude' -or $name -eq 'codex') -and $status -eq 'stale') {
            $stale += $name
        }
    }

    if ($baseStale) {
        Write-Host "Base image is stale — rebuilding base (with -Pull) and the agent image on top."
        _Powbox-BuildFromTable -Table $table -Force @("claude", "codex") -Target all -Pull -NoCache @args
        return
    }

    if ($stale.Count -eq 0) {
        Write-Host "Nothing to update — already up to date."
        return
    }

    Write-Host "Updating: $($stale -join ', ') (rebuilding only the affected image layers)."
    _Powbox-BuildFromTable -Table $table -Force $stale @args
}

function cc-list {
    docker ps -a --filter "name=claude-" --format "table {{.ID}}`t{{.Names}}`t{{.Status}}`t{{.Image}}"
}

function cx-list {
    docker ps -a --filter "name=codex-" --format "table {{.ID}}`t{{.Names}}`t{{.Status}}`t{{.Image}}"
}

function agent-list {
    docker ps -a --filter "name=claude-" --filter "name=codex-" --format "table {{.ID}}`t{{.Names}}`t{{.Status}}`t{{.Image}}"
}

function agent-volumes {
    docker volume ls --filter "name=claude-config" --filter "name=codex-config" --filter "name=agent-" --format "table {{.Name}}`t{{.Driver}}`t{{.Mountpoint}}"
}
