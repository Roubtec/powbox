param(
  [string]$Image = "powbox-agent:latest",
  [switch]$SkipDb,
  [switch]$SkipPodman,
  [switch]$SkipSelfHosted,
  [switch]$RequireImage
)

# The agent image is unified: both claude and codex (and codex's bwrap sandbox)
# are baked into the same image alongside the shared toolchain, so one smoke
# test validates everything in a single pass.
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

# Image-gated stages (1-4) need the agent image. Detect it once up front so a run
# with no image fails loudly here instead of self-skipping into a false "all
# green". -RequireImage (or POWBOX_SMOKE_REQUIRE_IMAGE=1, used by CI) turns an
# absent image into a hard error before any stage runs; the env var is also set so
# the sub-scripts that otherwise self-skip their image-gated checks (e.g. the
# self-hosted clone stage) fail instead. $skipped collects every stage we skip so
# the end-of-run banner can report that the run was partial.
if ($RequireImage) { $env:POWBOX_SMOKE_REQUIRE_IMAGE = '1' }
$skipped = [System.Collections.Generic.List[string]]::new()
docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
  if ($env:POWBOX_SMOKE_REQUIRE_IMAGE) {
    throw "image '$Image' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set - refusing to run a partial (image-skipping) smoke test. Build it first (./build.ps1 agent) or drop -RequireImage."
  }
  Write-Warning "image '$Image' not found - the image-gated stages need it. Stage 1 will fail and the self-hosted clone stage self-skips. Build it (./build.ps1 agent), or pass -RequireImage to fail fast instead of partway through."
}

# Stage 1 - tool presence + key image config: every expected CLI resolves and
# runs, and pnpm ships package-import-method=auto (not the old forced copy) so
# worktree installs can hardlink from a co-located store.
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
  & (Join-Path $rootDir "scripts/smoke-test-podman.ps1") -Image $Image
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
