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
	while [ "$#" -gt 0 ]; do
		mkdir -p "$(dirname "$CHECKOUT/$1")"
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

echo "Test: a non-report file whose name only resembles a report makes the branch mixed"
# Only an awk that expands escapes in -v (gawk) can misread this; mawk cannot.
add_branch learnings/session-e docs/agent-session-learnings-e.md docs/agent-session-learnings-cleanup.cmd
out="$("$COLLECT" list "$CHECKOUT")"
assert_contains "look-alike file makes the branch mixed" "$out" "$(printf 'sample\tlearnings/session-e\tmixed')"

echo "Test: two origins sharing a label are refused before anything is written"
FORK_ORIGIN="${WORK_ROOT}/fork/Sample.git"
FORK_CHECKOUT="${WORK_ROOT}/fork-checkout"
mkdir -p "${WORK_ROOT}/fork"
git clone --quiet --bare "$ORIGIN" "$FORK_ORIGIN"
git init --quiet "$FORK_CHECKOUT"
git -C "$FORK_CHECKOUT" remote add origin "$FORK_ORIGIN"
out="$("$COLLECT" export --into "${HOME_REPO}/dup" "$CHECKOUT" "$FORK_CHECKOUT" 2>&1 || true)"
assert_contains "shared label refused" "$out" "share the label sample"
if [ -e "${HOME_REPO}/dup" ]; then ko "refused export wrote nothing"; else ok "refused export wrote nothing"; fi

echo "Test: an interrupted export leaves no manifest for delete to act on"
BROKEN_CHECKOUT="${WORK_ROOT}/broken-checkout"
git init --quiet "$BROKEN_CHECKOUT"
git -C "$BROKEN_CHECKOUT" remote add origin "${WORK_ROOT}/missing.git"
SWEEP5="${HOME_REPO}/sweep5"
if "$COLLECT" export --into "$SWEEP5" "$CHECKOUT" "$BROKEN_CHECKOUT" >/dev/null 2>&1; then
	ko "export with an unreachable origin fails"
else
	ok "export with an unreachable origin fails"
fi
if [ -e "$SWEEP5/reports/sample/agent-session-learnings-b.md" ]; then ok "reports before the failure were copied"; else ko "reports before the failure were copied"; fi
if [ -e "$SWEEP5/MANIFEST.tsv" ]; then ko "no manifest after the failure"; else ok "no manifest after the failure"; fi
if "$COLLECT" delete --from "$SWEEP5" --yes >/dev/null 2>&1; then ko "delete refuses the interrupted export"; else ok "delete refuses the interrupted export"; fi
if "$COLLECT" export --into "$SWEEP5" "$CHECKOUT" >/dev/null 2>&1; then ko "re-export into the interrupted directory refused"; else ok "re-export into the interrupted directory refused"; fi

# Every manifest row of a branch has its own copy, holding exactly its blob.
copies_intact() {
	local sweep="$1" branch="$2" dest blob rows=0 seen=""
	while IFS=$'\t' read -r dest blob; do
		rows=$((rows + 1))
		case "$seen" in *"|$dest|"*) return 1 ;; esac
		seen="${seen}|$dest|"
		[ "$(git hash-object --no-filters "$sweep/$dest")" = "$blob" ] || return 1
	done < <(awk -F'\t' -v b="$branch" 'NR > 1 && $3 == b { print $9 "\t" $8 }' "$sweep/MANIFEST.tsv")
	[ "$rows" -eq "$3" ]
}

echo "Test: same-named reports in one branch each get their own copy"
add_branch learnings/session-g docs/a/agent-session-learnings-same.md docs/b/agent-session-learnings-same.md docs/c/agent-session-learnings-same.md
SWEEP7="${WORK_ROOT}/sweep7"
"$COLLECT" export --into "$SWEEP7" "$CHECKOUT"
if copies_intact "$SWEEP7" learnings/session-g 3; then ok "three same-named reports, three intact copies"; else ko "three same-named reports, three intact copies"; fi

echo "Test: a report under a non-ASCII path is recognised"
add_branch learnings/session-h "文档/agent-session-learnings-h.md"
out="$("$COLLECT" list "$CHECKOUT")"
assert_contains "non-ASCII report keeps the branch report-only" "$out" "$(printf 'sample\tlearnings/session-h\treport-only')"
assert_contains "non-ASCII report listed unquoted" "$out" "文档/agent-session-learnings-h.md"

echo "Test: a submodule change makes the branch mixed whatever diff.ignoreSubmodules says"
git -C "$CHECKOUT" checkout --quiet -b learnings/session-i main
mkdir -p "$CHECKOUT/docs"
printf 'report\n' >"$CHECKOUT/docs/agent-session-learnings-i.md"
git -C "$CHECKOUT" add docs/agent-session-learnings-i.md
git -C "$CHECKOUT" update-index --add --cacheinfo "160000,$(git -C "$CHECKOUT" rev-parse main),vendor/dep"
git -C "$CHECKOUT" commit --quiet -m session-i
git -C "$CHECKOUT" push --quiet origin learnings/session-i
git -C "$CHECKOUT" checkout --quiet main
out="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.ignoreSubmodules GIT_CONFIG_VALUE_0=all "$COLLECT" list "$CHECKOUT")"
assert_contains "submodule change makes the branch mixed" "$out" "$(printf 'sample\tlearnings/session-i\tmixed')"

echo "Test: a committed report with a non-ASCII name lets its branch go"
add_branch learnings/session-j "docs/agent-session-learnings-é.md"
SWEEP8="${HOME_REPO}/sweep8"
"$COLLECT" export --into "$SWEEP8" "$CHECKOUT"
git -C "$HOME_REPO" add sweep8
git -C "$HOME_REPO" commit --quiet -m sweep8
out="$("$COLLECT" delete --from "$SWEEP8")"
assert_contains "non-ASCII copy found committed" "$out" "$(printf 'would-delete\tsample\tlearnings/session-j')"

echo "Test: delete checks open pull requests wherever it can, and holds the branch where it cannot"
# The manifest URL is rewritten to each origin form in turn, git maps it back
# to the local origin, and a stub gh answers the login and pull-request queries.
add_branch learnings/session-f docs/agent-session-learnings-f.md
SWEEP6="${HOME_REPO}/sweep6"
"$COLLECT" export --into "$SWEEP6" "$CHECKOUT"
git -C "$HOME_REPO" add sweep6
git -C "$HOME_REPO" commit --quiet -m sweep6
STUB_BIN="${WORK_ROOT}/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
if [ "$1" = auth ]; then
	case " ${GH_LOGINS:-} " in *" $4 "*) exit 0 ;; esac
	exit 1
fi
[ "$GH_STUB" != fail ] || exit 1
printf '%s\n' "$GH_STUB"
STUB
chmod +x "$STUB_BIN/gh"
export GH_LOG="${WORK_ROOT}/gh.log"
# gh_delete <origin URL> <stub answer> [<hosts gh is logged in to>]
gh_delete() {
	awk -F'\t' -v OFS='\t' -v u="$1" 'NR > 1 { $2 = u } { print }' "$SWEEP6/MANIFEST.tsv" >"$SWEEP6/MANIFEST.tmp"
	mv "$SWEEP6/MANIFEST.tmp" "$SWEEP6/MANIFEST.tsv"
	: >"$GH_LOG"
	GH_STUB="$2" GH_LOGINS="${3:-}" PATH="${STUB_BIN}:${PATH}" \
		GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.${ORIGIN}.insteadOf" GIT_CONFIG_VALUE_0="$1" \
		"$COLLECT" delete --from "$SWEEP6" --yes
}
held_f() { printf 'held\tsample\tlearnings/session-f\t%s' "$1"; }
out="$(gh_delete https://github.com/acme/sample.git 1)"
assert_contains "open pull request holds the branch" "$out" "$(held_f 'an open pull request uses it as head')"
assert_contains "query goes to github.com" "$(cat "$GH_LOG")" "--hostname github.com graphql"
assert_contains "query names the owner and repo" "$(cat "$GH_LOG")" "o=acme -f n=sample"
assert_contains "query names the branch ref" "$(cat "$GH_LOG")" "r=refs/heads/learnings/session-f"
out="$(gh_delete https://github.com/acme/sample.git fail)"
assert_contains "failed query holds the branch" "$out" "$(held_f 'could not check for open pull requests')"
out="$(gh_delete https://github.com/acme/sample.git gone)"
assert_contains "vanished branch held" "$out" "$(held_f 'the remote branch no longer exists')"
out="$(gh_delete ssh://git@ssh.github.com:443/acme/sample.git/ 1)"
assert_contains "ssh:// GitHub URL is checked" "$out" "$(held_f 'an open pull request uses it as head')"
assert_contains "ssh.github.com is asked as github.com" "$(cat "$GH_LOG")" "o=acme -f n=sample"
out="$(gh_delete https://ghe.example.invalid/acme/sample 1 ghe.example.invalid)"
assert_contains "Enterprise host with a gh login is checked" "$out" "$(held_f 'an open pull request uses it as head')"
assert_contains "Enterprise query goes to its host" "$(cat "$GH_LOG")" "--hostname ghe.example.invalid graphql"
out="$(gh_delete https://ghe.example.invalid/acme/sample 0)"
assert_contains "host without a gh login is held" "$out" "$(held_f 'open pull requests cannot be checked on ghe.example.invalid')"
assert_not_contains "nothing queried for it" "$(cat "$GH_LOG")" "graphql"
out="$(gh_delete 'https://[2001:db8::1]/acme/sample.git' 0)"
assert_contains "IPv6 host is held, not taken for a local path" "$out" "$(held_f 'open pull requests cannot be checked on')"
out="$(gh_delete https://github.com/acme/re::po.git 1)"
assert_contains ":: in a GitHub path still gets the check" "$out" "$(held_f 'an open pull request uses it as head')"
out="$(gh_delete myalias:acme/sample.git 0)"
assert_contains "SSH host alias is held" "$out" "$(held_f 'open pull requests cannot be checked on myalias')"
if remote_has learnings/session-f; then ok "held branch still on origin"; else ko "held branch still on origin"; fi
out="$(gh_delete https://github.com/acme/sample.git 0)"
assert_contains "no open pull request lets it go" "$out" "$(printf 'deleted\tsample\tlearnings/session-f')"
if remote_has learnings/session-f; then ko "branch gone from origin"; else ok "branch gone from origin"; fi

echo "Test: a relative origin path is resolved against its checkout, not the caller"
REL_ORIGIN="${WORK_ROOT}/rel/Relsample.git"
REL_CHECKOUT="${WORK_ROOT}/rel/checkout"
git clone --quiet --bare "$ORIGIN" "$REL_ORIGIN"
git clone --quiet "$REL_ORIGIN" "$REL_CHECKOUT" 2>/dev/null
git -C "$REL_CHECKOUT" remote set-url origin ../Relsample.git
mkdir -p "$REL_CHECKOUT/sub" "$REL_CHECKOUT/docs"
git -C "$REL_CHECKOUT" checkout --quiet -b learnings/session-k origin/main
printf 'report k\n' >"$REL_CHECKOUT/docs/agent-session-learnings-k.md"
git -C "$REL_CHECKOUT" add docs/agent-session-learnings-k.md
git -C "$REL_CHECKOUT" commit --quiet -m session-k
git -C "$REL_CHECKOUT" push --quiet origin learnings/session-k
# rel_case <name> <checkout> [<env>...]: git itself reaches the origin from
# that checkout, and a list run from elsewhere finds session-k there too.
k_row="$(printf 'relsample\tlearnings/session-k\treport-only')"
rel_case() {
	local name="$1" dir="$2" out
	shift 2
	if (cd "$WORK_ROOT" && env "$@" git -C "$dir" ls-remote origin HEAD >/dev/null 2>&1); then
		ok "$name: git reaches the origin"
	else
		ko "$name: git reaches the origin"
	fi
	out="$(cd "$WORK_ROOT" && env "$@" "$COLLECT" list "$dir" 2>&1 || true)"
	assert_contains "$name: collect.sh reaches it too" "$out" "$k_row"
}
rel_case "work-tree subdirectory" "$REL_CHECKOUT/sub"
git init --quiet --bare "${WORK_ROOT}/rel/bare.git"
git -C "${WORK_ROOT}/rel/bare.git" remote add origin ../Relsample.git
rel_case "bare repository" "${WORK_ROOT}/rel/bare.git"
mkdir -p "${WORK_ROOT}/rel/deep"
git init --quiet --bare "${WORK_ROOT}/rel/deep/bare.git"
git -C "${WORK_ROOT}/rel/deep/bare.git" remote add origin ../../../Relsample.git
rel_case "subdirectory of a bare repository" "${WORK_ROOT}/rel/deep/bare.git/objects"
# A git dir whose work tree lies elsewhere: git resolves from the git dir.
mkdir -p "${WORK_ROOT}/rel/x/cw"
git init --quiet --bare "${WORK_ROOT}/rel/gd.git"
git -C "${WORK_ROOT}/rel/gd.git" config core.bare false
git -C "${WORK_ROOT}/rel/gd.git" config core.worktree ../x/cw
git -C "${WORK_ROOT}/rel/gd.git" remote add origin ../Relsample.git
rel_case "git dir with an outside work tree" "${WORK_ROOT}/rel/gd.git"
git init --quiet "${WORK_ROOT}/rel/tilde"
# shellcheck disable=SC2088 # the literal ~ is the point: git expands it
git -C "${WORK_ROOT}/rel/tilde" remote add origin '~/Relsample.git'
rel_case "leading ~" "${WORK_ROOT}/rel/tilde" HOME="${WORK_ROOT}/rel"
git -C "$REL_CHECKOUT" worktree add --quiet --detach "${WORK_ROOT}/rel/wts/wt" 2>/dev/null
git -C "$REL_CHECKOUT" remote set-url origin ../../Relsample.git
rel_case "linked worktree" "${WORK_ROOT}/rel/wts/wt"
rel_case ".git directory" "$REL_CHECKOUT/.git"
git -C "$REL_CHECKOUT" remote set-url origin ../Relsample.git
SWEEP9="${HOME_REPO}/sweep9"
(cd "$WORK_ROOT" && "$COLLECT" export --into "$SWEEP9" "$REL_CHECKOUT/sub" >/dev/null 2>&1) || true
rel_url="$(awk -F'\t' 'NR == 2 { print $2 }' "$SWEEP9/MANIFEST.tsv" 2>/dev/null || true)"
# Not by way of the checkout, which may be gone by the time delete runs.
if [ "$rel_url" = "$(cd "$REL_ORIGIN" && pwd -P)" ]; then
	ok "manifest records the origin's own absolute path"
else
	ko "manifest records the origin's own absolute path ($rel_url)"
fi
{ git -C "$HOME_REPO" add sweep9 2>/dev/null && git -C "$HOME_REPO" commit --quiet -m sweep9; } || true
(cd "$HOME_REPO" && "$COLLECT" delete --from "$SWEEP9" --yes >/dev/null 2>&1) || true
if git -C "$REL_ORIGIN" show-ref --verify --quiet refs/heads/learnings/session-k; then
	ko "delete reaches the relative origin"
else
	ok "delete reaches the relative origin"
fi

echo "Test: an origin URL carrying a credential is refused, a login name is not"
refused() {
	git -C "$CHECKOUT" remote set-url origin "$1"
	GIT_SSH_COMMAND=false "$COLLECT" list "$CHECKOUT" 2>&1 || true
}
out="$(refused 'https://user:secret@example.invalid/Sample.git')"
assert_contains "user and password over https refused" "$out" "embeds a credential"
assert_not_contains "credential not echoed" "$out" "secret"
assert_contains "token as https user refused" "$(refused 'https://tok3n@example.invalid/Sample.git')" "embeds a credential"
assert_contains "token under an upper-case scheme refused" "$(refused 'HTTPS://tok3n@example.invalid/Sample.git')" "embeds a credential"
assert_contains "token behind a remote-helper prefix refused" "$(refused 'persistent-https::https://tok3n@example.invalid/Sample.git')" "embeds a credential"
assert_contains "token before an IPv6 host refused" "$(refused 'https://tok3n@[::1]/Sample.git')" "embeds a credential"
assert_contains "token with :: in the path refused" "$(refused 'https://tok3n@example.invalid/a::b/Sample.git')" "embeds a credential"
assert_contains "password over ssh:// refused" "$(refused 'ssh://git:secret@example.invalid/Sample.git')" "embeds a credential"
out="$(refused 'ssh://git@example.invalid/Sample.git')"
assert_not_contains "ssh:// login name accepted" "$out" "embeds a credential"
assert_contains "and the origin is then tried as written" "$out" "cannot reach ssh://git@example.invalid/Sample.git"
out="$(refused 'git@example.invalid:Sample.git')"
assert_not_contains "scp-like login name accepted" "$out" "embeds a credential"
assert_contains "scp-like origin tried as written" "$out" "cannot reach git@example.invalid:Sample.git"
assert_contains "file:// origin tried as written" "$(refused 'file://../missing.git')" "cannot reach file://../missing.git"
assert_contains "helper-prefixed origin tried as written" "$(refused 'nohelper::../missing.git')" "cannot reach nohelper::../missing.git"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
