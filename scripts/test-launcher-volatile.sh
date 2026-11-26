#!/usr/bin/env bash
# Hermetic tests for --volatile / -Volatile in scripts/launch-agent.sh and its
# twin scripts/launch-agent.ps1, driven end to end against a fake `docker`.
#
# Container names are deterministic per project and agent, so a volatile launch
# meets the container a default launch left behind. The fake docker keeps that
# one container's state (absent, stopped or running) in a file and behaves like
# the real CLI where it matters: `rm` refuses a running container, and the
# agent's `compose run --name` fails with a name conflict while a container of
# that name exists. A `run --rm` leaves nothing behind once the session ends,
# a detached run leaves the container running, and any other run leaves it
# stopped. Every call is logged.
#
# Pinned here:
# - a stopped container is replaced (removed, then a fresh --rm one created);
# - a running container is refused, never removed, attached or started;
# - with no container there is nothing to remove;
# - after a volatile launch the next default launch creates a persistent one;
# - --persist keeps the fresh container, --detach still removes it on exit;
# - --volatile with --resume is refused before any Docker call;
# - self-hosted (--isolated, --reclone) never removes an agent-ws-* volume.
#
# Without pwsh the PowerShell half reports an honest skip.
# shellcheck disable=SC2030,SC2031 # PATH is only ever changed inside subshells.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0
skip=0
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

skipped() {
	skip=$((skip + 1))
	printf '  skip %s\n' "$1"
}

assert_eq() {
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		ko "$1" "expected: $3" "actual:   $2"
	fi
}

# Match in-process: a `printf | grep -q` pipeline lets grep exit at the first
# match while printf is still writing, which pipefail reports as a failure.
assert_contains() {
	if [[ "$2" == *"$3"* ]]; then
		ok "$1"
	else
		ko "$1" "missing: $3" "in:      $2"
	fi
}

assert_not_contains() {
	if [[ "$2" == *"$3"* ]]; then
		ko "$1" "unexpected: $3" "in:         $2"
	else
		ok "$1"
	fi
}

HAVE_PWSH=false
if command -v pwsh >/dev/null 2>&1; then
	HAVE_PWSH=true
fi

# PowerShell error records are colored and wrapped at the console width; strip
# both so a message can be matched as one line.
norm() {
	sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr '\r\n' '  ' | sed -e 's/ *| */ /g' -e 's/  */ /g'
}

# A fixture checkout, so the real checkout's .powbox-egress never leaks in.
CHECKOUT="$WORK_ROOT/checkout"
mkdir -p "$CHECKOUT/scripts" "$CHECKOUT/docker/shared" "$WORK_ROOT/ws"
cp "${ROOT_DIR}/scripts/launch-agent.sh" "${ROOT_DIR}/scripts/launch-agent.ps1" "$CHECKOUT/scripts/"
cp "${ROOT_DIR}/docker/shared/egress-rules.sh" "$CHECKOUT/docker/shared/"
cp "${ROOT_DIR}"/compose*.yml "$CHECKOUT/"
WS="$(cd "$WORK_ROOT/ws" && pwd -P)"

FAKE_BIN="$WORK_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/docker" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_LOG"
state="$(cat "$FAKE_STATE")"
case "$1" in
container | inspect)
	# `container inspect [--format ...] <name>` and `inspect [--format ...] <name>`.
	case "$*" in
	*State.Running*)
		[ "$state" != absent ] || exit 1
		[ "$state" = running ] && echo true || echo false
		;;
	*powbox.continue*) echo false ;;
	*/home/node/.local/share/containers*) echo yes ;;
	*"--format"*) ;;
	*) [ "$state" != absent ] || exit 1 ;;
	esac
	;;
rm)
	if [ "$state" = running ]; then
		echo "Error response from daemon: cannot remove container: container is running" >&2
		exit 1
	fi
	echo absent >"$FAKE_STATE"
	;;
start)
	# `start -ai` holds the session and returns when it ends; a detached start
	# leaves it running.
	case " $* " in
	*" -ai "*) echo stopped >"$FAKE_STATE" ;;
	*) echo running >"$FAKE_STATE" ;;
	esac
	;;
image)
	case "$*" in
	*powbox.base.selfhosted*) echo 1 ;;
	esac
	;;
compose)
	case " $* " in
	*" --name "*)
		if [ "$state" != absent ]; then
			echo "Error response from daemon: Conflict. The container name is already in use by container \"0123abcd\"." >&2
			exit 1
		fi
		case " $* " in
		*" -d "*) echo running >"$FAKE_STATE" ;;
		*" --rm "*) echo absent >"$FAKE_STATE" ;;
		*) echo stopped >"$FAKE_STATE" ;;
		esac
		;;
	esac
	;;
esac
exit 0
SH
chmod +x "$FAKE_BIN/docker"
FAKE_LOG="$WORK_ROOT/docker.log"
FAKE_STATE="$WORK_ROOT/state"

# launch <sh|ps1> <args...>: run the fixture checkout's launcher against the
# fake docker; leaves L_RC, L_OUT (normalized output) and L_LOG (docker calls).
# Bash-style flags are translated for the PowerShell launcher.
launch() {
	local which="$1"
	shift
	local -a args=("$@")
	: >"$FAKE_LOG"
	set +e
	if [ "$which" = sh ]; then
		L_OUT="$(FAKE_LOG="$FAKE_LOG" FAKE_STATE="$FAKE_STATE" PATH="$FAKE_BIN:$PATH" POWBOX_PODMAN=off \
			GIT_CONFIG_PATH="$WORK_ROOT/no-gitconfig" GH_HOST_CONFIG_DIR="$WORK_ROOT/no-gh" \
			bash "$CHECKOUT/scripts/launch-agent.sh" codex "${args[@]}" </dev/null 2>&1)"
		L_RC=$?
	else
		local i
		for i in "${!args[@]}"; do
			case "${args[$i]}" in
			--volatile) args[i]=-Volatile ;;
			--persist) args[i]=-Persist ;;
			--detach) args[i]=-Detach ;;
			--resume) args[i]=-Resume ;;
			--isolated) args[i]=-Isolated ;;
			--repo) args[i]=-Repo ;;
			--name) args[i]=-Name ;;
			--reclone) args[i]=-Reclone ;;
			esac
		done
		L_OUT="$(FAKE_LOG="$FAKE_LOG" FAKE_STATE="$FAKE_STATE" PATH="$FAKE_BIN:$PATH" POWBOX_PODMAN=off \
			GIT_CONFIG_PATH="$WORK_ROOT/no-gitconfig" GH_HOST_CONFIG_DIR="$WORK_ROOT/no-gh" \
			pwsh -NoProfile -NonInteractive -File "$CHECKOUT/scripts/launch-agent.ps1" codex "${args[@]}" </dev/null 2>&1)"
		L_RC=$?
	fi
	set -e
	L_OUT="$(printf '%s' "$L_OUT" | norm)"
	L_LOG="$(cat "$FAKE_LOG")"
}

# log_has <command>: whether the fake docker was called as `docker <command> ...`.
log_has() {
	grep -q "^$1 " <<<"$L_LOG"
}

# The agent's own `compose ... run ... --name` call (not the volume-prep run),
# padded with spaces so a flag can be matched as " --rm ".
agent_run() {
	local run
	run="$(printf '%s\n' "$L_LOG" | grep -E '^compose .* run .*--name ' || true)"
	[ -z "$run" ] || printf ' %s ' "$run"
}

# The flags `compose run` got before --name (so an argument further on, such
# as a CMD word, can never pass for one).
run_flags() {
	local run
	run="$(agent_run)"
	printf '%s' "${run%%--name *}"
}

state() {
	cat "$FAKE_STATE"
}

# expect_replaced <what>: the stopped container was removed with a message and
# a fresh one created in its place, without a name conflict.
expect_replaced() {
	assert_eq "$1: exit status" "$L_RC" 0
	if log_has rm; then ok "$1: removes the stopped container"; else ko "$1: removes the stopped container" "$L_LOG"; fi
	assert_contains "$1: says so" "$L_OUT" "olatile: replacing the stopped container"
	if [ -n "$(agent_run)" ]; then ok "$1: creates a fresh container"; else ko "$1: creates a fresh container" "$L_LOG"; fi
	assert_not_contains "$1: no name conflict" "$L_OUT" "Conflict"
	if log_has start || log_has attach; then ko "$1: neither starts nor attaches the old one" "$L_LOG"; else ok "$1: neither starts nor attaches the old one"; fi
}

for which in sh ps1; do
	if [ "$which" = ps1 ] && ! $HAVE_PWSH; then
		skipped "pwsh unavailable - launch-agent.ps1 volatile cases not run"
		continue
	fi
	t="[$which]"

	echo "Test: $t --volatile with no container"
	echo absent >"$FAKE_STATE"
	launch "$which" "$WS" --volatile
	assert_eq "$t no container: exit status" "$L_RC" 0
	if log_has rm; then ko "$t no container: removes nothing" "$L_LOG"; else ok "$t no container: removes nothing"; fi
	assert_contains "$t no container: the run is --rm" "$(run_flags)" " --rm "
	assert_eq "$t no container: nothing is left behind" "$(state)" absent

	echo "Test: $t --volatile replaces a stopped container"
	echo stopped >"$FAKE_STATE"
	launch "$which" "$WS" --volatile
	expect_replaced "$t stopped"
	assert_contains "$t stopped: the run is --rm" "$(run_flags)" " --rm "
	assert_not_contains "$t stopped: the run is attached" "$(run_flags)" " -d "
	assert_eq "$t stopped: nothing is left behind" "$(state)" absent

	echo "Test: $t --volatile refuses a running container"
	echo running >"$FAKE_STATE"
	launch "$which" "$WS" --volatile
	if [ "$L_RC" -ne 0 ]; then ok "$t running: refuses"; else ko "$t running: refuses" "$L_OUT"; fi
	assert_contains "$t running: says to stop it first" "$L_OUT" "is running; stop it before"
	if log_has rm; then ko "$t running: removes nothing" "$L_LOG"; else ok "$t running: removes nothing"; fi
	if log_has start || log_has attach; then ko "$t running: neither starts nor attaches" "$L_LOG"; else ok "$t running: neither starts nor attaches"; fi
	assert_eq "$t running: creates nothing" "$(agent_run)" ""
	assert_eq "$t running: the session keeps running" "$(state)" running

	echo "Test: $t default, then volatile, then default again"
	echo absent >"$FAKE_STATE"
	launch "$which" "$WS"
	assert_eq "$t first default: exit status" "$L_RC" 0
	assert_not_contains "$t first default: the run is not --rm" "$(run_flags)" " --rm "
	assert_eq "$t first default: leaves a stopped container" "$(state)" stopped
	launch "$which" "$WS"
	assert_eq "$t second default: exit status" "$L_RC" 0
	if log_has "start"; then ok "$t second default: reuses the stopped container"; else ko "$t second default: reuses the stopped container" "$L_LOG"; fi
	assert_eq "$t second default: creates nothing" "$(agent_run)" ""
	launch "$which" "$WS" --volatile
	expect_replaced "$t volatile after default"
	assert_eq "$t volatile after default: nothing is left behind" "$(state)" absent
	launch "$which" "$WS"
	assert_eq "$t default after volatile: exit status" "$L_RC" 0
	if log_has rm; then ko "$t default after volatile: removes nothing" "$L_LOG"; else ok "$t default after volatile: removes nothing"; fi
	if [ -n "$(agent_run)" ]; then ok "$t default after volatile: creates a container"; else ko "$t default after volatile: creates a container" "$L_LOG"; fi
	assert_not_contains "$t default after volatile: the run is not --rm" "$(run_flags)" " --rm "
	assert_eq "$t default after volatile: it persists" "$(state)" stopped

	echo "Test: $t --volatile --persist keeps the fresh container"
	echo stopped >"$FAKE_STATE"
	launch "$which" "$WS" --volatile --persist
	expect_replaced "$t persist"
	assert_not_contains "$t persist: the run is not --rm" "$(run_flags)" " --rm "
	assert_eq "$t persist: the fresh container is kept" "$(state)" stopped

	echo "Test: $t --volatile --detach is still removed on exit"
	echo stopped >"$FAKE_STATE"
	launch "$which" "$WS" --volatile --detach
	expect_replaced "$t detach"
	assert_contains "$t detach: the run is detached" "$(run_flags)" " -d "
	assert_contains "$t detach: the run is --rm" "$(run_flags)" " --rm "
	echo absent >"$FAKE_STATE"
	launch "$which" "$WS" --detach
	assert_contains "$t plain detach: the run is detached" "$(run_flags)" " -d "
	assert_not_contains "$t plain detach: the run is not --rm" "$(run_flags)" " --rm "

	echo "Test: $t --volatile with --resume is refused before Docker"
	for st in stopped running; do
		echo "$st" >"$FAKE_STATE"
		launch "$which" "$WS" --volatile --resume
		if [ "$L_RC" -ne 0 ]; then ok "$t resume, $st: refuses"; else ko "$t resume, $st: refuses" "$L_OUT"; fi
		assert_contains "$t resume, $st: says they contradict" "$L_OUT" "contradict each other"
		assert_eq "$t resume, $st: calls no docker" "$L_LOG" ""
		assert_eq "$t resume, $st: the container is untouched" "$(state)" "$st"
	done

	echo "Test: $t self-hosted keeps the workspace volume"
	echo stopped >"$FAKE_STATE"
	launch "$which" --isolated --repo example/repo --name keep --volatile
	expect_replaced "$t isolated"
	assert_contains "$t isolated: the run is --rm" "$(run_flags)" " --rm "
	assert_not_contains "$t isolated: no volume is removed" "$L_LOG" "volume rm"
	assert_not_contains "$t isolated: the volume is not wiped" "$L_LOG" "find /mnt/workspace"
	if grep -qE '^rm .*(-v|--volumes)' <<<"$L_LOG"; then ko "$t isolated: rm keeps volumes" "$L_LOG"; else ok "$t isolated: rm keeps volumes"; fi
	echo stopped >"$FAKE_STATE"
	launch "$which" --isolated --repo example/repo --name keep --reclone --volatile
	expect_replaced "$t isolated reclone"
	assert_eq "$t isolated reclone: removes the container once" "$(grep -c '^rm ' <<<"$L_LOG")" 1
	assert_contains "$t isolated reclone: still wipes the checkout for a fresh clone" "$L_LOG" "find /mnt/workspace"
	assert_not_contains "$t isolated reclone: no volume is removed" "$L_LOG" "volume rm"
	assert_contains "$t isolated reclone: the run is --rm" "$(run_flags)" " --rm "
	echo running >"$FAKE_STATE"
	launch "$which" --isolated --repo example/repo --name keep --reclone --volatile
	if [ "$L_RC" -ne 0 ]; then ok "$t isolated reclone, running: refuses"; else ko "$t isolated reclone, running: refuses" "$L_OUT"; fi
	if log_has rm; then ko "$t isolated reclone, running: removes nothing" "$L_LOG"; else ok "$t isolated reclone, running: removes nothing"; fi
	assert_not_contains "$t isolated reclone, running: wipes nothing" "$L_LOG" "find /mnt/workspace"
done

echo
echo "launcher volatile tests: ${pass} passed, ${fail} failed, ${skip} skipped"
[ "$fail" -eq 0 ]
