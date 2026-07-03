# Compute a deterministic digest over the powbox source files baked into the
# BASE image layer (docker/base/Dockerfile plus every file it COPYs, listed in
# scripts/base-source-files.txt). PowerShell parity of scripts/base-source-digest.sh.
#
# build-image.ps1 stamps the result as the powbox.base.recipe.digest label on the
# base image; check-updates.ps1 recomputes it from the working tree and compares.
# A mismatch means a base-layer source change and marks the base stale (the
# powbox-source analogue of the existing upstream-digest trigger). Build-time and
# check-time recomputation MUST agree exactly, so this script produces a
# byte-identical digest to the .sh sibling for the same tree; keep them in lockstep.
#
# Algorithm (must match base-source-digest.sh):
#   - read the manifest, dropping blank lines and hash-comments, trimming whitespace
#   - sort the paths in ordinal (byte) order so manifest ordering is irrelevant
#   - for each path emit "<sha256-of-file-bytes>  <path>\n" (two spaces, LF)
#   - the digest is "sha256:" + sha256 of that concatenated buffer
# A missing listed input is a hard error (a silently dropped file would make the
# build/check digests disagree forever).
$ErrorActionPreference = 'Stop'

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
    } finally {
        $sha.Dispose()
    }
    return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
}

# $PSScriptRoot is scripts/; its parent is the repo root.
$rootDir = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $rootDir 'scripts/base-source-files.txt'
if (-not (Test-Path $manifest)) {
    Write-Error "base-source-digest: manifest not found: $manifest"
    exit 1
}

$paths = @()
foreach ($line in [System.IO.File]::ReadAllLines($manifest)) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
    $paths += $trimmed
}

# Byte-ordinal sort to match `LC_ALL=C sort` in the .sh (paths are pure ASCII, so
# ordinal string comparison and byte comparison coincide).
$sorted = [string[]]$paths
[System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)

$buffer = ''
foreach ($rel in $sorted) {
    $file = Join-Path $rootDir $rel
    if (-not (Test-Path $file)) {
        Write-Error "base-source-digest: listed input missing: $rel"
        exit 1
    }
    $fileHash = Get-Sha256Hex ([System.IO.File]::ReadAllBytes($file))
    # Two spaces + LF, matching `sha256sum`-style lines hashed by the .sh.
    $buffer += $fileHash + '  ' + $rel + "`n"
}

$digest = Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($buffer))
Write-Output ('sha256:' + $digest)
