param(
  [string]$Image = "powbox-agent:latest",
  [switch]$SkipDb,
  [switch]$SkipPodman
)

# The agent image is unified: both claude and codex (and codex's bwrap sandbox)
# are baked into the same image alongside the shared toolchain, so one smoke
# test validates everything in a single pass.
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

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
# bring-up (and keep the fast presence-only sweep) with -SkipDb.
if ($SkipDb) {
  Write-Host "Skipping pg-dev-up functional test (-SkipDb)."
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
# wiring the launcher normally supplies via the compose overlays, and auto-skips on
# a host that cannot expose /dev/net/tun. Skip it explicitly with -SkipPodman; see
# scripts/smoke-test-podman.ps1 for what it covers. The helper throws on failure, so
# $ErrorActionPreference = "Stop" propagates that up.
if ($SkipPodman) {
  Write-Host "Skipping Podman smoke test (-SkipPodman)."
}
else {
  & (Join-Path $rootDir "scripts/smoke-test-podman.ps1") -Image $Image
}

Write-Host "Smoke test complete."
