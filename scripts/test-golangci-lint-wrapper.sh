#!/usr/bin/env bash
# Unit tests for docker/layers/full/golangci-lint-wrapper.sh, the PATH
# golangci-lint of the full layer set.
#
# The wrapper is copied to a tmpdir with its GOLANGCI_REAL assignment pointed
# at a stub that records the TMPDIR, GOLANGCI_LINT_CACHE and argv it was given.
# The rewrite is verified: a renamed assignment makes this suite FATAL rather
# than exec the real linter. With FAKE_LOCK set the stub also takes the
# linter's run guard the way v2 does — a non-blocking exclusive flock(2) on
# golangci-lint.lock in $TMPDIR, exit 3 "parallel golangci-lint is running"
# when it is held — so the per-worktree lock scoping is pinned without the
# real binary. The built image's end of it (the real binary, the symlink) is
# the full set's smoke probes.
#
# Needs bash, coreutils and git; the lock-collision cases also need flock(1)
# and skip honestly without it. Every TMPDIR the wrapper sees is a fixture
# path, so no case touches the container's real /tmp lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../docker/layers/full/golangci-lint-wrapper.sh"

pass=0
fail=0
skip=0
ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}
ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
	[ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/       /'
}
sk() {
	skip=$((skip + 1))
	printf '  skip %s\n' "$1"
}

if ! command -v git >/dev/null 2>&1; then
	echo "FATAL: git is required" >&2
	exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-golangci-lint-wrapper.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

LOG="$TMP/stub.log"
STUB="$TMP/golangci-lint-stub"
cat >"$STUB" <<'EOF'
#!/bin/sh
{
	echo "tmpdir=${TMPDIR-<unset>}"
	echo "cache=${GOLANGCI_LINT_CACHE-<unset>}"
	for a in "$@"; do echo "arg=$a"; done
} >"$FAKE_LOG"
if [ -n "${FAKE_LOCK:-}" ] && ! flock -n "${TMPDIR:-/tmp}/golangci-lint.lock" true; then
	echo "Error: parallel golangci-lint is running" >&2
	exit 3
fi
exit 0
EOF
chmod +x "$STUB"

WRAPPER="$TMP/golangci-lint"
sed "s#^GOLANGCI_REAL=\"/usr/local/libexec/golangci-lint\"\$#GOLANGCI_REAL=\"$STUB\"#" "$SRC" >"$WRAPPER"
if [ "$(grep -c "^GOLANGCI_REAL=\"$STUB\"\$" "$WRAPPER")" != 1 ] || [[ $(grep -v '^[[:space:]]*#' "$WRAPPER") == */usr/local/libexec/golangci-lint* ]]; then
	echo "FATAL: could not point the wrapper's GOLANGCI_REAL at the stub; refusing to run it." >&2
	exit 1
fi
chmod +x "$WRAPPER"

# Fixture: a repository with two linked worktrees in the powbox layout, plus a
# directory outside any repository.
REPO="$TMP/repo"
NOGIT="$TMP/nogit"
mkdir -p "$REPO" "$NOGIT"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q .worktrees/cont/a -b a
git -C "$REPO" worktree add -q .worktrees/cont/b -b b
WTA="$REPO/.worktrees/cont/a"
WTB="$REPO/.worktrees/cont/b"
mkdir -p "$WTA/sub/pkg"
# Outside the fixture repository git must not find an enclosing one.
export GIT_CEILING_DIRECTORIES="$TMP"

ROOTTMP="$TMP/tmp"
mkdir -p "$ROOTTMP"
BASE="$ROOTTMP/golangci-lint-$EUID"

OUT="$TMP/out"
# run <dir> [VAR=value ...] -- <args...>: run the wrapper in <dir> with the
# assignments added to its environment (VAR= with no value unsets VAR),
# leaving its exit status in $rc and its stderr in $OUT.
run() {
	local dir=$1
	shift
	local -a unsets=() sets=()
	while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
		case "$1" in
		*=) unsets+=(-u "${1%=}") ;;
		*) sets+=("$1") ;;
		esac
		shift
	done
	[ "$#" -eq 0 ] || shift
	rm -f "$LOG"
	rc=0
	(cd "$dir" && env "${unsets[@]}" "${sets[@]}" FAKE_LOG="$LOG" "$WRAPPER" "$@") >/dev/null 2>"$OUT" </dev/null || rc=$?
}
field() {
	sed -n "s/^$1=//p" "$LOG" 2>/dev/null || true
}
expect_field() {
	local name=$1 want=$2 desc=$3 got
	got="$(field "$name")"
	if [ "$got" = "$want" ]; then
		ok "$desc"
	else
		ko "$desc" "want $name=$want"$'\n'"got  $name=$got (exit $rc)"$'\n'"$(cat "$OUT")"
	fi
}

echo "run lock scoping"
run "$WTA" TMPDIR="$ROOTTMP" -- run ./...
expect_field tmpdir "$BASE$WTA" "a worktree's TMPDIR is re-rooted per toplevel under the caller's temp root"
A_TMP="$(field tmpdir)"
run "$WTB" TMPDIR="$ROOTTMP" -- run ./...
expect_field tmpdir "$BASE$WTB" "a sibling worktree gets a different TMPDIR"
run "$WTA/sub/pkg" TMPDIR="$ROOTTMP" -- run ./...
expect_field tmpdir "$A_TMP" "a subdirectory of a worktree shares that worktree's TMPDIR"
run "$REPO" TMPDIR="$ROOTTMP" -- run ./...
expect_field tmpdir "$BASE$REPO" "the main checkout gets its own TMPDIR even without a .worktrees mount"
run "$WTA" TMPDIR="$ROOTTMP/" -- run ./...
expect_field tmpdir "$A_TMP" "a trailing slash on the caller's TMPDIR yields the same scope"
if [ "$(stat -c %a "$BASE")" = 700 ]; then
	ok "the per-euid lock base is created owner-only"
else
	ko "the per-euid lock base is created owner-only" "$(stat -c %a "$BASE")"
fi
run "$NOGIT" TMPDIR="$ROOTTMP" -- run ./...
expect_field tmpdir "$ROOTTMP" "outside a repository a caller's TMPDIR passes through unchanged"
run "$NOGIT" TMPDIR= -- run ./...
expect_field tmpdir "<unset>" "outside a repository an unset TMPDIR stays unset"
run "$WTA" TMPDIR="$ROOTTMP" GOLANGCI_LINT_CACHE="$TMP/mycache" -- run ./...
expect_field tmpdir "$A_TMP" "the lock is still scoped when the caller sets GOLANGCI_LINT_CACHE"
run "$WTA" TMPDIR="$ROOTTMP" -- run --allow-serial-runners -c x.yml ./...
want_args=$'run\n--allow-serial-runners\n-c\nx.yml\n./...'
if [ "$(field arg)" = "$want_args" ]; then
	ok "the caller's flags reach the linter verbatim (none added)"
else
	ko "the caller's flags reach the linter verbatim (none added)" "$(field arg)"
fi
printf 'not a dir\n' >"$TMP/afile"
run "$WTA" TMPDIR="$TMP/afile" -- run ./...
if [ "$rc" = 0 ] && [ "$(field tmpdir)" = "$TMP/afile" ] && grep -q 'shared run lock' "$OUT"; then
	ok "a lock dir that cannot be created warns and still runs the linter with TMPDIR untouched"
else
	ko "a lock dir that cannot be created warns and still runs the linter with TMPDIR untouched" "exit $rc tmpdir=$(field tmpdir)"$'\n'"$(cat "$OUT")"
fi

echo "run lock collisions"
if command -v flock >/dev/null 2>&1; then
	# Hold worktree a's scoped lock as a concurrent run in a would.
	exec 9>"$A_TMP/golangci-lint.lock"
	flock 9
	run "$WTB" TMPDIR="$ROOTTMP" FAKE_LOCK=1 -- run ./...
	if [ "$rc" = 0 ]; then ok "a run in a sibling worktree is not blocked"; else ko "a run in a sibling worktree is not blocked" "exit $rc"$'\n'"$(cat "$OUT")"; fi
	run "$REPO" TMPDIR="$ROOTTMP" FAKE_LOCK=1 -- run ./...
	if [ "$rc" = 0 ]; then ok "a run in the main checkout is not blocked"; else ko "a run in the main checkout is not blocked" "exit $rc"$'\n'"$(cat "$OUT")"; fi
	run "$WTA/sub/pkg" TMPDIR="$ROOTTMP" FAKE_LOCK=1 -- run ./...
	if [ "$rc" = 3 ] && grep -q 'parallel golangci-lint is running' "$OUT"; then
		ok "a second run in the same worktree still meets the linter's guard"
	else
		ko "a second run in the same worktree still meets the linter's guard" "exit $rc"$'\n'"$(cat "$OUT")"
	fi
	exec 9>&-
	# Control: without a toplevel nothing is scoped, so the shared lock bites.
	exec 9>"$ROOTTMP/golangci-lint.lock"
	flock 9
	run "$NOGIT" TMPDIR="$ROOTTMP" FAKE_LOCK=1 -- run ./...
	if [ "$rc" = 3 ]; then ok "control: outside a repository the shared lock still collides"; else ko "control: outside a repository the shared lock still collides" "exit $rc"; fi
	exec 9>&-
else
	sk "flock(1) not available; lock-collision cases not run"
fi

echo "analysis cache scoping"
run "$WTA" TMPDIR="$ROOTTMP" GOLANGCI_LINT_CACHE= -- cache status
expect_field cache "$REPO/.worktrees/.golangci-cache/cont/a" "a worktree's cache is scoped under .worktrees/.golangci-cache/<container>/<slug>"
run "$WTA" TMPDIR="$ROOTTMP" GOLANGCI_LINT_CACHE="$TMP/mycache" -- cache status
expect_field cache "$TMP/mycache" "an explicit GOLANGCI_LINT_CACHE wins"
run "$REPO" TMPDIR="$ROOTTMP" GOLANGCI_LINT_CACHE= POWBOX_SELF_HOSTED=1 -- cache status
expect_field cache "$REPO/.worktrees/.golangci-cache/.root" "a self-hosted main checkout scopes to .root"
run "$NOGIT" TMPDIR="$ROOTTMP" GOLANGCI_LINT_CACHE= -- cache status
expect_field cache "<unset>" "outside a repository the cache is left at the default"

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
