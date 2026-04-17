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
        [switch]$Volatile,
        [string]$Ctx = ""
    )
    & "$env:POWBOX_ROOT\commands\claude-container.ps1" `
        -ProjectPath $ProjectPath `
        -Build:$Build -Detach:$Detach -Shell:$Shell `
        -Persist:$Persist -Resume:$Resume -Volatile:$Volatile `
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
        [switch]$Volatile,
        [string]$Exec = "",
        [string]$Ctx = ""
    )
    & "$env:POWBOX_ROOT\commands\codex-container.ps1" `
        -ProjectPath $ProjectPath `
        -Build:$Build -Detach:$Detach -Shell:$Shell `
        -Persist:$Persist -Resume:$Resume -Volatile:$Volatile `
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
    agent-prune-volumes
}

function agent-check-updates {
    & "$env:POWBOX_ROOT\commands\check-updates.ps1" @args
}

function agent-update-claude {
    & "$env:POWBOX_ROOT\build.ps1" -Target claude -NoCache @args
}

function agent-update-codex {
    & "$env:POWBOX_ROOT\build.ps1" -Target codex -NoCache @args
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
