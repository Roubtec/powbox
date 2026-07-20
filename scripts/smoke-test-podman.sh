#!/usr/bin/env bash
set -euo pipefail

# Smoke-test the rootless-Podman support baked into the agent image. This is the
# automated guard docs/rootless-podman.md's manual validation prompt asked for:
# run it after a base/Podman bump so engine regressions (a dropped containers.conf
# drop-in, a Podman that lost the `compose` subcommand, a nested run that no longer
# starts) surface here instead of the next time someone needs a nested container.
#
# The image is exercised as a throwaway `docker run`. The agent entrypoint is
# bypassed (--entrypoint /bin/sh, like the other smoke stages), so the launch-time
# wiring the launcher normally supplies via the compose overlays must be replicated
# on the command line here:
#   * /dev/net/tun  (compose.netdev.yml) — slirp4netns/pasta need it for EVERY run
#   * /dev/fuse     (compose.fuse.yml)   — overlay storage driver; vfs fallback else
#   * seccomp/apparmor/systempaths=unconfined + SYS_ADMIN/NET_ADMIN/NET_RAW
#       (compose.shared.yml) — without these crun/netavark EPERM and nothing runs.
#
# The probe has two halves. The engine-wiring checks (podman present, the
# containers.conf drop-in, `podman info`, the `podman compose` subcommand) need no
# devices and run on EVERY host. The nested-run + published-port + Compose
# exec-form-health-check checks need
# /dev/net/tun, so they self-skip when it is absent (e.g. Docker Desktop's VM under
# `auto`, where the device is not exposed) — a host that cannot do nested
# networking still validates the baked engine wiring instead of skipping blind, and
# is not treated as a regression. Device selection mirrors the launcher's
# POWBOX_PODMAN gate (POWBOX_FUSE is the deprecated alias): `on` forces both
# devices, `off` skips the whole stage, `auto` (default) attaches what the host
# exposes.
#
# A missing podman/podman-compose/etc. IS one of the regressions this stage exists
# to catch, so it FAILS rather than skipping: a current image must ship the engine.
# To run the smoke test against a legacy pre-Podman image on purpose, skip the
# whole stage explicitly with POWBOX_SMOKE_SKIP_PODMAN=1 (or POWBOX_PODMAN=off)
# rather than let a silent pass hide a real regression.

IMAGE="${1:-powbox-agent:latest}"

have_fuse=false
have_tun=false
case "${POWBOX_PODMAN:-${POWBOX_FUSE:-auto}}" in
on)
	have_fuse=true
	have_tun=true
	;;
off)
	echo "Skipping Podman smoke test (POWBOX_PODMAN=off)."
	exit 0
	;;
*)
	[ -e /dev/fuse ] && have_fuse=true
	[ -e /dev/net/tun ] && have_tun=true
	;;
esac

run_args=(
	--rm
	--cap-add SYS_ADMIN
	--cap-add NET_ADMIN
	--cap-add NET_RAW
	--security-opt seccomp=unconfined
	--security-opt apparmor=unconfined
	--security-opt systempaths=unconfined
)
# Attach the storage + networking devices the host exposes. The engine-wiring
# checks need neither; only the nested-run + published-port checks need
# /dev/net/tun, and they self-skip inside the container when it is absent.
fuse_note="vfs storage (no /dev/fuse)"
if [ "$have_fuse" = true ]; then
	run_args+=(--device /dev/fuse:/dev/fuse)
	fuse_note="overlay storage (/dev/fuse)"
fi
if [ "$have_tun" = true ]; then
	run_args+=(--device /dev/net/tun:/dev/net/tun)
	tun_note="/dev/net/tun"
else
	tun_note="no /dev/net/tun (nested-run checks will be skipped)"
fi

echo "Podman smoke test against $IMAGE — ${tun_note}, ${fuse_note}."

# The in-container probe. Single-quoted so the host shell leaves its $vars alone;
# it must therefore contain no single quotes. A non-zero exit is a failure: there
# is no skip sentinel — a missing engine is a real regression (use
# POWBOX_SMOKE_SKIP_PODMAN=1 to skip the stage for a legacy image on purpose).
set +e
docker run "${run_args[@]}" \
	-e SMOKE_HAVE_FUSE="$have_fuse" \
	-e SMOKE_HAVE_TUN="$have_tun" \
	--entrypoint /bin/sh "$IMAGE" -lc '
set -eu

fail() { echo "FAIL: $*" >&2; exit 1; }

# Engine presence is itself one of the regressions this stage exists to catch, so a
# missing podman FAILS rather than skipping — a current image must ship it.
command -v podman >/dev/null 2>&1 || fail "podman is not installed in this image"

# Entrypoint prep we bypass with --entrypoint: mirror the two things
# entrypoint-core.sh does for Podman — a private runtime dir (created, locked to
# 700, and exported), and (only when /dev/fuse is absent) a vfs storage.conf, since
# the overlay default needs fuse-overlayfs. No shared image store is mounted into
# this throwaway container, so the graphroot starts empty and the
# additionalimagestores wiring in entrypoint-core.sh is irrelevant here.
_xdg="${XDG_RUNTIME_DIR:-/home/node/.local/run}"
mkdir -p "$_xdg" && chmod 700 "$_xdg"
export XDG_RUNTIME_DIR="$_xdg"
if [ "${SMOKE_HAVE_FUSE:-false}" != true ]; then
	mkdir -p "$HOME/.config/containers"
	printf "[storage]\ndriver = \"vfs\"\n" >"$HOME/.config/containers/storage.conf"
fi

# 1. Engine sanity + static wiring (no network — runs on every host, including one
# that cannot expose /dev/net/tun). The cgroup manager + network backend come from
# the baked containers.conf drop-in; a base bump that drops or overrides it changes
# these. Rootless must be true.
[ "$(id -u)" -eq 1000 ] || fail "not running as uid 1000 (node)"
command -v podman-compose >/dev/null 2>&1 || fail "podman-compose missing"
command -v docker >/dev/null 2>&1 || fail "docker shim missing"
grep -q "^node:" /etc/subuid || fail "no node: range in /etc/subuid"
grep -q "^node:" /etc/subgid || fail "no node: range in /etc/subgid"

info=$(podman info --format "{{.Host.Security.Rootless}}|{{.Host.CgroupManager}}|{{.Host.NetworkBackend}}" 2>/dev/null) || fail "podman info failed"
[ "$info" = "true|cgroupfs|netavark" ] || fail "podman info = [$info], want [true|cgroupfs|netavark]"

# netavark has no nft binary in this image, so the drop-in pins the iptables
# firewall driver; without it every bridge network / published port dies at start.
grep -Eqr "firewall_driver.*iptables" /etc/containers/containers.conf.d/ || fail "firewall_driver=iptables drop-in missing (netavark would try nft)"

# The compose subcommand (the reason for the trixie/Podman-5 base bump; absent on
# Podman < 4.7) must exist, or "podman compose" / "docker compose" both break.
podman compose version >/dev/null 2>&1 || fail "podman compose subcommand missing (Podman < 4.7?)"

# The remaining checks start nested containers, which need /dev/net/tun. When it was
# not attached (the host could not expose it), skip just these — the engine wiring
# above is already validated — rather than fail on an environment limitation.
if [ "${SMOKE_HAVE_TUN:-false}" != true ]; then
	echo "Podman engine wiring OK (static checks). Skipping nested-run + published-port + Compose exec-form health-check checks: /dev/net/tun was not attached on this host."
	exit 0
fi

# 2. Nested run on the default network. This alone proves the seccomp/apparmor
# profile (crun keyring + pivot_root), /dev/net/tun (slirp4netns/pasta), and the
# ping_group_range sysctl write (systempaths=unconfined) all work — if any were
# missing the run would not start. --quiet suppresses the image-pull progress
# (this throwaway container has an empty graphroot, so Alpine is pulled on first
# use) so it cannot pollute the output the exact-match grep below checks; a real
# run error still reaches stderr and is captured by 2>&1 for the failure message.
out=$(podman run --quiet --rm docker.io/library/alpine echo nested_ok 2>&1) || fail "podman run on the default network failed: $out"
printf "%s" "$out" | grep -qx nested_ok || fail "unexpected nested-run output: $out"

# 3. Bridge network + published port. A user-defined network is a netavark bridge;
# publishing a port on it exercises the iptables firewall driver and the
# route_localnet sysctl write that systempaths=unconfined unblocks — exactly the
# regressions the drop-in and compose flags exist to prevent. Both fail at container
# *start*, so a still-running container is the pass signal.
podman network create smoke-net >/dev/null || fail "podman network create failed"
cid=""
compose_dir=""
compose_proj=""
cleanup() {
	[ -n "$cid" ] && podman rm -f "$cid" >/dev/null 2>&1 || true
	podman network rm smoke-net >/dev/null 2>&1 || true
	if [ -n "$compose_proj" ]; then
		[ -n "$compose_dir" ] && docker compose -f "$compose_dir/docker-compose.yml" -p "$compose_proj" down -v >/dev/null 2>&1 || true
		for c in $(podman ps -aq --filter "label=com.docker.compose.project=$compose_proj" 2>/dev/null); do
			podman rm -f "$c" >/dev/null 2>&1 || true
		done
		podman network rm "${compose_proj}_default" >/dev/null 2>&1 || true
	fi
	[ -n "$compose_dir" ] && rm -rf "$compose_dir"
	return 0
}
trap cleanup EXIT
cid=$(podman run --quiet -d --network smoke-net -p 127.0.0.1:8099:8099 docker.io/library/alpine sleep 30) || fail "podman run -d -p on a bridge network failed (netavark firewall_driver / route_localnet regression?)"
sleep 2
podman ps --filter "id=$cid" --filter status=running -q | grep -q . || fail "published-port container did not stay running: $(podman logs "$cid" 2>&1 | tail -3)"

# 4. Compose exec-form health check. Motivating regression (Kalm2 SPIRE overlay):
# podman-compose left a distroless exec-form health check stuck at "starting". The
# fixture has TWO services so the check has real teeth: "hc" (test /bin/true) MUST
# reach healthy, and a negative-control "bad" (test /bin/false) MUST NOT — see 4b.
# Exercised through "docker compose" (the shim spelling agents use); it routes to
# "podman compose" -> the podman-compose provider, so both spellings share one path.
# See docs/rootless-podman.md "Compose health-check behavior" for the full contract.
compose_dir=$(mktemp -d) || fail "mktemp -d for the compose health-check fixture failed"
chmod 700 "$compose_dir"
compose_proj="smokehc$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d " \n")"
[ "$compose_proj" = smokehc ] && compose_proj="smokehc$$"
cat >"$compose_dir/docker-compose.yml" <<"SMOKE_COMPOSE_YAML"
services:
  hc:
    image: docker.io/library/alpine
    command: ["sleep", "120"]
    healthcheck:
      test: ["CMD", "/bin/true"]
      interval: 2s
      timeout: 2s
      retries: 3
      start_period: 1s
  bad:
    image: docker.io/library/alpine
    command: ["sleep", "120"]
    healthcheck:
      test: ["CMD", "/bin/false"]
      interval: 2s
      timeout: 2s
      retries: 3
      start_period: 1s
SMOKE_COMPOSE_YAML
up_out=$(docker compose -f "$compose_dir/docker-compose.yml" -p "$compose_proj" up -d 2>&1) || fail "docker compose up on the exec-form health-check fixture failed: $up_out"
hc_cid=$(podman ps -aq --filter "label=com.docker.compose.project=$compose_proj" --filter "label=com.docker.compose.service=hc" 2>/dev/null | head -n1)
[ -n "$hc_cid" ] || fail "compose service container not found for project $compose_proj (compose up did not create it)"
bad_cid=$(podman ps -aq --filter "label=com.docker.compose.project=$compose_proj" --filter "label=com.docker.compose.service=bad" 2>/dev/null | head -n1)
[ -n "$bad_cid" ] || fail "compose negative-control container not found for project $compose_proj (compose up did not create it)"

# 4a. Exec-form TRANSLATION check. Inspect the health check Compose actually wired
# onto the container and CLASSIFY it, rather than only checking it is non-empty
# (which silently passes the CMD->CMD-SHELL rewrite that breaks distroless).
# .Config.Healthcheck.Test[0] is "CMD" for a preserved exec array, "CMD-SHELL" for a
# shell-wrapped one. On this sandbox podman-compose 1.3 ALWAYS rewrites the exec form
# ["CMD","/bin/true"] -> ["CMD-SHELL","/bin/sh -c /bin/true"], so we surface that as a
# loud KNOWN-XFAIL (a detected+reported condition, not a silent pass hidden in prose):
# a distroless image with no /bin/sh WOULD be stuck at starting — the reported Kalm2
# symptom. We only FAIL if the check was dropped or mangled BEYOND that known wrap
# (the intended binary did not survive), and NOTE it if a future provider stops
# wrapping (the docs workaround could then be revisited).
hc_kind=$(podman inspect --format "{{if and .Config.Healthcheck .Config.Healthcheck.Test}}{{index .Config.Healthcheck.Test 0}}{{end}}" "$hc_cid" 2>/dev/null || echo "")
hc_test=$(podman inspect --format "{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{else}}null{{end}}" "$hc_cid" 2>/dev/null || echo "")
case "$hc_kind" in
CMD-SHELL)
	case "$hc_test" in
	*/bin/true*) echo "KNOWN-XFAIL: podman-compose 1.3 rewrote the exec-form health check [CMD /bin/true] to ${hc_test} — a distroless image with no /bin/sh WOULD be stuck at starting (the Kalm2 SPIRE symptom); alpine has a shell so it still reaches healthy. See docs/rootless-podman.md Compose health-check behavior." ;;
	*) fail "compose mistranslated the exec-form health check beyond the known CMD-SHELL wrap: ${hc_test} (the intended /bin/true did not survive the conversion)" ;;
	esac
	;;
CMD)
	echo "NOTE: podman-compose preserved the exec-form health check as ${hc_test} (no shell wrap) — the CMD-SHELL rewrite documented in docs/rootless-podman.md may no longer apply; revisit accepted limitation #2." ;;
"") fail "compose dropped the exec-form health check entirely (Config.Healthcheck.Test is empty: ${hc_test})" ;;
*) fail "compose produced an unrecognized health-check form (kind=[${hc_kind}], test=${hc_test})" ;;
esac

# 4b. Health-state PROPAGATION + negative control. There is NO systemd in this
# container (cgroupfs, /run/systemd/system absent), so Podman never fires the
# PERIODIC health-check timer and a service state would sit at "starting" forever on
# its own — true for a plain "podman run --health-cmd" too, not only Compose. The
# only supported trigger here is to run the check explicitly with
# "podman healthcheck run", which executes the wired command once and propagates the
# result. drive_health does exactly that in a bounded loop and echoes the final
# state. This is deliberately proven to be non-vacuous: the "hc" service (/bin/true)
# MUST reach healthy, while the negative-control "bad" service (/bin/false), driven
# the SAME way, MUST NOT — driving only reports the command real result, so a
# never-succeeding check that ever reported healthy would mean the healthy assertion
# could not catch a service Compose leaves perpetually at starting. That negative
# control is the bounded proof that a never-healthy service fails clearly.
drive_health() { # $1=container $2=max-iterations; echoes final health, always rc 0
	_n=0
	_h=""
	while [ "$_n" -lt "$2" ]; do
		podman healthcheck run "$1" >/dev/null 2>&1 || true
		_h=$(podman inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" "$1" 2>/dev/null || true)
		[ "$_h" = healthy ] && break
		_n=$((_n + 1))
		sleep 1
	done
	printf "%s" "${_h:-unknown}"
}
hc_health=$(drive_health "$hc_cid" 15)
[ "$hc_health" = healthy ] || fail "compose exec-form health check never reached healthy (last state: ${hc_health}); a service stuck at starting/unhealthy fails here — see docs/rootless-podman.md Compose health-check behavior"
bad_health=$(drive_health "$bad_cid" 6)
[ "$bad_health" = healthy ] && fail "negative control broke: a never-succeeding health command (/bin/false) reported healthy (state: ${bad_health}) — the healthy assertion is vacuous and would not catch a stuck-at-starting service"
echo "Negative control OK: the never-succeeding /bin/false service correctly never reached healthy (last state: ${bad_health})."

echo "Podman engine OK: rootless nested run, bridge published port, the compose subcommand, and a Compose exec-form health check reaching healthy (with a never-healthy negative control failing as expected) all work."
'
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
	echo "Podman smoke test FAILED (exit $rc). See container output above." >&2
	exit "$rc"
fi
echo "Smoke test (podman) passed."
