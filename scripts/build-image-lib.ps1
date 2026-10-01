# Image-inspection decisions for scripts/build-image.ps1, dot-sourced by it and
# exercised by scripts/test-layer-sets.sh against a fake `docker`. PowerShell twin
# of scripts/build-image-lib.sh, which documents each decision; keep the two in
# lockstep, since an image built by one driver is judged by the other on the next
# build.

$script:PowboxBaseTag = 'powbox-agent-base:latest'
$script:PowboxLayersTag = 'powbox-agent-layers:latest'
$script:PowboxAgentTag = 'powbox-agent:latest'

function Get-ImageLabel {
    param([string]$Image, [string]$Label)
    $v = docker image inspect $Image --format "{{ index .Config.Labels `"$Label`" }}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v -or $v -eq '<no value>') { return "" }
    return ([string]$v).Trim()
}

function Get-ImageId {
    param([string]$Image)
    $id = docker image inspect $Image --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $id) { return "" }
    return ([string]$id).Trim()
}

function Test-ImagePresent {
    param([string]$Image)
    docker image inspect $Image *> $null
    return ($LASTEXITCODE -eq 0)
}

# See parent_signature in build-image-lib.sh: the same inspect line, plus LF,
# hashed to the same bytes. docker prints UTF-8 (an Env value may hold any
# text), and PowerShell decodes a native command's output with the console
# encoding, a legacy code page by default on Windows; decode it as UTF-8 so the
# bytes hashed are the ones docker printed.
function Get-ParentSignature {
    param([string]$Image)
    $consoleEncoding = [Console]::OutputEncoding
    try {
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $null = $_ }
        $raw = docker image inspect $Image --format '{{json .RootFS.Layers}} {{json .Config.Env}} {{json .Config.Shell}} {{json .Config.WorkingDir}} {{json .Config.User}}' 2>$null
        $rc = $LASTEXITCODE
    } finally {
        try { [Console]::OutputEncoding = $consoleEncoding } catch { $null = $_ }
    }
    if ($rc -ne 0 -or -not $raw) { return "" }
    $line = (@($raw) -join "`n") + "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($line))
    } finally {
        $sha.Dispose()
    }
    return 'sha256:' + (-join ($hash | ForEach-Object { $_.ToString('x2') }))
}

function Get-ImageRootFs {
    param([string]$Image)
    $v = docker image inspect $Image --format '{{json .RootFS.Layers}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v) { return "" }
    return ([string]$v).Trim()
}

# See layers_base_mismatch in build-image-lib.sh. Returns "" when the layer-set
# image is built on the base that exists now.
function Get-LayersBaseMismatch {
    $base = $script:PowboxBaseTag
    $tag = $script:PowboxLayersTag
    $baseLayers = Get-ImageRootFs $base
    $layers = Get-ImageRootFs $tag
    if (-not $baseLayers -or -not $layers) {
        return "the filesystem layers of $tag and $base could not be read"
    }
    $open = $baseLayers
    if ($open.EndsWith(']', [System.StringComparison]::Ordinal)) { $open = $open.Substring(0, $open.Length - 1) }
    if ($layers -cne $baseLayers -and -not $layers.StartsWith($open + ',', [System.StringComparison]::Ordinal)) {
        return "$tag is not built on ${base}: its filesystem layers do not start with the base's"
    }
    return ""
}

# See layers_onbuild_triggers in build-image-lib.sh. Returns "" when the
# layer-set image records no ONBUILD triggers.
function Get-LayersOnBuildTrigger {
    $tag = $script:PowboxLayersTag
    $triggers = docker image inspect $tag --format '{{json .Config.OnBuild}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return "the ONBUILD triggers of $tag could not be read" }
    $triggers = (@($triggers) -join "`n").Trim()
    if ([string]::Equals($triggers, 'null', [System.StringComparison]::Ordinal) -or [string]::Equals($triggers, '[]', [System.StringComparison]::Ordinal)) { return "" }
    return "$tag records ONBUILD triggers, which would run in the agent build outside the set's digest: $triggers"
}

# See layers_stale_reason in build-image-lib.sh. Returns "" when the layer-set
# image is current.
function Get-LayersStaleReason {
    param([string]$Set, [string]$Digest)
    $tag = $script:PowboxLayersTag
    if (-not (Test-ImagePresent $tag)) { return "$tag does not exist" }
    $baked = Get-ImageLabel $tag 'powbox.layers.set'
    if ($baked -cne $Set) {
        $shown = if ($baked) { $baked } else { 'none' }
        return "$tag was built from layer set '$shown', not '$Set'"
    }
    $baked = Get-ImageLabel $tag 'powbox.layers.digest'
    if (-not $Digest) { return "the digest of layer set '$Set' could not be computed" }
    if ($baked -cne $Digest) { return "layer set '$Set' changed since $tag was built" }
    $baseId = Get-ImageId $script:PowboxBaseTag
    $baked = Get-ImageLabel $tag 'powbox.layers.base.id'
    if (-not $baseId -or $baked -cne $baseId) { return "$tag was built on a different $($script:PowboxBaseTag)" }
    $mismatch = Get-LayersBaseMismatch
    if ($mismatch) { return $mismatch }
    return (Get-LayersOnBuildTrigger)
}

# See resolve_codex_commit in build-image-lib.sh.
function Resolve-CodexCommit {
    param([string]$HeadCommit, [string]$CodexVersion, [string]$Signature, [bool]$NoCache)
    $tag = $script:PowboxAgentTag
    if ($NoCache -or -not (Test-ImagePresent $tag)) { return $HeadCommit }
    $prevSignature = Get-ImageLabel $tag 'powbox.parent.signature'
    if (-not $Signature -or $Signature -cne $prevSignature) { return $HeadCommit }
    $prevVer = Get-ImageLabel $tag 'powbox.codex.version'
    $prevCommit = Get-ImageLabel $tag 'powbox.commit.codex'
    if ($prevVer -ceq $CodexVersion) {
        if ($prevCommit) { return $prevCommit }
        return 'unknown'
    }
    return $HeadCommit
}
