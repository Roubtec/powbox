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

# The same whitespace class as the .sh's [[:space:]] under LC_ALL=C, which is
# also what Docker splits an instruction's words on.
$whitespace = [char[]]@(' ', "`t", "`n", "`r", [char]0x0B, [char]0x0C)
$wordSeparators = $whitespace
# Go's unicode.IsSpace, spelled out as the .sh's UNICODE_SPACES is rather than
# left to [char]::IsWhiteSpace: BuildKit trims these from the start of an
# instruction, a comment or an empty continuation line.
$lineSpace = [char[]](@(' ', "`t", "`n", "`r", [char]0x0B, [char]0x0C, [char]0x85, [char]0xA0, [char]0x1680) +
    @(0x2000..0x200A | ForEach-Object { [char]$_ }) +
    @([char]0x2028, [char]0x2029, [char]0x202F, [char]0x205F, [char]0x3000))
# As Docker's continuation rule: a backslash ending the line continues it, unless
# another backslash precedes it. Only spaces and tabs may follow it.
$continuation = [regex]'(^|[^\\])\\[ \t]*\z'

# Case folding of ASCII letters only, as the .sh's tr under LC_ALL=C does;
# ToUpperInvariant would also fold, say, a dotless i into I. U+0130 and U+212A
# fold to I and K first, as in the .sh's upper (Go's strings.ToLower maps them
# into ASCII, and BuildKit matches keywords with it).
function ConvertTo-AsciiUpper([string]$Text) {
    $Text = $Text.Replace([string][char]0x130, 'I').Replace([string][char]0x212A, 'K')
    return [regex]::Replace($Text, '[a-z]', { param($m) $m.Value.ToUpperInvariant() })
}
function ConvertTo-AsciiLower([string]$Text) {
    return [regex]::Replace($Text, '[A-Z]', { param($m) $m.Value.ToLowerInvariant() })
}

# Every string comparison here is ordinal, as the .sh's byte comparisons are:
# PowerShell's -eq/-ceq/-contains and .NET's StartsWith/EndsWith without a
# StringComparison compare by culture, which ignores zero-width and format
# characters (U+200B, U+00AD, U+FEFF), so "ONBUILD" would equal U+FEFF ONBUILD
# and a U+200B line would read as blank, where BuildKit and the .sh disagree.
function Test-SameString([string]$A, [string]$B) {
    return [string]::Equals($A, $B, [System.StringComparison]::Ordinal)
}

function Test-BlankOrComment([string]$Line) {
    $t = $Line.TrimStart($lineSpace)
    return ($t.Length -eq 0 -or $t.StartsWith('#', [System.StringComparison]::Ordinal))
}

function Get-StrippedContinuation([string]$Line) {
    $t = $Line.TrimEnd(' ', "`t")
    return $t.Substring(0, $t.Length - 1)
}

# Whether the latest stage descends from ${BASE_IMAGE}, and the names of the
# stages so far that do (lowercased, as Docker matches them).
$script:fromCount = 0
$script:fromLine = 0
$script:fromLogical = ''
$script:fromOnBase = $false
$script:baseStages = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)

# Record a FROM: its flags are skipped, then the image, then an optional AS name.
function Register-From([int]$LineNo, [string]$Logical, [string[]]$Words) {
    $i = 1
    while ($i -lt $Words.Count -and $Words[$i].StartsWith('--', [System.StringComparison]::Ordinal)) { $i++ }
    $image = if ($i -lt $Words.Count) { ConvertFrom-ShellWord $Words[$i] } else { '' }
    $name = ''
    if (($i + 2) -lt $Words.Count -and (Test-SameString (ConvertTo-AsciiLower $Words[$i + 1]) 'as')) {
        $name = ConvertTo-AsciiLower $Words[$i + 2]
    }
    $script:fromCount++
    $script:fromLine = $LineNo
    $script:fromLogical = $Logical
    $script:fromOnBase = ((Test-SameString $image '${BASE_IMAGE}') -or (Test-SameString $image '$BASE_IMAGE') -or $script:baseStages.Contains((ConvertTo-AsciiLower $image)))
    if ($script:fromOnBase -and $name) { [void]$script:baseStages.Add($name) }
}

# Report an ONBUILD, a COPY or ADD whose flags lack --chmod=<mode> and a RUN
# that bind-mounts the build context, and pass a FROM to Register-From.
function Test-Instruction([int]$LineNo, [string]$Logical) {
    $words = @($Logical.Split($wordSeparators, [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($words.Count -eq 0) { return }
    $keyword = ConvertTo-AsciiUpper $words[0]
    if (Test-SameString $keyword 'FROM') {
        Register-From -LineNo $LineNo -Logical $Logical -Words $words
        return
    }
    if (Test-SameString $keyword 'ONBUILD') {
        Write-DigestError "${SetDir}/Dockerfile:${LineNo}: ONBUILD is not allowed (its trigger runs in the agent build, outside the set's digest): $Logical"
        return
    }
    if (Test-SameString $keyword 'RUN') {
        # See check_run_mounts in the .sh.
        foreach ($flag in @(Get-FlagWord $Logical.Substring($words[0].Length).TrimEnd($lineSpace))) {
            if ($flag.StartsWith('--mount=', [System.StringComparison]::Ordinal) -and (Test-MountBindsContext $flag.Substring(8))) {
                Write-DigestError "${SetDir}/Dockerfile:${LineNo}: RUN --mount= binding the build context is not allowed (the set's digest does not cover the modes it exposes; mount from=<stage-or-image>, or COPY with --chmod=<mode>): $Logical"
                return
            }
        }
        return
    }
    if (-not (Test-SameString $keyword 'COPY') -and -not (Test-SameString $keyword 'ADD')) { return }
    for ($i = 1; $i -lt $words.Count; $i++) {
        $w = $words[$i]
        if ($w.StartsWith('--chmod=', [System.StringComparison]::Ordinal) -and $w.Length -gt 8) { return }
        if (-not $w.StartsWith('--', [System.StringComparison]::Ordinal)) { break }
    }
    Write-DigestError "${SetDir}/Dockerfile:${LineNo}: ${keyword} without --chmod=<mode>: $Logical"
}

# See flag_words in the .sh. The text is walked as its UTF-8 bytes, each read
# as one Latin-1 character, as BuildKit's extractBuilderFlags reads it, so a
# 0x85 or 0xA0 byte splits a word here too.
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$flagSpace = [int[]]@(0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0xA0)
function Get-FlagWord([string]$Text) {
    $s = $latin1.GetString([System.Text.Encoding]::UTF8.GetBytes($Text))
    $out = New-Object System.Collections.Generic.List[string]
    $k = 0
    while ($true) {
        while ($k -lt $s.Length -and $flagSpace -contains [int]$s[$k]) { $k++ }
        if (-not (($k + 1) -lt $s.Length -and [int]$s[$k] -eq 0x2D -and [int]$s[$k + 1] -eq 0x2D)) { break }
        $word = New-Object System.Text.StringBuilder
        $quote = 0
        while ($k -lt $s.Length) {
            $c = [int]$s[$k]
            $k++
            if ($quote -eq 0 -and $flagSpace -contains $c) {
                break
            } elseif ($quote -eq 0 -and ($c -eq 0x27 -or $c -eq 0x22)) {
                $quote = $c
            } elseif ($quote -ne 0 -and $c -eq $quote) {
                $quote = 0
            } elseif ($c -eq 0x5C) {
                if ($k -lt $s.Length) {
                    [void]$word.Append($s[$k])
                    $k++
                }
            } else {
                [void]$word.Append([char]$c)
            }
        }
        $w = $word.ToString()
        if (Test-SameString $w '--') { break }
        $out.Add($w)
    }
    return $out.ToArray()
}

# See mount_fields in the .sh: the fields of a --mount= value, or $null where
# BuildKit's csvvalue fails.
function Get-MountField([string]$Value) {
    if ($Value.Length -eq 0) { return $null }
    $out = New-Object System.Collections.Generic.List[string]
    $s = $Value
    while ($true) {
        if ($s.StartsWith('"', [System.StringComparison]::Ordinal)) {
            $s = $s.Substring(1)
            $field = ''
            while ($true) {
                $q = $s.IndexOf([char]'"')
                if ($q -lt 0) { return $null }
                $field += $s.Substring(0, $q)
                $s = $s.Substring($q + 1)
                if ($s.StartsWith('"', [System.StringComparison]::Ordinal)) {
                    $field += '"'
                    $s = $s.Substring(1)
                } elseif ($s.StartsWith(',', [System.StringComparison]::Ordinal)) {
                    $out.Add($field)
                    $s = $s.Substring(1)
                    break
                } elseif ($s.Length -eq 0) {
                    $out.Add($field)
                    return , $out
                } else {
                    return $null
                }
            }
            continue
        }
        $comma = $s.IndexOf([char]',')
        $field = if ($comma -ge 0) { $s.Substring(0, $comma) } else { $s }
        if ($field.Contains('"')) { return $null }
        $out.Add($field)
        if ($comma -lt 0) { return , $out }
        $s = $s.Substring($comma + 1)
    }
}

# See mount_binds_context in the .sh for which mounts count as a bind of the
# build context and why.
function Test-MountBindsContext([string]$Value) {
    $fields = Get-MountField $Value
    if ($null -eq $fields) { return $true }
    $type = 'bind'
    $from = ''
    foreach ($field in $fields) {
        $eq = $field.IndexOf([char]'=')
        if ($eq -lt 0) { continue }
        $key = ConvertTo-AsciiLower $field.Substring(0, $eq)
        if (Test-SameString $key 'type') {
            $type = ConvertTo-AsciiLower $field.Substring($eq + 1)
        } elseif (Test-SameString $key 'from') {
            $from = $field.Substring($eq + 1)
        }
    }
    if ([Array]::IndexOf([string[]]@('cache', 'tmpfs', 'secret', 'ssh'), $type) -ge 0) { return $false }
    return ($from.Length -eq 0 -or $from.IndexOfAny([char[]]@('$', "'", '"', '\')) -ge 0)
}

# See shell_words in the .sh: the words BuildKit's shell lexer sees when it
# looks for heredocs, quotes and backslash escapes kept in them, split on
# $lineSpace, an unquoted << keeping the spaces, tabs and CRs after it.
function Get-ShellWord([string]$Text) {
    $out = New-Object System.Collections.Generic.List[string]
    $word = New-Object System.Text.StringBuilder
    $quote = ''
    $have = $false
    for ($k = 0; $k -lt $Text.Length; $k++) {
        $c = [string]$Text[$k]
        if ($quote) {
            [void]$word.Append($c)
            if (Test-SameString $c $quote) {
                $quote = ''
            } elseif ((Test-SameString $c '\') -and (Test-SameString $quote '"') -and ($k + 1) -lt $Text.Length) {
                $k++
                [void]$word.Append($Text[$k])
            }
            continue
        }
        if ($lineSpace -contains $Text[$k]) {
            if ($have) { $out.Add($word.ToString()) }
            [void]$word.Clear()
            $have = $false
        } elseif (Test-SameString $c '\') {
            [void]$word.Append($c)
            $have = $true
            if (($k + 1) -lt $Text.Length) {
                $k++
                [void]$word.Append($Text[$k])
            }
        } elseif ((Test-SameString $c '"') -or (Test-SameString $c "'")) {
            $quote = $c
            [void]$word.Append($c)
            $have = $true
        } elseif (Test-SameString $c '<') {
            [void]$word.Append($c)
            $have = $true
            if (($k + 1) -lt $Text.Length -and $Text[$k + 1] -eq [char]'<') {
                $k++
                [void]$word.Append('<')
                while (($k + 1) -lt $Text.Length -and " `t`r".IndexOf($Text[$k + 1]) -ge 0) {
                    $k++
                    [void]$word.Append($Text[$k])
                }
            }
        } else {
            [void]$word.Append($c)
            $have = $true
        }
    }
    if ($have) { $out.Add($word.ToString()) }
    return $out.ToArray()
}

# See unquote_word in the .sh.
function ConvertFrom-ShellWord([string]$Text) {
    $out = New-Object System.Text.StringBuilder
    $quote = ''
    for ($k = 0; $k -lt $Text.Length; $k++) {
        $c = [string]$Text[$k]
        if (Test-SameString $quote "'") {
            if (Test-SameString $c "'") { $quote = '' } else { [void]$out.Append($c) }
        } elseif (Test-SameString $quote '"') {
            if (Test-SameString $c '"') {
                $quote = ''
            } elseif ((Test-SameString $c '\') -and ($k + 1) -lt $Text.Length -and '"\$'.IndexOf($Text[$k + 1]) -ge 0) {
                $k++
                [void]$out.Append($Text[$k])
            } else {
                [void]$out.Append($c)
            }
        } elseif ((Test-SameString $c "'") -or (Test-SameString $c '"')) {
            $quote = $c
        } elseif (Test-SameString $c '\') {
            if (($k + 1) -lt $Text.Length) {
                $k++
                [void]$out.Append($Text[$k])
            }
        } else {
            [void]$out.Append($c)
        }
    }
    return $out.ToString()
}

# See skip_heredocs in the .sh: skip the bodies of the heredocs a RUN, COPY or
# ADD (also behind ONBUILD) opens, advancing $script:i past each terminator.
function Skip-Heredoc([int]$LineNo, [string]$Logical) {
    if (-not $Logical.Contains('<<')) { return }
    $words = @(Get-ShellWord $Logical)
    if ($words.Count -lt 2) { return }
    if (Test-SameString (ConvertTo-AsciiUpper $words[0]) 'ONBUILD') {
        $words = @($words | Select-Object -Skip 1)
        if ($words.Count -lt 2) { return }
    }
    $keyword = ConvertTo-AsciiUpper $words[0]
    if (-not (Test-SameString $keyword 'RUN') -and -not (Test-SameString $keyword 'COPY') -and -not (Test-SameString $keyword 'ADD')) { return }
    for ($w = 1; $w -lt $words.Count; $w++) {
        $m = $heredocOpener.Match($words[$w])
        if (-not $m.Success) { continue }
        $chomp = $m.Groups[1].Value
        $rest = $m.Groups[2].Value
        $name = ''
        if (-not $rest.Contains('<')) { $name = ConvertFrom-ShellWord $rest }
        if (-not $name) { continue }
        $found = $false
        while (($script:i + 1) -lt $n) {
            $script:i++
            $body = $lines[$script:i]
            if ($chomp) { $body = $body.TrimStart([char]"`t") }
            if (Test-SameString $body $name) { $found = $true; break }
        }
        if (-not $found) {
            Write-DigestError "${SetDir}/Dockerfile:${LineNo}: heredoc $name is never terminated: $Logical"
        }
    }
}

$heredocOpener = [regex]'^[0-9]*<<(-?)[ \t\r]*([^<]*)\z'
$directive = [regex]'^([A-Za-z][A-Za-z0-9]*)[ \t\n\r\v\f]*=[ \t\n\r\v\f]*(.*[^ \t\n\r\v\f])[ \t\n\r\v\f]*\z'

# See the .sh: a Dockerfile that is not valid UTF-8 is refused, so a stray
# byte is never decoded to U+FFFD here while the .sh keeps it raw.
try {
    $content = (New-Object System.Text.UTF8Encoding($false, $true)).GetString([System.IO.File]::ReadAllBytes($dockerfile))
} catch [System.Text.DecoderFallbackException] {
    Write-DigestError "${SetDir}/Dockerfile: not valid UTF-8"
    exit 1
}
# See the .sh: its `read` drops NUL bytes, so a Dockerfile holding one is
# refused in both.
if ($content.Contains([string][char]0)) {
    Write-DigestError "${SetDir}/Dockerfile: contains a NUL byte"
    exit 1
}
if ($content.StartsWith([string][char]0xFEFF, [System.StringComparison]::Ordinal)) { $content = $content.Substring(1) }
$lines = New-Object System.Collections.Generic.List[string]
foreach ($raw in $content.Split([char]"`n")) {
    # BuildKit strips every trailing CR, not only a CRLF's one.
    $lines.Add($raw.TrimEnd([char]"`r"))
}
# A trailing LF leaves one empty element that the .sh's read loop never sees.
if ($content.EndsWith("`n", [System.StringComparison]::Ordinal)) { $lines.RemoveAt($lines.Count - 1) }

$n = $lines.Count

# Parser directives are the leading `# name=value` lines naming a directive
# Docker knows; any other line ends them.
for ($i = 0; $i -lt $n; $i++) {
    $t = $lines[$i].TrimStart($lineSpace)
    if (-not $t.StartsWith('#', [System.StringComparison]::Ordinal)) { break }
    $m = $directive.Match($t.Substring(1).TrimStart($lineSpace))
    if (-not $m.Success) { break }
    if ([Array]::IndexOf(@('syntax', 'escape', 'check'), (ConvertTo-AsciiLower $m.Groups[1].Value)) -lt 0) { break }
    if ((Test-SameString (ConvertTo-AsciiLower $m.Groups[1].Value) 'escape') -and -not (Test-SameString $m.Groups[2].Value '\')) {
        Write-DigestError "${SetDir}/Dockerfile:$($i + 1): only the default \ escape is supported: $($lines[$i])"
    }
}

$i = 0
while ($i -lt $n) {
    $line = $lines[$i]
    $start = $i + 1
    if (Test-BlankOrComment $line) { $i++; continue }
    # BuildKit trims an instruction's first line, not its continuations.
    $logical = $line.TrimStart($lineSpace)
    $cont = $false
    if ($continuation.IsMatch($logical)) {
        $cont = $true
        $logical = Get-StrippedContinuation $logical
    }
    while ($cont -and ($i + 1) -lt $n) {
        $i++
        $next = $lines[$i]
        if (Test-BlankOrComment $next) { continue }
        if ($continuation.IsMatch($next)) {
            $logical = $logical + (Get-StrippedContinuation $next)
        } else {
            $logical = $logical + $next
            $cont = $false
        }
    }
    # BuildKit's splitCommand trims the joined line too, so leading whitespace
    # a continuation brought in does not hide the keyword.
    $logical = $logical.TrimStart($lineSpace)
    Test-Instruction $start $logical
    Skip-Heredoc $start $logical
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
    if ($item.PSIsContainer) {
        if (@(Get-ChildItem -LiteralPath $item.FullName -Force).Count -eq 0) {
            Write-DigestError "${path}: empty directories are not allowed in a layer set (the digest covers files only; create the directory in a RUN instead)"
        }
        continue
    }
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
