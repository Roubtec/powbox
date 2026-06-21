#!/usr/bin/env bash
# Unit tests for docker/shared/pnpm-shadow-wrapper.sh.
#
# Focus: the task-002b regression guard. When a folder is launched as NON-dev
# (no package.json/pnpm-workspace.yaml/.powbox.yml at launch) the launcher mounts
# no isolated root node_modules volume and sets no PNPM_STORE_DIR; if the user then
# scaffolds a JS project mid-session and runs a ROOT install, node_modules would
# land straight on the host bind mount. The wrapper cannot retrofit the missing
# mount, so it must print exactly ONE loud stderr warning (and still proceed) in
# that case — and must stay SILENT for a self-hosted run, an already-mounted
# dir-mounted dev project, a subpackage install, a store-only command like `pnpm
# fetch` (install-class, but it never writes node_modules), and a non-install command.
#
# Runs the real repo copy of the wrapper directly — no image build. mountpoint and
# shadow-refresh.sh are stubbed on a front-of-PATH dir so the mount answer is
# deterministic and the shadow refresh is a hermetic no-op; the wrapper's terminal
# `exec pnpm …` is harmless here (the warning is emitted BEFORE it, so the test
# does not depend on pnpm being installed). The wrapper hard-requires its effective
# dir to live under /workspace (its production contract), so the fixture workspace
# is created there; the stage self-skips when /workspace is not writable (i.e. when
# not run inside a powbox-style container).
#
# Usage: scripts/test-pnpm-shadow-wrapper.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/../docker/shared/pnpm-shadow-wrapper.sh"

if [ ! -f "$WRAPPER" ]; then
	echo "FATAL: pnpm-shadow-wrapper.sh not found at $WRAPPER" >&2
	exit 1
fi

# Stable substring of the regression warning the wrapper emits to stderr.
WARN_NEEDLE="root node_modules is NOT an isolated volume"

# The wrapper only acts under /workspace (its production path contract), so the
# fixture must live there. Self-skip cleanly where that is impossible — a generic
# dev box or CI runner without /workspace — like the other smoke stages do.
if ! WS="$(mktemp -d /workspace/powbox-wrapper-smoke-XXXXXX 2>/dev/null)"; then
	echo "pnpm-shadow-wrapper test skipped: cannot create a fixture under /workspace (run inside a powbox container)."
	exit 0
fi

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$WS" "$STUB_DIR"' EXIT

# Stub mountpoint: returns POWBOX_TEST_MP_RESULT verbatim (1 = NOT a mountpoint,
# the non-dev regression shape; 0 = a mountpoint, the dev-project shape). The
# wrapper only ever calls `mountpoint -q <path>`, so the args are irrelevant here.
cat >"$STUB_DIR/mountpoint" <<'STUB'
#!/usr/bin/env bash
exit "${POWBOX_TEST_MP_RESULT:-1}"
STUB

# Stub shadow-refresh.sh: a no-op so the test never depends on real shadow/sudo/mount
# machinery (and the warning, which is emitted independently of it, is isolated).
cat >"$STUB_DIR/shadow-refresh.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_DIR/mountpoint" "$STUB_DIR/shadow-refresh.sh"

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}
ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
}

# wrapper_stderr <cwd> <mp_result> <store_dir> <self_hosted> [wrapper-args...]
# Run the real wrapper with a controlled cwd, mountpoint answer, and env, and echo
# only its stderr. Both env vars are set EXPLICITLY every call so the ambient
# container env (this test runs inside a real powbox container, which may export
# PNPM_STORE_DIR) can never leak into a case. Default args exercise a ROOT install
# that does not actually install (`install --help` exits 0, writes no node_modules).
wrapper_stderr() {
	local cwd="$1" mp="$2" store="$3" self="$4"
	shift 4
	local -a args=("$@")
	[ "${#args[@]}" -gt 0 ] || args=(install --help)
	# Discard the wrapper's stdout (its terminal `exec pnpm …`) and capture only its
	# stderr: `>/dev/null` on the inner command, `2>&1` on the subshell. The trailing
	# `|| true` keeps this non-fatal under `set -e`: the test asserts only on stderr
	# content, never on the wrapper's exit code (dominated by its terminal `exec pnpm`),
	# so the stage stays hermetic and pnpm-independent as documented in the header.
	(
		cd "$cwd" || exit 1
		PATH="$STUB_DIR:$PATH" \
			POWBOX_TEST_MP_RESULT="$mp" \
			PNPM_STORE_DIR="$store" \
			POWBOX_SELF_HOSTED="$self" \
			bash "$WRAPPER" "${args[@]}" >/dev/null
	) 2>&1 || true
}

# assert_warns / assert_no_warn <stderr> <msg>
assert_warns() {
	if printf '%s' "$1" | grep -qF "$WARN_NEEDLE"; then
		ok "$2"
	else
		ko "$2 (expected the regression warning on stderr)"
	fi
}
assert_no_warn() {
	if printf '%s' "$1" | grep -qF "$WARN_NEEDLE"; then
		ko "$2 (did NOT expect the regression warning on stderr)"
	else
		ok "$2"
	fi
}

# Exactly one warning line — never a duplicate.
assert_warns_once() {
	local n
	# `grep -cF` exits 1 (printing `0`) when there are no matches; `|| true` keeps the
	# count substitution non-fatal under `set -e` so a zero-match case is asserted as a
	# normal `ko`, not an abort.
	n="$(printf '%s\n' "$1" | grep -cF "$WARN_NEEDLE" || true)"
	if [ "$n" -eq 1 ]; then
		ok "$2"
	else
		ko "$2 (expected exactly 1 warning line, got $n)"
	fi
}

echo "Test: non-dev folder, mid-session ROOT install -> warns (the regression case)"
err="$(wrapper_stderr "$WS" 1 "" "")"
assert_warns "$err" "root install with no volume + no PNPM_STORE_DIR warns"
assert_warns_once "$err" "the warning is emitted exactly once"

echo "Test: dir-mounted dev project (root node_modules IS a mountpoint) -> silent"
err="$(wrapper_stderr "$WS" 0 "" "")"
assert_no_warn "$err" "an already-mounted root node_modules does not warn"

echo "Test: dir-mounted dev project (PNPM_STORE_DIR set) -> silent"
err="$(wrapper_stderr "$WS" 1 "$WS/.worktrees/.pnpm-store" "")"
assert_no_warn "$err" "a launch that set PNPM_STORE_DIR does not warn"

echo "Test: self-hosted (--isolated) run -> silent"
# Self-hosted always sets PNPM_STORE_DIR too, but assert the early POWBOX_SELF_HOSTED
# return on its own by leaving the store empty: it must still not warn.
err="$(wrapper_stderr "$WS" 1 "" "1")"
assert_no_warn "$err" "POWBOX_SELF_HOSTED=1 short-circuits before the warning"

echo "Test: subpackage install (effdir != workspace root) -> silent"
mkdir -p "$WS/packages/foo"
err="$(wrapper_stderr "$WS/packages/foo" 1 "" "")"
assert_no_warn "$err" "a non-root (subpackage) install does not warn"

echo "Test: store-only 'fetch' in the warning-shaped condition -> silent"
# `pnpm fetch` is install-class (it warms the pnpm store, so it still triggers a
# shadow refresh) but it ONLY populates the store from the lockfile — it never writes
# the root node_modules onto the host bind mount. So in the SAME non-dev / non-mounted
# / no-PNPM_STORE_DIR condition that makes a `pnpm install` warn, `pnpm fetch` must
# stay silent. `fetch --help` exits 0 and touches nothing; the gate is evaluated
# before the terminal exec, so this stays hermetic.
err="$(wrapper_stderr "$WS" 1 "" "" fetch --help)"
assert_no_warn "$err" "a store-only 'fetch' does not warn even in the regression-shaped condition"

echo "Test: non-install command (no node_modules write) -> silent"
err="$(wrapper_stderr "$WS" 1 "" "" --version)"
assert_no_warn "$err" "a command with no install-class token does not warn"

echo "Test: 'install' as an ARGUMENT, not the subcommand -> silent"
# False-positive guard: the wrapper keys the warning off the RESOLVED pnpm subcommand
# (first positional token), so an install-class word that is merely an argument must not
# trip it. `pnpm run install` runs a package script NAMED `install`; `pnpm exec install`
# execs a command NAMED `install` — in both the real subcommand is `run`/`exec`, which
# writes no root node_modules. In the exact regression-shaped condition (non-dev, no
# PNPM_STORE_DIR, not a mountpoint, at the workspace root) that makes a true `pnpm
# install` warn, both must stay silent. The gate is evaluated before the terminal exec,
# so this stays hermetic regardless of what (if anything) the script/command does.
err="$(wrapper_stderr "$WS" 1 "" "" run install)"
assert_no_warn "$err" "'pnpm run install' (install is a run-script name) does not warn"
err="$(wrapper_stderr "$WS" 1 "" "" exec install)"
assert_no_warn "$err" "'pnpm exec install' (install is an exec'd command name) does not warn"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
