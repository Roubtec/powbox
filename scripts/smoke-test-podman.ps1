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
# The probe has two halves. The engine-wiring checks (podman present, the
# containers.conf drop-in, `podman info`, the `podman compose` subcommand) need no
# devices and run on EVERY host. The nested-run + published-port + Compose
# exec-form-health-check checks need
# /dev/net/tun, so they self-skip when it is absent (e.g. Docker Desktop's VM under
# `auto`, where the Windows host cannot see the device) - a host that cannot do
# nested networking still validates the baked engine wiring instead of skipping
# blind, and is not treated as a regression. Device selection mirrors the launcher's
# POWBOX_PODMAN gate (POWBOX_FUSE is the deprecated alias): `on` forces both
# devices, `off` skips the whole stage, `auto` (default) attaches what the host
# exposes.
#
# A missing podman/podman-compose/etc. IS one of the regressions this stage exists
# to catch, so it FAILS rather than skipping: a current image must ship the engine.
# To run the smoke test against a legacy pre-Podman image on purpose, skip the
# whole stage explicitly with POWBOX_SMOKE_SKIP_PODMAN=1 (or POWBOX_PODMAN=off).

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

# The storage + networking devices the host exposes. The engine-wiring checks need
# neither; only the nested-run + published-port checks need /dev/net/tun, and they
# self-skip inside the container when it is absent.
$runArgs = @(
  "run", "--rm",
  "--cap-add", "SYS_ADMIN",
  "--cap-add", "NET_ADMIN",
  "--cap-add", "NET_RAW",
  "--security-opt", "seccomp=unconfined",
  "--security-opt", "apparmor=unconfined",
  "--security-opt", "systempaths=unconfined"
)
$fuseNote = "vfs storage (no /dev/fuse)"
if ($haveFuse) {
  $runArgs += @("--device", "/dev/fuse:/dev/fuse")
  $fuseNote = "overlay storage (/dev/fuse)"
}
if ($haveTun) {
  $runArgs += @("--device", "/dev/net/tun:/dev/net/tun")
  $tunNote = "/dev/net/tun"
}
else {
  $tunNote = "no /dev/net/tun (nested-run checks will be skipped)"
}

Write-Host "Podman smoke test against $Image - $tunNote, $fuseNote."

# The in-container probe, built with explicit LF joins (single-quoted lines so
# PowerShell leaves the shell $vars alone; a here-string would inherit this file's
# CRLF endings and the stray ^M would break /bin/sh -lc). A non-zero exit is a
# failure: there is no skip sentinel - a missing engine is a real regression (use
# POWBOX_SMOKE_SKIP_PODMAN=1 to skip the stage for a legacy image on purpose). The
# lines must contain no single quotes.
$script = @(
  'set -eu'
  'fail() { echo "FAIL: $*" >&2; exit 1; }'
  'command -v podman >/dev/null 2>&1 || fail "podman is not installed in this image"'
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
  'if [ "${SMOKE_HAVE_TUN:-false}" != true ]; then'
  '  echo "Podman engine wiring OK (static checks). Skipping nested-run + published-port + Compose exec-form health-check checks: /dev/net/tun was not attached on this host."'
  '  exit 0'
  'fi'
  'out=$(podman run --quiet --rm docker.io/library/alpine echo nested_ok 2>&1) || fail "podman run on the default network failed: $out"'
  'printf "%s" "$out" | grep -qx nested_ok || fail "unexpected nested-run output: $out"'
  'podman network create smoke-net >/dev/null || fail "podman network create failed"'
  'cid=""'
  'compose_dir=""'
  'compose_proj=""'
  'cleanup() { [ -n "$cid" ] && podman rm -f "$cid" >/dev/null 2>&1 || true; podman network rm smoke-net >/dev/null 2>&1 || true; if [ -n "$compose_proj" ]; then [ -n "$compose_dir" ] && docker compose -f "$compose_dir/docker-compose.yml" -p "$compose_proj" down -v >/dev/null 2>&1 || true; for c in $(podman ps -aq --filter "label=com.docker.compose.project=$compose_proj" 2>/dev/null); do podman rm -f "$c" >/dev/null 2>&1 || true; done; podman network rm "${compose_proj}_default" >/dev/null 2>&1 || true; fi; [ -n "$compose_dir" ] && rm -rf "$compose_dir"; return 0; }'
  'trap cleanup EXIT'
  'cid=$(podman run --quiet -d --network smoke-net -p 127.0.0.1:8099:8099 docker.io/library/alpine sleep 30) || fail "podman run -d -p on a bridge network failed (netavark firewall_driver / route_localnet regression?)"'
  'sleep 2'
  'podman ps --filter "id=$cid" --filter status=running -q | grep -q . || fail "published-port container did not stay running: $(podman logs "$cid" 2>&1 | tail -3)"'
  '# Compose exec-form health check (mirror of scripts/smoke-test-podman.sh section 4).'
  '# TWO services: "hc" (/bin/true) MUST reach healthy; the negative-control "bad"'
  '# (/bin/false) MUST NOT. No systemd here (cgroupfs), so the PERIODIC timer never'
  '# fires and state would sit at "starting" forever; the only supported trigger is'
  '# "podman healthcheck run", so we drive the check explicitly and assert propagation.'
  '# podman-compose 1.3 rewrites the exec form CMD -> CMD-SHELL, surfaced as a KNOWN-XFAIL'
  '# below. Exercised via "docker compose" (the shim spelling agents use).'
  'compose_dir=$(mktemp -d) || fail "mktemp -d for the compose health-check fixture failed"'
  'chmod 700 "$compose_dir"'
  'compose_proj="smokehc$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d " \n")"'
  '[ "$compose_proj" = smokehc ] && compose_proj="smokehc$$"'
  'cat >"$compose_dir/docker-compose.yml" <<"SMOKE_COMPOSE_YAML"'
  'services:'
  '  hc:'
  '    image: docker.io/library/alpine'
  '    command: ["sleep", "120"]'
  '    healthcheck:'
  '      test: ["CMD", "/bin/true"]'
  '      interval: 2s'
  '      timeout: 2s'
  '      retries: 3'
  '      start_period: 1s'
  '  bad:'
  '    image: docker.io/library/alpine'
  '    command: ["sleep", "120"]'
  '    healthcheck:'
  '      test: ["CMD", "/bin/false"]'
  '      interval: 2s'
  '      timeout: 2s'
  '      retries: 3'
  '      start_period: 1s'
  'SMOKE_COMPOSE_YAML'
  'up_out=$(docker compose -f "$compose_dir/docker-compose.yml" -p "$compose_proj" up -d 2>&1) || fail "docker compose up on the exec-form health-check fixture failed: $up_out"'
  'hc_cid=$(podman ps -aq --filter "label=com.docker.compose.project=$compose_proj" --filter "label=com.docker.compose.service=hc" 2>/dev/null | head -n1)'
  '[ -n "$hc_cid" ] || fail "compose service container not found for project $compose_proj (compose up did not create it)"'
  'bad_cid=$(podman ps -aq --filter "label=com.docker.compose.project=$compose_proj" --filter "label=com.docker.compose.service=bad" 2>/dev/null | head -n1)'
  '[ -n "$bad_cid" ] || fail "compose negative-control container not found for project $compose_proj (compose up did not create it)"'
  '# 4a. Exec-form TRANSLATION check: classify what compose actually wired, not just'
  '# that it is non-empty. On podman-compose 1.3 the exec form is ALWAYS rewritten to'
  '# CMD-SHELL, surfaced as a loud KNOWN-XFAIL; FAIL only if dropped or mangled beyond'
  '# that known wrap, NOTE if a future provider stops wrapping.'
  'hc_kind=$(podman inspect --format "{{if and .Config.Healthcheck .Config.Healthcheck.Test}}{{index .Config.Healthcheck.Test 0}}{{end}}" "$hc_cid" 2>/dev/null || echo "")'
  'hc_test=$(podman inspect --format "{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{else}}null{{end}}" "$hc_cid" 2>/dev/null || echo "")'
  'case "$hc_kind" in'
  'CMD-SHELL)'
  '  case "$hc_test" in'
  '  */bin/true*) echo "KNOWN-XFAIL: podman-compose 1.3 rewrote the exec-form health check [CMD /bin/true] to ${hc_test} -- a distroless image with no /bin/sh WOULD be stuck at starting (the Kalm2 SPIRE symptom); alpine has a shell so it still reaches healthy. See docs/rootless-podman.md Compose health-check behavior." ;;'
  '  *) fail "compose mistranslated the exec-form health check beyond the known CMD-SHELL wrap: ${hc_test} (the intended /bin/true did not survive the conversion)" ;;'
  '  esac ;;'
  'CMD) echo "NOTE: podman-compose preserved the exec-form health check as ${hc_test} (no shell wrap) -- the CMD-SHELL rewrite documented in docs/rootless-podman.md may no longer apply; revisit accepted limitation #2." ;;'
  '"") fail "compose dropped the exec-form health check entirely (Config.Healthcheck.Test is empty: ${hc_test})" ;;'
  '*) fail "compose produced an unrecognized health-check form (kind=[${hc_kind}], test=${hc_test})" ;;'
  'esac'
  '# 4b. PROPAGATION + negative control: drive the check explicitly (no systemd timer'
  '# here) and prove the assertion is non-vacuous -- hc MUST reach healthy, bad MUST NOT.'
  'drive_health() { _n=0; _h=""; while [ "$_n" -lt "$2" ]; do podman healthcheck run "$1" >/dev/null 2>&1 || true; _h=$(podman inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" "$1" 2>/dev/null || true); [ "$_h" = healthy ] && break; _n=$((_n + 1)); sleep 1; done; printf "%s" "${_h:-unknown}"; }'
  'hc_health=$(drive_health "$hc_cid" 15)'
  '[ "$hc_health" = healthy ] || fail "compose exec-form health check never reached healthy (last state: ${hc_health}); a service stuck at starting/unhealthy fails here -- see docs/rootless-podman.md Compose health-check behavior"'
  'bad_health=$(drive_health "$bad_cid" 6)'
  '[ "$bad_health" = healthy ] && fail "negative control broke: a never-succeeding health command (/bin/false) reported healthy (state: ${bad_health}) -- the healthy assertion is vacuous and would not catch a stuck-at-starting service"'
  'echo "Negative control OK: the never-succeeding /bin/false service correctly never reached healthy (last state: ${bad_health})."'
  'echo "Podman engine OK: rootless nested run, bridge published port, the compose subcommand, and a Compose exec-form health check reaching healthy (with a never-healthy negative control failing as expected) all work."'
) -join "`n"

$runArgs += @(
  "-e", "SMOKE_HAVE_FUSE=$($haveFuse.ToString().ToLower())",
  "-e", "SMOKE_HAVE_TUN=$($haveTun.ToString().ToLower())",
  "--entrypoint", "/bin/sh", $Image, "-lc", $script
)

docker @runArgs
$rc = $LASTEXITCODE

if ($rc -eq 0) {
  Write-Host "Smoke test (podman) passed."
}
else {
  throw "Podman smoke test failed (exit $rc). See container output above."
}
