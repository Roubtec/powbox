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

# Collect expected (protected) volumes by deriving them from each existing
# claude-*/codex-* container's ACTUAL mounts, not by constructing
# agent-{nm,wt,ws,podman}-<name> from the container name. Name-construction
# over-expected volumes a container does not really mount: a dir-mounted container
# relaunched without a package.json mounts no nm/wt (MOUNT_WORKSPACE_VOLUMES=off),
# and a self-hosted (--isolated) container keeps its data in agent-ws-<name> with
# no nm/wt — yet any leftover agent-nm-<name>/agent-wt-<name> from a prior launch
# was marked expected and so never reported as an orphan. Conversely, a pre-rename
# container still mounting its legacy agent-nm-<project>/agent-wt-<project> was NOT
# protected by the new-name construction, so prune mislisted genuinely-mounted
# volumes. Reading real mounts fixes both: a container protects exactly what it
# mounts (legacy or new), and a volume no existing container mounts becomes an
# orphan candidate (the confirm prompt + Docker's in-use refusal are the backstop).
foreach ($containerName in $containerNames) {
    if ([string]::IsNullOrWhiteSpace($containerName)) {
        continue
    }

    # Skip containers agent-prune is removing this run so their volumes are
    # correctly reported as orphans. On a real run they are already gone from
    # `docker ps -a`; on a -WhatIf preview they still exist, but we must NOT
    # inspect them here, or their mounts would be re-protected and hide removals a
    # real run would perform.
    if ($removedContainers.Contains($containerName)) {
        continue
    }

    if ($containerName -like 'claude-*' -or $containerName -like 'codex-*') {
        # `docker inspect` emits one mount Name per line (bind mounts render an
        # empty Name, skipped below; anonymous volumes carry a hex name that never
        # matches the agent-* prefixes). stderr is dropped so a container that
        # vanished between `docker ps -a` and here (a rare race) is a harmless
        # no-op, not a hard error.
        $mountedVolumes = @(docker inspect --format '{{range .Mounts}}{{println .Name}}{{end}}' $containerName 2>$null)
        foreach ($mountedVolume in $mountedVolumes) {
            if ($mountedVolume -like 'agent-nm-*' -or $mountedVolume -like 'agent-wt-*' -or $mountedVolume -like 'agent-ws-*' -or $mountedVolume -like 'agent-podman-*') {
                [void]$expectedVolumes.Add($mountedVolume)
            }
        }
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
