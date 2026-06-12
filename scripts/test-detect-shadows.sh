#!/usr/bin/env bash
# Unit tests for docker/shared/detect-shadows.sh.
#
# Focus: the .powbox.yml literal-vs-glob split.  A literal path (no glob
# metacharacters) is emitted even when absent, so committed worktree
# scaffolding is created + tmpfs-shadowed at startup; a glob pattern stays
# existence-gated.  Also covers the under-/workspace-root security validation
# (including symlink escape) and confirms the pnpm/npm workspace logic is
# unchanged.
#
# Runs directly against the repo copy of detect-shadows.sh — no image build
# needed.  Requires bash, yq, and jq on PATH (all present in the agent image).
#
# Usage: scripts/test-detect-shadows.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DETECT="$SCRIPT_DIR/../docker/shared/detect-shadows.sh"

if [ ! -f "$DETECT" ]; then
	echo "FATAL: detect-shadows.sh not found at $DETECT" >&2
	exit 1
fi

pass=0
fail=0

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

# new_ws <name> — create a fresh workspace dir and echo its canonical path.
# Canonicalizing here means detect-shadows resolves the same path back, so
# emitted paths compare equal to "$ws/<rel>" with no symlink surprises.
new_ws() {
	local ws="$WORK_ROOT/$1"
	mkdir -p "$ws"
	realpath "$ws"
}

# write_powbox <ws> <entry...> — write a .powbox.yml shadow list.  Each entry
# is double-quoted so YAML special leaders ('!', '*', '[') are taken literally;
# detect-shadows does its own glob expansion on the resulting string value.
write_powbox() {
	local ws="$1"
	shift
	{
		echo "shadow:"
		local entry
		for entry in "$@"; do
			printf '  - "%s"\n' "$entry"
		done
	} >"$ws/.powbox.yml"
}

# run_out <ws> — stdout of detect-shadows (stderr silenced).
run_out() {
	bash "$DETECT" "$1" 2>/dev/null
}

# run_err <ws> — stderr of detect-shadows (stdout silenced).
run_err() {
	{ bash "$DETECT" "$1" >/dev/null; } 2>&1
}

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
}

# assert_emits <ws> <abs-path> <msg>
assert_emits() {
	if run_out "$1" | grep -qxF "$2"; then
		ok "$3"
	else
		ko "$3 (expected '$2' in output)"
	fi
}

# assert_absent <ws> <abs-path> <msg>
assert_absent() {
	if run_out "$1" | grep -qxF "$2"; then
		ko "$3 (did not expect '$2' in output)"
	else
		ok "$3"
	fi
}

# assert_no_output <ws> <msg>
assert_no_output() {
	local out
	out="$(run_out "$1")"
	if [ -z "$out" ]; then
		ok "$2"
	else
		ko "$2 (expected no output, got: $(printf '%s' "$out" | tr '\n' ' '))"
	fi
}

# assert_stderr <ws> <substring> <msg>
assert_stderr() {
	if run_err "$1" | grep -qF "$2"; then
		ok "$3"
	else
		ko "$3 (expected stderr to contain '$2')"
	fi
}

echo "Test: literal non-existent paths are emitted (created at startup)"
ws="$(new_ws literal-absent)"
# Mirror real usage: this script runs inside a git repo, so .git exists; it is
# the declared .git/worktrees *subdir* that is absent on a fresh checkout.
mkdir "$ws/.git"
write_powbox "$ws" .worktrees .git/worktrees .claude/worktrees
assert_emits "$ws" "$ws/.worktrees" "literal .worktrees emitted though absent"
assert_emits "$ws" "$ws/.git/worktrees" "literal .git/worktrees emitted though absent"
assert_emits "$ws" "$ws/.claude/worktrees" "literal .claude/worktrees emitted though absent"

echo "Test: .git/* literal skipped when .git is absent (non-git folder)"
ws="$(new_ws git-absent)"
write_powbox "$ws" .git/worktrees
assert_absent "$ws" "$ws/.git/worktrees" ".git/worktrees not emitted when .git absent"
assert_stderr "$ws" ".git is not a directory" "diagnostic explains the .git-absent skip"

echo "Test: .git/* literal skipped when .git is a file (linked worktree)"
ws="$(new_ws git-file)"
printf 'gitdir: /elsewhere/.git/worktrees/wt\n' >"$ws/.git"
write_powbox "$ws" .git/worktrees
assert_absent "$ws" "$ws/.git/worktrees" ".git/worktrees not emitted when .git is a file"
assert_stderr "$ws" ".git is not a directory" "diagnostic explains the linked-worktree skip"

echo "Test: non-matching glob produces no output (existence-gated)"
ws="$(new_ws glob-nomatch)"
write_powbox "$ws" 'packages/*/node_modules'
assert_no_output "$ws" "unmatched glob emits nothing"

echo "Test: matching glob emitted, package without node_modules skipped"
ws="$(new_ws glob-match)"
mkdir -p "$ws/packages/a/node_modules" "$ws/packages/b/node_modules" "$ws/packages/c"
write_powbox "$ws" 'packages/*/node_modules'
assert_emits "$ws" "$ws/packages/a/node_modules" "matching glob emits packages/a/node_modules"
assert_emits "$ws" "$ws/packages/b/node_modules" "matching glob emits packages/b/node_modules"
assert_absent "$ws" "$ws/packages/c/node_modules" "glob skips package lacking node_modules"

echo "Test: ? and [..] classify as glob, not literal (absent → nothing)"
ws="$(new_ws glob-meta)"
write_powbox "$ws" 'foo?' 'bar[12]'
assert_absent "$ws" "$ws/foo?" "'foo?' treated as glob, not emitted as literal"
assert_absent "$ws" "$ws/bar[12]" "'bar[12]' treated as glob, not emitted as literal"
assert_no_output "$ws" "no glob matches → no output"

echo "Test: escaping literal (../) rejected to stderr, not emitted"
ws="$(new_ws escape)"
write_powbox "$ws" '../evil'
assert_no_output "$ws" "escaping literal emits nothing"
assert_stderr "$ws" "resolves outside workspace root" "escaping literal rejected to stderr"

echo "Test: symlink escape rejected (realpath -m canonicalizes the prefix)"
ws="$(new_ws symlink-escape)"
ln -s /tmp "$ws/escape"
write_powbox "$ws" 'escape/evil'
assert_no_output "$ws" "symlink escape emits nothing"
assert_stderr "$ws" "resolves outside workspace root" "symlink escape rejected to stderr"

echo "Test: negation entries are skipped"
ws="$(new_ws negation)"
write_powbox "$ws" '!secret'
assert_no_output "$ws" "negation '!secret' skipped"

echo "Test: the workspace root itself is rejected with an accurate message"
ws="$(new_ws root-self)"
write_powbox "$ws" '.'
assert_no_output "$ws" "'.' (resolves to workspace root) not shadowed"
assert_stderr "$ws" "workspace root itself" "'.' rejected with a workspace-root diagnostic, not 'outside'"

echo "Test: pnpm workspace globs remain existence-gated on the package dir"
ws="$(new_ws pnpm-ws)"
mkdir -p "$ws/pkgs/x/node_modules" "$ws/pkgs/y"
cat >"$ws/pnpm-workspace.yaml" <<'YAML'
packages:
  - "pkgs/*"
YAML
assert_emits "$ws" "$ws/pkgs/x/node_modules" "pnpm pkg x → node_modules emitted"
assert_emits "$ws" "$ws/pkgs/y/node_modules" "pnpm pkg y → node_modules emitted (dir need not pre-exist)"
assert_absent "$ws" "$ws/pkgs/z/node_modules" "pnpm skips package dir that does not exist"

echo "Test: package.json workspaces array remains existence-gated"
ws="$(new_ws npm-ws)"
mkdir -p "$ws/apps/web"
cat >"$ws/package.json" <<'JSON'
{ "workspaces": ["apps/*"] }
JSON
assert_emits "$ws" "$ws/apps/web/node_modules" "npm workspace apps/web → node_modules emitted"

echo "Test: a path emitted via both workspace and .powbox.yml is deduplicated"
ws="$(new_ws dedup)"
mkdir -p "$ws/pkgs/x/node_modules"
cat >"$ws/pnpm-workspace.yaml" <<'YAML'
packages:
  - "pkgs/*"
YAML
write_powbox "$ws" 'pkgs/x/node_modules'
count="$(run_out "$ws" | grep -cxF "$ws/pkgs/x/node_modules" || true)"
if [ "$count" -eq 1 ]; then
	ok "duplicate path collapsed to a single line"
else
	ko "dedup failed (count=$count)"
fi

echo "Test: a bare workspace with no declarations emits nothing"
ws="$(new_ws empty)"
assert_no_output "$ws" "no .powbox.yml and no workspaces → no output"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
