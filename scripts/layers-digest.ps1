# Compute the digest of a layer-set directory (docker/layers/<set>), after
# checking that the set obeys the layer Dockerfile contract. PowerShell parity of
# scripts/layers-digest.sh: it must print a byte-identical digest for the same
# tree and reject the same sets, so keep the two in lockstep. The algorithm, the
# contract and the exit statuses are documented in the .sh header.
#
# Usage: layers-digest.ps1 <set-directory>
#
# Exit status: 0 with the digest on stdout; 1 when the set breaks the contract or
# cannot be read (every offending line or path is named on stderr); 2 on a usage
# error. The .sh's status 3 (no sha256 tool) cannot happen here.
param([string]$SetDir = '')

$ErrorActionPreference = 'Stop'

if (-not $SetDir) {
    [Console]::Error.WriteLine('usage: layers-digest.ps1 <set-directory>')
    exit 2
}
$SetDir = $SetDir.TrimEnd('/', '\')
if (-not $SetDir) { $SetDir = '/' }
$script:errors = 0

function Write-DigestError([string]$Message) {
    [Console]::Error.WriteLine("layers-digest: $Message")
    $script:errors++
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
    } finally {
        $sha.Dispose()
    }
    return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
}

function Test-SymbolicLink($Item) {
    return ($Item.LinkType -eq 'SymbolicLink' -or $Item.LinkType -eq 'Junction')
}

if (-not (Test-Path -LiteralPath $SetDir -PathType Container)) {
    [Console]::Error.WriteLine("layers-digest: layer-set directory not found: $SetDir")
    exit 1
}
# .NET file APIs resolve a relative path against the process directory, which
# Push-Location in a calling script does not move, so work on the resolved path
# and keep $SetDir, as given, for messages.
$setFull = (Resolve-Path -LiteralPath $SetDir).ProviderPath.TrimEnd('/', '\')
$dockerfile = Join-Path $setFull 'Dockerfile'
if (-not (Test-Path -LiteralPath $dockerfile -PathType Leaf) -or (Test-SymbolicLink (Get-Item -LiteralPath $dockerfile -Force))) {
    [Console]::Error.WriteLine("layers-digest: $SetDir/Dockerfile is missing or not a regular file")
    exit 1
}

# The same whitespace class as the .sh's [[:space:]] under LC_ALL=C, and the
# narrower one its `read -a` splits words on.
$whitespace = [char[]]@(' ', "`t", "`n", "`r", [char]0x0B, [char]0x0C)
$wordSeparators = [char[]]@(' ', "`t", "`n")
$continuation = [regex]'\\[ \t\n\r\v\f]*\z'

function Test-BlankOrComment([string]$Line) {
    $t = $Line.TrimStart($whitespace)
    return ($t -eq '' -or $t.StartsWith('#'))
}

function Get-StrippedContinuation([string]$Line) {
    $t = $Line.TrimEnd($whitespace)
    return $t.Substring(0, $t.Length - 1)
}

# Whether the latest stage descends from ${BASE_IMAGE}, and the names of the
# stages so far that do (lowercased, as Docker matches them).
$script:fromCount = 0
$script:fromLine = 0
$script:fromLogical = ''
$script:fromOnBase = $false
$script:baseStages = New-Object System.Collections.Generic.HashSet[string]

# Record a FROM: its flags are skipped, then the image, then an optional AS name.
function Register-From([int]$LineNo, [string]$Logical, [string[]]$Words) {
    $i = 1
    while ($i -lt $Words.Count -and $Words[$i].StartsWith('--', [System.StringComparison]::Ordinal)) { $i++ }
    $image = if ($i -lt $Words.Count) { $Words[$i] } else { '' }
    $name = ''
    if (($i + 2) -lt $Words.Count -and $Words[$i + 1].ToLowerInvariant() -eq 'as') {
        $name = $Words[$i + 2].ToLowerInvariant()
    }
    $script:fromCount++
    $script:fromLine = $LineNo
    $script:fromLogical = $Logical
    $script:fromOnBase = ($image -ceq '${BASE_IMAGE}' -or $image -ceq '$BASE_IMAGE' -or $script:baseStages.Contains($image.ToLowerInvariant()))
    if ($script:fromOnBase -and $name) { [void]$script:baseStages.Add($name) }
}

# Report a COPY or ADD (also behind ONBUILD) whose flags lack --chmod=<mode>,
# and pass a FROM to Register-From.
function Test-Instruction([int]$LineNo, [string]$Logical) {
    $words = @($Logical.Split($wordSeparators, [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($words.Count -eq 0) { return }
    $i = 0
    $keyword = $words[0].ToUpperInvariant()
    if ($keyword -eq 'FROM') {
        Register-From -LineNo $LineNo -Logical $Logical -Words $words
        return
    }
    if ($keyword -eq 'ONBUILD' -and $words.Count -gt 1) {
        $keyword = $words[1].ToUpperInvariant()
        $i = 1
    }
    if ($keyword -ne 'COPY' -and $keyword -ne 'ADD') { return }
    for ($i++; $i -lt $words.Count; $i++) {
        $w = $words[$i]
        if ($w.StartsWith('--chmod=', [System.StringComparison]::Ordinal) -and $w.Length -gt 8) { return }
        if (-not $w.StartsWith('--', [System.StringComparison]::Ordinal)) { break }
    }
    Write-DigestError "${SetDir}/Dockerfile:${LineNo}: ${keyword} without --chmod=<mode>: $Logical"
}

$content = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($dockerfile))
$lines = New-Object System.Collections.Generic.List[string]
foreach ($raw in $content.Split([char]"`n")) {
    if ($raw.EndsWith("`r")) { $raw = $raw.Substring(0, $raw.Length - 1) }
    $lines.Add($raw)
}
# A trailing LF leaves one empty element that the .sh's read loop never sees.
if ($content.EndsWith("`n")) { $lines.RemoveAt($lines.Count - 1) }

$n = $lines.Count
$i = 0
while ($i -lt $n) {
    $line = $lines[$i]
    $start = $i + 1
    if (Test-BlankOrComment $line) { $i++; continue }
    $logical = $line
    $cont = $false
    if ($continuation.IsMatch($line)) {
        $cont = $true
        $logical = Get-StrippedContinuation $line
    }
    while ($cont -and ($i + 1) -lt $n) {
        $i++
        $next = $lines[$i]
        if (Test-BlankOrComment $next) { continue }
        if ($continuation.IsMatch($next)) {
            $logical = $logical + ' ' + (Get-StrippedContinuation $next)
        } else {
            $logical = $logical + ' ' + $next
            $cont = $false
        }
    }
    Test-Instruction $start $logical
    $i++
}

if ($script:fromCount -eq 0) {
    Write-DigestError "${SetDir}/Dockerfile: no FROM; the final stage must build FROM `${BASE_IMAGE}"
} elseif (-not $script:fromOnBase) {
    Write-DigestError "${SetDir}/Dockerfile:$($script:fromLine): the final stage must build FROM `${BASE_IMAGE} (directly or through an earlier stage): $($script:fromLogical)"
}

$files = New-Object System.Collections.Generic.List[string]
$entries = New-Object System.Collections.Generic.List[object]
foreach ($item in @(Get-ChildItem -LiteralPath $setFull -Recurse -Force)) {
    $rel = $item.FullName.Substring($setFull.Length).TrimStart('/', '\').Replace('\', '/')
    $entries.Add([PSCustomObject]@{ Rel = $rel; Key = [System.Text.Encoding]::UTF8.GetBytes($rel); Item = $item })
}
# Sort by the UTF-8 bytes of the path, as the .sh's `sort -z` under LC_ALL=C
# does. StringComparer.Ordinal compares UTF-16 code units instead, which puts a
# surrogate pair (U+1F600) before U+E000..U+FFFF (U+FF21) where the bytes put it
# after, and would hash those sets differently from the .sh.
$sorted = $entries.ToArray()
[System.Array]::Sort($sorted, [System.Comparison[object]] {
        param($a, $b)
        $x = $a.Key
        $y = $b.Key
        $len = [System.Math]::Min($x.Length, $y.Length)
        for ($j = 0; $j -lt $len; $j++) {
            if ($x[$j] -ne $y[$j]) { return ([int]$x[$j] - [int]$y[$j]) }
        }
        return ($x.Length - $y.Length)
    })

foreach ($entry in $sorted) {
    $rel = $entry.Rel
    $item = $entry.Item
    $path = "$SetDir/$rel"
    if (Test-SymbolicLink $item) {
        Write-DigestError "${path}: symlinks are not allowed in a layer set (create the link in a RUN instead)"
        continue
    }
    if ($item.PSIsContainer) { continue }
    # On Unix a FIFO, socket or device still surfaces as a file item, and only
    # PowerShell's stat view tells it apart. Windows has no such entries.
    $stat = if ($item.PSObject.Properties['UnixStat']) { $item.UnixStat } else { $null }
    if ($stat -and [string]$stat.ItemType -ne 'File') {
        Write-DigestError "${path}: not a regular file; only regular files are allowed in a layer set"
        continue
    }
    $files.Add($rel)
}

if ($script:errors -gt 0) { exit 1 }

$buffer = New-Object System.Text.StringBuilder
foreach ($rel in $files) {
    $fileHash = Get-Sha256Hex ([System.IO.File]::ReadAllBytes((Join-Path $setFull $rel)))
    [void]$buffer.Append($fileHash).Append('  ').Append($rel).Append("`n")
}
Write-Output ('sha256:' + (Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($buffer.ToString()))))
exit 0
