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
        # Each container expects both an nm (node_modules) and a wt (worktrees +
        # pnpm store) volume for its project.
        [void]$expectedVolumes.Add("agent-nm-$projectSuffix")
        [void]$expectedVolumes.Add("agent-wt-$projectSuffix")
    }
}

# Per-project candidates (agent-nm-* / agent-wt-*) plus the deprecated shared
# store (agent-pnpm-store), which nothing mounts anymore now that the store is
# per-project inside each agent-wt-* volume.
$candidateVolumes = @(docker volume ls --format "{{.Name}}" | Where-Object { $_ -like 'agent-nm-*' -or $_ -like 'agent-wt-*' -or $_ -eq 'agent-pnpm-store' })
$pruneCandidates = @($candidateVolumes | Where-Object { -not $expectedVolumes.Contains($_) })

if ($pruneCandidates.Count -eq 0) {
    Write-Host 'No orphaned agent-nm-*/agent-wt-* (or deprecated agent-pnpm-store) volumes found.'
    return
}

Write-Host 'Prune candidates:'
$pruneCandidates | Sort-Object | ForEach-Object { Write-Host "  $_" }

$removedCount = 0

foreach ($volumeName in ($pruneCandidates | Sort-Object)) {
    if ($PSCmdlet.ShouldProcess($volumeName, 'Remove orphaned per-project volume')) {
        docker volume rm $volumeName | Out-Null
        $removedCount += 1
        Write-Host "Removed $volumeName"
    }
}

if ($removedCount -gt 0) {
    Write-Host "Removed $removedCount orphaned volume(s)."
}
