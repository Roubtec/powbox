#!/usr/bin/env bash
# The in-container half of Stage 3's restart probe (task 090): rootless Podman
# must work on the first command after the agent container restarts, although
# its runtime state from before the restart is still on disk.
#
# This file is SOURCE TEXT, not a program to run. Both drivers of the stage,
# scripts/smoke-test-podman.sh and its PowerShell mirror scripts/smoke-test-podman.ps1,
# read it verbatim and hand it to `docker exec <container> bash -c "<this file>"
# powbox-podman-restart <phase> [<start id>]`, so it runs inside the throwaway
# container the driver booted through the real entrypoint-core.sh. One file keeps
# the two drivers from drifting. The shebang is never honoured; it is there so
# that shellcheck reads the file as bash. It is deliberately not executable.
#
# Contract with BOTH drivers (change it in both):
#   phase `before`: start a nested container named `stale` that keeps running,
#     then print `START=<id>`, the container-start id entrypoint-core.sh recorded.
#     The driver then kills the outer container (SIGKILL, like a host crash) and
#     starts it again, which reruns the entrypoint.
#   phase `after <id>`: the id from `before`. Fails unless the entrypoint recorded
#     a new start, the first podman, docker and docker compose commands all work,
#     and `stale` is reported stopped and can be started again.
# Exit 0 is a pass; any failure prints `FAIL: <reason>` and exits 1.
set -eu

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

marker="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set in this image}/.powbox-podman-start"

case "${1:-}" in
before)
	out=$(podman run --quiet -d --name stale docker.io/library/alpine sleep 600 2>&1) || fail "podman run -d before the restart failed: $out"
	[ -n "$(podman ps -q --filter name=stale --filter status=running)" ] || fail "the nested container did not stay running before the restart"
	[ -s "$marker" ] || fail "entrypoint-core.sh recorded no container start in $marker"
	echo "START=$(cat "$marker")"
	;;
after)
	before="${2:?phase after needs the start id from phase before}"
	[ -s "$marker" ] || fail "entrypoint-core.sh recorded no container start in $marker after the restart"
	after=$(cat "$marker")
	[ "$after" != "$before" ] || fail "the start id did not change across the restart ($after), so the entrypoint treated the restarted container as the same start"

	# The first command after the restart. Stale state fails it with "invalid
	# internal status, try resetting the pause process".
	out=$(podman ps -a 2>&1) || fail "podman ps -a failed after the restart: $out"
	out=$(docker ps -a 2>&1) || fail "docker ps -a (shim) failed after the restart: $out"
	status=$(podman inspect --format "{{.State.Status}}" stale 2>&1) || fail "podman inspect of the pre-restart container failed: $status"
	[ "$status" != running ] || fail "the pre-restart container is still reported running, so Podman kept stale state"

	out=$(podman run --quiet --rm docker.io/library/alpine echo restart_ok 2>&1) || fail "podman run failed after the restart: $out"
	[ "$out" = restart_ok ] || fail "unexpected nested-run output after the restart: $out"
	out=$(podman start stale 2>&1) || fail "podman start of the pre-restart container failed: $out"
	[ -n "$(podman ps -q --filter name=stale --filter status=running)" ] || fail "the pre-restart container did not run again after podman start"

	dir=$(mktemp -d) || fail "mktemp -d for the compose fixture failed"
	printf 'services:\n  probe:\n    image: docker.io/library/alpine\n    command: ["sleep", "120"]\n' >"$dir/docker-compose.yml"
	out=$(docker compose -f "$dir/docker-compose.yml" -p restartprobe up -d 2>&1) || fail "docker compose up failed after the restart: $out"
	[ -n "$(podman ps -q --filter label=com.docker.compose.project=restartprobe --filter status=running)" ] || fail "docker compose up started no running service after the restart: $out"
	echo "Podman after a restart OK: stale runtime state was cleared, podman, docker and docker compose work, and the pre-restart container restarts."
	;;
*)
	fail "unknown phase: ${1:-<none>}"
	;;
esac
