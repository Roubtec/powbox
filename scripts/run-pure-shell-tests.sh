#!/usr/bin/env bash
# Run every source-level scripts/test-*.sh suite that is hermetic on a native-
# Linux CI host. New suites join this runner automatically; the small routed
# exception list below is deliberately checked so a rename/removal cannot leave
# stale classification behind.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# These suites are still automatic, but their real home is Tier 1:
#
# - test-gh-review-threads.sh needs the helper fetched from the separately
#   versioned agent-skills repository (or its baked /usr/local/bin copy).
# - test-pg-dev-up-scoped.sh starts real PostgreSQL daemons and needs the server
#   binaries baked into the agent image.
# - test-pnpm-shadow-wrapper.sh must create its fixture below the production
#   /workspace root, which an arbitrary host checkout does not provide.
#
# commands/smoke-test.sh runs all three with the built image. Keep this list in
# step with that routing; everything not listed here is selected by the glob.
routed_to_tier1=(
	test-gh-review-threads.sh
	test-pg-dev-up-scoped.sh
	test-pnpm-shadow-wrapper.sh
)

declare -A routed=()
for name in "${routed_to_tier1[@]}"; do
	routed["$name"]=1
	if [ ! -f "$SCRIPT_DIR/$name" ]; then
		echo "FATAL: routed Tier 1 suite is missing: scripts/$name" >&2
		exit 1
	fi
done

shopt -s nullglob
all_suites=("$SCRIPT_DIR"/test-*.sh)
if [ "${#all_suites[@]}" -eq 0 ]; then
	echo "FATAL: no scripts/test-*.sh suites found" >&2
	exit 1
fi

suites=()
for suite in "${all_suites[@]}"; do
	name="${suite##*/}"
	[ -n "${routed[$name]:-}" ] || suites+=("$suite")
done

if [ "${#suites[@]}" -eq 0 ]; then
	echo "FATAL: no Tier 0 pure-shell suites selected" >&2
	exit 1
fi

# Run in parallel: the suites use private mktemp fixtures, and the slowest ones
# are intentionally independent. Capture each log separately so parallel output
# never interleaves and a failure is headed by the exact suite name.
work_root="$(mktemp -d "${TMPDIR:-/tmp}/powbox-pure-shell-tests.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

pids=()
names=()
for suite in "${suites[@]}"; do
	name="${suite##*/}"
	names+=("$name")
	(
		started=$SECONDS
		rc=0
		bash "$suite" >"$work_root/$name.log" 2>&1 || rc=$?
		printf '%s\n' "$rc" >"$work_root/$name.rc"
		printf '%s\n' "$((SECONDS - started))" >"$work_root/$name.seconds"
	) &
	pids+=("$!")
done

failures=0
for i in "${!pids[@]}"; do
	wait "${pids[$i]}"
	name="${names[$i]}"
	rc="$(cat "$work_root/$name.rc")"
	seconds="$(cat "$work_root/$name.seconds")"
	if [ "$rc" -eq 0 ]; then
		printf '\n===== PASS: scripts/%s (%ss) =====\n' "$name" "$seconds"
	else
		printf '\n===== FAIL: scripts/%s (exit %s, %ss) =====\n' "$name" "$rc" "$seconds" >&2
		failures=$((failures + 1))
	fi
	cat "$work_root/$name.log"
done

printf '\nPure-shell Tier 0 suites: %s completed, %s failed; %s routed to Tier 1.\n' \
	"${#suites[@]}" "$failures" "${#routed_to_tier1[@]}"
[ "$failures" -eq 0 ]
