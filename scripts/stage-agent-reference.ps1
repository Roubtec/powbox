# Compose the on-demand agent reference directory the agent image bakes for
# both agents. PowerShell parity of scripts/stage-agent-reference.sh, which
# documents the output; for the same inputs the two must write the same bytes
# and modes. The home and its rules are documented in docs/agent-reference.md.
#
# Usage: stage-agent-reference.ps1 [<set> [<repo-root>]]
#   <set>        the layer set from scripts/layers-select.ps1; empty or absent
#                means none
#   <repo-root>  default: this script's repo
#
# Files are handled as raw bytes through ISO-8859-1, which maps every byte to
# one char and back, so a contribution in any encoding (or none) comes out as
# the .sh writes it; only the ASCII bytes the .sh acts on are touched.
param([string]$Set = '', [string]$Root = '')

$ErrorActionPreference = 'Stop'

function Exit-Stage([string]$Message) {
    [Console]::Error.WriteLine("stage-agent-reference: $Message")
    exit 1
}

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$coreDir = Join-Path $Root 'docker/shared/agent-reference'
$stagingDir = Join-Path $Root '.powbox-staging'
$outDir = Join-Path $stagingDir 'agent-reference'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$isUnix = $PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows

# Modes as the .sh sets them: BuildKit's COPY cache key includes the mode, so
# the two drivers must agree on it. Not Set- verbs: the ShouldProcess rule
# would want -WhatIf support for helpers that only touch this script's output.
function Ensure-FileMode([string]$Path) {
    if ($isUnix) {
        [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead')
    }
}
function Ensure-DirMode([string]$Path) {
    if ($isUnix) {
        [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')
    }
}

function Test-Link([System.IO.FileSystemInfo]$Item) {
    return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# The names in a source directory, byte-sorted; refuses any entry that is not
# a regular name.md file.
function Get-SourceName([string]$Dir) {
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($item in (Get-ChildItem -LiteralPath $Dir -Force)) {
        $path = Join-Path $Dir $item.Name
        if ($item.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.md\z') { Exit-Stage "${path}: only files named like name.md belong here" }
        if ($item.PSIsContainer -or (Test-Link $item)) { Exit-Stage "$path is not a regular file" }
        $names.Add($item.Name)
    }
    $sorted = $names.ToArray()
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return , $sorted
}

# A set file's text as a contribution, without the final LF (empty when it
# holds only whitespace).
function Get-Normalized([string]$Path) {
    $text = $latin1.GetString([System.IO.File]::ReadAllBytes($Path))
    if ($text.Contains([string][char]0)) { Exit-Stage "$Path contains a NUL byte" }
    if ($text.StartsWith("$([char]0xEF)$([char]0xBB)$([char]0xBF)", [System.StringComparison]::Ordinal)) { $text = $text.Substring(3) }
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd([char[]]@(' ', "`t", "`n"))
    return ($text -creplace '^(?:[ \t]*\n)+', '')
}

if (-not (Test-Path -LiteralPath $coreDir -PathType Container)) { Exit-Stage "$coreDir not found" }
$coreNames = Get-SourceName $coreDir

$setDir = ''
$setNames = @()
if ($Set) {
    if ($Set -cnotmatch '^[a-z0-9][a-z0-9._-]*\z') { Exit-Stage "invalid layer-set name '$Set'" }
    $setDir = Join-Path $Root "docker/layers/$Set/agent-reference"
    $setItem = Get-Item -LiteralPath $setDir -Force -ErrorAction SilentlyContinue
    if ($null -ne $setItem) {
        if (-not $setItem.PSIsContainer -or (Test-Link $setItem)) { Exit-Stage "$setDir is not a directory" }
        $setNames = Get-SourceName $setDir
    }
}

# Compose every output file in memory first, so a failure leaves the staged
# directory as it was. Ordinal keys: the names are case-sensitive on Linux.
$files = [System.Collections.Generic.Dictionary[string, byte[]]]::new([System.StringComparer]::Ordinal)
foreach ($name in $coreNames) {
    $files[$name] = [System.IO.File]::ReadAllBytes((Join-Path $coreDir $name))
}
foreach ($name in $setNames) {
    $text = Get-Normalized (Join-Path $setDir $name)
    if (-not $text) { continue }
    if ($files.ContainsKey($name)) {
        $bytes = $files[$name]
        $suffix = ''
        if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 10) { $suffix = "`n" }
        $suffix += "`n## Contributed by the ``$Set`` layer set`n`n$text`n"
        $files[$name] = [byte[]]($bytes + $latin1.GetBytes($suffix))
    } else {
        $files[$name] = $latin1.GetBytes("$text`n")
    }
}

# Move-Item would move a file into a directory rather than replace it, and
# pruning never removes a directory; refuse before changing anything.
$staged = @()
if (Test-Path -LiteralPath $outDir -PathType Container) { $staged = @(Get-ChildItem -LiteralPath $outDir -Force) }
foreach ($item in $staged) {
    if ($item.PSIsContainer -and -not (Test-Link $item)) { Exit-Stage "$(Join-Path $outDir $item.Name) is a directory" }
}
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
Ensure-DirMode $outDir
foreach ($item in $staged) {
    if (-not $files.ContainsKey($item.Name)) { Remove-Item -LiteralPath (Join-Path $outDir $item.Name) -Force }
}

foreach ($name in $files.Keys) {
    $out = Join-Path $outDir $name
    $bytes = $files[$name]
    if (Test-Path -LiteralPath $out -PathType Leaf) {
        # A file we cannot read (another user's) counts as changed, as it does for cmp.
        try { $current = [System.IO.File]::ReadAllBytes($out) } catch { $current = $null }
        if ($null -ne $current -and [Convert]::ToBase64String($current) -ceq [Convert]::ToBase64String($bytes)) {
            # Setting the mode fails on a file another user owns (a sudo build's
            # leftover); replacing the file is then the way to the mode.
            $modeSet = $true
            try { Ensure-FileMode $out } catch { $modeSet = $false }
            if ($modeSet) { continue }
        }
    }
    $tmp = Join-Path $stagingDir ".agent-reference.$([System.Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        Ensure-FileMode $tmp
        Move-Item -LiteralPath $tmp -Destination $out -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}
exit 0
