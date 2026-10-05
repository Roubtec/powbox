# Print the name of the selected layer set, or nothing for the lean image.
# PowerShell parity of scripts/layers-select.sh; the two must agree case for case.
#
# Usage: layers-select.ps1 [<repo-root>]   (default: this script's repo)
#
# The selector is the gitignored <repo-root>/.powbox-layers. Its first line that
# is neither blank nor a #-comment, trimmed of whitespace (which covers a CRLF
# line ending), is the set name; a leading UTF-8 BOM is ignored. A missing or
# effectively empty file selects no set. A name that does not match
# ^[a-z0-9][a-z0-9._-]*$, or one without docker/layers/<name>/Dockerfile, is a
# hard error (exit 1) that names the offending value or path.
#
# The file is read as raw bytes and split on LF only, and only the ASCII
# whitespace that the .sh trims is trimmed here, so a byte the .sh would keep
# (a lone CR mid-line, a non-breaking space) fails the name check in both.
param([string]$Root = '')

$ErrorActionPreference = 'Stop'

function Exit-Select([string]$Message) {
    [Console]::Error.WriteLine("layers-select: $Message")
    exit 1
}

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$selector = Join-Path $Root '.powbox-layers'

if (-not (Test-Path -LiteralPath $selector)) { exit 0 }
if (-not (Test-Path -LiteralPath $selector -PathType Leaf)) { Exit-Select "$selector is not a regular file" }

$bytes = [System.IO.File]::ReadAllBytes($selector)
$offset = 0
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$text = $latin1.GetString($bytes, $offset, $bytes.Length - $offset)

$whitespace = [char[]]@(' ', "`t", "`n", "`r", [char]0x0B, [char]0x0C)
$name = ''
foreach ($line in $text.Split([char]"`n")) {
    $trimmed = $line.Trim($whitespace)
    # Ordinal, as the .sh's byte tests are: -eq '' and a one-argument StartsWith
    # compare by culture, which ignores format and control characters, so a line
    # holding only the byte 0xAD (U+00AD) would read as blank and 0xAD before '#'
    # as a comment, where the .sh rejects both as an invalid name.
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
    $name = $trimmed
    break
}

if (-not $name) { exit 0 }

if ($name -cnotmatch '^[a-z0-9][a-z0-9._-]*\z') {
    # Bytes, not [Console]::Error: the name was decoded one char per byte, so a
    # text writer would re-encode each non-ASCII byte (0xFF as C3 BF), where the
    # .sh echoes the name exactly as the file holds it.
    $utf8 = [System.Text.Encoding]::UTF8
    [byte[]]$message = $utf8.GetBytes("layers-select: invalid layer-set name '") + $latin1.GetBytes($name) +
        $utf8.GetBytes("' in $selector (must match ^[a-z0-9][a-z0-9._-]*`$)`n")
    $stderr = [Console]::OpenStandardError()
    $stderr.Write($message, 0, $message.Length)
    $stderr.Flush()
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $Root "docker/layers/$name/Dockerfile") -PathType Leaf)) {
    Exit-Select "docker/layers/$name/Dockerfile not found (layer set '$name' is selected in $selector)"
}
Write-Output $name
exit 0
