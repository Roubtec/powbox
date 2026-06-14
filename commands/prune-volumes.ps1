[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

$ErrorActionPreference = 'Stop'

$containerNames = @(docker ps -a --filter "name=claude-" --filter "name=codex-" --format "{{.Names}}")
$expectedVolumes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($containerName in $containerNames) {
    if ([string]::IsNullOrWhiteSpace($containerName)) {
        continue
    }

    $projectSuffix = $null
    if ($containerName -like 'claude-*') {
        $projectSuffix = $containerName -replace '^claude-', ''
    } elseif ($containerName -like 'codex-*') {
        $projectSuffix = $containerName -replace '^codex-', ''
    }

    if ($projectSuffix) {
        # Each container expects an nm (node_modules) and a wt (worktrees + pnpm
        # store) volume for its project (project-keyed, shared between the
        # project's two agents) plus its own agent-podman-* store and (for a
        # self-hosted container) its agent-ws-* workspace, both keyed by the FULL
        # container name so a project's concurrently-running Claude and Codex
        # containers never share one. agent-ws-* is over-expected for dir-mounted
        # containers too (which never create one), which is harmless.
        [void]$expectedVolumes.Add("agent-nm-$projectSuffix")
        [void]$expectedVolumes.Add("agent-wt-$projectSuffix")
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
# the store is per-project inside each agent-wt-* volume.
$candidateVolumes = @(docker volume ls --format "{{.Name}}" | Where-Object { $_ -like 'agent-nm-*' -or $_ -like 'agent-wt-*' -or $_ -like 'agent-ws-*' -or $_ -like 'agent-podman-*' -or $_ -eq 'agent-pnpm-store' })
$pruneCandidates = @($candidateVolumes | Where-Object { -not $expectedVolumes.Contains($_) })

if ($pruneCandidates.Count -eq 0) {
    Write-Host 'No orphaned agent-nm-*/agent-wt-*/agent-ws-*/agent-podman-* (or deprecated agent-pnpm-store) volumes found.'
    return
}

Write-Host 'Prune candidates:'
$pruneCandidates | Sort-Object | ForEach-Object { Write-Host "  $_" }

# Confirm once for the whole batch, mirroring prune-volumes.sh. Skip the prompt
# when -WhatIf is in effect (the ShouldProcess call below previews each removal
# instead) or when -Confirm was passed explicitly (ShouldProcess then prompts
# per volume, so a batch prompt would just double up).
if (-not $WhatIfPreference -and -not $PSBoundParameters.ContainsKey('Confirm')) {
    $answer = Read-Host "`nRemove these volumes? [y/N]"
    if ($answer -notmatch '^[yY]') {
        Write-Host 'Aborted.'
        return
    }
}

$removedCount = 0
$skippedCount = 0

foreach ($volumeName in ($pruneCandidates | Sort-Object)) {
    if ($PSCmdlet.ShouldProcess($volumeName, 'Remove orphaned per-project volume')) {
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
