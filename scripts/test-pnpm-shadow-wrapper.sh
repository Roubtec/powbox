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

echo "Test: a value-taking global flag BEFORE the subcommand -> still warns (task-002b gap)"
# Regression for the codex review on PR #70: the subcommand resolver must step past a
# value-taking global flag and its VALUE, or it misreads the value as the subcommand and
# suppresses the warning. `pnpm --reporter silent install` is a real ROOT install
# (--reporter takes `silent`; install is the subcommand), so in the regression-shaped
# condition it MUST warn. The old resolver only skipped -C/--dir/--filter/-F, so it
# resolved the subcommand as `silent` and stayed silent. --loglevel is a second,
# independent value-taking global proving the fix is not a one-flag special-case.
err="$(wrapper_stderr "$WS" 1 "" "" --reporter silent install --help)"
assert_warns "$err" "'pnpm --reporter silent install' warns (value-taking flag before the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" --loglevel debug install --help)"
assert_warns "$err" "'pnpm --loglevel debug install' warns (a second value-taking global)"
# --loglevel is enum-valued, but one level — `info` — is ALSO the npm-compat `info` (view
# alias) subcommand. Without stepping over --loglevel's value, `pnpm --loglevel info install`
# would resolve to `info` and silently skip the warning on a real root install.
err="$(wrapper_stderr "$WS" 1 "" "" --loglevel info install --help)"
assert_warns "$err" "'pnpm --loglevel info install' warns (level 'info' is not the 'info' subcommand)"

echo "Test: a value-taking flag before a NON-install subcommand -> silent"
# The flip side of the fix must not over-warn: `--reporter silent run install` still
# resolves to `run` (the first real subcommand), so the trailing `install` stays a
# script name and the command does not warn.
err="$(wrapper_stderr "$WS" 1 "" "" --reporter silent run install)"
assert_no_warn "$err" "'pnpm --reporter silent run install' does not warn (run is the subcommand)"

echo "Test: an arbitrary-string flag whose VALUE equals a subcommand name -> resolves the real subcommand"
# `-C <dir>` / `--filter <pkg>` take user-controlled strings that can collide with a
# subcommand name. A directory literally named `run` must not be misread as the `run`
# subcommand: `pnpm -C run install` (from the workspace root fixture) is still a root
# install and must warn; `--filter run install` likewise.
err="$(wrapper_stderr "$WS" 1 "" "" -C "$WS" install --help)"
assert_warns "$err" "'pnpm -C <ws> install' warns (explicit dir, root install)"
err="$(wrapper_stderr "$WS" 1 "" "" --filter run install --help)"
assert_warns "$err" "'pnpm --filter run install' warns (filter value 'run' is not the subcommand)"

echo "Test: a management/query subcommand with an install-class-looking positional -> silent"
# The subcommand resolver must recognize NON-install subcommands too, or it skips them and
# latches the trailing install-class word. `pnpm why install` / `pnpm list add` / `pnpm
# remove update` / `pnpm config get install` / `pnpm outdated add` all have a real
# subcommand (why/list/remove/config/outdated) that writes no root node_modules, so even
# in the regression-shaped condition they must stay silent. (A package literally named
# `install`/`add`/`update` exists on the registry, so these are realistic queries.)
err="$(wrapper_stderr "$WS" 1 "" "" why install)"
assert_no_warn "$err" "'pnpm why install' does not warn (why is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" list add)"
assert_no_warn "$err" "'pnpm list add' does not warn (list is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" remove update)"
assert_no_warn "$err" "'pnpm remove update' does not warn (remove is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" config get install)"
assert_no_warn "$err" "'pnpm config get install' does not warn (config is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" outdated add)"
assert_no_warn "$err" "'pnpm outdated add' does not warn (outdated is the subcommand)"
# `cache`/`stage` take a sub-action + package pattern; they must be recognized too so the
# resolver does not skip them onto a trailing install-class word.
err="$(wrapper_stderr "$WS" 1 "" "" cache delete add)"
assert_no_warn "$err" "'pnpm cache delete add' does not warn (cache is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" stage view install)"
assert_no_warn "$err" "'pnpm stage view install' does not warn (stage is the subcommand)"

echo "Test: 'pnpm help <topic>' -> silent (help is the subcommand, not a root install)"
# Regression for the copilot review on PR #70: `help` must be recognized as a subcommand,
# or the resolver skips it and latches the trailing install-class topic. `pnpm help install`
# / `pnpm help add` print documentation — they write no node_modules — so even in the
# regression-shaped condition they must stay silent.
err="$(wrapper_stderr "$WS" 1 "" "" help install)"
assert_no_warn "$err" "'pnpm help install' does not warn (help is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" help add)"
assert_no_warn "$err" "'pnpm help add' does not warn (help is the subcommand)"

echo "Test: an npm-compat registry/query command with an install-class positional -> silent"
# Regression for the codex P3 review on PR #70: the npm-compatible registry/query commands
# (`view`/`info`/`search`/`star`/`dist-tag`) take a package or keyword positional that can be
# an install-class word. `pnpm view install` queries the registry for the package literally
# named `install`; it writes no root node_modules, so it must stay silent. If the resolver
# did not recognize `view`/… it would skip it and latch the trailing `install`, falsely
# warning. (`install`/`add`/`update` all exist on the registry, so these are realistic.)
err="$(wrapper_stderr "$WS" 1 "" "" view install)"
assert_no_warn "$err" "'pnpm view install' does not warn (view is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" info add)"
assert_no_warn "$err" "'pnpm info add' does not warn (info is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" search update)"
assert_no_warn "$err" "'pnpm search update' does not warn (search is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" star update)"
assert_no_warn "$err" "'pnpm star update' does not warn (star is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" dist-tag ls install)"
assert_no_warn "$err" "'pnpm dist-tag ls install' does not warn (dist-tag is the subcommand)"

echo "Test: more npm-compat commands whose natural positional is an install-class word -> silent"
# Same class as the registry block, swept proactively (PR #70 fresh-review follow-up). These
# are realistic with NO contrived package name: `owner add` is a documented sub-action of the
# `owner` command, and `bugs`/`repo`/`docs` take a package whose name can be `install`/`add`.
# The resolver must recognize the real command so it does not latch the trailing word.
err="$(wrapper_stderr "$WS" 1 "" "" owner add lodash)"
assert_no_warn "$err" "'pnpm owner add lodash' does not warn (owner is the subcommand, add is its sub-action)"
err="$(wrapper_stderr "$WS" 1 "" "" bugs install)"
assert_no_warn "$err" "'pnpm bugs install' does not warn (bugs is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" repo add)"
assert_no_warn "$err" "'pnpm repo add' does not warn (repo is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" docs install)"
assert_no_warn "$err" "'pnpm docs install' does not warn (docs is the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" deprecate install msg)"
assert_no_warn "$err" "'pnpm deprecate install' does not warn (deprecate is the subcommand)"
# Aliases of the registry commands must resolve too: `show`->view, `find`->search.
err="$(wrapper_stderr "$WS" 1 "" "" show install)"
assert_no_warn "$err" "'pnpm show install' does not warn (show is a view alias)"
err="$(wrapper_stderr "$WS" 1 "" "" find update)"
assert_no_warn "$err" "'pnpm find update' does not warn (find is a search alias)"

echo "Test: a glob-PATTERN value-taking global before the subcommand -> still warns (task-002b gap)"
# Regression for the codex P2 review on PR #70: the resolver must step past a value-taking
# pattern global AND its value, or it misreads the (bare-token) pattern as the subcommand.
# `pnpm --hoist-pattern run install` is a real ROOT install (--hoist-pattern takes `run` as
# its glob value; install is the subcommand), so it MUST warn. The old skip list lacked the
# `--*-pattern` globals, so it read `run` as the subcommand and stayed silent.
# --changed-files-ignore-pattern is a second, independent pattern global proving the fix is
# not a one-flag special-case.
err="$(wrapper_stderr "$WS" 1 "" "" --hoist-pattern run install --help)"
assert_warns "$err" "'pnpm --hoist-pattern run install' warns (pattern value 'run' is not the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" --changed-files-ignore-pattern run install --help)"
assert_warns "$err" "'pnpm --changed-files-ignore-pattern run install' warns (a second pattern global)"
# `--trust-policy-exclude <package-spec>` is a third arbitrary-string class (a package spec,
# not an enum), so its value can be a bare subcommand name too.
err="$(wrapper_stderr "$WS" 1 "" "" --trust-policy-exclude run install --help)"
assert_warns "$err" "'pnpm --trust-policy-exclude run install' warns (spec value 'run' is not the subcommand)"
# `--global-dir <dir>` is a value-taking dir global (a dir named `run` is plausible), and
# `--cpu`/`--libc`/`--os`/`--reporter` are loose strings pnpm consumes without enum
# validation. None may be read as the subcommand: each of these is a real root install.
err="$(wrapper_stderr "$WS" 1 "" "" --global-dir run install --help)"
assert_warns "$err" "'pnpm --global-dir run install' warns (dir value 'run' is not the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" --cpu run install --help)"
assert_warns "$err" "'pnpm --cpu run install' warns (loose-string value 'run' is not the subcommand)"
err="$(wrapper_stderr "$WS" 1 "" "" --reporter run install --help)"
assert_warns "$err" "'pnpm --reporter run install' warns (--reporter is a free string, not a validated enum)"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
