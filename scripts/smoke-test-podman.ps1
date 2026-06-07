param(
  [string]$Image = "powbox-agent:latest"
)

# Smoke-test the rootless-Podman support baked into the agent image. This is the
# automated guard docs/rootless-podman.md's manual validation prompt asked for:
# run it after a base/Podman bump so engine regressions (a dropped containers.conf
# drop-in, a Podman that lost the `compose` subcommand, a nested run that no longer
# starts) surface here instead of the next time someone needs a nested container.
#
# The image is exercised as a throwaway `docker run`. The agent entrypoint is
# bypassed (--entrypoint /bin/sh, like the other smoke stages), so the launch-time
# wiring the launcher normally supplies via the compose overlays is replicated on
# the command line here: /dev/net/tun (compose.netdev.yml, nested networking),
# /dev/fuse (compose.fuse.yml, overlay storage; vfs fallback otherwise), and
# seccomp/apparmor/systempaths=unconfined + SYS_ADMIN/NET_ADMIN/NET_RAW
# (compose.shared.yml) - without which crun/netavark EPERM and nothing runs.
#
# Device selection mirrors the launcher's POWBOX_PODMAN gate (POWBOX_FUSE is the
# deprecated alias): `on` forces both, `off` skips the whole stage, `auto` (default)
# attaches what the host exposes. /dev/net/tun is mandatory, so when it is absent
# the stage SKIPS rather than failing - a host that cannot do nested networking
# (e.g. Docker Desktop's VM, where the Windows host cannot see the device under
# `auto`) is not a Podman regression; force it with POWBOX_PODMAN=on if it exists.

$ErrorActionPreference = "Stop"

$podmanRequest = if ($env:POWBOX_PODMAN) { $env:POWBOX_PODMAN } elseif ($env:POWBOX_FUSE) { $env:POWBOX_FUSE } else { "auto" }
$haveFuse = $false
$haveTun = $false
switch ($podmanRequest) {
  "on" { $haveFuse = $true; $haveTun = $true }
  "off" {
    Write-Host "Skipping Podman smoke test (POWBOX_PODMAN=off)."
    return
  }
  default {
    if (Test-Path "/dev/fuse") { $haveFuse = $true }
    if (Test-Path "/dev/net/tun") { $haveTun = $true }
  }
}

if (-not $haveTun) {
  Write-Host "Skipping Podman smoke test: /dev/net/tun is not available to this host, so nested-container networking cannot be exercised. Force it with POWBOX_PODMAN=on if the device exists (e.g. the Docker Desktop VM)."
  return
}

$runArgs = @(
  "run", "--rm",
  "--cap-add", "SYS_ADMIN",
  "--cap-add", "NET_ADMIN",
  "--cap-add", "NET_RAW",
  "--security-opt", "seccomp=unconfined",
  "--security-opt", "apparmor=unconfined",
  "--security-opt", "systempaths=unconfined",
  "--device", "/dev/net/tun:/dev/net/tun"
)
$fuseNote = "vfs storage (no /dev/fuse)"
if ($haveFuse) {
  $runArgs += @("--device", "/dev/fuse:/dev/fuse")
  $fuseNote = "overlay storage (/dev/fuse)"
}

Write-Host "Podman smoke test against $Image - devices: /dev/net/tun + $fuseNote."

# The in-container probe, built with explicit LF joins (single-quoted lines so
# PowerShell leaves the shell $vars alone; a here-string would inherit this file's
# CRLF endings and the stray ^M would break /bin/sh -lc). Exit 97 is the "image
# predates Podman support" sentinel the caller turns into a skip; any other
# non-zero is a failure. The lines must contain no single quotes.
$script = @(
  'set -eu'
  'fail() { echo "FAIL: $*" >&2; exit 1; }'
  'command -v podman >/dev/null 2>&1 || exit 97'
  '_xdg="${XDG_RUNTIME_DIR:-/home/node/.local/run}"'
  'mkdir -p "$_xdg" && chmod 700 "$_xdg"'
  'export XDG_RUNTIME_DIR="$_xdg"'
  'if [ "${SMOKE_HAVE_FUSE:-false}" != true ]; then'
  '  mkdir -p "$HOME/.config/containers"'
  '  printf "[storage]\ndriver = \"vfs\"\n" >"$HOME/.config/containers/storage.conf"'
  'fi'
  '[ "$(id -u)" -eq 1000 ] || fail "not running as uid 1000 (node)"'
  'command -v podman-compose >/dev/null 2>&1 || fail "podman-compose missing"'
  'command -v docker >/dev/null 2>&1 || fail "docker shim missing"'
  'grep -q "^node:" /etc/subuid || fail "no node: range in /etc/subuid"'
  'grep -q "^node:" /etc/subgid || fail "no node: range in /etc/subgid"'
  'info=$(podman info --format "{{.Host.Security.Rootless}}|{{.Host.CgroupManager}}|{{.Host.NetworkBackend}}" 2>/dev/null) || fail "podman info failed"'
  '[ "$info" = "true|cgroupfs|netavark" ] || fail "podman info = [$info], want [true|cgroupfs|netavark]"'
  'grep -Eqr "firewall_driver.*iptables" /etc/containers/containers.conf.d/ || fail "firewall_driver=iptables drop-in missing (netavark would try nft)"'
  'podman compose version >/dev/null 2>&1 || fail "podman compose subcommand missing (Podman < 4.7?)"'
  'out=$(podman run --quiet --rm docker.io/library/alpine echo nested_ok 2>&1) || fail "podman run on the default network failed: $out"'
  'printf "%s" "$out" | grep -qx nested_ok || fail "unexpected nested-run output: $out"'
  'podman network create smoke-net >/dev/null || fail "podman network create failed"'
  'cid=""'
  'cleanup() { [ -n "$cid" ] && podman rm -f "$cid" >/dev/null 2>&1; podman network rm smoke-net >/dev/null 2>&1; return 0; }'
  'trap cleanup EXIT'
  'cid=$(podman run --quiet -d --network smoke-net -p 127.0.0.1:8099:8099 docker.io/library/alpine sleep 30) || fail "podman run -d -p on a bridge network failed (netavark firewall_driver / route_localnet regression?)"'
  'sleep 2'
  'podman ps --filter "id=$cid" --filter status=running -q | grep -q . || fail "published-port container did not stay running: $(podman logs "$cid" 2>&1 | tail -3)"'
  'echo "Podman engine OK: rootless nested run, bridge published port, and the compose subcommand all work."'
) -join "`n"

$runArgs += @(
  "-e", "SMOKE_HAVE_FUSE=$($haveFuse.ToString().ToLower())",
  "--entrypoint", "/bin/sh", $Image, "-lc", $script
)

docker @runArgs
$rc = $LASTEXITCODE

if ($rc -eq 0) {
  Write-Host "Smoke test (podman) passed."
}
elseif ($rc -eq 97) {
  Write-Host "Skipping Podman smoke test: '$Image' does not contain podman (image predates rootless-Podman support)."
}
else {
  throw "Podman smoke test failed (exit $rc). See container output above."
}
