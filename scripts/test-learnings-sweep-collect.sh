#!/usr/bin/env bash
# Tests for .claude/skills/learnings-sweep/collect.sh, the helper that gathers
# session-learnings reports from other repositories' throwaway branches and
# then deletes those branches. The delete half is the part worth pinning: it
# must only ever remove a branch whose whole content is safely committed
# elsewhere. Hermetic: every "origin" is a local bare repository.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECT="${ROOT_DIR}/.claude/skills/learnings-sweep/collect.sh"

pass=0
fail=0
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
}

assert_contains() {
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) ko "$1 (missing '$3' in: $2)" ;;
	esac
}

assert_not_contains() {
	case "$2" in
	*"$3"*) ko "$1 (unexpected '$3')" ;;
	*) ok "$1" ;;
	esac
}

remote_has() { git -C "$ORIGIN" show-ref --verify --quiet "refs/heads/$1"; }

# A bare origin with a default branch and three candidate branches, a checkout
# of it, and a separate repository to aggregate into.
ORIGIN="${WORK_ROOT}/Sample.git"
CHECKOUT="${WORK_ROOT}/checkout"
HOME_REPO="${WORK_ROOT}/home"
git init --quiet --bare --initial-branch=main "$ORIGIN"
git clone --quiet "$ORIGIN" "$CHECKOUT" 2>/dev/null
git -C "$CHECKOUT" checkout --quiet -b main
printf 'base\n' >"$CHECKOUT/README.md"
git -C "$CHECKOUT" add README.md
git -C "$CHECKOUT" commit --quiet -m base
git -C "$CHECKOUT" push --quiet origin main

add_branch() {
	local branch="$1"
	shift
	git -C "$CHECKOUT" checkout --quiet -b "$branch" main
	mkdir -p "$CHECKOUT/docs"
	while [ "$#" -gt 0 ]; do
		printf 'content of %s on %s\n' "$1" "$branch" >"$CHECKOUT/$1"
		git -C "$CHECKOUT" add "$1"
		shift
	done
	git -C "$CHECKOUT" commit --quiet -m "$branch"
	git -C "$CHECKOUT" push --quiet origin "$branch"
	git -C "$CHECKOUT" checkout --quiet main
}
add_branch learnings/session-a docs/agent-session-learnings-a.md
add_branch learnings/session-b docs/agent-session-learnings-b.md deploy.yml
add_branch throwaway/old docs/agent-session-learnings-old.md

git init --quiet --initial-branch=main "$HOME_REPO"
git -C "$HOME_REPO" commit --quiet --allow-empty -m init

echo "Test: list classifies branches and honours --also"
out="$("$COLLECT" list "$CHECKOUT")"
assert_contains "report-only branch listed" "$out" "$(printf 'sample\tlearnings/session-a\treport-only')"
assert_contains "branch with another file is mixed" "$out" "$(printf 'sample\tlearnings/session-b\tmixed')"
assert_not_contains "other naming not collected by default" "$out" "throwaway/old"
out="$("$COLLECT" list --also 'throwaway/*' "$CHECKOUT")"
assert_contains "--also adds a glob" "$out" "$(printf 'sample\tthrowaway/old\treport-only')"

echo "Test: export copies reports verbatim and writes the manifest"
SWEEP="${HOME_REPO}/sweep"
"$COLLECT" export --into "$SWEEP" "$CHECKOUT"
if cmp -s "$SWEEP/reports/sample/agent-session-learnings-a.md" <(git -C "$ORIGIN" show learnings/session-a:docs/agent-session-learnings-a.md); then
	ok "report copied byte for byte"
else
	ko "report copied byte for byte"
fi
manifest="$(cat "$SWEEP/MANIFEST.tsv")"
assert_contains "manifest records the source commit" "$manifest" "$(git -C "$ORIGIN" rev-parse learnings/session-a)"
assert_contains "mixed branch still exported" "$manifest" "agent-session-learnings-b.md"
assert_not_contains "non-report file not exported" "$manifest" "deploy.yml"
if "$COLLECT" export --into "$SWEEP" "$CHECKOUT" >/dev/null 2>&1; then
	ko "second export into the same directory refused"
else
	ok "second export into the same directory refused"
fi

echo "Test: delete refuses until the aggregated copies are committed"
out="$("$COLLECT" delete --from "$SWEEP" --yes)"
assert_contains "uncommitted copy holds the branch" "$out" "$(printf 'held\tsample\tlearnings/session-a')"
if remote_has learnings/session-a; then ok "branch survives the refusal"; else ko "branch survives the refusal"; fi

git -C "$HOME_REPO" add sweep
out="$("$COLLECT" delete --from "$SWEEP" --yes)"
assert_contains "staged but uncommitted copy holds the branch" "$out" "$(printf 'held\tsample\tlearnings/session-a')"
git -C "$HOME_REPO" commit --quiet -m sweep

echo "Test: delete without --yes changes nothing"
out="$("$COLLECT" delete --from "$SWEEP")"
assert_contains "dry run names the branch" "$out" "$(printf 'would-delete\tsample\tlearnings/session-a')"
if remote_has learnings/session-a; then ok "dry run deletes nothing"; else ko "dry run deletes nothing"; fi

echo "Test: delete removes report-only branches and holds the rest"
out="$("$COLLECT" delete --from "$SWEEP" --yes)"
assert_contains "report-only branch deleted" "$out" "$(printf 'deleted\tsample\tlearnings/session-a')"
assert_contains "mixed branch held" "$out" "$(printf 'held\tsample\tlearnings/session-b\tclass is mixed')"
if remote_has learnings/session-a; then ko "deleted branch is gone from origin"; else ok "deleted branch is gone from origin"; fi
if remote_has learnings/session-b; then ok "mixed branch still on origin"; else ko "mixed branch still on origin"; fi
assert_contains "deletion logged" "$(cat "$SWEEP/DELETED-BRANCHES.tsv")" "learnings/session-a"

echo "Test: a branch that moved after export is held"
add_branch learnings/session-c docs/agent-session-learnings-c.md
SWEEP2="${HOME_REPO}/sweep2"
"$COLLECT" export --into "$SWEEP2" "$CHECKOUT"
git -C "$HOME_REPO" add sweep2
git -C "$HOME_REPO" commit --quiet -m sweep2
git -C "$CHECKOUT" checkout --quiet learnings/session-c
printf 'later\n' >>"$CHECKOUT/docs/agent-session-learnings-c.md"
git -C "$CHECKOUT" commit --quiet -am later
git -C "$CHECKOUT" push --quiet origin learnings/session-c
git -C "$CHECKOUT" checkout --quiet main
out="$("$COLLECT" delete --from "$SWEEP2" --yes)"
assert_contains "moved branch held" "$out" "$(printf 'held\tsample\tlearnings/session-c')"
if remote_has learnings/session-c; then ok "moved branch still on origin"; else ko "moved branch still on origin"; fi

echo "Test: a copy committed with different content holds its branch"
add_branch learnings/session-d docs/agent-session-learnings-d.md
SWEEP3="${HOME_REPO}/sweep3"
"$COLLECT" export --into "$SWEEP3" "$CHECKOUT"
printf 'edited\n' >>"$SWEEP3/reports/sample/agent-session-learnings-d.md"
git -C "$HOME_REPO" add sweep3
git -C "$HOME_REPO" commit --quiet -m sweep3
out="$("$COLLECT" delete --from "$SWEEP3" --yes)"
assert_contains "altered commit holds the branch" "$out" "$(printf 'held\tsample\tlearnings/session-d')"
if remote_has learnings/session-d; then ok "its branch is still on origin"; else ko "its branch is still on origin"; fi

echo "Test: an origin URL carrying a credential is refused"
git -C "$CHECKOUT" remote set-url origin 'https://user:secret@example.invalid/Sample.git'
out="$("$COLLECT" list "$CHECKOUT" 2>&1 || true)"
assert_contains "credentialed URL refused" "$out" "embeds a credential"
assert_not_contains "credential not echoed" "$out" "secret"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
