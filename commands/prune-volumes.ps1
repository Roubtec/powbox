# -Yes skips the batch confirmation prompt (mirrors prune-volumes.sh --yes), for
# scripted/agent-driven GC. -WhatIf previews removals without touching anything
# (the sh --dry-run); -Confirm prompts per volume via ShouldProcess.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$containerNames = @(docker ps -a --filter "name=claude-" --filter "name=codex-" --format "{{.Names}}")
$expectedVolumes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# When invoked via `agent-prune`, the stopped-container prune removes exited
# claude-*/codex- containers before us. In a real run they are already gone from
# `docker ps -a` here, but in a -WhatIf preview nothing was removed, so agent-prune
# passes their names in POWBOX_PRUNE_REMOVED_CONTAINERS and we treat them as
# already-removed — otherwise the preview would count their full-name-keyed
# agent-{nm,wt,ws,podman}-* volumes as expected and hide removals a real run would
# perform. Unset (standalone prune-volumes) -> every existing container, exited or
# not, still pins its volumes (Docker would refuse to remove them). Exact,
# case-sensitive match (Ordinal), mirroring the shell.
$removedContainers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
if ($env:POWBOX_PRUNE_REMOVED_CONTAINERS) {
    foreach ($removedName in ($env:POWBOX_PRUNE_REMOVED_CONTAINERS -split "`n")) {
        $trimmed = $removedName.Trim()
        if ($trimmed) { [void]$removedContainers.Add($trimmed) }
    }
}

foreach ($containerName in $containerNames) {
    if ([string]::IsNullOrWhiteSpace($containerName)) {
        continue
    }

    # Skip containers agent-prune is removing this run so their volumes are
    # correctly reported as orphans.
    if ($removedContainers.Contains($containerName)) {
        continue
    }

    if ($containerName -like 'claude-*' -or $containerName -like 'codex-*') {
        # Every agent volume is now keyed by the FULL container name (agent +
        # project), so a container named claude-<slug> expects
        # agent-{nm,wt,ws,podman}-claude-<slug> — i.e. agent-<kind>-$containerName.
        # A shared writable node_modules / pnpm store would corrupt two live agents,
        # so nm/wt are per-container like ws/podman. agent-ws-* is over-expected for
        # dir-mounted containers (which never create one), which is harmless.
        [void]$expectedVolumes.Add("agent-nm-$containerName")
        [void]$expectedVolumes.Add("agent-wt-$containerName")
        [void]$expectedVolumes.Add("agent-ws-$containerName")
        [void]$expectedVolumes.Add("agent-podman-$containerName")
    }
}

# The global shared image store is infra shared by every container (like the
# config volumes), not a per-container store — it matches the agent-podman-*
# candidate glob below but is never an orphan. Always expect it.
[void]$expectedVolumes.Add("agent-podman-imagestore")

# Candidates: agent-nm-* / agent-wt-* / agent-ws-* / agent-podman-* plus the
# deprecated shared store (agent-pnpm-store), which nothing mounts anymore now that
# the store is per-container inside each agent-wt-* volume.
$candidateVolumes = @(docker volume ls --format "{{.Name}}" | Where-Object { $_ -like 'agent-nm-*' -or $_ -like 'agent-wt-*' -or $_ -like 'agent-ws-*' -or $_ -like 'agent-podman-*' -or $_ -eq 'agent-pnpm-store' })
$pruneCandidates = @($candidateVolumes | Where-Object { -not $expectedVolumes.Contains($_) })

if ($pruneCandidates.Count -eq 0) {
    Write-Host 'No orphaned agent-nm-*/agent-wt-*/agent-ws-*/agent-podman-* (or deprecated agent-pnpm-store) volumes found.'
    return
}

Write-Host 'Prune candidates:'
$pruneCandidates | Sort-Object | ForEach-Object { Write-Host "  $_" }

# Confirm once for the whole batch, mirroring prune-volumes.sh. Skip the prompt
# when -Yes was passed (non-interactive removal), when -WhatIf is in effect (the
# ShouldProcess call below previews each removal instead), or when -Confirm was
# passed explicitly (ShouldProcess then prompts per volume, so a batch prompt
# would just double up).
if (-not $Yes -and -not $WhatIfPreference -and -not $PSBoundParameters.ContainsKey('Confirm')) {
    $answer = Read-Host "`nRemove these volumes? [y/N]"
    if ($answer -notmatch '^[yY]') {
        Write-Host 'Aborted.'
        return
    }
}

$removedCount = 0
$skippedCount = 0

foreach ($volumeName in ($pruneCandidates | Sort-Object)) {
    if ($PSCmdlet.ShouldProcess($volumeName, 'Remove orphaned agent volume')) {
        # Capture output (merging stderr) and key off the exit code: a volume still
        # referenced by an existing container (e.g. a pre-change container holding the
        # deprecated agent-pnpm-store) can't be removed yet, and docker returns non-zero.
        # Don't count or report it as removed.
        $rmOutput = docker volume rm $volumeName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $removedCount += 1
            Write-Host "Removed $volumeName"
        }
        else {
            $skippedCount += 1
            Write-Warning "Skipped $volumeName - could not remove (still in use by a container?): $rmOutput"
        }
    }
}

# Print the removed-count summary unconditionally after a confirmed run (matches
# prune-volumes.sh), but not during a -WhatIf preview where nothing was touched.
if (-not $WhatIfPreference) {
    Write-Host "Removed $removedCount orphaned volume(s)."
}
if ($skippedCount -gt 0) {
    Write-Warning "Skipped $skippedCount volume(s) still in use - remove or recreate the owning container, then re-run."
}
