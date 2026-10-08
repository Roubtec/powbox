#!/usr/bin/env bash
# Hermetic test that scripts/launch-agent.sh never reads past its final
# `docker compose run` once the session ends.
#
# Bash reads a script one command at a time from a byte offset into the open
# file. The final run lasts the whole agent session, and if the launcher is
# rewritten in place meanwhile (an editor save, a checkout through a layer that
# keeps the inode), the next read lands at the old end-of-file offset in the new
# content and executes whatever fragment sits there — reported as
# `launch-agent.sh: line 2075: ault: command not found`, the tail of "default"
# from a comment. The launcher wraps the run and an `exit` in a brace group,
# which bash parses whole before running it.
#
# Driving the real launcher that far would mean answering every Docker call
# before it, so the suite extracts the final brace group and runs it in a small
# harness whose fake `docker` rewrites the harness file in place, putting a
# marker command past the old end of file. The group must stop before the
# marker, preserve the run's exit status, and still fire the EXIT trap. A
# control run of the same block without the group must reach the marker, which
# proves the harness reproduces the hazard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LAUNCH_SH="${ROOT_DIR}/scripts/launch-agent.sh"

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

# The final block: from the `{` line that opens the group around the session's
# `docker compose "${FINAL_COMPOSE_ARGS[@]}" run` to the end of the file.
BLOCK="${WORK_ROOT}/block.sh"
awk '
	/^\{$/ { buf = $0 "\n"; open = 1; next }
	open && !found && /docker compose "\$\{FINAL_COMPOSE_ARGS\[@\]\}" run/ { found = 1 }
	open && !found && !/^\t/ { open = 0; buf = "" }
	open { buf = buf $0 "\n" }
	END { if (found) printf "%s", buf }
' "$LAUNCH_SH" >"$BLOCK"

echo "launch-agent.sh final block"
if [ ! -s "$BLOCK" ]; then
	ko "the final compose run sits in a top-level { ... } group" \
		"no '{' line directly opening a group around docker compose \"\${FINAL_COMPOSE_ARGS[@]}\" run"
	printf '\n%d passed, %d failed\n' "$pass" "$fail"
	exit 1
fi
ok "the final compose run sits in a top-level { ... } group"

if [ "$(tail -n 1 "$BLOCK")" = "}" ] && [ "$(tail -n 2 "$BLOCK" | head -n 1)" = $'\texit' ]; then
	ok "the group ends the file with exit then }"
else
	ko "the group ends the file with exit then }" "last lines: $(tail -n 2 "$BLOCK" | tr '\n' '|')"
fi

# The same block without the group: drop the `{`, `exit` and `}` lines and one
# level of indentation. This is the shape that was vulnerable.
UNWRAPPED="${WORK_ROOT}/unwrapped.sh"
sed -e '1d' -e '$d' "$BLOCK" | sed -e '$d' -e 's/^\t//' >"$UNWRAPPED"

# Every variable the block expands is declared empty (arrays as arrays), so the
# harness runs under the launcher's own `set -euo pipefail`.
declarations() {
	grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}' "$1" | sed -E 's/^\$\{([^[]*)\[@\]\}$/\1=()/' | sort -u
	grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$1" | sed -E 's/^\$\{(.*)\}$/\1=x/' | sort -u
	# shellcheck disable=SC2016 # matches a literal "$NAME" in the block
	grep -oE '"\$[A-Za-z_][A-Za-z0-9_]*"' "$1" | sed -E 's/^"\$(.*)"$/\1=x/' | sort -u
}

# run_harness <block-file> <docker-exit-status>
# Builds a harness from <block-file>, runs it, and sets HARNESS_RC plus the
# INJECTED and TRAPPED flags.
run_harness() {
	local block="$1" docker_rc="$2"
	local dir harness
	dir="$(mktemp -d "${WORK_ROOT}/run.XXXXXX")"
	harness="${dir}/harness.sh"
	{
		printf 'set -euo pipefail\n'
		printf 'trap %q EXIT\n' "touch '${dir}/trapped'"
		declarations "$block"
		# The fake docker stands in for the hours-long session: it rewrites the
		# harness in place (same inode) so everything up to the old end of file
		# is filler and a marker command sits just past it.
		printf 'docker() {\n'
		printf '\tlocal size\n'
		# shellcheck disable=SC2016 # $(...) runs in the harness, not here
		printf '\tsize=$(wc -c <%q)\n' "$harness"
		# shellcheck disable=SC2016 # $size expands in the harness, not here
		printf '\t{ head -c "$size" /dev/zero | tr %q %q; printf %q; } 1<>%q\n' \
			'\0' '#' "\ntouch '${dir}/injected'\n" "$harness"
		printf '\treturn %d\n' "$docker_rc"
		printf '}\n'
		cat "$block"
	} >"$harness"
	HARNESS_RC=0
	bash "$harness" >/dev/null 2>&1 || HARNESS_RC=$?
	INJECTED=false
	TRAPPED=false
	[ ! -e "${dir}/injected" ] || INJECTED=true
	[ ! -e "${dir}/trapped" ] || TRAPPED=true
}

echo
echo "in-place rewrite during the session"

run_harness "$UNWRAPPED" 0
if [ "$INJECTED" = true ]; then
	ok "control: without the group, bash runs what the rewrite put past the old end"
else
	ko "control: without the group, bash runs what the rewrite put past the old end" \
		"the harness no longer reproduces the hazard, so the checks below prove nothing"
fi

run_harness "$BLOCK" 0
if [ "$INJECTED" = false ]; then
	ok "the grouped block never reads past itself after a clean exit"
else
	ko "the grouped block never reads past itself after a clean exit" "the marker past the old end of file ran"
fi
if [ "$HARNESS_RC" -eq 0 ]; then
	ok "a clean session exits 0"
else
	ko "a clean session exits 0" "exit status ${HARNESS_RC}"
fi
if [ "$TRAPPED" = true ]; then
	ok "the EXIT trap still fires"
else
	ko "the EXIT trap still fires"
fi

run_harness "$BLOCK" 7
if [ "$INJECTED" = false ] && [ "$HARNESS_RC" -eq 7 ]; then
	ok "a failed session keeps its exit status and never reads past the group"
else
	ko "a failed session keeps its exit status and never reads past the group" \
		"exit status ${HARNESS_RC}, marker ran: ${INJECTED}"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
