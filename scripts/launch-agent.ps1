param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("claude", "codex")]
  [string]$Agent,
  [string]$ProjectPath = ".",
  [switch]$Build,
  [switch]$Detach,
  [switch]$Shell,
  [switch]$Persist,
  [switch]$Resume,
  [switch]$Continue,
  [switch]$Volatile,
  [string]$Exec = "",
  [string[]]$Ctx = @(),
  # Self-hosted ("-Isolated") mode: the container clones the repo into a private
  # per-instance volume instead of bind-mounting a host dir. All of these stay
  # inert (and dir-mounted mode stays byte-for-byte unchanged) unless -Isolated.
  [switch]$Isolated,
  [string]$Repo = "",
  [string]$Name = "",
  [string]$Ref = "",
  # -Fresh is a documented alias for -Reclone (README flag table), mirroring the bash
  # launcher's `--reclone | --fresh`. The PS wrapper chain forwards -Reclone by name,
  # so the alias is repeated at every user-facing layer (cc/cx, *-container.ps1, here).
  [Alias("Fresh")]
  [switch]$Reclone
)

$ErrorActionPreference = "Stop"

if ($Exec -ne "" -and $Agent -ne "codex") {
  Write-Error "-Exec is only supported for codex."
  exit 1
}

# Reject the self-hosted-only options when -Isolated was not given, so a typo fails
# loudly instead of silently launching the unchanged dir-mounted mode.
if (-not $Isolated -and ($Repo -ne "" -or $Name -ne "" -or $Ref -ne "" -or $Reclone)) {
  Write-Error "-Repo/-Name/-Ref/-Reclone require -Isolated."
  exit 1
}

# SHA256(input) truncated to 12 lowercase hex chars — the shared hash shape for
# both the dir-mounted path hash and the self-hosted instance hash.
function Get-Powbox-Hash12 ([string]$Value) {
  return [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
      [System.Text.Encoding]::UTF8.GetBytes($Value)
    )
  ).Replace("-", "").Substring(0, 12).ToLowerInvariant()
}

function Get-Powbox-HashHexFromByteArray ([byte[]]$Bytes) {
  return [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
  ).Replace("-", "").ToLowerInvariant()
}

function Write-Powbox-Warning ([string]$Message) {
  Write-Warning $Message
}

function ConvertFrom-Powbox-YamlCommentedLine ([string]$Line) {
  $out = [System.Text.StringBuilder]::new()
  $quote = [char]0
  $prevBlank = $true
  for ($i = 0; $i -lt $Line.Length; $i++) {
    $c = $Line[$i]
    if ($quote -eq [char]0) {
      switch ($c) {
        "'" { $quote = "'"; [void]$out.Append($c); $prevBlank = $false; continue }
        '"' { $quote = '"'; [void]$out.Append($c); $prevBlank = $false; continue }
        "#" {
          if ($prevBlank) { return $out.ToString() }
          [void]$out.Append($c); $prevBlank = $false; continue
        }
        " " { [void]$out.Append($c); $prevBlank = $true; continue }
        "`t" { [void]$out.Append($c); $prevBlank = $true; continue }
        default { [void]$out.Append($c); $prevBlank = $false; continue }
      }
    }
    elseif ($quote -eq "'") {
      [void]$out.Append($c)
      if ($c -eq "'") {
        if (($i + 1) -lt $Line.Length -and $Line[$i + 1] -eq "'") {
          $i++
          [void]$out.Append($Line[$i])
        }
        else { $quote = [char]0 }
      }
    }
    else {
      [void]$out.Append($c)
      if ($c -eq '\') {
        if (($i + 1) -lt $Line.Length) {
          $i++
          [void]$out.Append($Line[$i])
        }
      }
      elseif ($c -eq '"') { $quote = [char]0 }
    }
  }
  return $out.ToString()
}

function ConvertFrom-Powbox-YamlScalar ([string]$Value, [string]$Context) {
  $raw = (ConvertFrom-Powbox-YamlCommentedLine $Value).Trim(" ", "`t", "`r")
  if ($raw -eq "") { return [pscustomobject]@{ Ok = $true; Value = "" } }
  if ($raw[0] -eq "'") {
    $out = [System.Text.StringBuilder]::new()
    for ($i = 1; $i -lt $raw.Length; $i++) {
      $c = $raw[$i]
      if ($c -eq "'") {
        if (($i + 1) -lt $raw.Length -and $raw[$i + 1] -eq "'") {
          [void]$out.Append("'")
          $i++
        }
        elseif ($i -eq ($raw.Length - 1)) {
          return [pscustomobject]@{ Ok = $true; Value = $out.ToString() }
        }
        else {
          Write-Powbox-Warning "$Context has trailing content after a quoted scalar; skipping."
          return [pscustomobject]@{ Ok = $false; Value = "" }
        }
      }
      else { [void]$out.Append($c) }
    }
    Write-Powbox-Warning "$Context has an unterminated single-quoted scalar; skipping."
    return [pscustomobject]@{ Ok = $false; Value = "" }
  }
  if ($raw[0] -eq '"') {
    $out = [System.Text.StringBuilder]::new()
    for ($i = 1; $i -lt $raw.Length; $i++) {
      $c = $raw[$i]
      if ($c -eq '\') {
        $i++
        if ($i -ge $raw.Length) {
          Write-Powbox-Warning "$Context has a dangling escape in a double-quoted scalar; skipping."
          return [pscustomobject]@{ Ok = $false; Value = "" }
        }
        $esc = $raw[$i]
        switch ($esc) {
          '"' { [void]$out.Append('"') }
          '\' { [void]$out.Append('\') }
          '/' { [void]$out.Append('/') }
          'b' { [void]$out.Append("`b") }
          'f' { [void]$out.Append("`f") }
          'n' { [void]$out.Append("`n") }
          'r' { [void]$out.Append("`r") }
          't' { [void]$out.Append("`t") }
          default {
            Write-Powbox-Warning "$Context uses an unsupported YAML escape \$esc; skipping."
            return [pscustomobject]@{ Ok = $false; Value = "" }
          }
        }
      }
      elseif ($c -eq '"') {
        if ($i -eq ($raw.Length - 1)) {
          return [pscustomobject]@{ Ok = $true; Value = $out.ToString() }
        }
        Write-Powbox-Warning "$Context has trailing content after a quoted scalar; skipping."
        return [pscustomobject]@{ Ok = $false; Value = "" }
      }
      else { [void]$out.Append($c) }
    }
    Write-Powbox-Warning "$Context has an unterminated double-quoted scalar; skipping."
    return [pscustomobject]@{ Ok = $false; Value = "" }
  }
  return [pscustomobject]@{ Ok = $true; Value = $raw }
}

function Split-Powbox-YamlKeyValue ([string]$Line) {
  $trimmed = (ConvertFrom-Powbox-YamlCommentedLine $Line).Trim(" ", "`t", "`r")
  if ($trimmed -match '^([A-Za-z_][A-Za-z0-9_.-]*):($|[ \t].*)$') {
    return [pscustomobject]@{ Key = $Matches[1]; Value = $Matches[2] }
  }
  return $null
}

function Test-Powbox-TopSection ([string]$File, [string]$Section) {
  if (-not (Test-Path $File -PathType Leaf)) { return $false }
  foreach ($line in [System.IO.File]::ReadLines($File)) {
    $stripped = (ConvertFrom-Powbox-YamlCommentedLine $line).Trim(" ", "`t", "`r")
    if ($stripped -eq "") { continue }
    if ($line[0] -eq ' ' -or $line[0] -eq "`t") { continue }
    $kv = Split-Powbox-YamlKeyValue $line
    if ($kv -and $kv.Key -eq $Section) { return $true }
  }
  return $false
}

function Test-Powbox-EffectiveCtxConfigPresent ([string]$Workspace) {
  if (Test-Powbox-TopSection (Join-Path $Workspace ".powbox.local.yml") "ctx") { return $true }
  return (Test-Powbox-TopSection (Join-Path $Workspace ".powbox.yml") "ctx")
}

function Test-Powbox-LocalShadowConfigPresent ([string]$Workspace) {
  return (Test-Powbox-TopSection (Join-Path $Workspace ".powbox.local.yml") "shadow")
}

function Complete-Powbox-CtxObject ([ref]$Current, [System.Collections.IList]$Entries) {
  $obj = $Current.Value
  if ($null -eq $obj) { return }
  if ($obj.Bad) { $Current.Value = $null; return }
  if (-not $obj.PathSet -or $obj.Path -eq "") {
    Write-Powbox-Warning "$($obj.Origin) is missing required path; skipping."
    $Current.Value = $null
    return
  }
  [void]$Entries.Add([pscustomobject]@{ Path = $obj.Path; Name = $obj.Name; Mode = $obj.Mode; ShortForm = $false; Origin = $obj.Origin })
  $Current.Value = $null
}

function Read-Powbox-CtxFile ([string]$File) {
  $entries = [System.Collections.Generic.List[object]]::new()
  $present = $false
  if (-not (Test-Path $File -PathType Leaf)) {
    return [pscustomobject]@{ Present = $false; Entries = @() }
  }
  $inCtx = $false
  $current = $null
  $lineNo = 0
  foreach ($lineRaw in [System.IO.File]::ReadLines($File)) {
    $lineNo++
    $line = $lineRaw.TrimEnd("`r")
    $stripped = (ConvertFrom-Powbox-YamlCommentedLine $line).Trim(" ", "`t", "`r")
    if ($stripped -eq "") { continue }
    if ($line[0] -ne ' ' -and $line[0] -ne "`t") {
      if ($inCtx) { Complete-Powbox-CtxObject ([ref]$current) $entries }
      $inCtx = $false
      $kv = Split-Powbox-YamlKeyValue $line
      if (-not $kv) { continue }
      if ($kv.Key -eq "ctx") {
        $present = $true
        $valueTrim = $kv.Value.Trim(" ", "`t", "`r")
        if ($valueTrim -eq "") { $inCtx = $true }
        elseif ($valueTrim -eq "[]") { $inCtx = $false }
        else { Write-Powbox-Warning "${File}:${lineNo}: unsupported inline ctx value; use a block list or ctx: []." }
      }
      continue
    }
    if (-not $inCtx) { continue }
    if ($stripped.StartsWith("-")) {
      Complete-Powbox-CtxObject ([ref]$current) $entries
      $rest = $stripped.Substring(1).Trim(" ", "`t", "`r")
      if ($rest -eq "") {
        $current = @{ Path = ""; Name = ""; Mode = ""; Origin = "${File}:${lineNo}"; PathSet = $false; Bad = $false }
        continue
      }
      $kv = Split-Powbox-YamlKeyValue $rest
      if ($kv -and @("path", "name", "mode").Contains($kv.Key)) {
        $current = @{ Path = ""; Name = ""; Mode = ""; Origin = "${File}:${lineNo}"; PathSet = $false; Bad = $false }
        $parsed = ConvertFrom-Powbox-YamlScalar $kv.Value "${File}:${lineNo}: ctx.$($kv.Key)"
        if ($parsed.Ok) {
          switch ($kv.Key) {
            "path" { $current.Path = $parsed.Value; $current.PathSet = $true }
            "name" { $current.Name = $parsed.Value }
            "mode" { $current.Mode = $parsed.Value }
          }
        }
        else { $current.Bad = $true }
      }
      else {
        $parsed = ConvertFrom-Powbox-YamlScalar $rest "${File}:${lineNo}: ctx entry"
        if ($parsed.Ok) {
          [void]$entries.Add([pscustomobject]@{ Path = $parsed.Value; Name = ""; Mode = ""; ShortForm = $true; Origin = "${File}:${lineNo}" })
        }
      }
      continue
    }
    if ($null -ne $current) {
      $kv = Split-Powbox-YamlKeyValue $stripped
      if (-not $kv) {
        Write-Powbox-Warning "${File}:${lineNo}: unsupported ctx object syntax; skipping entry."
        $current.Bad = $true
        continue
      }
      if ($kv.Key -in @("path", "name", "mode")) {
        $parsed = ConvertFrom-Powbox-YamlScalar $kv.Value "${File}:${lineNo}: ctx.$($kv.Key)"
        if ($parsed.Ok) {
          switch ($kv.Key) {
            "path" { $current.Path = $parsed.Value; $current.PathSet = $true }
            "name" { $current.Name = $parsed.Value }
            "mode" { $current.Mode = $parsed.Value }
          }
        }
        else { $current.Bad = $true }
      }
      else {
        Write-Powbox-Warning "${File}:${lineNo}: unsupported ctx object key '$($kv.Key)'; skipping entry."
        $current.Bad = $true
      }
    }
    else {
      Write-Powbox-Warning "${File}:${lineNo}: ctx property without a list item; skipping."
    }
  }
  if ($inCtx) { Complete-Powbox-CtxObject ([ref]$current) $entries }
  return [pscustomobject]@{ Present = $present; Entries = @($entries) }
}

function Read-Powbox-EffectiveCtxConfig ([string]$Workspace) {
  $base = Read-Powbox-CtxFile (Join-Path $Workspace ".powbox.yml")
  $local = Read-Powbox-CtxFile (Join-Path $Workspace ".powbox.local.yml")
  if ($local.Present) { return $local }
  if ($base.Present) { return $base }
  return [pscustomobject]@{ Present = $false; Entries = @() }
}

function Expand-Powbox-LeadingTilde ([string]$Path) {
  if (($Path -eq "~" -or $Path.StartsWith("~/") -or $Path.StartsWith("~\")) -and $HOME) {
    if ($Path -eq "~") { return $HOME }
    return (Join-Path $HOME $Path.Substring(2))
  }
  return $Path
}

function Test-Powbox-AbsolutePath ([string]$Path) {
  if ($Path -match '^/' -or $Path -match '^[A-Za-z]:[\\/]' -or $Path -match '^\\\\' -or $Path -match '^//') { return $true }
  return $false
}

function Resolve-Powbox-DirectoryPath ([string]$Path) {
  $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
  try {
    $linkTarget = [System.IO.DirectoryInfo]::new($resolved).ResolveLinkTarget($true)
    if ($linkTarget) { $resolved = $linkTarget.FullName }
  }
  catch {
    # ResolveLinkTarget requires .NET 6+ / pwsh 7.1+; keep Resolve-Path's result.
    Write-Debug "ResolveLinkTarget unavailable for ctx path: $($_.Exception.Message)"
  }
  $pathRoot = [System.IO.Path]::GetPathRoot($resolved)
  if ($pathRoot -and $resolved.Length -gt $pathRoot.Length) {
    $resolved = $resolved.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  }
  return $resolved
}

function Resolve-Powbox-ConfigCtxDirectory ([string]$RawPath, [string]$Workspace, [string]$Origin) {
  $path = Expand-Powbox-LeadingTilde $RawPath
  if (-not (Test-Powbox-AbsolutePath $path)) { $path = Join-Path $Workspace $path }
  if (-not (Test-Path -LiteralPath $path -PathType Container)) {
    Write-Powbox-Warning "${Origin}: context path does not exist or is not a directory; skipping: $RawPath"
    return $null
  }
  try { return (Resolve-Powbox-DirectoryPath $path) }
  catch {
    Write-Powbox-Warning "${Origin}: failed to resolve context path; skipping: $RawPath"
    return $null
  }
}

function Resolve-Powbox-CliCtxDirectory ([string]$RawPath) {
  $path = Expand-Powbox-LeadingTilde $RawPath
  if (-not (Test-Path -LiteralPath $path -PathType Container)) {
    Write-Error "Error: context path does not exist: $RawPath"
    exit 1
  }
  try { return (Resolve-Powbox-DirectoryPath $path) }
  catch {
    Write-Error "Error: failed to resolve context path: $RawPath"
    exit 1
  }
}

function Get-Powbox-PathBasename ([string]$Path) {
  return [System.IO.DirectoryInfo]::new($Path).Name
}

function Test-Powbox-CtxName ([string]$Name) {
  if ([string]::IsNullOrEmpty($Name)) { return $false }
  if ($Name -eq "." -or $Name -eq "..") { return $false }
  if ($Name.Contains("/") -or $Name.Contains("\")) { return $false }
  return $true
}

function Add-Powbox-CtxMount ([System.Collections.IList]$Mounts, [string]$Name, [string]$Path, [string]$Mode, [string]$Origin, [bool]$Strict = $false) {
  if (-not (Test-Powbox-CtxName $Name)) {
    if ($Strict) {
      Write-Error "Error: context mount name derived from $Path is not a usable single path segment: $Name"
      exit 1
    }
    Write-Powbox-Warning "${Origin}: context mount name is not a usable single path segment; skipping: $Name"
    return
  }
  foreach ($mount in $Mounts) {
    if ($mount.Name -ceq $Name) {
      if ($Strict) {
        Write-Error "Error: duplicate ctx target name '$Name' across -Ctx values. Add an alias to disambiguate."
        exit 1
      }
      Write-Powbox-Warning "${Origin}: duplicate ctx target name '$Name'; skipping later entry. Add a name: alias to disambiguate."
      return
    }
  }
  [void]$Mounts.Add([pscustomobject]@{ Name = $Name; Path = $Path; Mode = $Mode })
}

function Split-Powbox-CliCtxValue ([string]$Value) {
  if ([string]::IsNullOrEmpty($Value)) {
    Write-Error "Error: -Ctx value has an empty path."
    exit 1
  }
  $path = $Value
  $mode = "ro"
  if ($path.EndsWith(":ro")) {
    $mode = "ro"
    $path = $path.Substring(0, $path.Length - 3)
  }
  elseif ($path.EndsWith(":rw")) {
    $mode = "rw"
    $path = $path.Substring(0, $path.Length - 3)
  }
  if ($path -eq "") {
    Write-Error "Error: -Ctx value has an empty path: $Value"
    exit 1
  }
  $name = ""
  $equalsIndex = $path.IndexOf("=")
  if ($equalsIndex -ge 0) {
    $aliasCandidate = $path.Substring(0, $equalsIndex)
    if (Test-Powbox-CtxName $aliasCandidate) {
      $name = $aliasCandidate
      $path = $path.Substring($equalsIndex + 1)
      if ($path -eq "") {
        Write-Error "Error: -Ctx value has an empty path: $Value"
        exit 1
      }
    }
  }
  return [pscustomobject]@{ Path = $path; Name = $name; Mode = $mode }
}

function Get-Powbox-CtxHash ([object[]]$Mounts) {
  $sorted = @($Mounts)
  [array]::Sort($sorted, [System.Comparison[object]]{ param($a, $b) [StringComparer]::Ordinal.Compare($a.Name, $b.Name) })
  $utf8 = [System.Text.Encoding]::UTF8
  $stream = [System.IO.MemoryStream]::new()
  foreach ($mount in $sorted) {
    foreach ($field in @($mount.Name, $mount.Path, $mount.Mode)) {
      $bytes = $utf8.GetBytes($field)
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.WriteByte(0)
    }
  }
  return (Get-Powbox-HashHexFromByteArray $stream.ToArray())
}

function Resolve-Powbox-CtxMountSet ([string]$Workspace) {
  $mounts = [System.Collections.Generic.List[object]]::new()
  if (@($Ctx).Count -gt 0) {
    foreach ($ctxValue in @($Ctx)) {
      $parsed = Split-Powbox-CliCtxValue $ctxValue
      $resolved = Resolve-Powbox-CliCtxDirectory $parsed.Path
      $name = if ($parsed.Name -ne "") { $parsed.Name } else { Get-Powbox-PathBasename $resolved }
      Add-Powbox-CtxMount -Mounts $mounts -Name $name -Path $resolved -Mode $parsed.Mode -Origin "-Ctx" -Strict $true
    }
    return [pscustomobject]@{ DesiredPresent = $true; Hash = (Get-Powbox-CtxHash @($mounts)); Mounts = @($mounts) }
  }
  if ($Isolated) { return [pscustomobject]@{ DesiredPresent = $false; Hash = ""; Mounts = @() } }
  $config = Read-Powbox-EffectiveCtxConfig $Workspace
  if (-not $config.Present) { return [pscustomobject]@{ DesiredPresent = $false; Hash = ""; Mounts = @() } }
  foreach ($entry in $config.Entries) {
    $rawPath = $entry.Path
    $mode = $entry.Mode
    if ($mode -eq "") {
      if ($entry.ShortForm) {
        if ($rawPath.EndsWith(":ro")) { $mode = "ro"; $rawPath = $rawPath.Substring(0, $rawPath.Length - 3) }
        elseif ($rawPath.EndsWith(":rw")) { $mode = "rw"; $rawPath = $rawPath.Substring(0, $rawPath.Length - 3) }
        else { $mode = "ro" }
      }
      else { $mode = "ro" }
    }
    if ($mode -notin @("ro", "rw")) {
      Write-Powbox-Warning "$($entry.Origin): unsupported ctx mode '$mode'; expected ro or rw; skipping."
      continue
    }
    if ($rawPath -eq "") {
      Write-Powbox-Warning "$($entry.Origin): ctx entry has an empty path; skipping."
      continue
    }
    $resolved = Resolve-Powbox-ConfigCtxDirectory -RawPath $rawPath -Workspace $Workspace -Origin $entry.Origin
    if ($null -eq $resolved) { continue }
    $name = if ($entry.Name -ne "") { $entry.Name } else { Get-Powbox-PathBasename $resolved }
    Add-Powbox-CtxMount -Mounts $mounts -Name $name -Path $resolved -Mode $mode -Origin $entry.Origin
  }
  return [pscustomobject]@{ DesiredPresent = $true; Hash = (Get-Powbox-CtxHash @($mounts)); Mounts = @($mounts) }
}

function ConvertTo-Powbox-YamlDoubleQuoted ([string]$Value) {
  $s = $Value.Replace('$', '$$')
  $out = [System.Text.StringBuilder]::new()
  foreach ($c in $s.ToCharArray()) {
    switch ($c) {
      '\' { [void]$out.Append('\\') }
      '"' { [void]$out.Append('\"') }
      "`n" { [void]$out.Append('\n') }
      "`r" { [void]$out.Append('\r') }
      "`t" { [void]$out.Append('\t') }
      default { [void]$out.Append($c) }
    }
  }
  return '"' + $out.ToString() + '"'
}

function Write-Powbox-CtxComposeOverlay ([string]$File, [object[]]$Mounts) {
  $lines = [System.Collections.Generic.List[string]]::new()
  [void]$lines.Add("services:")
  [void]$lines.Add("  agent:")
  [void]$lines.Add("    volumes:")
  foreach ($mount in $Mounts) {
    $readOnly = if ($mount.Mode -eq "ro") { "true" } else { "false" }
    [void]$lines.Add("      - type: bind")
    [void]$lines.Add("        source: $(ConvertTo-Powbox-YamlDoubleQuoted $mount.Path)")
    [void]$lines.Add("        target: $(ConvertTo-Powbox-YamlDoubleQuoted ("/ctx/" + $mount.Name))")
    [void]$lines.Add("        read_only: $readOnly")
  }
  [System.IO.File]::WriteAllText($File, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Test-Powbox-Command ([string]$CommandName) {
  return $null -ne (Get-Command $CommandName -ErrorAction SilentlyContinue)
}

function Write-Powbox-LocalConfigIgnoreWarning ([string]$Workspace) {
  if (-not (Test-Path (Join-Path $Workspace ".powbox.local.yml") -PathType Leaf)) { return }
  if (-not (Test-Powbox-Command "git")) { return }
  git -C $Workspace rev-parse --is-inside-work-tree *> $null
  if ($LASTEXITCODE -ne 0) { return }
  git -C $Workspace check-ignore -q -- .powbox.local.yml *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Powbox-Warning ".powbox.local.yml exists but is not ignored by git. Add it to .gitignore to keep local-only host paths out of commits."
  }
}

# Canonical "host/owner/repo" key for a repo spec (lowercased, .git stripped, any
# userinfo removed) so different repos sharing a basename get distinct identities,
# while the SAME repo expressed different ways (owner/repo slug, https URL,
# scp-style git@host:path) maps to one stable key. Folded into a NAMED instance's
# discriminator below. Must stay in lockstep with launch-agent.sh's repo_identity
# so the two launchers agree on a named instance's identity.
function Get-Powbox-RepoIdentity ([string]$Spec) {
  $id = $Spec
  if ($id -match '://') {
    $id = $id -replace '^[^:]+://', ''   # drop scheme://
    $id = $id -replace '^[^@/]*@', ''    # drop any userinfo
  }
  elseif ($id -match '^[^/]+@[^/]+:') {
    $id = $id -replace '^[^@]*@', ''        # drop user@
    $id = $id -replace '^([^:]+):', '$1/'   # host:path → host/path (first colon)
  }
  else {
    $id = "github.com/$id"                   # bare owner/repo slug → default host
  }
  # Trim trailing slashes before stripping .git so a URL copied with a trailing
  # separator (https://github.com/owner/app.git/) normalises to the same identity as
  # the bare form; otherwise the .git strip misses and a relaunch with the same -Name
  # spawns a second container. Mirrors launch-agent.sh's repo_identity.
  $id = $id -replace '/+$', ''
  $id = $id -replace '\.git$', ''
  return $id.ToLowerInvariant()
}

# In dir-mounted mode the positional is a host project directory and must exist;
# in self-hosted mode it is re-interpreted as the repo spec (resolved below) and is
# NOT a host path, so the directory checks/resolution are skipped.
if (-not $Isolated -and -not (Test-Path $ProjectPath -PathType Container)) {
  Write-Error "Error: project path does not exist: $ProjectPath"
  exit 1
}

# Per-instance volume names that only exist in one mode. Declared up front so they
# are always defined when referenced in the other mode.
$nodeModulesVolume = ""
$worktreesVolume = ""
$workspaceVolume = ""
# Whether to mount the dir-mounted node_modules volume. Only set true for a
# project that actually looks like one that needs it (see below); a non-dev
# folder mounted for research or file management gets neither volume, so Docker
# never auto-creates empty node_modules/ and .worktrees/ mountpoint dirs in the
# host folder. This flag keeps its historical name and meaning — the JS/powbox
# gate — because PNPM_STORE_DIR and the pnpm wrapper's regression guard key on it.
$mountWorkspaceVolumes = $false
# Whether to mount the dir-mounted worktrees volume (a SUPERSET gate): true
# whenever $mountWorkspaceVolumes is, PLUS for a go.mod-only repo — Go projects
# want the persistent worktrees volume (it now also holds the Go caches, see
# below) but have no use for an isolated node_modules mount, which would only
# litter an empty node_modules/ dir in the host folder.
$mountWorktreesVolume = $false
$repoSpec = ""

if ($Isolated) {
  # --- Self-hosted (isolated) identity ---------------------------------------
  # Resolve the repo to clone. Precedence: explicit -Repo wins; else if the
  # positional is an existing directory, infer it from that dir's `origin` remote
  # (the "standing inside a repo" convenience); else the positional itself is the
  # repo spec (an owner/repo slug or a clone URL).
  if ($Repo -ne "") {
    $repoSpec = $Repo
  }
  elseif (Test-Path $ProjectPath -PathType Container) {
    $repoSpec = (git -C $ProjectPath remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoSpec)) {
      Write-Error "-Isolated needs a repo to clone (owner/repo or a clone URL). None was given and 'git remote get-url origin' found nothing in $ProjectPath. Pass it explicitly, e.g. -Repo owner/repo, or -Repo https://github.com/owner/repo.git"
      exit 1
    }
    $repoSpec = $repoSpec.Trim()
    # Redact any userinfo (token) from the displayed origin URL so an embedded
    # credential is not echoed to the terminal; the real spec is still used below.
    $repoSpecSafe = $repoSpec -replace '(://)[^/]*@', '$1'
    Write-Host "Self-hosted mode: inferred repo from origin in ${ProjectPath}: $repoSpecSafe" -ForegroundColor Yellow
  }
  else {
    $repoSpec = $ProjectPath
  }

  # Reject a clone URL that embeds a credential in its authority (e.g. a PAT URL
  # https://<token>@github.com/owner/repo.git). Self-hosted containers are kept by
  # default, so the spec is frozen into POWBOX_CLONE_REPO in the container env where
  # `docker inspect` would expose the secret. The container authenticates via gh, so an
  # embedded credential is never needed. Only http(s) userinfo is a secret; an ssh://
  # URL's `git@` is a benign SSH user, normalised to HTTPS in the container.
  if ($repoSpec -match '^https?://') {
    $repoAuthority = ($repoSpec -replace '^https?://', '') -replace '/.*$', ''
    if ($repoAuthority -match '@') {
      Write-Error "The clone URL embeds a credential in its authority (userinfo before '@'). Self-hosted containers are kept, so this would persist the secret in the container environment (visible via 'docker inspect'). The container authenticates via gh - drop the credential and pass a plain URL or slug, e.g. -Repo owner/repo."
      exit 1
    }
  }

  # Reject control characters in any value frozen into a container label. cc-list /
  # agent-list parse the labels back with a \x1f field separator and one-container-per-
  # line reads, so a newline or a literal \x1f in -Name/-Repo/-Ref would split a record
  # or shift fields and corrupt the listing (display quoting can't undo a real newline).
  # No legitimate repo spec, ref, or name contains a control char, so fail fast here.
  foreach ($pair in @(@('-Name', $Name), @('-Repo', $repoSpec), @('-Ref', $Ref))) {
    if ($pair[1] -match '[\x00-\x1F\x7F]') {
      Write-Error "$($pair[0]) must not contain control characters (newlines, tabs, etc.)."
      exit 1
    }
  }

  # repo-slug: leaf after the last '/', strip a trailing .git, lowercase + sanitise
  # (the same shape as the dir-mounted project basename handling).
  $repoBasename = ($repoSpec.TrimEnd('/') -split '/')[-1]
  $repoBasename = $repoBasename -replace '\.git$', ''
  $repoSlug = (($repoBasename.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-') -replace '-+', '-').Trim('-')
  if ([string]::IsNullOrEmpty($repoSlug)) {
    Write-Error "Could not derive a repo slug from '$repoSpec'."
    exit 1
  }

  # Instance discriminator: -Name <label> if given (named → deterministic →
  # reusable), else a high-resolution timestamp + pid + random token so two
  # same-second unnamed launches never collide (unnamed → fresh every launch).
  #
  # A NAMED discriminator folds in the canonical repo identity, so the same -Name
  # used for two different repos that share a basename (owner1/app vs owner2/app)
  # resolves to distinct identities instead of one shared app-<hash> — which would
  # otherwise let the second launch attach to (or -Reclone wipe) the first repo's
  # container and workspace. It ALSO folds in the agent, so the same repo+name under
  # both agents (cc vs cx) gets distinct $projectSlug values and therefore distinct
  # /workspace/<slug> paths — the per-instance workspace volume is already keyed per
  # container (agent-ws-<container>), so without this the two agents would share one
  # in-container cwd while holding independent clones, and a delegated peer agent
  # (both config volumes are always mounted) resumes sessions by cwd and would pick up
  # the other clone's history. The unnamed branch already gets a globally-unique
  # timestamp, so it needs no repo/agent discriminator.
  if (-not [string]::IsNullOrEmpty($Name)) {
    $instanceLabel = (Get-Powbox-RepoIdentity $repoSpec) + "|" + $Agent + "|" + $Name
  }
  else {
    $rand = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $instanceLabel = "ts-" + [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfffffff") + "-" + $PID + "-" + $rand
  }
  $instanceHash = Get-Powbox-Hash12 $instanceLabel
  # Cosmetic, human-readable slug from -Name, folded into $projectSlug so the
  # container/workspace name and cc-list show WHICH instance without an inspect. It does
  # NOT own identity: the 12-char hash above (which hashes the RAW -Name) does, so two
  # -Names that slugify alike ("Feature A" and "feature/a" both -> feature-a) stay
  # distinct containers (told apart by the hash and the powbox.instance-name label).
  # Sanitise to the repo-slug shape, cap the length, and drop it if it empties out so a
  # punctuation-only name never weakens the hash-based identity. Empty for unnamed.
  $nameSlug = (($Name.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-') -replace '-+', '-').Trim('-', '.')
  if ($nameSlug.Length -gt 32) { $nameSlug = $nameSlug.Substring(0, 32).TrimEnd('-', '.') }
  $projectSlug = if ($nameSlug) { "$repoSlug-$nameSlug-$instanceHash" } else { "$repoSlug-$instanceHash" }
}
else {
  # --- Dir-mounted identity (unchanged) --------------------------------------
  $resolvedProject = (Resolve-Path $ProjectPath).Path
  # Resolve symlinks/junctions so the same physical directory always gets the same hash,
  # regardless of which path was used to reference it.
  try {
    $linkTarget = [System.IO.DirectoryInfo]::new($resolvedProject).ResolveLinkTarget($true)
    if ($linkTarget) { $resolvedProject = $linkTarget.FullName }
  }
  catch {
    # ResolveLinkTarget requires .NET 6+ / pwsh 7.1+; fall back to Resolve-Path result.
  }
  # Strip trailing directory separator so that "C:\project" and "C:\project\" hash identically.
  # Guard against trimming filesystem root paths (e.g. "C:\" → "C:" or "/" → ""), which would
  # break Split-Path, hashing, and Docker bind-mount paths. Only trim when the path extends
  # beyond its own root (i.e. it is not itself a root path like "C:\" or "/").
  $pathRoot = [System.IO.Path]::GetPathRoot($resolvedProject)
  if ($resolvedProject.Length -gt $pathRoot.Length) {
    $resolvedProject = $resolvedProject.TrimEnd([System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar)
  }
  $projectName = Split-Path $resolvedProject -Leaf
  $projectHash = Get-Powbox-Hash12 $resolvedProject.ToLowerInvariant()

  $safeProject = (($projectName.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-') -replace '-+', '-').Trim('-')
  $projectSlug = "$safeProject-$projectHash"
  # Root node_modules and the worktrees+store volumes are keyed by the OUTER container
  # (agent + project) = "$Agent-$projectSlug" = $containerName (set just below), NOT
  # just the project. This MUST match agent-podman-*'s per-container keying: a project's
  # Claude and Codex containers can run at the same time and mount these volumes at the
  # SAME in-container paths. Two live agents sharing one writable node_modules tree (or
  # one pnpm store) corrupt each other — concurrent installs race, and a build in one
  # reads a tree the other is relinking. Per-container volumes give each agent its own
  # node_modules, virtual store, pnpm store, and worktree disk budget; the cost is lost
  # cross-agent dedup, which correctness for simultaneous agents is worth it. Subpackage
  # node_modules are already per-container (tmpfs shadows).
  $nodeModulesVolume = "agent-nm-$Agent-$projectSlug"
  # Per-container worktrees volume. Holds the git worktrees AND the pnpm store under
  # ONE mount so pnpm hardlinks package files into per-worktree node_modules
  # instead of copying them. ext4, persistent, container-local, and (now) private to
  # this one container — so two agents never overcommit one shared worktree volume.
  $worktreesVolume = "agent-wt-$Agent-$projectSlug"
  # Mount those volumes only when the host folder looks like a project that uses
  # them: a JS/Node project (package.json — covers npm/yarn/pnpm — or
  # pnpm-workspace.yaml), one that has opted into powbox via committed .powbox.yml
  # (e.g. a non-JS repo that still wants persistent worktrees), or one with a
  # local-only shadow: key. A research/file-management folder, including one with
  # only local ctx: mounts, gets no node_modules/.worktrees mounts and no host litter.
  # The entrypoint's shadow loop independently finds nothing to shadow for such a
  # folder, so launcher and entrypoint stay consistent.
  if ((Test-Path (Join-Path $resolvedProject 'package.json') -PathType Leaf) -or
    (Test-Path (Join-Path $resolvedProject 'pnpm-workspace.yaml') -PathType Leaf) -or
    (Test-Path (Join-Path $resolvedProject '.powbox.yml') -PathType Leaf) -or
    (Test-Powbox-LocalShadowConfigPresent $resolvedProject)) {
    $mountWorkspaceVolumes = $true
  }
  # The worktrees volume has a second, WIDER trigger: go.mod. A pure-Go repo gets
  # agent-wt-* (persistent Go caches + worktrees) but NOT agent-nm-* — no empty
  # node_modules/ litter on the host (the empty .worktrees/ mountpoint dir is
  # accepted; it appears for every gated repo). PNPM_STORE_DIR stays keyed to the
  # JS/powbox gate above so the pnpm wrapper's host-litter warning still fires
  # for a stray root `pnpm install` in a go.mod-only repo.
  if ($mountWorkspaceVolumes -or (Test-Path (Join-Path $resolvedProject 'go.mod') -PathType Leaf)) {
    $mountWorktreesVolume = $true
  }
}

$containerName = "$Agent-$projectSlug"
$workspaceMount = "/workspace/$projectSlug"
# pnpm store path under the workspace mount (same mount as .worktrees/<task> in
# both modes — a per-container volume in dir-mounted mode, the one workspace volume
# in self-hosted mode — so per-worktree `pnpm install` hardlinks from the store).
$worktreesStoreDir = "/workspace/$projectSlug/.worktrees/.pnpm-store"
# Go caches beside the pnpm store, under the same persistent mount. Their
# in-container defaults (~/go/pkg/mod, ~/.cache/go-build) sit OUTSIDE every
# volume, so container recreation cold-downloads all modules and rebuilds
# everything; pointing GOMODCACHE/GOCACHE here survives recreation in both modes.
# Deliberately SHARED across a project's worktrees (unlike the golangci-lint
# analysis cache): the module cache is content-addressed with its own locking and
# the build cache is designed for concurrent builds, so sharing is safe and is
# the whole point (warm caches for every worktree).
$worktreesGoModCacheDir = "/workspace/$projectSlug/.worktrees/.gomodcache"
$worktreesGoCacheDir = "/workspace/$projectSlug/.worktrees/.gocache"
# Per-container rootless Podman storage (images + named volumes) so an in-sandbox
# agent's containers and their data persist across restarts. Keyed by the OUTER
# container (agent + project), NOT just the project: a project's Claude and Codex
# containers can run concurrently, and two Podman instances with separate
# runroots/namespaces sharing one graphroot corrupt each other's metadata and
# lifecycle state. A shared image cache is a separate concern (additionalimagestores).
$podmanVolume = "agent-podman-$containerName"
if ($Isolated) {
  # The one per-instance workspace volume that REPLACES the host bind mount plus the
  # dir-mounted agent-nm-*/agent-wt-* shadows: the clone, node_modules, .worktrees,
  # and the pnpm store all live inside it as ordinary subdirs (one mount → pnpm
  # hardlinks everywhere). Keyed by the full container name, like the podman volume.
  $workspaceVolume = "agent-ws-$containerName"
}

# Internal/testing hook: print the resolved identity and exit before touching
# Docker. Lets the self-hosted smoke test assert naming without launching anything.
if ($env:POWBOX_PRINT_IDENTITY -eq "1") {
  if ($Isolated) { Write-Output "mode=isolated" } else { Write-Output "mode=dir-mounted" }
  Write-Output "PROJECT_NAME=$projectSlug"
  Write-Output "CONTAINER_NAME=$containerName"
  Write-Output "WORKSPACE_MOUNT=/workspace/$projectSlug"
  Write-Output "PODMAN_VOLUME=$podmanVolume"
  Write-Output "NM_VOLUME=$nodeModulesVolume"
  Write-Output "WT_VOLUME=$worktreesVolume"
  Write-Output "WS_VOLUME=$workspaceVolume"
  # Lowercase to match the bash launcher's "true"/"false" (PowerShell stringifies a
  # bool as "True"/"False"), keeping the two launchers' identity output identical.
  Write-Output "MOUNT_WORKSPACE_VOLUMES=$($mountWorkspaceVolumes.ToString().ToLowerInvariant())"
  Write-Output "MOUNT_WORKTREES_VOLUME=$($mountWorktreesVolume.ToString().ToLowerInvariant())"
  Write-Output "REPO_SPEC=$repoSpec"
  Write-Output "CLONE_REF=$Ref"
  exit 0
}

$ctxConfigPresent = $false
if (-not $Isolated) {
  Write-Powbox-LocalConfigIgnoreWarning $resolvedProject
  $ctxConfigPresent = Test-Powbox-EffectiveCtxConfigPresent $resolvedProject
}

$ctxDesiredPresent = $false
$ctxHash = ""
$ctxMounts = @()
if (-not $Resume) {
  $ctxResult = Resolve-Powbox-CtxMountSet $resolvedProject
  $ctxDesiredPresent = $ctxResult.DesiredPresent
  $ctxHash = $ctxResult.Hash
  $ctxMounts = @($ctxResult.Mounts)
}

if ($env:POWBOX_PRINT_CTX -eq "1") {
  Write-Output "CTX_CONFIG_PRESENT=$($ctxConfigPresent.ToString().ToLowerInvariant())"
  Write-Output "CTX_DESIRED_PRESENT=$($ctxDesiredPresent.ToString().ToLowerInvariant())"
  Write-Output "CTX_HASH=$ctxHash"
  Write-Output "CTX_MOUNT_COUNT=$($ctxMounts.Count)"
  for ($i = 0; $i -lt $ctxMounts.Count; $i++) {
    Write-Output "CTX_MOUNT_${i}_NAME=$($ctxMounts[$i].Name)"
    Write-Output "CTX_MOUNT_${i}_PATH=$($ctxMounts[$i].Path)"
    Write-Output "CTX_MOUNT_${i}_MODE=$($ctxMounts[$i].Mode)"
  }
  if ($env:POWBOX_CTX_OVERLAY_OUT -and $ctxMounts.Count -gt 0) {
    Write-Powbox-CtxComposeOverlay $env:POWBOX_CTX_OVERLAY_OUT $ctxMounts
    Write-Output "CTX_OVERLAY=$env:POWBOX_CTX_OVERLAY_OUT"
  }
  exit 0
}

$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$composeShared = Join-Path $rootDir "compose.shared.yml"
$composeOverlay = Join-Path $rootDir "compose.agent.yml"
$composeFuse = Join-Path $rootDir "compose.fuse.yml"
$composeNetdev = Join-Path $rootDir "compose.netdev.yml"
$composeSelfHosted = Join-Path $rootDir "compose.selfhosted.yml"
$composeArgs = @("-p", "powbox", "-f", $composeShared, "-f", $composeOverlay)
# Self-hosted overlay: replaces the host workspace BIND mount in compose.shared.yml
# with the per-instance named volume (merged by target path /workspace/<slug>).
# Added after the shared file so its volume entry wins; the fuse/netdev overlays
# appended later only add devices, so ordering with them is irrelevant.
if ($Isolated) {
  $composeArgs += @("-f", $composeSelfHosted)
}

# Ensure named volumes exist (compose won't auto-create external volumes). Both
# config volumes are always created/mounted so the non-primary agent can be
# spun up in-container with its own persistent login and skills.
# agent-podman-imagestore is the single GLOBAL read-only image cache shared by
# every container across all projects (consumed via Podman additionalimagestores).
# It is infra, like the config volumes — created here, never per-container.
$sharedVolumes = @("agent-gh-config", "agent-zsh-history", "claude-config", "codex-config", "agent-podman-imagestore")
foreach ($vol in $sharedVolumes) {
  docker volume inspect $vol *> $null
  if ($LASTEXITCODE -ne 0) {
    docker volume create $vol *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Error "Failed to create required Docker volume '$vol'. Ensure Docker is running and you have permission to access the Docker daemon."
      exit 1
    }
  }
}

# In dir-mounted mode WORKSPACE_PATH is the host bind source. In self-hosted mode
# the workspace mount comes from compose.selfhosted.yml (which overrides the bind by
# target path), so WORKSPACE_PATH is unused — set it to a harmless "." that still
# parses as a valid short-syntax mount source, and export the volume name the
# overlay interpolates into its external `name:`.
if ($Isolated) {
  $env:WORKSPACE_PATH = "."
  $env:POWBOX_WS_VOLUME = $workspaceVolume
}
else {
  $env:WORKSPACE_PATH = $resolvedProject
}
$env:PROJECT_NAME = $projectSlug

$ghHostConfigPath = if ($env:GH_HOST_CONFIG_DIR) { $env:GH_HOST_CONFIG_DIR } else { "$env:APPDATA\GitHub CLI" }
$gitConfigPath = if ($env:GIT_CONFIG_PATH) { $env:GIT_CONFIG_PATH } else { Join-Path $env:USERPROFILE ".gitconfig" }

$containerExists = $false
$containerRunning = $false

docker container inspect $containerName *> $null
if ($LASTEXITCODE -eq 0) {
  $containerExists = $true
  $runningState = docker container inspect --format '{{.State.Running}}' $containerName 2>$null
  $containerRunning = ($LASTEXITCODE -eq 0 -and $runningState.Trim() -eq 'true')
}

if ($Build) {
  & (Join-Path $rootDir "scripts/build-image.ps1") -Target agent
}

if ($Resume) {
  if (-not $containerExists) {
    Write-Error "No persisted container named $containerName was found. Start it once normally, or with -Persist if you want to be explicit."
    exit 1
  }
  if (@($Ctx).Count -gt 0) {
    Write-Host "Note: -Ctx is ignored with -Resume; container will resume with its existing mounts. Omit -Resume to apply ctx changes." -ForegroundColor Yellow
  }
  elseif ($ctxConfigPresent) {
    Write-Host "Note: configured ctx mounts are ignored with -Resume; container will resume with its existing mounts. Omit -Resume to apply ctx changes." -ForegroundColor Yellow
  }
  if ($Continue) {
    Write-Host "Note: -Continue is ignored with -Resume; container will restart with the CMD it was originally created with. Omit -Resume to apply a continue-flag change." -ForegroundColor Yellow
  }
  if ($Reclone) {
    Write-Host "Note: -Reclone is ignored with -Resume; the existing checkout is left untouched. Omit -Resume to wipe and re-clone." -ForegroundColor Yellow
  }
  if ($Ref -ne "") {
    Write-Host "Note: -Ref is ignored on resume; the existing checkout is left untouched." -ForegroundColor Yellow
  }

  # A running container (e.g. launched -Detach, or its terminal was lost) can't be
  # `docker start`ed - that errors - so reattach instead. Mirrors the reuse path
  # below; cci/cxi reach this with -Resume against a named instance that may well
  # still be running.
  if ($containerRunning) {
    if ($Detach) {
      Write-Host "Container $containerName is already running."
      exit 0
    }
    docker attach $containerName
    exit $LASTEXITCODE
  }

  if ($Detach) {
    docker start $containerName
    exit $LASTEXITCODE
  }

  docker start -ai $containerName
  exit $LASTEXITCODE
}

# Self-hosted -Reclone: wipe and re-seed an existing named container's clone. A
# reused container is started in place (reuse block below) and never re-runs the
# prep/create flow, so -Reclone removes the stopped container to force that flow;
# the prep step then empties the (kept) agent-ws-* volume and the entrypoint clones
# fresh. The wipe is one-shot - nothing about it is frozen into the container.
if ($Isolated -and $Reclone -and -not $Volatile -and $containerExists) {
  if ($containerRunning) {
    Write-Error "Container $containerName is running; stop it before -Reclone (it re-clones on recreate)."
    exit 1
  }
  Write-Host "-Reclone: recreating $containerName so it re-seeds its workspace from a fresh clone."
  docker rm $containerName *> $null
  if ($LASTEXITCODE -ne 0) {
    docker container inspect $containerName *> $null
    if ($LASTEXITCODE -eq 0) {
      Write-Error "Failed to remove existing container $containerName for -Reclone."
      exit 1
    }
  }
  $containerExists = $false
}

# -Ref only takes effect when seed-workspace actually CLONES, and it clones only when the
# per-instance workspace volume holds no checkout: a brand-new instance, or a -Reclone
# (whose prep empties the volume). Whenever that volume is already populated, seed-workspace
# keeps the existing checkout and -Ref is silently ignored - so warn. Gate on the VOLUME,
# not $containerExists: that also covers a container pruned while its agent-ws-* volume
# survived (e.g. agent-prune-stopped), and stays correct when a later block recreates the
# container (the kept volume is reused). The volume is created by the prep step below, so on
# a genuine first launch it does not exist yet here and no warning fires. Benign by design -
# attended launches can switch refs in-container.
if ($Isolated -and $Ref -ne "" -and -not $Reclone) {
  docker volume inspect $workspaceVolume *> $null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Note: -Ref '$Ref' applies only to a fresh clone; $containerName keeps the existing checkout in its workspace volume. Use -Reclone to re-clone at this ref, or switch branches inside the container." -ForegroundColor Yellow
  }
}

if (-not $Volatile -and $containerExists) {
  # Context mounts are frozen at container creation. When this launch has an
  # explicit desired set (CLI -Ctx, ctx: in config, or explicit ctx: []), compare
  # the canonical mount-set hash label and recreate stopped mismatches. When there
  # is no desired set, keep whatever ctx mounts the container already has.
  if ($ctxDesiredPresent) {
    $existingCtxHash = (docker inspect --format '{{with .Config.Labels}}{{with (index . "powbox.ctx-hash")}}{{.}}{{end}}{{end}}' $containerName 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($existingCtxHash)) { $existingCtxHash = "" }
    else { $existingCtxHash = $existingCtxHash.Trim() }
    if ($existingCtxHash -ne $ctxHash) {
      if ($containerRunning) {
        Write-Error "Container $containerName is running with a different ctx mount set. Stop the container first, then relaunch with the new ctx configuration."
        exit 1
      }
      if ($existingCtxHash -eq "") {
        Write-Host "Context mount set changed (existing container has no powbox.ctx-hash label, now '$ctxHash'); recreating container."
      }
      else {
        Write-Host "Context mount set changed (was '$existingCtxHash', now '$ctxHash'); recreating container."
      }
      docker rm $containerName *> $null
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting a ctx mount-set change."
          exit 1
        }
      }
      $containerExists = $false
    }
  }
  else {
    $existingCtxDestinations = (docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' $containerName 2>$null)
    if ($LASTEXITCODE -ne 0) { $existingCtxDestinations = "" }
    $ctxDestinations = @($existingCtxDestinations -split "`r?`n" | Where-Object { $_ -eq "/ctx" -or $_.StartsWith("/ctx/") })
    if ($ctxDestinations.Count -gt 0) {
      Write-Host "Note: container has ctx mounts from a previous session ($($ctxDestinations -join ', ')). Use -Volatile to start fresh or -Ctx/config ctx to change them."
    }
  }
}

# Resolve which host devices rootless Podman will receive this launch into a
# normalised set string ("fuse,tun" / "fuse" / "tun" / "none"). The device list is
# frozen at container creation — `docker start` can't add /dev/fuse or /dev/net/tun
# to an existing container — so this is recorded as a label and a change recreates a
# stopped container (mirrors ctx mount-set and -Continue handling). 'auto' resolves against
# the launcher host's /dev here (on a Windows host shell /dev/* is absent, so auto ->
# none; force with POWBOX_PODMAN=on for the Docker Desktop VM); 'on' forces both
# devices, 'off' neither. The compose-file selection below derives from the same
# value, so the label and the actual attach never disagree.
$podmanRequest = if ($env:POWBOX_PODMAN) { $env:POWBOX_PODMAN } elseif ($env:POWBOX_FUSE) { $env:POWBOX_FUSE } else { "auto" }
$podmanDevices = switch ($podmanRequest) {
  "on" { "fuse,tun" }
  "off" { "none" }
  default {
    $devs = @()
    if (Test-Path "/dev/fuse") { $devs += "fuse" }
    if (Test-Path "/dev/net/tun") { $devs += "tun" }
    if ($devs.Count -gt 0) { ($devs -join ",") } else { "none" }
  }
}

# Detect whether the -Continue flag state differs from what the container was created with.
# The CMD is frozen at container creation, so a flag change only takes effect after recreation.
# Missing label on an existing container predates this flag — treat it as "true" so the old
# auto-resume default remains in effect for reused containers until the user explicitly opts out,
# at which point this branch recycles the container to honour the new intent.
if (-not $Volatile -and $containerExists) {
  $existingContinue = (docker inspect --format '{{with .Config.Labels}}{{with (index . "powbox.continue")}}{{.}}{{end}}{{end}}' $containerName 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($existingContinue)) {
    $existingContinue = "true"
  }
  $existingContinue = $existingContinue.Trim()
  $wantContinue = if ($Continue) { "true" } else { "false" }
  if ($existingContinue -ne $wantContinue) {
    if ($containerRunning) {
      Write-Host "Note: container $containerName is running; -Continue=$wantContinue is ignored because the existing process was started with -Continue=$existingContinue. Attaching to the running process. Stop it and relaunch to apply the flag change." -ForegroundColor Yellow
    }
    else {
      Write-Host "Continue flag changed (was '$existingContinue', now '$wantContinue'); recreating container."
      docker rm $containerName *> $null
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting a -Continue flag change."
          exit 1
        }
      }
      $containerExists = $false
    }
  }
}

# Detect whether the existing container's node_modules + .worktrees mounts still match
# what THIS launch wants, and recreate a stopped container when they do NOT. The expected
# mount at each destination depends on the (split) host-litter gate:
#   * JS/powbox project ($mountWorkspaceVolumes=$true)  -> BOTH per-agent volumes
#     agent-{nm,wt}-<container>;
#   * go.mod-only repo ($mountWorktreesVolume=$true only) -> ONLY agent-wt-<container>
#     (Go caches + worktrees), NO node_modules mount;
#   * non-dev folder (both gates false)                    -> NO mount at all.
# This covers three upgrade/mismatch paths:
  #   * predates the .worktrees volume entirely (no .worktrees mount) — it still
#     has a tmpfs .worktrees shadow and points pnpm at the old shared store, so worktree
#     installs never hardlink even after the image is rebuilt;
#   * predates the per-agent volume RENAME — it mounts the old project-keyed
#     agent-{nm,wt}-<project> instead of agent-{nm,wt}-<container>. A bare `docker start`
#     keeps the stale source, so a project's Claude and Codex would still share one
#     writable node_modules / pnpm store and race — exactly what per-agent keying prevents;
#     and
#   * predates the host-litter gate (or the SPLIT gate), OR the folder changed shape — it
#     still mounts node_modules/.worktrees in a non-dev folder (or node_modules in a
#     go.mod-only repo), so a bare `docker start` keeps re-creating empty mountpoint dirs
#     in the host folder and the gate never takes effect for the upgraded container.
#     Recreating without those mounts stops the litter.
# Mere presence of a .worktrees mount can't distinguish these, so we compare the actual
# mounted volume NAME at each destination to the expected name (empty = expect no mount).
# Warn (don't disrupt) if it is currently running. Self-hosted mode is skipped ($Isolated):
# its node_modules/.worktrees are subdirs INSIDE the one workspace volume, not separate
# mounts, so there is nothing to compare — and a steady-state non-dev reuse (no mounts
# present, none expected) compares equal and is correctly left alone.
if (-not $Isolated -and -not $Volatile -and $containerExists) {
  $expectedNmMount = ""
  $expectedWtMount = ""
  if ($mountWorkspaceVolumes) {
    $expectedNmMount = $nodeModulesVolume
  }
  if ($mountWorktreesVolume) {
    $expectedWtMount = $worktreesVolume
  }
  $wtMountName = (docker inspect --format "{{range .Mounts}}{{if eq .Destination `"$workspaceMount/.worktrees`"}}{{.Name}}{{end}}{{end}}" $containerName 2>$null)
  if ($LASTEXITCODE -ne 0) { $wtMountName = "" }
  $wtMountName = "$wtMountName".Trim()
  $nmMountName = (docker inspect --format "{{range .Mounts}}{{if eq .Destination `"$workspaceMount/node_modules`"}}{{.Name}}{{end}}{{end}}" $containerName 2>$null)
  if ($LASTEXITCODE -ne 0) { $nmMountName = "" }
  $nmMountName = "$nmMountName".Trim()
  if ($wtMountName -ne $expectedWtMount -or $nmMountName -ne $expectedNmMount) {
    $recreateStaleMounts = $false
    if ($mountWorkspaceVolumes) {
      if ($containerRunning) {
        Write-Host "Note: container $containerName uses outdated workspace volumes (node_modules/.worktrees not keyed per-agent, or missing); it may share a writable node_modules/pnpm store with another agent and worktree installs won't hardlink. Stop it and relaunch (or use -Volatile) to migrate to the per-agent volumes." -ForegroundColor Yellow
      }
      else {
        Write-Host "Container $containerName uses outdated workspace volumes (not keyed per-agent); recreating it so node_modules/.worktrees use agent-{nm,wt}-$containerName and worktree installs hardlink from the co-located pnpm store."
        $recreateStaleMounts = $true
      }
    }
    elseif ($mountWorktreesVolume) {
      if ($containerRunning) {
        Write-Host "Note: container $containerName does not match this go.mod-only repo's expected mounts (only .worktrees = agent-wt-$containerName, no node_modules volume); Go caches/worktrees won't persist correctly or an empty node_modules/ keeps appearing in the host folder. Stop it and relaunch (or use -Volatile) to fix the mounts." -ForegroundColor Yellow
      }
      else {
        Write-Host "Container $containerName does not match this go.mod-only repo's expected mounts; recreating it with only the .worktrees volume (agent-wt-$containerName — persistent Go caches + worktrees) and no node_modules mount."
        $recreateStaleMounts = $true
      }
    }
    else {
      if ($containerRunning) {
        Write-Host "Note: container $containerName still mounts node_modules/.worktrees, but this folder isn't a dev project — those mounts keep re-creating empty node_modules/.worktrees dirs in the host folder. Stop it and relaunch (or use -Volatile) to drop the mounts and leave no host litter." -ForegroundColor Yellow
      }
      else {
        Write-Host "Container $containerName mounts node_modules/.worktrees but this folder isn't a dev project; recreating it without those mounts so it leaves no host litter."
        $recreateStaleMounts = $true
      }
    }
    if ($recreateStaleMounts) {
      docker rm $containerName *> $null
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting outdated workspace volume mounts."
          exit 1
        }
      }
      $containerExists = $false
    }
  }
}

# Detect whether the existing container predates the per-container Podman storage
# volume. Such a container was created before rootless-Podman support, so its
# /home/node/.local/share/containers is ephemeral (no agent-podman-* mount) and
# it was launched without /dev/fuse — pulled images and podman volumes would not
# persist, even after the image is rebuilt. Recreate a stopped container that
# lacks the mount so the new volume + device attach; warn (don't disrupt) if it
# is currently running.
if (-not $Volatile -and $containerExists) {
  $hasPodmanMount = (docker inspect --format "{{range .Mounts}}{{if eq .Destination `"/home/node/.local/share/containers`"}}yes{{end}}{{end}}" $containerName 2>$null)
  if ($LASTEXITCODE -ne 0) { $hasPodmanMount = "" }
  if ([string]::IsNullOrWhiteSpace($hasPodmanMount)) {
    if ($containerRunning) {
      Write-Host "Note: container $containerName predates the per-container Podman storage volume; nested-container images and volumes won't persist and the podman devices (/dev/fuse, /dev/net/tun) aren't attached. Stop it and relaunch (or use -Volatile) to enable persistent rootless Podman storage." -ForegroundColor Yellow
    }
    else {
      Write-Host "Container $containerName predates the per-container Podman storage volume; recreating it so rootless Podman images and volumes persist."
      docker rm $containerName *> $null
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting a missing Podman storage volume mount."
          exit 1
        }
      }
      $containerExists = $false
    }
  }
}

# Detect whether the existing container was created with a different rootless-Podman
# device set than this launch resolves (POWBOX_PODMAN changed, or the host's /dev
# visibility changed under `auto`). The device list is frozen at creation, so a
# stopped container first created with POWBOX_PODMAN=off — or under `auto` on a host
# that couldn't see the devices — can't gain /dev/fuse or /dev/net/tun on `docker
# start`: nested Podman would stay on vfs with no default networking. Recreate a
# stopped mismatch so the new device set attaches; warn (don't disrupt) a running
# one. A container with no recorded label predates this check — leave it alone, since
# we can't know what it was created with and the storage-mount check above already
# recreates truly pre-Podman containers.
if (-not $Volatile -and $containerExists) {
  $existingPodmanDevices = (docker inspect --format '{{with .Config.Labels}}{{with (index . "powbox.podman-devices")}}{{.}}{{end}}{{end}}' $containerName 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($existingPodmanDevices)) {
    $existingPodmanDevices = ""
  }
  else {
    $existingPodmanDevices = $existingPodmanDevices.Trim()
  }
  if ($existingPodmanDevices -ne "" -and $existingPodmanDevices -ne $podmanDevices) {
    if ($containerRunning) {
      Write-Host "Note: container $containerName is running with Podman devices '$existingPodmanDevices'; this launch resolves to '$podmanDevices'. The device set is fixed at container creation — stop it and relaunch (or use -Volatile) to apply the change." -ForegroundColor Yellow
    }
    else {
      Write-Host "Podman device set changed (was '$existingPodmanDevices', now '$podmanDevices'); recreating container."
      docker rm $containerName *> $null
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting a Podman device set change."
          exit 1
        }
      }
      $containerExists = $false
    }
  }
}

if (-not $Volatile -and $containerExists) {
  if ($containerRunning) {
    if ($Detach) {
      Write-Host "Container $containerName is already running."
      exit 0
    }

    docker attach $containerName
    exit $LASTEXITCODE
  }

  if ($Detach) {
    docker start $containerName
    exit $LASTEXITCODE
  }

  docker start -ai $containerName
  exit $LASTEXITCODE
}

# Self-hosted capability guard (Task 001a, Approach B). The clone-into-volume path
# for -Isolated lives entirely in the BASE image layer (seed-workspace.sh plus
# entrypoint-core.sh's clone call), so an agent image whose base predates
# self-hosted mode would create the workspace volume but never clone into it -
# landing the agent in an EMPTY checkout with no loud failure. The base stamps a
# static powbox.base.selfhosted=1 label (inherited by the agent image); if the
# resolved image lacks it, fail fast here with an actionable message instead. Only
# reached on the create/recreate path (the resume/reuse branches above already
# exited), i.e. exactly when a clone would run. Skipped when the image is absent -
# that is a missing-image problem the build/compose flow handles, not a stale base.
# A pre-label image also lacks it and is correctly rejected: it cannot self-host.
if ($Isolated) {
  docker image inspect powbox-agent:latest *> $null
  if ($LASTEXITCODE -eq 0) {
    $selfhostedCap = docker image inspect powbox-agent:latest --format '{{ index .Config.Labels "powbox.base.selfhosted" }}' 2>$null
    if (-not $selfhostedCap -or $selfhostedCap.Trim() -eq '' -or $selfhostedCap.Trim() -eq '<no value>') {
      Write-Error ("This agent image's base predates self-hosted mode, so -Isolated would create the workspace " +
        "volume but start you in an EMPTY checkout (the clone step lives in the base layer). Rebuild the base + " +
        "agent, then relaunch: agent-full-rebuild  (or: build.ps1 all; build.sh all on Linux/macOS).")
      exit 1
    }
  }
}

if ($Shell) {
  $command = @("zsh")
  if ($Continue) {
    Write-Host "Note: -Continue has no effect with -Shell; this launch opens a plain zsh." -ForegroundColor Yellow
  }
}
elseif ($Agent -eq "codex" -and $Exec -ne "") {
  $command = @("codex", "exec", $Exec)
  if ($Continue) {
    Write-Host "Note: -Continue has no effect with -Exec; codex exec always starts a fresh non-interactive session." -ForegroundColor Yellow
  }
}
elseif ($Agent -eq "claude") {
  if ($Continue) {
    # Pre-flight check: only pass --continue if a session history exists for this
    # working directory. Claude stores sessions in ~/.claude/projects/<slug>/,
    # where <slug> is the cwd with every non-alphanumeric, non-dash character
    # replaced by '-' (verified empirically against '/', '.', '_', spaces, '+',
    # and uppercase; case is preserved and adjacent dashes are not collapsed).
    # Passing --continue when no session exists makes claude print "No
    # conversation found" and exit instead of falling back to a fresh session.
    # The check runs inside the container where claude-config is mounted.
    $continueCheck = 'slug=$(printf %s "$PWD" | sed "s/[^a-zA-Z0-9-]/-/g"); if ls "$HOME/.claude/projects/$slug"/*.jsonl >/dev/null 2>&1; then exec claude --dangerously-skip-permissions --continue; else exec claude --dangerously-skip-permissions; fi'
    $command = @("sh", "-c", $continueCheck)
  }
  else {
    $command = @("claude", "--dangerously-skip-permissions")
  }
}
else {
  if ($Continue) {
    # Codex resume --last already filters to the current cwd and falls through to
    # a fresh interactive session when nothing resumable exists there.
    $command = @("codex", "resume", "--last", "--dangerously-bypass-approvals-and-sandbox")
  }
  else {
    $command = @("codex", "--dangerously-bypass-approvals-and-sandbox")
  }
}

$gitConfigArgs = @()
if (Test-Path $gitConfigPath) {
  $gitConfigArgs = @("-v", "${gitConfigPath}:/home/node/.gitconfig-host:ro")
}

$ghConfigArgs = @()
if (Test-Path $ghHostConfigPath) {
  $ghConfigArgs = @("-v", "${ghHostConfigPath}:/home/node/.config/gh-host:ro")
}

# Pre-create and chown the per-instance volumes to node so the entrypoint (which
# runs as node) can write into them. Self-hosted mode has ONE workspace volume (it
# must be node-owned before the entrypoint clones into it) and no nm/wt shadows;
# dir-mounted mode has the separate node_modules + worktrees shadows.
if ($Isolated) {
  # The per-instance workspace volume is declared external in compose.selfhosted.yml,
  # and compose validates external volumes (erroring if absent) BEFORE it would honour
  # the ad-hoc -v "${workspaceVolume}:/mnt/workspace" below - so on a first launch the
  # prep run would die with "External volume does not exist" and never create the
  # container (making even the loud-clone-failure drop-to-zsh path unreachable).
  # Pre-create the volume here so the prep step can chown it to node and clone into it.
  # The dir-mounted nm/wt/podman volumes need no such step because nothing declares them
  # external (the ad-hoc -v auto-creates them). Idempotent via the inspect guard, like
  # the shared volumes above.
  docker volume inspect $workspaceVolume *> $null
  if ($LASTEXITCODE -ne 0) {
    docker volume create $workspaceVolume *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Error "Failed to create the self-hosted workspace volume '$workspaceVolume'. Ensure Docker is running and you have permission to access the Docker daemon."
      exit 1
    }
  }
  # Seed the workspace volume so the entrypoint (running as node) can clone into
  # it: chown it to node AND, WHEN IT WOULD OTHERWISE BE EMPTY, leave it NON-EMPTY
  # (a single placeholder file). Docker re-initialises an EMPTY named volume from
  # the image on every mount; because the workspace mounts at the nested
  # /workspace/<slug> (a path absent from the image), that re-init recreates the
  # volume root as root:root on the real run, clobbering this chown and leaving node
  # unable to write the clone. A NON-empty volume is left untouched, so the
  # placeholder makes the chown stick. seed-workspace.sh empties the dir again just
  # before cloning. Only write it when the volume is empty: a REUSED instance
  # (recreated for a non-reclone reason — a ctx or Podman-device change, or the
  # stopped container pruned while its agent-ws-* volume remains) already holds a
  # .git checkout (non-empty, so the chown sticks without help) that
  # seed-workspace.sh's reuse path does NOT clean — writing the placeholder there
  # would leave a stray untracked .powbox-ws-init in the agent's working tree.
  # -Reclone is a one-shot, launcher-driven wipe: empty the workspace volume here
  # (the container was recreated above) so the entrypoint re-clones into a clean
  # dir. The volume itself is kept. Nothing persists the wipe, so a later restart
  # of a named instance never re-wipes the agent's work.
  $wsPrepCmd = 'mkdir -p /mnt/workspace /mnt/containers /mnt/podman-imagestore && chown node:node /mnt/workspace /mnt/containers /mnt/podman-imagestore && { [ -n "$(ls -A /mnt/workspace 2>/dev/null)" ] || : > /mnt/workspace/.powbox-ws-init; }'
  if ($Reclone) {
    $wsPrepCmd = "find /mnt/workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; " + $wsPrepCmd
  }
  docker compose @composeArgs run --rm --no-deps --user root --entrypoint /bin/sh `
    -v "${workspaceVolume}:/mnt/workspace" `
    -v "${podmanVolume}:/mnt/containers" `
    -v "agent-podman-imagestore:/mnt/podman-imagestore" `
    agent `
    -lc $wsPrepCmd
}
else {
  # Always pre-create the per-container Podman store + the global image store; add
  # the node_modules/worktrees volumes only when this project uses them (see the
  # split $mountWorkspaceVolumes / $mountWorktreesVolume gates — a go.mod-only
  # repo gets just the worktrees volume) so a non-dev folder leaves no host litter.
  $prepVolArgs = @(
    "-v", "${podmanVolume}:/mnt/containers",
    "-v", "agent-podman-imagestore:/mnt/podman-imagestore"
  )
  $prepPaths = "/mnt/containers /mnt/podman-imagestore"
  if ($mountWorkspaceVolumes) {
    $prepVolArgs += @("-v", "${nodeModulesVolume}:/mnt/node_modules")
    $prepPaths = "/mnt/node_modules $prepPaths"
  }
  if ($mountWorktreesVolume) {
    $prepVolArgs += @("-v", "${worktreesVolume}:/mnt/worktrees")
    $prepPaths = "/mnt/worktrees $prepPaths"
  }
  docker compose @composeArgs run --rm --no-deps --user root --entrypoint /bin/sh `
    @prepVolArgs `
    agent `
    -lc "mkdir -p $prepPaths && chown node:node $prepPaths"
}

if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

$runArgs = @()
if ($Detach) {
  $runArgs += "-d"
}
elseif ($Volatile -and -not $Persist) {
  $runArgs += "--rm"
}

# Pass the host devices rootless Podman needs through to the agent, each in its
# own compose overlay (`docker compose run` has no --device flag, only `docker
# run` does, so a device must be declared in a compose file added to the -f chain):
#   compose.fuse.yml   -> /dev/fuse    (fuse-overlayfs overlay storage driver;
#                                       absence just falls back to the vfs driver)
#   compose.netdev.yml -> /dev/net/tun (slirp4netns/pasta nested networking;
#                                       absence breaks every default `podman run`)
# POWBOX_PODMAN gates both (POWBOX_FUSE is the deprecated alias):
#   on   -> force both. Use on Docker Desktop / WSL2, where the devices live in the
#          Docker VM and the launcher's host shell cannot see them to auto-detect;
#          if the Docker host cannot expose a forced device the run hard-fails.
#   off  -> neither (Podman still runs: vfs storage, networking only via
#          --network=host/none).
#   auto -> attach each device independently when the host shell can see it. On a
#          Windows host shell /dev/* does not exist, so `auto` resolves to off
#          there; force with POWBOX_PODMAN=on when the Docker Desktop VM has them.
#          The two are detected separately so a host exposing /dev/net/tun but not
#          /dev/fuse still gets networking on vfs.
if (-not $env:POWBOX_PODMAN -and $env:POWBOX_FUSE) {
  Write-Host "Note: POWBOX_FUSE is deprecated; use POWBOX_PODMAN (it now gates both /dev/fuse and /dev/net/tun)." -ForegroundColor Yellow
}
# Attach each compose overlay from the already-resolved $podmanDevices set so the
# devices actually passed match the powbox.podman-devices label recorded below.
switch -Wildcard (",$podmanDevices,") {
  "*,fuse,*" { $composeArgs += @("-f", $composeFuse) }
}
switch -Wildcard (",$podmanDevices,") {
  "*,tun,*" { $composeArgs += @("-f", $composeNetdev) }
}

$continueLabel = if ($Continue) { "true" } else { "false" }

# Seed the GLOBAL shared image store from a dedicated, short-lived, DETACHED
# writer — the ONLY container that mounts agent-podman-imagestore read-write. The
# agent container below mounts the same volume read-only, so a runaway process in
# one project can't poison the cache every other project resolves images from.
# Detached so the launch never blocks on pulls; idempotent and quick once
# populated (seed-image-store.sh skips images already present, and its flock
# serializes concurrent writers). Only meaningful on the overlay path — an
# additionalimagestores entry must match the consumer's driver, and consumers
# only enable overlay when /dev/fuse is present — so gate it on the resolved fuse
# device. Best-effort: a writer that can't start must never abort the agent launch.
if (",$podmanDevices," -like "*,fuse,*") {
  try {
    # Go straight to entrypoint-core.sh (firewall + XDG + the writer-role Podman
    # setup) instead of the default entrypoint-agent.sh, so the writer skips the
    # per-agent skill/config seeding and stays lean — it only needs egress and a
    # Podman that can pull. AGENT_CONFIG_DIR is required by core but unused here, so
    # point it at a throwaway path; AGENT_SETUP_HOOK is cleared so no agent hook runs.
    docker compose @composeArgs run --rm -d --no-deps `
      --entrypoint /usr/local/bin/entrypoint-core.sh `
      -e POWBOX_IMAGE_STORE_ROLE=writer `
      -e AGENT_CONFIG_DIR=/tmp/powbox-imgstore-writer `
      -e AGENT_SETUP_HOOK= `
      -v "agent-podman-imagestore:/mnt/podman-imagestore" `
      agent `
      seed-image-store.sh seed *> $null
  }
  catch {
    # Best-effort cache seeding must never abort the agent launch.
  }
  $global:LASTEXITCODE = 0
}

# PRIMARY_AGENT selects which agent the unified image runs and seeds as primary.
# Both API keys flow through via compose.agent.yml so a delegated peer agent can
# authenticate too.
$envArgs = @("--name", $containerName, "--label", "powbox.continue=$continueLabel", "--label", "powbox.podman-devices=$podmanDevices", "-e", "CONTAINER_NAME=$containerName", "-e", "PRIMARY_AGENT=$Agent")
if ($ctxDesiredPresent) {
  $envArgs += @("--label", "powbox.ctx-hash=$ctxHash")
}
# Point pnpm at the co-located store only when this project actually mounts the
# worktrees volume the store lives in (dir-mounted JS/powbox project) or in
# self-hosted mode (store is a subdir of the one workspace volume). Omitting it for a
# non-dev dir-mounted folder stops the entrypoint from mkdir-ing .worktrees/.pnpm-store
# onto the host bind mount - pnpm just keeps its image-default store there instead.
if ($Isolated -or $mountWorkspaceVolumes) {
  $envArgs += @("-e", "PNPM_STORE_DIR=$worktreesStoreDir")
}
# Point the Go module + build caches into the same persistent mount — keyed on the
# WIDER worktrees gate (or self-hosted mode, where .worktrees is a subdir of the
# one workspace volume), NOT the JS gate above: a go.mod-only repo mounts only the
# worktrees volume. Omitting them for a non-dev dir-mounted folder stops the
# entrypoint from mkdir-ing cache dirs onto the host bind mount — go just keeps
# its image-default (container-ephemeral) cache paths there instead. Plain env is
# all `go` needs (no `go env -w`), matching the PNPM_STORE_DIR precedent; the
# entrypoint pre-creates the dirs (guarded, warn-don't-abort).
if ($Isolated -or $mountWorktreesVolume) {
  $envArgs += @(
    "-e", "GOMODCACHE=$worktreesGoModCacheDir",
    "-e", "GOCACHE=$worktreesGoCacheDir"
  )
}

# Dir-mounted mode only: tell the entrypoint the workspace's HOST bind-mount source (and
# the launching user's home) so the workspace-perms heal can REFUSE to chown a mount that
# is actually a system or home directory. A cc/cx accidentally run from ~ would otherwise
# bind-mount the whole home tree and re-own it to node, breaking sshd's StrictModes chain
# on ~/.ssh and locking the user out of the host. POWBOX_WORKSPACE_DIR pairs the container
# mountpoint (/workspace/<slug>) with that source so the entrypoint records the per-mount
# marker map (/run/powbox/workspace-sources) both heal- and fix-workspace-perms.sh classify
# on (mountinfo is only their fallback). (On Windows/WSL/macOS the heal never fires - those
# FUSE mounts honour node's writes - so this is belt-and-suspenders there; it matters on a
# native-Linux host.) Self-hosted mode has no bind mount, so it is skipped.
if (-not $Isolated) {
  # Resolve $HOME the same way $resolvedProject was (Resolve-Path + ResolveLinkTarget),
  # so a home reached through a symlink/junction is compared against the entrypoint's
  # physical mountinfo source on equal footing rather than as a mismatched logical path.
  # Fall back to the raw value if it cannot be resolved (unset/missing/no access).
  $resolvedHome = $HOME
  if ($resolvedHome) {
    try {
      $resolvedHome = (Resolve-Path $resolvedHome -ErrorAction Stop).Path
      $homeLink = [System.IO.DirectoryInfo]::new($resolvedHome).ResolveLinkTarget($true)
      if ($homeLink) { $resolvedHome = $homeLink.FullName }
    }
    catch {
      # Resolve-Path failed or ResolveLinkTarget needs .NET 6+ / pwsh 7.1+; keep what we have.
      $resolvedHome = $HOME
    }
  }
  $envArgs += @(
    "-e", "POWBOX_WORKSPACE_HOST_PATH=$resolvedProject",
    "-e", "POWBOX_WORKSPACE_HOST_HOME=$resolvedHome",
    "-e", "POWBOX_WORKSPACE_DIR=$workspaceMount"
  )
}

# Self-hosted clone inputs + label, plus the volume mounts. The entrypoint (after gh
# auth) clones POWBOX_CLONE_REPO at POWBOX_CLONE_REF into POWBOX_WORKSPACE_DIR, and
# skips the clone when a .git already exists (reuse). These are frozen at creation;
# -Reclone is NOT one of them on purpose - it is a one-shot launcher action (the prep
# step empties the volume so the entrypoint clones fresh), so a reused container
# never re-wipes the agent's work on a later restart. In dir-mounted mode the root
# node_modules and .worktrees are separate per-container named volumes mounted over the
# bind mount — but only for a project that uses them (the split $mountWorkspaceVolumes /
# $mountWorktreesVolume gates: a JS/powbox project gets both, a go.mod-only repo gets
# just .worktrees); a non-dev folder gets neither. In self-hosted mode they are ordinary
# subdirs of the one workspace volume (mounted via compose.selfhosted.yml), so no extra
# -v args are added here.
$workspaceVolArgs = @()
if ($Isolated) {
  $envArgs += @(
    "-e", "POWBOX_SELF_HOSTED=1",
    "-e", "POWBOX_CLONE_REPO=$repoSpec",
    "-e", "POWBOX_CLONE_REF=$Ref",
    "-e", "POWBOX_WORKSPACE_DIR=$workspaceMount"
  )
  # Label self-hosted containers so tooling/lists can distinguish them from dir-mounted
  # ones (they already share the claude-/codex- name prefix). instance-name stores -Name
  # verbatim (pre-slugify) so cc-list/agent-list tell apart two names that slugify alike;
  # repo + ref give the list enough to reconstruct the resume command. ref records what
  # was REQUESTED at creation and is not re-applied on resume (see the -Ref warning).
  $envArgs += @(
    "--label", "powbox.self-hosted=true",
    "--label", "powbox.instance-name=$Name",
    "--label", "powbox.repo=$repoSpec",
    "--label", "powbox.ref=$Ref"
  )
}
else {
  # Only for a project that uses them; a non-dev folder gets neither, so Docker never
  # creates empty node_modules/.worktrees mountpoints in the host folder.
  if ($mountWorkspaceVolumes) {
    $workspaceVolArgs += @("-v", "${nodeModulesVolume}:${workspaceMount}/node_modules")
  }
  if ($mountWorktreesVolume) {
    $workspaceVolArgs += @("-v", "${worktreesVolume}:${workspaceMount}/.worktrees")
  }
}

$ctxComposeFile = ""
$finalComposeArgs = @($composeArgs)
try {
  if ($ctxMounts.Count -gt 0) {
    $ctxComposeFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "powbox-compose-ctx-$([guid]::NewGuid().ToString('N')).yml")
    Write-Powbox-CtxComposeOverlay $ctxComposeFile $ctxMounts
    $finalComposeArgs += @("-f", $ctxComposeFile)
  }

  docker compose @finalComposeArgs run @runArgs `
    @envArgs `
    @gitConfigArgs `
    @ghConfigArgs `
    @workspaceVolArgs `
    -v "${podmanVolume}:/home/node/.local/share/containers" `
    -v "agent-podman-imagestore:/mnt/podman-imagestore:ro" `
    -w $workspaceMount `
    agent `
    @command
  $finalExitCode = $LASTEXITCODE
}
finally {
  if ($ctxComposeFile -ne "" -and (Test-Path $ctxComposeFile)) {
    Remove-Item -LiteralPath $ctxComposeFile -Force
  }
}
exit $finalExitCode
