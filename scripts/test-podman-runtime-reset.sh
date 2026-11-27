#!/usr/bin/env bash
# Hermetic tests for the stale Podman runtime-state reset in
# docker/shared/entrypoint-core.sh (task 090). XDG_RUNTIME_DIR sits on the
# container's writable layer, so Podman state from an earlier container start
# survives a restart and makes every podman command fail; the entrypoint clears
# it once per container start.
#
# Booting the entrypoint needs an image, so the suite extracts the two functions
# it calls, powbox_container_start_id and powbox_clear_stale_podman_runtime, and
# runs them against fixture directories: what is cleared, what is kept, that a
# second run within one start clears nothing, and that a start that cannot be
# identified clears nothing. A static check pins the call site: inside the
# Podman block, after the image-store writer's exec, and before the storage
# driver is chosen. The live counterpart is the restart probe in
# scripts/smoke-test-podman.sh.
# The case patterns and call_text are literal source text, not expansions.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTRYPOINT="${SCRIPT_DIR}/../docker/shared/entrypoint-core.sh"

pass=0
fail=0
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		printf '       %s\n' "${@:2}"
	fi
}

FNS="$WORK_ROOT/fns.sh"
awk '/^powbox_container_start_id\(\) \{/,/^\}/; /^powbox_clear_stale_podman_runtime\(\) \{/,/^\}/' "$ENTRYPOINT" >"$FNS"
# shellcheck source=/dev/null
. "$FNS"
if ! declare -F powbox_container_start_id >/dev/null || ! declare -F powbox_clear_stale_podman_runtime >/dev/null; then
	echo "FATAL: could not extract the reset functions from $ENTRYPOINT" >&2
	exit 1
fi

# A runtime dir as an earlier start leaves it: Podman's subdirectories plus the
# sockets and locks other tools keep beside them.
make_runtime() {
	local d="$1"
	mkdir -p "$d/libpod/tmp/exits" "$d/containers/overlay-containers" "$d/crun/abc" "$d/netns" "$d/podman" \
		"$d/cc-socks" "$d/pnpm-dir-locks-1000" "$d/.dotnet"
	echo 4242 >"$d/libpod/tmp/pause.pid"
	: >"$d/libpod/tmp/alive"
	: >"$d/containers/auth.json"
	: >"$d/netns/netns-0000"
	: >"$d/podman/podman.sock"
	: >"$d/cc-socks/6.sock"
	: >"$d/pnpm-dir-locks-1000/lock"
}

podman_dirs_present() {
	local d="$1" sub n=0
	for sub in containers crun libpod netns podman; do
		if [ -e "$d/$sub" ] || [ -L "$d/$sub" ]; then
			n=$((n + 1))
		fi
	done
	echo "$n"
}

others_kept() {
	[ -e "$1/cc-socks/6.sock" ] && [ -e "$1/pnpm-dir-locks-1000/lock" ] && [ -d "$1/.dotnet" ]
}

echo "powbox_clear_stale_podman_runtime"

# 1. State from an earlier start and no marker: cleared, the rest kept.
d="$WORK_ROOT/no-marker"
make_runtime "$d"
err="$(powbox_clear_stale_podman_runtime "$d" "boot-1:100" 2>&1)"
if [ "$(podman_dirs_present "$d")" = 0 ]; then ok "no marker: Podman subdirectories removed"; else ko "no marker: Podman subdirectories removed" "left: $(ls -A "$d")"; fi
if others_kept "$d"; then ok "no marker: other tools' sockets and locks kept"; else ko "no marker: other tools' sockets and locks kept" "left: $(ls -A "$d")"; fi
if [ "$(cat "$d/.powbox-podman-start")" = "boot-1:100" ]; then ok "no marker: this start recorded"; else ko "no marker: this start recorded"; fi
case "$err" in
*"Note: cleared the Podman runtime state"*) ok "no marker: the clear is announced" ;;
*) ko "no marker: the clear is announced" "stderr: $err" ;;
esac

# 2. The marker names an earlier start: cleared.
d="$WORK_ROOT/old-marker"
make_runtime "$d"
echo "boot-1:100" >"$d/.powbox-podman-start"
powbox_clear_stale_podman_runtime "$d" "boot-1:200" 2>/dev/null
if [ "$(podman_dirs_present "$d")" = 0 ] && others_kept "$d"; then ok "earlier start's marker: state cleared"; else ko "earlier start's marker: state cleared" "left: $(ls -A "$d")"; fi
if [ "$(cat "$d/.powbox-podman-start")" = "boot-1:200" ]; then ok "earlier start's marker: replaced by this start"; else ko "earlier start's marker: replaced by this start"; fi

# 3. The marker names this start: a Podman of this start may be live, so
# nothing is touched, and nothing is announced.
d="$WORK_ROOT/same-start"
make_runtime "$d"
echo "boot-1:200" >"$d/.powbox-podman-start"
err="$(powbox_clear_stale_podman_runtime "$d" "boot-1:200" 2>&1)"
if [ "$(podman_dirs_present "$d")" = 5 ] && [ "$(cat "$d/libpod/tmp/pause.pid")" = 4242 ]; then ok "same start: live state untouched"; else ko "same start: live state untouched" "left: $(ls -A "$d")"; fi
if [ -z "$err" ]; then ok "same start: silent"; else ko "same start: silent" "stderr: $err"; fi

# 4. The start cannot be identified: nothing is cleared, with a warning.
d="$WORK_ROOT/unknown-start"
make_runtime "$d"
err="$(powbox_clear_stale_podman_runtime "$d" "" 2>&1)"
if [ "$(podman_dirs_present "$d")" = 5 ] && [ ! -e "$d/.powbox-podman-start" ]; then ok "unidentified start: nothing cleared, no marker"; else ko "unidentified start: nothing cleared, no marker" "left: $(ls -A "$d")"; fi
case "$err" in
*"Warning: cannot identify this container start"*) ok "unidentified start: warned" ;;
*) ko "unidentified start: warned" "stderr: $err" ;;
esac

# 5. A fresh runtime dir (first start of a new container): marker written, no note.
d="$WORK_ROOT/fresh"
mkdir -p "$d"
err="$(powbox_clear_stale_podman_runtime "$d" "boot-2:5" 2>&1)"
if [ "$(cat "$d/.powbox-podman-start")" = "boot-2:5" ] && [ -z "$err" ]; then ok "fresh dir: marker written silently"; else ko "fresh dir: marker written silently" "stderr: $err"; fi

# 6. A symlinked subdirectory: the link goes, what it points at stays.
d="$WORK_ROOT/symlink"
mkdir -p "$d" "$WORK_ROOT/outside"
: >"$WORK_ROOT/outside/keep"
ln -s "$WORK_ROOT/outside" "$d/libpod"
powbox_clear_stale_podman_runtime "$d" "boot-3:1" 2>/dev/null
if [ ! -e "$d/libpod" ] && [ ! -L "$d/libpod" ] && [ -e "$WORK_ROOT/outside/keep" ]; then ok "symlinked subdirectory: link removed, target kept"; else ko "symlinked subdirectory: link removed, target kept"; fi

# 7. A runtime dir whose marker cannot be written: warned, not fatal.
d="$WORK_ROOT/marker-unwritable"
make_runtime "$d"
mkdir -p "$d/.powbox-podman-start"
if err="$(powbox_clear_stale_podman_runtime "$d" "boot-4:1" 2>&1)"; then ok "unwritable marker: returns 0"; else ko "unwritable marker: returns 0"; fi
case "$err" in
*"Warning: could not write"*) ok "unwritable marker: warned" ;;
*) ko "unwritable marker: warned" "stderr: $err" ;;
esac

echo "powbox_container_start_id"

fake_proc() {
	local p="$1" stat="$2"
	mkdir -p "$p/sys/kernel/random" "$p/1"
	echo "d3adb33f-0000-4000-8000-000000000001" >"$p/sys/kernel/random/boot_id"
	printf '%s\n' "$stat" >"$p/1/stat"
}

# Field 22 is the start time; the command name may hold spaces and ')'.
p="$WORK_ROOT/proc-plain"
fake_proc "$p" "1 (docker-init) S 0 1 1 34816 1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 98765 1056768 1 18446744073709551615"
got="$(powbox_container_start_id "$p")"
if [ "$got" = "d3adb33f-0000-4000-8000-000000000001:98765" ]; then ok "start id: boot id plus PID 1 start time"; else ko "start id: boot id plus PID 1 start time" "got: $got"; fi

p="$WORK_ROOT/proc-odd-comm"
fake_proc "$p" "1 (a b) c) S 0 1 1 34816 1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 4321 1056768 1 18446744073709551615"
got="$(powbox_container_start_id "$p")"
if [ "$got" = "d3adb33f-0000-4000-8000-000000000001:4321" ]; then ok "start id: command name with spaces and ')'"; else ko "start id: command name with spaces and ')'" "got: $got"; fi

p="$WORK_ROOT/proc-no-stat"
fake_proc "$p" "x"
rm -f "$p/1/stat"
got="$(powbox_container_start_id "$p")"
if [ -z "$got" ]; then ok "start id: empty without /proc/1/stat"; else ko "start id: empty without /proc/1/stat" "got: $got"; fi

p="$WORK_ROOT/proc-no-boot"
fake_proc "$p" "1 (init) S 0 1 1 34816 1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 4321 1056768 1"
rm -f "$p/sys/kernel/random/boot_id"
got="$(powbox_container_start_id "$p")"
if [ -z "$got" ]; then ok "start id: empty without a boot id"; else ko "start id: empty without a boot id" "got: $got"; fi

p="$WORK_ROOT/proc-short-stat"
fake_proc "$p" "1 (init) S 0 1"
got="$(powbox_container_start_id "$p")"
if [ -z "$got" ]; then ok "start id: empty for a truncated stat line"; else ko "start id: empty for a truncated stat line" "got: $got"; fi

got="$(powbox_container_start_id)"
case "$got" in
?*:[0-9]*) ok "start id: readable from this host's /proc" ;;
*) ko "start id: readable from this host's /proc" "got: $got" ;;
esac

echo "call site"

# The call must sit in the Podman block, after the writer's exec (the writer
# never restarts) and before the storage driver is chosen, guarded on a prepared
# runtime dir.
block="$(awk '/^if command -v podman >\/dev\/null 2>&1; then$/,/^fi$/' "$ENTRYPOINT")"
writer_line="" call_line="" guard_line="" driver_line="" n=0 prev=""
call_text='powbox_clear_stale_podman_runtime "$_xdg" "$(powbox_container_start_id)"'
while IFS= read -r line; do
	n=$((n + 1))
	case "$line" in
	*'POWBOX_IMAGE_STORE_ROLE:-}" = "writer"'*) [ -n "$writer_line" ] || writer_line=$n ;;
	*"$call_text"*)
		if [ -z "$call_line" ]; then
			call_line=$n
			case "$prev" in *'"$_xdg_ready" = true'*) guard_line=$((n - 1)) ;; esac
		fi
		;;
	*'_driver_marker='*) [ -n "$driver_line" ] || driver_line=$n ;;
	esac
	prev="$line"
done <<<"$block"
if [ -n "$writer_line" ] && [ -n "$call_line" ] && [ -n "$driver_line" ] &&
	[ "$writer_line" -lt "$call_line" ] && [ "$call_line" -lt "$driver_line" ]; then
	ok "call site: in the Podman block, after the writer branch, before the driver choice"
else
	ko "call site: in the Podman block, after the writer branch, before the driver choice" \
		"writer=$writer_line call=$call_line driver=$driver_line"
fi
if [ -n "$guard_line" ]; then
	ok "call site: guarded on a prepared runtime dir"
else
	ko "call site: guarded on a prepared runtime dir"
fi

echo
echo "podman runtime reset: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
