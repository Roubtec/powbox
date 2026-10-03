# Compose the agent instruction template the agent image bakes for both agents.
# PowerShell parity of scripts/stage-agent-template.sh, which documents the
# output; for the same inputs the two must write the same bytes.
#
# Usage: stage-agent-template.ps1 [<set> [<repo-root>]]
#   <set>        the layer set from scripts/layers-select.ps1; empty or absent
#                means none
#   <repo-root>  default: this script's repo
#
# Files are handled as raw bytes through ISO-8859-1, which maps every byte to
# one char and back, so notes in any encoding (or none) come out as the .sh
# writes them; only the ASCII bytes the .sh acts on are touched.
param([string]$Set = '', [string]$Root = '')

$ErrorActionPreference = 'Stop'

function Exit-Stage([string]$Message) {
    [Console]::Error.WriteLine("stage-agent-template: $Message")
    exit 1
}

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$template = Join-Path $Root 'docker/shared/container-agent.md.tmpl'
$stagingDir = Join-Path $Root '.powbox-staging'
$out = Join-Path $stagingDir 'agent.md.tmpl'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

# Mode 0644 whatever the umask or an existing file's mode, as the .sh sets it:
# BuildKit's COPY cache key includes the file mode, so the two drivers must agree
# on it too.
function Set-StagedMode([string]$Path) {
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead')
    }
}

if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { Exit-Stage "$template not found" }

$notes = ''
if ($Set) {
    if ($Set -cnotmatch '^[a-z0-9][a-z0-9._-]*\z') { Exit-Stage "invalid layer-set name '$Set'" }
    $notesFile = Join-Path $Root "docker/layers/$Set/agent-notes.md"
    if (Test-Path -LiteralPath $notesFile) {
        if (-not (Test-Path -LiteralPath $notesFile -PathType Leaf)) { Exit-Stage "$notesFile is not a regular file" }
        $notes = $latin1.GetString([System.IO.File]::ReadAllBytes($notesFile))
        if ($notes.Contains([string][char]0)) { Exit-Stage "$notesFile contains a NUL byte" }
        if ($notes.StartsWith("$([char]0xEF)$([char]0xBB)$([char]0xBF)", [System.StringComparison]::Ordinal)) { $notes = $notes.Substring(3) }
        $notes = $notes.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd([char[]]@(' ', "`t", "`n"))
        $notes = $notes -creplace '^(?:[ \t]*\n)+', ''
    }
}

$bytes = [System.IO.File]::ReadAllBytes($template)
if ($notes) {
    $suffix = ''
    if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 10) { $suffix = "`n" }
    $suffix += "`n## Additional tooling from the ``$Set`` layer set`n`n$notes`n"
    $bytes = [byte[]]($bytes + $latin1.GetBytes($suffix))
}

if (-not (Test-Path -LiteralPath $stagingDir)) { New-Item -ItemType Directory -Path $stagingDir | Out-Null }
if (Test-Path -LiteralPath $out -PathType Leaf) {
    $current = [System.IO.File]::ReadAllBytes($out)
    if ([Convert]::ToBase64String($current) -ceq [Convert]::ToBase64String($bytes)) {
        Set-StagedMode $out
        exit 0
    }
}
$tmp = Join-Path $stagingDir ".agent.md.tmpl.$([System.Guid]::NewGuid().ToString('N'))"
try {
    [System.IO.File]::WriteAllBytes($tmp, $bytes)
    Set-StagedMode $tmp
    Move-Item -LiteralPath $tmp -Destination $out -Force
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
}
exit 0
