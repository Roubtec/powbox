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
# devices and run on EVERY host. The nested-run + published-port checks need
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
	echo "Podman engine wiring OK (static checks). Skipping nested-run + published-port checks: /dev/net/tun was not attached on this host."
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
cleanup() {
	[ -n "$cid" ] && podman rm -f "$cid" >/dev/null 2>&1
	podman network rm smoke-net >/dev/null 2>&1
	return 0
}
trap cleanup EXIT
cid=$(podman run --quiet -d --network smoke-net -p 127.0.0.1:8099:8099 docker.io/library/alpine sleep 30) || fail "podman run -d -p on a bridge network failed (netavark firewall_driver / route_localnet regression?)"
sleep 2
podman ps --filter "id=$cid" --filter status=running -q | grep -q . || fail "published-port container did not stay running: $(podman logs "$cid" 2>&1 | tail -3)"

echo "Podman engine OK: rootless nested run, bridge published port, and the compose subcommand all work."
'
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
	echo "Podman smoke test FAILED (exit $rc). See container output above." >&2
	exit "$rc"
fi
echo "Smoke test (podman) passed."
