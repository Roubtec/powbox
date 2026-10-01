param(
  [ValidateSet("base", "layers", "agent", "all")]
  [string]$Target = "all",
  [string]$ClaudeVersion = "latest",
  [string]$CodexVersion = "latest",
  [switch]$NoCache,
  [switch]$Pull
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $rootDir
try {
  . (Join-Path $rootDir "scripts/build-image-lib.ps1")

  # Upstream base image, parsed from the base Dockerfile's FROM so it never
  # drifts from what is actually built. $script:BaseSourceDigest is resolved
  # lazily just before the base target is built and stamped onto the image as a
  # label (see docker/base/Dockerfile) so agent-check-updates can detect a
  # newer base.
  $baseFrom = Select-String -Path (Join-Path $rootDir "docker/base/Dockerfile") -Pattern '^FROM\s+(\S+)' | Select-Object -First 1
  $script:BaseSourceImage = if ($baseFrom) { $baseFrom.Matches[0].Groups[1].Value } else { "node:24-trixie-slim" }
  $script:BaseSourceDigest = ""

  # Powbox commit that built this image, baked into the agent's top layers and
  # the skill ownership marker for provenance. A `-dirty` suffix flags an
  # uncommitted worktree; falls back to "unknown" outside a git checkout.
  function Get-PowboxCommit {
    $sha = git -C $rootDir rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $sha) { return "unknown" }
    $sha = $sha.Trim()
    $dirty = git -C $rootDir status --porcelain 2>$null
    if ($LASTEXITCODE -eq 0 -and $dirty) { $sha = "$sha-dirty" }
    return $sha
  }
  $script:PowboxCommit = Get-PowboxCommit

  # Digest over the base layer's powbox SOURCE inputs (the base Dockerfile plus
  # the files it COPYs; see scripts/base-source-digest.ps1). Stamped as
  # powbox.base.recipe.digest on the base image so check-updates.ps1 can flag a
  # stale base when powbox's own base recipe changes - the powbox-source analogue
  # of the existing upstream node:24-trixie-slim digest trigger. Only consumed by
  # the base target. Empty on the rare failure (no crypto/manifest); an empty
  # label just means check-updates cannot detect recipe staleness, never a false
  # rebuild.
  $script:PowboxBaseRecipeDigest = ""
  try {
    $script:PowboxBaseRecipeDigest = (& (Join-Path $rootDir "scripts/base-source-digest.ps1") 2>$null).Trim()
  } catch {
    $script:PowboxBaseRecipeDigest = ""
  }

  # The layer set named by .powbox-layers (empty: none, the lean image), its
  # directory, which is the layers bake's whole build context, and its digest.
  # Resolved for every target that builds above the base, before any fetch or
  # build, so an invalid selector or a set that breaks the layer Dockerfile
  # contract stops the run before it changes anything.
  $script:LayersSet = ""
  $script:LayersDir = ""
  $script:LayersDigest = ""
  if ($Target -ne "base") {
    $selected = & (Join-Path $rootDir "scripts/layers-select.ps1")
    if ($LASTEXITCODE -ne 0) { exit 1 }
    if ($selected) { $script:LayersSet = ([string]$selected).Trim() }
    if ($script:LayersSet) {
      $script:LayersDir = "docker/layers/$($script:LayersSet)"
      $digest = & (Join-Path $rootDir "scripts/layers-digest.ps1") $script:LayersDir
      if ($LASTEXITCODE -ne 0) { exit 1 }
      $script:LayersDigest = ([string]$digest).Trim()
    }
  }
  if ($Target -eq "layers" -and -not $script:LayersSet) {
    [Console]::Error.WriteLine("No layer set is selected, so there is nothing for the layers target to build.")
    [Console]::Error.WriteLine("Name one in .powbox-layers (see .powbox-layers.example).")
    exit 1
  }

  # --- agent-skills fetch (host-side, credentials never enter the image) ------
  # The Codex skill palette baked into the agent image comes ENTIRELY from
  # Roubtec/agent-skills (task 015b moved the shared skills there; the forfeit
  # moved the last powbox-specific ones too). Fetch that repo HERE, on the
  # host - never with a `RUN git clone` inside the Dockerfile. The repo is
  # PUBLIC (it started out private and was flipped in task 015e), so the clone
  # below needs no credentials at all; the container-side plugin channel relies
  # on that same public visibility to clone the marketplace anonymously.
  # Fetching host-side into a gitignored staging dir under the build context,
  # which the Dockerfile COPYs, is still what we want: the fetch runs on every
  # AGENT build (never the base-only target - see the dispatch below) and
  # records the resulting HEAD SHA as AgentSkillsCommit (stamped on the image),
  # so a moved agent-skills tip is always picked up and provenanced instead of
  # being hidden behind a cached `RUN git clone` layer - and no GitHub token
  # can ever land in a layer/cache should the repo be re-privatized.
  $script:AgentSkillsRepoUrl = "https://github.com/Roubtec/agent-skills.git"
  $script:AgentSkillsRef = "main"
  $script:AgentSkillsStaging = Join-Path $rootDir ".agent-skills-src"
  $script:AgentSkillsCommit = "unknown"

  function Fetch-AgentSkills {
    # Shallow-clone (or refresh an existing shallow clone of) agent-skills main
    # into the staging dir, then record its HEAD SHA. FAILS LOUDLY: any fetch
    # error aborts the build rather than baking a stale/empty seed dir.
    $err = @"
agent-skills fetch failed; cannot build the Codex skill palette.
Ensure this host can reach $($script:AgentSkillsRepoUrl) ($($script:AgentSkillsRef)).
The repo is public, so the clone is anonymous and needs no GitHub auth - check
the network/proxy first (auth would only matter if the repo were re-privatized).
No image was built.
"@
    Write-Host "Fetching Roubtec/agent-skills ($($script:AgentSkillsRef)) for the Codex skill bake..."
    $gitDir = Join-Path $script:AgentSkillsStaging ".git"
    $originUrl = ""
    if (Test-Path $gitDir) {
      $originUrl = (git -C $script:AgentSkillsStaging config --get remote.origin.url 2>$null)
      if ($originUrl) { $originUrl = $originUrl.Trim() }
    }
    if ((Test-Path $gitDir) -and ($originUrl -eq $script:AgentSkillsRepoUrl)) {
      # reset --hard only rewinds TRACKED files; a stray dir left in the
      # gitignored staging checkout would survive into codex/dev-skills/skills/
      # and bake as a phantom skill, so hard-clean untracked/ignored paths too.
      git -C $script:AgentSkillsStaging fetch --depth 1 origin $script:AgentSkillsRef *> $null
      if ($LASTEXITCODE -eq 0) { git -C $script:AgentSkillsStaging reset --hard FETCH_HEAD *> $null }
      if ($LASTEXITCODE -eq 0) { git -C $script:AgentSkillsStaging clean -ffdx *> $null }
      if ($LASTEXITCODE -ne 0) { Write-Error $err; exit 1 }
    } else {
      if (Test-Path $script:AgentSkillsStaging) { Remove-Item -Recurse -Force $script:AgentSkillsStaging }
      git clone --depth 1 --branch $script:AgentSkillsRef $script:AgentSkillsRepoUrl $script:AgentSkillsStaging *> $null
      if ($LASTEXITCODE -ne 0) { Write-Error $err; exit 1 }
    }
    $sha = git -C $script:AgentSkillsStaging rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $sha) { Write-Error $err; exit 1 }
    $script:AgentSkillsCommit = $sha.Trim()
    # The Dockerfile COPYs exactly this path; fail here rather than bake empty.
    $skillsDir = Join-Path $script:AgentSkillsStaging "codex/dev-skills/skills"
    if (-not (Test-Path $skillsDir)) {
      Write-Error "agent-skills at $($script:AgentSkillsCommit) is missing codex/dev-skills/skills/; refusing to build an empty Codex skill bake."
      exit 1
    }
    # ...and it must hold at least one skill sub-directory. An existing but EMPTY
    # tree would pass Test-Path yet bake nothing (the Dockerfile RUN loops the
    # child dirs), so fail loudly here too.
    if (-not (Get-ChildItem -Path $skillsDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)) {
      Write-Error "agent-skills at $($script:AgentSkillsCommit) has an empty codex/dev-skills/skills/; refusing to build an empty Codex skill bake."
      exit 1
    }
    # The agent image also bakes these helpers straight from this clone (their
    # single source of truth - powbox keeps no in-tree copy). The Dockerfile COPYs
    # exactly these paths; a missing file would otherwise fail the build with a
    # cryptic BuildKit cache-key error, so check each here loudly and name it.
    # Presence only, deliberately: Windows carries no exec bit, so the Bash
    # driver's extra -x check has no counterpart here.
    foreach ($helperName in @('gh-review-threads', 'dc-enter', 'dc-remove')) {
      $helper = Join-Path $script:AgentSkillsStaging "plugins/dev-skills/bin/$helperName"
      if (-not (Test-Path $helper -PathType Leaf)) {
        Write-Error "agent-skills at $($script:AgentSkillsCommit) is missing plugins/dev-skills/bin/$helperName; refusing to build without the baked helper."
        exit 1
      }
    }
    Write-Host "agent-skills at $($script:AgentSkillsCommit)"
  }

  # Values the bake steps below fill in for the agent and layers targets.
  # BaseImage is the agent's parent: the base, or the layer-set image when a set
  # is selected.
  $script:BaseImage = $script:PowboxBaseTag
  $script:PowboxCommitCodex = $script:PowboxCommit
  $script:PowboxCommitBase = "unknown"
  $script:PowboxParentSignature = ""
  $script:PowboxLayersBaseId = ""

  function Get-RegistryBaseDigest {
    $digest = docker buildx imagetools inspect $script:BaseSourceImage --format '{{.Manifest.Digest}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $digest) { return "" }
    return $digest.Trim()
  }

  function Get-LocalBaseDigest {
    $repoDigests = docker image inspect $script:BaseSourceImage --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $repoDigests) { return "" }
    foreach ($line in $repoDigests) {
      if ($line -match '@(sha256:[0-9a-f]{64})') { return $Matches[1] }
    }
    return ""
  }

  function Resolve-BaseSourceDigest {
    param([bool]$WithPull)
    # -Pull refreshes the upstream tag in the LOCAL IMAGE STORE via `docker pull`.
    # buildx's own --pull only updates BuildKit's separate build cache, leaving
    # the `docker images` entry stale; pulling into the store means this bake
    # builds FROM the refreshed image AND the next no-pull rebuild reuses it, so
    # the stamped digest always matches what we actually built from. Read it back
    # from the store afterwards, falling back to the registry digest only when the
    # base is absent locally (e.g. the pull failed offline); buildx pulls it at
    # bake time.
    if ($WithPull) { docker pull $script:BaseSourceImage *> $null }
    $script:BaseSourceDigest = Get-LocalBaseDigest
    if (-not $script:BaseSourceDigest) {
      $script:BaseSourceDigest = Get-RegistryBaseDigest
    }
  }

  function Invoke-Bake {
    param(
      [Parameter(Mandatory = $true)]
      [string[]]$Targets,
      [switch]$WithPull,
      [switch]$WithNoCache
    )

    if ($Targets -contains "base") {
      Resolve-BaseSourceDigest -WithPull:$WithPull.IsPresent
    }

    $docker_args = @("buildx", "bake", "--file", (Join-Path $rootDir "docker-bake.hcl"))

    # No --pull here: Resolve-BaseSourceDigest already pulled the upstream base
    # into the local image store when -Pull was requested, and this bake builds
    # FROM that store image. A bake --pull would re-resolve from the registry
    # into BuildKit's cache instead, re-introducing the store/cache split.
    if ($WithNoCache) {
      $docker_args += "--no-cache"
    }

    $docker_args += $Targets

    $bakeEnv = [ordered]@{
      BASE_IMAGE                = $script:BaseImage
      CLAUDE_CODE_VERSION       = $ClaudeVersion
      CODEX_VERSION             = $CodexVersion
      BASE_SOURCE_IMAGE         = $script:BaseSourceImage
      BASE_SOURCE_DIGEST        = $script:BaseSourceDigest
      POWBOX_BASE_RECIPE_DIGEST = $script:PowboxBaseRecipeDigest
      POWBOX_COMMIT             = $script:PowboxCommit
      POWBOX_COMMIT_CODEX       = $script:PowboxCommitCodex
      POWBOX_COMMIT_BASE        = $script:PowboxCommitBase
      POWBOX_PARENT_SIGNATURE   = $script:PowboxParentSignature
      AGENT_SKILLS_COMMIT       = $script:AgentSkillsCommit
    }
    if ($script:LayersSet) {
      $bakeEnv["POWBOX_LAYERS_DIR"] = $script:LayersDir
      $bakeEnv["POWBOX_LAYERS_SET"] = $script:LayersSet
      $bakeEnv["POWBOX_LAYERS_DIGEST"] = $script:LayersDigest
      $bakeEnv["POWBOX_LAYERS_BASE_ID"] = $script:PowboxLayersBaseId
    }
    $shown = @($bakeEnv.Keys | ForEach-Object { "$_=$($bakeEnv[$_])" }) -join ' '
    Write-Host "Running: $shown docker $($docker_args -join ' ')"
    foreach ($name in $bakeEnv.Keys) {
      Set-Item -Path "Env:$name" -Value ([string]$bakeEnv[$name])
    }
    docker @docker_args
    if ($LASTEXITCODE -ne 0) {
      exit $LASTEXITCODE
    }
  }

  function Assert-BaseImage {
    if (Test-ImagePresent $script:PowboxBaseTag) {
      return
    }

    # Build the base image without -NoCache. That flag applies to the top-layer
    # agent build only (i.e. "don't reuse cached agent layers"). When the base
    # image is simply absent locally there is nothing to skip caching for, and
    # rebuilding it fresh unconditionally on every no-cache top-layer build
    # would be unnecessarily slow. Use `build.ps1 base -NoCache` if you
    # explicitly want a fresh base.
    Write-Host "Base image $($script:PowboxBaseTag) was not found locally. Building it first."
    Invoke-Bake -Targets @("base")
  }

  # The base step of the layers and agent targets: refresh the base under
  # -Pull, otherwise build it only when it is missing.
  function Initialize-BaseImage {
    if ($Pull) {
      Invoke-Bake -Targets @("base") -WithPull
    } else {
      Assert-BaseImage
    }
  }

  # Records the base this bake builds FROM, read now, after the run's base
  # step, for the next run's currency test.
  function Invoke-LayersBake {
    param([switch]$WithNoCache)
    $script:PowboxLayersBaseId = Get-ImageId $script:PowboxBaseTag
    Invoke-Bake -Targets @("layers") -WithNoCache:$WithNoCache
    # The bake labels the image with that base whatever the set built on, so
    # check its layers, and that it records no ONBUILD trigger, before anything
    # is built on it.
    $mismatch = Get-LayersBaseMismatch
    if ($mismatch) {
      [Console]::Error.WriteLine("error: $mismatch.")
      [Console]::Error.WriteLine("The final stage of $($script:LayersDir)/Dockerfile must be built FROM `${BASE_IMAGE}.")
      exit 1
    }
    $mismatch = Get-LayersOnBuildTrigger
    if ($mismatch) {
      [Console]::Error.WriteLine("error: $mismatch.")
      [Console]::Error.WriteLine("Remove every ONBUILD from $($script:LayersDir)/Dockerfile.")
      exit 1
    }
  }

  # Bake the layer-set image only when it is not current for the selected set
  # (see Get-LayersStaleReason). Always from cache, like Assert-BaseImage: the
  # agent target's -NoCache is about the agent's own layers.
  function Assert-LayersImage {
    $reason = Get-LayersStaleReason -Set $script:LayersSet -Digest $script:LayersDigest
    if (-not $reason) {
      Write-Host "Layer-set image $($script:PowboxLayersTag) is current for set '$($script:LayersSet)'; reusing it."
      return
    }
    Write-Host "Baking $($script:PowboxLayersTag): $reason."
    Invoke-LayersBake
  }

  # Everything read off the parent here describes the image the agent is
  # actually built FROM, so it runs after the base and layer-set steps.
  function Invoke-AgentBake {
    param([switch]$WithNoCache)
    $script:BaseImage = if ($script:LayersSet) { $script:PowboxLayersTag } else { $script:PowboxBaseTag }
    $script:PowboxParentSignature = Get-ParentSignature $script:BaseImage
    $script:PowboxCommitCodex = Resolve-CodexCommit -HeadCommit $script:PowboxCommit -CodexVersion $CodexVersion -Signature $script:PowboxParentSignature -NoCache:$WithNoCache.IsPresent
    # The base commit file is written by the agent's top metadata layer from the
    # label its parent carries (a layer-set image inherits it from the base), so
    # the file and the label the agent inherits always agree.
    $script:PowboxCommitBase = Get-ImageLabel $script:BaseImage "powbox.commit.base"
    if (-not $script:PowboxCommitBase) { $script:PowboxCommitBase = "unknown" }
    Invoke-Bake -Targets @("agent") -WithNoCache:$WithNoCache
  }

  # -Pull only makes sense for the base image (whose FROM is an upstream
  # registry image); it re-pulls that upstream tag into the local image store
  # (see Resolve-BaseSourceDigest). The layer-set and agent images build FROM
  # local images, not registry ones, so -Pull on those targets refreshes the
  # base first; the layer-set image is then not current (its recorded base ID
  # no longer matches) and is baked again on the new base, and the agent
  # follows it. Without a selected set the agent sits directly on the
  # refreshed base.
  # The agent image bakes its whole Codex skill palette from the fetched
  # agent-skills clone, so fetch it before any agent bake. Done
  # here (not for the base-only target) so `build.ps1 base` never needs network
  # access to agent-skills, and so the fetch fails the build BEFORE the base
  # build when it is going to fail at all.
  switch ($Target) {
    "all" {
      Fetch-AgentSkills
      Invoke-Bake -Targets @("base") -WithPull:$Pull -WithNoCache:$NoCache
      if ($script:LayersSet) { Invoke-LayersBake -WithNoCache:$NoCache }
      Invoke-AgentBake -WithNoCache:$NoCache
    }
    "agent" {
      Fetch-AgentSkills
      Initialize-BaseImage
      if ($script:LayersSet) { Assert-LayersImage }
      Invoke-AgentBake -WithNoCache:$NoCache
    }
    "layers" {
      Initialize-BaseImage
      Invoke-LayersBake -WithNoCache:$NoCache
    }
    "base" {
      Invoke-Bake -Targets @("base") -WithPull:$Pull -WithNoCache:$NoCache
    }
  }
}
finally {
  Pop-Location
}
