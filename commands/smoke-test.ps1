param(
  [string]$Image = "powbox-agent:latest",
  [switch]$SkipDb,
  [switch]$SkipPodman,
  [switch]$SkipSelfHosted,
  [switch]$SkipDirMount,
  [switch]$RequireImage
)

# The agent image is unified: both claude and codex (and codex's bwrap sandbox)
# are baked into the same image alongside the shared toolchain, so one smoke
# test validates everything in a single pass.
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

# The image-gated checks in stages 1-3 (and Stage 4's clone behavior) need the
# agent image; Stage 4's self-hosted identity contract runs without it. Detect
# the image once up front so a missing one is reported clearly here rather than as
# a raw docker error at Stage 1. -RequireImage (or POWBOX_SMOKE_REQUIRE_IMAGE=1,
# used by CI) turns an absent image into a hard error before any stage runs; the
# env var is also set so a sub-script invoked directly (e.g. the self-hosted clone
# stage) fails instead of self-skipping its image-gated checks into a false "all
# green". $skipped collects every stage we skip so the end-of-run banner can
# report that the run was partial.
# -RequireImage writes the *process* environment ($env:), which in an interactive
# session persists after this script returns (unlike the bash wrapper, whose
# exported var dies with the child process). Save the prior value and restore it in
# the finally below so later direct calls to the smoke sub-scripts in the same
# session behave as before instead of inheriting a sticky REQUIRE_IMAGE=1.
$prevRequireImage = $env:POWBOX_SMOKE_REQUIRE_IMAGE
if ($RequireImage) { $env:POWBOX_SMOKE_REQUIRE_IMAGE = '1' }
try {
$skipped = [System.Collections.Generic.List[string]]::new()
docker image inspect $Image *> $null
$imagePresent = ($LASTEXITCODE -eq 0)
if (-not $imagePresent) {
  if ($env:POWBOX_SMOKE_REQUIRE_IMAGE) {
    throw "image '$Image' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set - refusing to run a partial (image-skipping) smoke test. Build it first (./build.ps1 agent) or drop -RequireImage."
  }
  Write-Warning "image '$Image' not found - the image-gated stages need it. Stage 1 will fail and abort the run before any later stage (Stages 2-5) runs, so you get no partial coverage. Build it (./build.ps1 agent), or pass -RequireImage to fail fast here with a clear message instead of a raw docker error at Stage 1."
}

# Stage 0 - sensitive-host-path predicate unit test. The Bash smoke (commands/smoke-test.sh)
# runs this hermetically on the host; on Windows there is no native bash, so run the SAME
# Bash test INSIDE the agent image - which ships bash and the base-image mawk the mountinfo
# parser is verified against - with the repo mounted read-only. This mirrors the Bash Stage
# 0's coverage of the predicate and the /proc/self/mountinfo source lookup that stop the
# workspace-perms heal from recursively chowning a mount whose host source is a system/home
# dir (the VPS-lockout incident - an accidental cc/cx from ~ re-owning the home tree and
# breaking sshd StrictModes on ~/.ssh). Unlike the Bash version it needs the image (no host
# bash on Windows), so it self-skips - recorded in $skipped - when the image is absent; the
# live end-to-end guard is Stage 5.
if (-not $imagePresent) {
  Write-Warning "Skipping sensitive-host-path predicate unit test (Stage 0) - image '$Image' not found (no native bash on Windows to run it hermetically)."
  $skipped.Add("Stage 0: sensitive-host-path predicate unit test (image absent)")
}
else {
  Write-Host "Running sensitive-host-path predicate unit test (in $Image) ..."
  docker run --rm -v "${rootDir}:/repo:ro" --entrypoint /bin/bash $Image /repo/scripts/test-sensitive-host-path.sh
  if ($LASTEXITCODE -ne 0) {
    throw "sensitive-host-path predicate unit test failed. See container output above."
  }
}

# Stage 1 - tool presence + key image config: every expected CLI resolves and
# runs, and pnpm ships package-import-method=auto (not the old forced copy) so
# worktree installs can hardlink from a co-located store. The GOBIN probe
# plants a stub tool in ~/go/bin and runs it by bare name: these commands run
# under a login shell (`sh -lc`), which resets PATH from /etc/profile, so the
# probe passing proves the baked profile.d snippet restores $HOME/go/bin -
# the documented "`go install` and it's runnable" contract.
& (Join-Path $rootDir "scripts/smoke-test-image.ps1") `
  -Image $Image `
  -Commands @(
    'claude --version >/dev/null'
    'codex --version >/dev/null'
    'bwrap --version >/dev/null'
    'gh --version >/dev/null'
    'node --version >/dev/null'
    'npm --version >/dev/null'
    'pnpm --version >/dev/null'
    'pnpm config get package-import-method | grep -qx auto'
    'pip3 --version >/dev/null'
    'python3 --version >/dev/null'
    'sqlcmd -? >/dev/null'
    'sqlite3 --version >/dev/null'
    'psql --version >/dev/null'
    'pg-dev-up check >/dev/null'
    'command -v wt-bootstrap >/dev/null'
    'command -v wt-enter >/dev/null'
    'command -v wt-remove >/dev/null'
    'shellcheck --version >/dev/null'
    'ping -V >/dev/null'
    'nc -h >/dev/null 2>&1'
    'bc --version >/dev/null'
    'less --version >/dev/null'
    'lsof -v >/dev/null 2>&1'
    'tree --version >/dev/null'
    'fd --version >/dev/null'
    'fzf --version >/dev/null'
    'bat --version >/dev/null'
    'ssh -V >/dev/null 2>&1'
    'rsync --version >/dev/null'
    'strace -V >/dev/null'
    'gpg --version >/dev/null'
    'gcc --version >/dev/null'
    'go version >/dev/null'
    'command -v gofmt >/dev/null'
    'golangci-lint version >/dev/null'
    'mkdir -p "$HOME/go/bin" && printf "%s\n" "#!/bin/sh" "echo gobin-ok" > "$HOME/go/bin/powbox-gobin-probe" && chmod +x "$HOME/go/bin/powbox-gobin-probe" && powbox-gobin-probe | grep -qx gobin-ok'
    'file --version >/dev/null'
    'printf test | xxd >/dev/null'
    'envsubst --version >/dev/null'
    'yq --version >/dev/null'
    'shfmt --version >/dev/null'
    'unzip -v >/dev/null'
    'zip -v >/dev/null'
    'wget --version >/dev/null'
    'htop --version >/dev/null'
  )

# Stage 2 - pg-dev-up functional test: stand up a real throwaway cluster and
# connect through the emitted DATABASE_URL. Unlike `pg-dev-up check` (binary
# presence only) this exercises role/db creation, URL percent-encoding, the
# 127.0.0.1 host binding, and the eval round-trip. Deliberately nasty
# credentials prove the SQL-quoting and URL-encoding paths. Skip the daemon
# bring-up with -SkipDb (the Podman stage below still runs unless -SkipPodman is
# also supplied; pass both for a Stage 1 presence-only run).
if ($SkipDb) {
  Write-Host "Skipping pg-dev-up functional test (-SkipDb)."
  $skipped.Add("Stage 2: pg-dev-up functional (-SkipDb)")
}
else {
  Write-Host "Running pg-dev-up functional test against $Image ..."
# Build the in-container script with explicit LF joins (single-quoted lines so
# PowerShell leaves the shell $vars alone). A here-string would inherit this
# file's CRLF endings (.gitattributes pins *.ps1 to eol=crlf), and the stray
# ^M would break parsing under /bin/sh -lc on a Windows checkout.
$dbScript = @(
  'set -e'
  'pg-dev-up up >/dev/null'
  'url=$(pg-dev-up url)'
  'echo "DATABASE_URL=$url"'
  'printf %s "$url" | grep -qF "p%40s%2Fs%26w%23d" || { echo "FAIL: password not percent-encoded in URL" >&2; exit 1; }'
  'printf %s "$url" | grep -qF "@127.0.0.1:" || { echo "FAIL: URL host is not 127.0.0.1" >&2; exit 1; }'
  'eval "$(pg-dev-up url --export)"'
  'out=$(psql "$DATABASE_URL" -tAc "SELECT current_user, current_database()")'
  'echo "psql SELECT -> $out"'
  'printf %s "$out" | grep -qxF "t|app" || { echo "FAIL: unexpected psql result: $out" >&2; exit 1; }'
  'pg-dev-up down >/dev/null'
) -join "`n"

docker run --rm `
  -e POSTGRES_USER=t `
  -e "POSTGRES_PASSWORD=p@s/s&w#d" `
  -e POSTGRES_DB=app `
  --entrypoint /bin/sh $Image -lc $dbScript

if ($LASTEXITCODE -ne 0) {
  throw "pg-dev-up functional test failed. See container output above."
}

  Write-Host "pg-dev-up functional test passed."
}

# Stage 3 - rootless Podman engine: the agent image bakes podman + a docker shim
# (docs/rootless-podman.md). This is the automated guard that follow-up asked for -
# a base/Podman bump that regresses the engine (a dropped containers.conf drop-in, a
# Podman without the `compose` subcommand, a nested run that no longer starts) is
# caught here. The helper runs the image with the launch-time device + security
# wiring the launcher normally supplies via the compose overlays. On a host that
# cannot expose /dev/net/tun it still validates the static engine wiring and skips
# only the nested-run checks; a genuinely broken image fails on any host. Skip the
# whole stage explicitly with -SkipPodman; see scripts/smoke-test-podman.ps1 for
# what it covers. The helper throws on failure, so $ErrorActionPreference = "Stop"
# propagates that up.
if ($SkipPodman) {
  Write-Host "Skipping Podman smoke test (-SkipPodman)."
  $skipped.Add("Stage 3: rootless Podman engine (-SkipPodman)")
}
else {
  # smoke-test-podman.ps1 also treats POWBOX_PODMAN=off (deprecated alias
  # POWBOX_FUSE=off) as a whole-stage skip and returns with its own notice; and
  # under auto (the default) on a host without /dev/net/tun it runs the static
  # engine checks but returns after self-skipping the nested-run + published-port
  # checks (e.g. Docker Desktop / a hosted runner with no tun device). Mirror both
  # gates so the banner records the partial run instead of claiming all stages ran -
  # the child evaluates the same host /dev/net/tun condition before its docker run,
  # so the two agree. The child still prints the skip message; we track it here.
  $podmanRequest = if ($env:POWBOX_PODMAN) { $env:POWBOX_PODMAN } elseif ($env:POWBOX_FUSE) { $env:POWBOX_FUSE } else { "auto" }
  & (Join-Path $rootDir "scripts/smoke-test-podman.ps1") -Image $Image
  if ($podmanRequest -eq "off") {
    $skipped.Add("Stage 3: rootless Podman engine (POWBOX_PODMAN=off)")
  }
  elseif ($podmanRequest -ne "on" -and -not (Test-Path "/dev/net/tun")) {
    $skipped.Add("Stage 3: rootless Podman nested-run checks (no /dev/net/tun)")
  }
}

# Stage 4 - self-hosted ("-Isolated") launch mode. Validates the launcher's
# self-hosted identity contract (always, no image needed) and the baked
# seed-workspace.sh clone/reuse/reclone/failure + single-mount hardlink behavior
# against the image (self-skips when the image is absent). Skip the whole stage
# with -SkipSelfHosted; see scripts/smoke-test-selfhosted.ps1. The helper throws
# on failure, so $ErrorActionPreference = "Stop" propagates that up.
if ($SkipSelfHosted) {
  Write-Host "Skipping self-hosted smoke test (-SkipSelfHosted)."
  $skipped.Add("Stage 4: self-hosted launch mode (-SkipSelfHosted)")
}
else {
  & (Join-Path $rootDir "scripts/smoke-test-selfhosted.ps1") -Image $Image
  # POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1 runs Stage A (launcher identity) but skips
  # Stage B (clone behavior) inside the child, which still returns success. Record
  # that partial coverage so the banner does not claim all stages ran.
  if ($env:POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE) {
    $skipped.Add("Stage 4: self-hosted clone behavior (POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE)")
  }
}

# Stage 5 - native-Linux dir-mount ownership. A bind-mounted root-owned repo is
# root:root inside the container, which the node agent (uid 1000) cannot write;
# entrypoint-core.sh's write probe + the sudo-allowlisted fix-workspace-perms.sh
# helper (PR #55) chown it to node so git/edits work. This stage runs two cases: the
# all-root-owned mount (PR #55) and a mixed-ownership mount (task 007) - a node-owned
# root that hides nested root-owned files from a host `sudo git pull` that the helper's
# uid-0 re-own heals. BOTH cases (tasks 005a + 007a) drive the GENUINE extracted entrypoint
# decision unit heal-workspace-perms.sh - the byte-for-byte probe-and-call code
# entrypoint-core.sh runs - so they guard the probe/decision path (does the probe still
# detect the unwritable mount and hand it to the helper?), not only the helper; that unit
# still ultimately invokes fix-workspace-perms.sh by the same allowlisted path/sudo
# mechanism, so the in-isolation helper + sudoers coverage is preserved. The all-root case
# exercises the root-level write probe; the mixed case (node-owned root + nested uid-0
# entries) exercises the nested-uid-0 DETECTION scan task 007 added that the root-level
# probe misses, so reverting ONLY that scan now fails the smoke (task 007a). Neither case
# boots the full entrypoint chain
# (firewall/gh/shadow need the launcher's compose wiring, out of scope here). It asserts
# node can
# write + git-commit each after the fix. It self-skips when the image is absent (honouring -RequireImage /
# POWBOX_SMOKE_REQUIRE_IMAGE), when the host is not native Linux, when it cannot
# create a root-owned fixture (no root / passwordless sudo - the local-dev case; it
# runs for real on a CI runner), or when the host masks the native-Linux uid bug.
# Skip the whole stage with -SkipDirMount; see scripts/smoke-test-dirmount.ps1. The
# helper throws on failure, so $ErrorActionPreference = "Stop" propagates that up.
if ($SkipDirMount) {
  Write-Host "Skipping dir-mount ownership smoke test (-SkipDirMount)."
  $skipped.Add("Stage 5: dir-mount ownership (-SkipDirMount)")
}
else {
  # The child still returns success when it self-skips at runtime (non-Linux host,
  # no root/passwordless sudo, or a host that masks the uid bug), so completion
  # alone cannot distinguish a real pass from a skip. Hand it a marker file: it
  # records the skip reason there and we surface it in the banner below, so a
  # partial run is not reported as "all stages ran". An empty marker means the
  # stage actually ran.
  $dirmountMarker = New-TemporaryFile
  try {
    $env:POWBOX_SMOKE_SKIP_MARKER = $dirmountMarker.FullName
    & (Join-Path $rootDir "scripts/smoke-test-dirmount.ps1") -Image $Image
  }
  finally {
    Remove-Item Env:\POWBOX_SMOKE_SKIP_MARKER -ErrorAction SilentlyContinue
  }
  $dirmountSkip = Get-Content -LiteralPath $dirmountMarker.FullName -Raw -ErrorAction SilentlyContinue
  if ($dirmountSkip) { $skipped.Add("Stage 5: dir-mount ownership ($($dirmountSkip.Trim()))") }
  Remove-Item -LiteralPath $dirmountMarker.FullName -ErrorAction SilentlyContinue
}

if ($skipped.Count -gt 0) {
  Write-Host ""
  Write-Host "================ SMOKE TEST: STAGES SKIPPED ================"
  foreach ($s in $skipped) { Write-Host "  - $s" }
  Write-Host "This was a PARTIAL smoke test - the stages above did not run."
  Write-Host "For a full run (e.g. in CI) drop the -Skip* switches; pass"
  Write-Host "-RequireImage to also fail on a missing image."
  Write-Host "==========================================================="
}
else {
  Write-Host "Smoke test complete (all stages ran)."
}
}
finally {
  # Restore only if we set it: a CI run that exported POWBOX_SMOKE_REQUIRE_IMAGE
  # directly (without -RequireImage) must keep its own value untouched.
  if ($RequireImage) {
    if ($null -eq $prevRequireImage) {
      Remove-Item Env:\POWBOX_SMOKE_REQUIRE_IMAGE -ErrorAction SilentlyContinue
    }
    else {
      $env:POWBOX_SMOKE_REQUIRE_IMAGE = $prevRequireImage
    }
  }
}
