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
        [string]$Ctx = "",
        [switch]$Isolated,
        [string]$Repo = "",
        [string]$Name = "",
        [string]$Ref = "",
        # -Fresh: documented alias for -Reclone (parity with bash --reclone | --fresh).
        [Alias("Fresh")]
        [switch]$Reclone
    )
    & "$env:POWBOX_ROOT\commands\claude-container.ps1" `
        -ProjectPath $ProjectPath `
        -Build:$Build -Detach:$Detach -Shell:$Shell `
        -Persist:$Persist -Resume:$Resume -Continue:$Continue -Volatile:$Volatile `
        -Ctx $Ctx `
        -Isolated:$Isolated -Repo $Repo -Name $Name -Ref $Ref -Reclone:$Reclone
    # In self-hosted (-Isolated) mode the positional is a repo spec, not a path, so
    # never Set-Location into it.
    if ($PSBoundParameters.ContainsKey('ProjectPath') -and -not $Isolated -and $? -and (_Powbox-ShouldCd)) {
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
        [string]$Ctx = "",
        [switch]$Isolated,
        [string]$Repo = "",
        [string]$Name = "",
        [string]$Ref = "",
        # -Fresh: documented alias for -Reclone (parity with bash --reclone | --fresh).
        [Alias("Fresh")]
        [switch]$Reclone
    )
    & "$env:POWBOX_ROOT\commands\codex-container.ps1" `
        -ProjectPath $ProjectPath `
        -Build:$Build -Detach:$Detach -Shell:$Shell `
        -Persist:$Persist -Resume:$Resume -Continue:$Continue -Volatile:$Volatile `
        -Exec $Exec -Ctx $Ctx `
        -Isolated:$Isolated -Repo $Repo -Name $Name -Ref $Ref -Reclone:$Reclone
    # In self-hosted (-Isolated) mode the positional is a repo spec, not a path, so
    # never Set-Location into it.
    if ($PSBoundParameters.ContainsKey('ProjectPath') -and -not $Isolated -and $? -and (_Powbox-ShouldCd)) {
        Set-Location -LiteralPath $ProjectPath
    }
}

function _Powbox-GetIsolatedByName {
    param(
        [string]$AgentPrefix,
        [string]$InstanceName
    )

    $cand = @(docker ps -a --filter "name=$AgentPrefix" --filter "label=powbox.self-hosted=true" --format "{{.Names}}" | Where-Object { $_ })
    if ($cand.Count -eq 0) { return @() }

    $sep = [char]31
    $fmt = '{{.Name}}' + $sep + '{{index .Config.Labels "powbox.instance-name"}}' + $sep + '{{index .Config.Labels "powbox.repo"}}' + $sep + '{{index .Config.Labels "powbox.ref"}}' + $sep + '{{.State.Status}}'
    @(docker inspect --format $fmt @cand 2>$null | ForEach-Object {
        $parts = $_.Split($sep)
        if ($parts.Count -lt 5) { return }
        $iname = if ($parts[1] -ne '<no value>') { $parts[1] } else { '' }
        # Case-sensitive (-cne): the launcher hashes the raw -Name, so case-only
        # variants (feature vs Feature) are distinct valid instances. Matching them
        # case-insensitively would resume the wrong one or report a false ambiguity;
        # keep parity with the bash shortcut's `[ "$iname" = "$lookup_name" ]`.
        if ($iname -cne $InstanceName) { return }
        [pscustomobject]@{
            Container = $parts[0].TrimStart('/')
            Name = $iname
            Repo = if ($parts[2] -ne '<no value>') { $parts[2] } else { '' }
            Ref = if ($parts[3] -ne '<no value>') { $parts[3] } else { '' }
            Status = $parts[4]
        }
    })
}

function _Powbox-ResumeIsolatedByName {
    param(
        [string]$AgentLabel,
        [string]$AgentPrefix,
        [string]$Shortcut,
        [string]$InstanceName
    )

    $matches = @(_Powbox-GetIsolatedByName -AgentPrefix $AgentPrefix -InstanceName $InstanceName)
    if ($matches.Count -eq 0) {
        Write-Error "No self-hosted $AgentLabel container found with -Name $(_Powbox-MarkerField $InstanceName). Use $Shortcut-list to see known instances."
        return
    }
    if ($matches.Count -gt 1) {
        Write-Error "-Name $(_Powbox-MarkerField $InstanceName) matches multiple self-hosted $AgentLabel containers. Relaunch one explicitly with -Repo, or prune the stale instance."
        $matches | Sort-Object Repo, Container | ForEach-Object {
            $ref = if ($_.Ref) { " -Ref $(_Powbox-MarkerField $_.Ref)" } else { "" }
            Write-Host "  $($_.Container) [$($_.Status)] repo=$(_Powbox-MarkerField $_.Repo)$ref" -ForegroundColor Yellow
        }
        return
    }

    $match = $matches[0]
    if (-not $match.Repo) {
        Write-Error "Container $($match.Container) has -Name $(_Powbox-MarkerField $InstanceName) but no powbox.repo label, so $Shortcut cannot reconstruct the isolated resume command. Use: docker start -ai $($match.Container)"
        return
    }

    & $Shortcut -Isolated -Repo $match.Repo -Name $match.Name -Resume
}

function cci {
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Name
    )
    _Powbox-ResumeIsolatedByName -AgentLabel "Claude" -AgentPrefix "claude-" -Shortcut "cc" -InstanceName $Name
}

function cxi {
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Name
    )
    _Powbox-ResumeIsolatedByName -AgentLabel "Codex" -AgentPrefix "codex-" -Shortcut "cx" -InstanceName $Name
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

# Re-seed the image-baked skills onto the claude-config/codex-config volumes,
# overriding the startup no-clobber so updated skill text in a rebuilt image
# replaces the stale copies left on the volumes. Forwards flags:
# -DryRun (preview), -Prune (drop obsolete seeds), -AdoptAll (take baked
# versions of unmarked name-collisions).
function agent-update-skills {
    & "$env:POWBOX_ROOT\commands\update-skills.ps1" @args
}

# After a successful image rebuild, offer to re-seed skills from the fresh image
# in the same flow. update-skills.ps1 itself prompts about conflicts/obsolete
# skills, so this only needs the top-level yes/no. Skipped when non-interactive.
function _Powbox-OfferReseed {
    if ([System.Console]::IsInputRedirected) { return }
    $reply = Read-Host 'Re-seed skills from the freshly built image onto the config volumes now? [y/N]'
    if ($reply -match '^(y|yes)$') {
        & "$env:POWBOX_ROOT\commands\update-skills.ps1"
    } else {
        Write-Host "Skipped skill re-seed. Run 'agent-update-skills' later to refresh."
    }
}

function _Powbox-NormLabel {
    param([string]$Value)
    if (-not $Value -or $Value -eq '<no value>') { return 'unknown' }
    return $Value
}

# Show the powbox commit that built each layer of powbox-agent:latest, plus the
# powbox working-tree HEAD so a stale image (built from an older repo state) is
# obvious even when the agent binaries themselves are current. A piecemeal build
# can carry up to three distinct commits: the base image has its own parent, and
# the Claude layer can rebuild without touching the Codex layer below it.
function agent-image-info {
    $img = "powbox-agent:latest"
    docker image inspect $img *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Image $img not found - build it with agent-update."
        return
    }
    $fmt = '{{index .Config.Labels "powbox.commit.base"}}|{{index .Config.Labels "powbox.commit.codex"}}|{{index .Config.Labels "powbox.commit.claude"}}|{{index .Config.Labels "powbox.codex.version"}}|{{index .Config.Labels "powbox.claude.version"}}'
    $p = (docker image inspect $img --format $fmt) -split '\|'
    Write-Host "$img - powbox commit that built each layer:"
    Write-Host ("  base:         {0}" -f (_Powbox-NormLabel $p[0]))
    Write-Host ("  codex:        {0}  (codex {1})" -f (_Powbox-NormLabel $p[1]), (_Powbox-NormLabel $p[3]))
    Write-Host ("  claude/top:   {0}  (claude {1})" -f (_Powbox-NormLabel $p[2]), (_Powbox-NormLabel $p[4]))
    $head = git -C $env:POWBOX_ROOT rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $head) {
        $dirty = git -C $env:POWBOX_ROOT status --porcelain 2>$null
        if ($dirty) { $head = "$head-dirty" }
        Write-Host ("  working tree: {0}" -f $head)
    }
}

# Print image provenance, then offer the skill re-seed, after a successful build.
function _Powbox-PostBuild {
    agent-image-info 2>$null
    _Powbox-OfferReseed
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

    # Provenance: which powbox commit built the current image vs. the working
    # tree. A current binary set can still sit on an image built from an older
    # repo - this surfaces that so the user can rebuild for repo changes alone.
    agent-image-info 2>$null

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
        if ($LASTEXITCODE -eq 0) { _Powbox-PostBuild }
        return
    }

    if ($stale.Count -eq 0) {
        Write-Host "Nothing to update — already up to date."
        return
    }

    Write-Host "Updating: $($stale -join ', ') (rebuilding only the affected image layers)."
    _Powbox-BuildFromTable -Table $table -Force $stale @args
    if ($LASTEXITCODE -eq 0) { _Powbox-PostBuild }
}

# Print the standard 'docker ps' table for the given filters, appending a marker to each
# self-hosted (-Isolated) row so you can tell WHICH instance it is and resume it without
# an inspect:  [self-hosted name=<-Name as entered> repo=<spec> ref=<ref>]  (fields are
# omitted when empty, so an unnamed instance shows just repo/ref and an old container
# with none of the labels shows a bare [self-hosted]). The self-hosted set is resolved
# with a label FILTER (docker ps --filter label=powbox.self-hosted=true) and the per-row
# name/repo/ref come from the powbox.instance-name/repo/ref labels via `docker inspect
# --format {{index ...}}` — both portable, unlike the '{{.Label ...}}' column podman's
# docker shim rejects. The name shown is the RAW -Name (the powbox.instance-name label),
# which disambiguates two names that slugify to the same container-name shape. A field
# value containing whitespace or shell metacharacters is single-quoted (e.g.
# name='Feature A') so the marker stays unambiguous and pastes straight back into -Name;
# the raw value is preserved, so its identity hash still recomputes. The header and
# dir-mounted rows pass through unchanged, so the output is identical to before when no
# self-hosted container exists.

# Render one marker field value (see powbox.sh _powbox_marker_field): verbatim when
# "simple" (repo specs/refs with slashes, colons, @, dots stay readable), else single-
# quoted so a value with spaces/metacharacters is unambiguous and pasteable into a resume
# command. PowerShell single-quote escaping doubles an embedded quote. The raw value is
# never altered, only how it is displayed.
function _Powbox-MarkerField([string]$v) {
    if ($v -match '[^A-Za-z0-9._/@:+-]') { "'" + $v.Replace("'", "''") + "'" } else { $v }
}

function _Powbox-AgentList {
    param([string[]]$Filters)
    $cand = @(docker ps -a @Filters --filter "label=powbox.self-hosted=true" --format "{{.Names}}" | Where-Object { $_ })
    # Markers keyed by container name, read from the labels in one inspect. Fields are
    # separated by \x1f (US, [char]31), NOT a tab: a non-whitespace separator keeps an
    # empty field (an unnamed instance's blank instance-name) from being lost, matching
    # powbox.sh. .Split keeps empty entries, so columns stay positional.
    $markers = @{}
    if ($cand.Count -gt 0) {
        $sep = [char]31
        $fmt = '{{.Name}}' + $sep + '{{index .Config.Labels "powbox.instance-name"}}' + $sep + '{{index .Config.Labels "powbox.repo"}}' + $sep + '{{index .Config.Labels "powbox.ref"}}'
        docker inspect --format $fmt @cand 2>$null | ForEach-Object {
            $parts = $_.Split($sep)
            $n = $parts[0].TrimStart('/') # docker inspect's .Name is /-prefixed
            if (-not $n) { return }
            # A missing label can surface as the literal "<no value>" (Docker renders a
            # nil labels map that way for `index`), so an old/pre-label container would
            # otherwise show "name=<no value> repo=<no value> ...". Treat it as empty so
            # such a container shows a bare [self-hosted], matching the repo's other label
            # reads (commands/check-updates.ps1, build-image.ps1).
            $iname = if ($parts.Count -ge 2 -and $parts[1] -ne '<no value>') { $parts[1] } else { '' }
            $irepo = if ($parts.Count -ge 3 -and $parts[2] -ne '<no value>') { $parts[2] } else { '' }
            $iref = if ($parts.Count -ge 4 -and $parts[3] -ne '<no value>') { $parts[3] } else { '' }
            $m = " [self-hosted"
            if ($iname) { $m += " name=$(_Powbox-MarkerField $iname)" }
            if ($irepo) { $m += " repo=$(_Powbox-MarkerField $irepo)" }
            if ($iref) { $m += " ref=$(_Powbox-MarkerField $iref)" }
            $m += "]"
            $markers[$n] = $m
        }
    }
    docker ps -a @Filters --format "table {{.ID}}`t{{.Names}}`t{{.Status}}`t{{.Image}}" | ForEach-Object {
        $line = $_
        # Names is field 2 of the table (ID NAMES STATUS IMAGE), and a container name
        # never contains whitespace, so the 2nd whitespace-delimited token is the
        # row's exact name. Compare it for EQUALITY: matching the whole line by
        # substring would mislabel a row when one container name is a substring of
        # another (claude-foo vs claude-foo-bar) or appears in another column. The
        # header row's field 2 ("ID") matches no container, so it passes through.
        $rowName = ($line.TrimStart() -split '\s+', 3)[1]
        $marked = if ($markers.ContainsKey($rowName)) { $markers[$rowName] } else { "" }
        "$line$marked"
    }
}

function cc-list {
    _Powbox-AgentList -Filters @("--filter", "name=claude-")
}

function cx-list {
    _Powbox-AgentList -Filters @("--filter", "name=codex-")
}

function agent-list {
    _Powbox-AgentList -Filters @("--filter", "name=claude-", "--filter", "name=codex-")
}

function agent-volumes {
    docker volume ls --filter "name=claude-config" --filter "name=codex-config" --filter "name=agent-" --format "table {{.Name}}`t{{.Driver}}`t{{.Mountpoint}}"
}
