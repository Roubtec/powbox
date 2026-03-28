[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

$ErrorActionPreference = 'Stop'

# Collect containers from both Claude and Codex harnesses
$containerNames = @(docker ps -a --filter "name=claude-" --filter "name=codex-" --format "{{.Names}}")
$expectedVolumes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($containerName in $containerNames) {
    if ([string]::IsNullOrWhiteSpace($containerName)) {
        continue
    }

    # Extract the project suffix from either prefix and map to agent-nm-*
    $projectSuffix = $null
    if ($containerName -like 'claude-*') {
        $projectSuffix = $containerName -replace '^claude-', ''
    } elseif ($containerName -like 'codex-*') {
        $projectSuffix = $containerName -replace '^codex-', ''
    }

    if ($projectSuffix) {
        [void]$expectedVolumes.Add("agent-nm-$projectSuffix")
    }
}

$nodeModulesVolumes = @(docker volume ls --format "{{.Name}}" | Where-Object { $_ -like 'agent-nm-*' })
$pruneCandidates = @($nodeModulesVolumes | Where-Object { -not $expectedVolumes.Contains($_) })

if ($pruneCandidates.Count -eq 0) {
    Write-Host 'No orphaned agent-nm-* volumes found.'
    return
}

Write-Host 'Prune candidates:'
$pruneCandidates | Sort-Object | ForEach-Object { Write-Host "  $_" }

$removedCount = 0

foreach ($volumeName in ($pruneCandidates | Sort-Object)) {
    if ($PSCmdlet.ShouldProcess($volumeName, 'Remove orphaned node_modules volume')) {
        docker volume rm $volumeName | Out-Null
        $removedCount += 1
        Write-Host "Removed $volumeName"
    }
}

if ($removedCount -gt 0) {
    Write-Host "Removed $removedCount orphaned agent-nm-* volume(s)."
}
