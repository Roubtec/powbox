#!/usr/bin/env bash
set -euo pipefail

# Offline contract coverage for the disposable-clone helpers in
# plugins/dev-skills/bin: dc-enter (make a clone of the invoking repository that
# is safe to wreck, printing only its path) and dc-remove (drop one, however
# wrecked, and nothing else).
#
# Sync discipline: any behavior change to either helper must update this suite in
# the same PR. If powbox later bakes the helpers onto the container PATH, this
# suite is the consumer contract to import, with DC_ENTER_HELPER/DC_REMOVE_HELPER
# retargeting it at the baked artifacts.
#
# POWBOX IMPORT NOTE (the only local edit — this paragraph). Powbox now does bake
# both helpers, so this file is the imported copy of that consumer contract,
# taken VERBATIM from Roubtec/agent-skills at commit
# 3cf0360401cfad75475c2c0d74fd9ad556370655 (the helpers themselves landed in
# PR #42, 885cdee). agent-skills remains the single source of truth: fix a
# helper or a fixture THERE and re-import, never here — a local edit makes this
# copy prove less about the artifact it guards. commands/smoke-test.{sh,ps1}
# run it as Stage 0j inside the agent image with DC_ENTER_HELPER and
# DC_REMOVE_HELPER pointed at /usr/local/bin/dc-enter and /usr/local/bin/
# dc-remove, so the baked artifacts are what is exercised; scripts/
# run-pure-shell-tests.sh therefore routes it to Tier 1 rather than the source
# runner. When re-importing, update the commit named above.
#
# Hermetic and host-independent: every fixture is a throwaway repository under
# one mktemp -d root, and the suite NEVER runs a helper against this repository —
# `in_repo` is the only way a helper is invoked and it always changes directory
# inside a subshell. Needs only Bash, git, and coreutils.
#
# Run from the repository root: bash scripts/test-dc-helpers.sh
#
# Covers:
#   (a) stdout purity and the DC="$(dc-enter probe)" calling convention
#   (b) the isolation guarantee — refs, commits, and gc --prune=now in the clone
#       leave the source's refs and reachable objects untouched, the clone takes
#       a commit where nothing has configured an identity, neither an inherited
#       GIT_CONFIG nor a caller's own global branch.<name>.* setting breaks the
#       run or lets the clone's config surgery reach outside it, an inherited
#       GIT_DIR does not aim that surgery at the source but IS reported on stderr
#       (the helper's unset cannot reach the caller's shell) without joining the
#       path on stdout while GIT_PREFIX and the other entries on git's list that
#       aim git nowhere are NOT reported, a remote surviving in the caller's
#       global or command-scope
#       config is refused rather than left live in the clone, an anonymous push
#       target surviving there as remote.pushDefault or branch.<name>.pushRemote
#       /.remote is refused for the same reason while a branch.<name>.rebase is
#       not, an alternate-backed source yields a clone that outlives the
#       deletion of the store it borrowed from, and a PARTIAL-clone source —
#       whose missing objects only a fetch from its promisor remote brings in —
#       is refused outright before anything is created, by each of the three
#       markers git registers a promisor remote from, read as git reads them and
#       from where git reads them: a multivalued promisor whose LAST value is
#       false is still refused, one in command-scope config is seen at all, an
#       unreadable value counts as set, and a global-file extensions.partialClone
#       — which git ignores — is not mistaken for one, while a repository whose
#       only promisor key is an ordinary single `false` still gets its clone.
#       A SHALLOW source is bounded rather than refused: exact for the refs that
#       arrive, loudly fatal for one whose object the fetch never brought, and
#       quietly missing the objects no ref reaches at all. The alternate-backed
#       source carries the second half of that bound by a different route: the
#       dissociation's repack cannot see an unreachable object held only by the
#       donor, or packed in the source before it was stranded, while a loose one
#       there survives — all three asserted. Both bounds are characterization
#       cases with a self-contained control beside them: close either and the
#       assertions invert rather than disappear
#   (c) the <ref> interface: default is the INVOKING worktree's HEAD (not the
#       main worktree's), branch/tag/sha/rev forms, a short name that is both a
#       branch and a tag resolving to the branch, a qualified ref and a
#       $GIT_DIR pseudo-ref each still winning over a branch named literally
#       like it — in every spelling git's own rules resolve, upper-case hex, any
#       run of whitespace after `ref:`, a target written on the line BELOW it, a
#       symref aimed at another root ref or at HEAD or through a chain, and a
#       one-level file no root-ref list carries (COMMIT_EDITMSG holding an id, a
#       lower-case name) included — while a same-named $GIT_DIR file whose
#       CONTENT is not a ref (COMMIT_EDITMSG and its all-caps kin holding prose,
#       an empty root-ref file, a BISECT_START holding a branch name, a dangling
#       NOTES_MERGE_REF, a symref carrying a second line under its target, a bare
#       id of the OTHER hash width, and either padded with a non-ASCII space git
#       does not treat as whitespace) leaves the branch checked out; a MERGE_RR
#       whose rerere id names no object refused rather than answered with the
#       branch, while the same name with no rerere file underneath is an ordinary
#       branch again; the branch-over-tag preference held to the plain tag rather
#       than extended to a root ref aimed at one; a local head whose name begins
#       with a dash checked out rather than parsed as options; and refusal on a
#       bad ref
#   (d) the ref namespace: an exact mirror of the source's refs, demonstrated on
#       a source carrying refs outside refs/heads/ and refs/tags/ — including one
#       hiding a namespace from upload-pack, which a refspec fetch would drop
#   (e) clone-root refusals: inside the worktree, the git dir, another worktree,
#       or reached through a symlink — non-zero with an empty stdout — plus the
#       worktree enumeration failing closed on every shape of bad listing
#   (f) reuse: an existing clone is refused (a concurrent sibling may be in it),
#       --replace re-derives it pristine, and neither a stranger's directory nor
#       one whose marker records another clone is ever discarded
#   (g) per-agent and per-worktree path scoping, and the sibling case where two
#       callers share both
#   (h) dc-remove: removes a dirty clone, refuses a path, refuses an empty slug
#       even when another argument follows, refuses a foreign or mis-marked
#       directory, no-ops on an unknown slug, and removes exactly the path
#       dc-enter printed (which pins the two path derivations together) —
#       including under an inherited GIT_DIR, which it drops exactly as dc-enter
#       does so both helpers derive their paths from the same repository
#   (i) the incident's shape: a failed clone step must not let a script proceed
#       to operate in the repository root, even when piped as the original was
#   (j) hardlink policy: --no-hardlinks by default, DC_HARDLINKS=1 opt-in, with
#       the isolation guarantee holding either way
#   (k) clone-root hygiene: repeated separators collapse, a relative root and a
#       newline-bearing one are refused by both helpers — including a newline at
#       the very end and one only the RESOLVED root has — and a newline anywhere
#       in the SOURCE's path, end included, still works — as does a SINGLE
#       QUOTE there, which is the character the clone's ownership-trust
#       plumbing has to escape for the shell git runs `--upload-pack` through.
#       These are the checks that must be made on the value the caller supplied
#       rather than on the canonicalized one, since canonicalizing changes it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DC_ENTER="${DC_ENTER_HELPER:-${ROOT_DIR}/plugins/dev-skills/bin/dc-enter}"
DC_REMOVE="${DC_REMOVE_HELPER:-${ROOT_DIR}/plugins/dev-skills/bin/dc-remove}"

for helper in "$DC_ENTER" "$DC_REMOVE"; do
	[ -x "$helper" ] || {
		echo "test-dc-helpers: helper not found or not executable: $helper" >&2
		exit 1
	}
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dc-helpers-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Hermetic git: no user or system config leaks in, so the helpers' behavior does
# not depend on the machine running the suite.
# A fresh HOME does not achieve that on its own. `GIT_CONFIG_GLOBAL` and
# `XDG_CONFIG_HOME` both redirect git's "global" config away from $HOME;
# `GIT_CONFIG_COUNT` and `GIT_CONFIG_PARAMETERS` inject config settings with no
# file involved at all — git exports the latter to every subprocess of a `git -c`
# invocation, so a suite run from inside a hook, an alias, or `submodule foreach`
# inherits one; and the GIT_AUTHOR_*/GIT_COMMITTER_*/EMAIL variables supply a
# committer identity directly. A development container setting any of them —
# powbox sets GIT_CONFIG_GLOBAL — would hand this suite the identity a clean CI
# runner does not have, so a fixture step that forgot the `g` wrapper below would
# pass locally and exit 128 in CI. Clearing them makes a local run reproduce the
# runner, and the probe below asserts that it does rather than trusting this list
# to stay complete.
# `GIT_CONFIG` is cleared for a different reason, and for the SUITE's own sake
# rather than the helpers'. It supplies no identity to git as a whole — `git
# config` is the only command that honours it — but it redirects that command's
# reads AND writes at the named file, and this suite asserts on the clones' own
# configuration with `git -C "$CLONE" config`. Left set, those assertions would
# describe the caller's file instead of the clone they name. dc-enter drops the
# variable itself so a caller carrying one still gets a clone; section (b)
# asserts that, which is a separate job from keeping these reads honest.
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
export XDG_CONFIG_HOME="$WORK/home/.config"
mkdir -p "$HOME"
# Scrubbing the environment is still not enough on its own: with nothing
# configured at all, git INVENTS an identity from the account's gecos name and
# the hostname, and accepts the invented one wherever that hostname carries a
# domain. On such a host a fixture step missing the `g` wrapper would commit
# happily and section (b)'s check of dc-enter's own identity fallback would pass
# without the fallback ever running. `user.useConfigOnly` forbids the invention,
# so "no identity unless something configured one" holds everywhere rather than
# only where the hostname happens to be bare. This is the one setting the suite
# deliberately puts in its throwaway HOME; everything else stays scrubbed.
printf '[user]\n\tuseConfigOnly = true\n' >"$HOME/.gitconfig"
export DC_AGENT=testagent
unset DC_ROOT DC_HARDLINKS

fails=0
checks=0

assert_eq() {
	checks=$((checks + 1))
	if [ "$2" != "$3" ]; then
		fails=$((fails + 1))
		printf 'FAIL [%s]: got %q, want %q\n' "$1" "$2" "$3" >&2
	fi
}
assert_ne() {
	checks=$((checks + 1))
	if [ "$2" = "$3" ]; then
		fails=$((fails + 1))
		printf 'FAIL [%s]: both values are %q, expected them to differ\n' "$1" "$2" >&2
	fi
}
assert_contains() {
	checks=$((checks + 1))
	case "$2" in
	*"$3"*) ;;
	*)
		fails=$((fails + 1))
		printf 'FAIL [%s]: %q does not contain %q\n' "$1" "$2" "$3" >&2
		;;
	esac
}
assert_true() {
	checks=$((checks + 1))
	if [ "$2" != true ]; then
		fails=$((fails + 1))
		printf 'FAIL [%s]: expected true\n' "$1" >&2
	fi
}

# Run a command with the working directory inside a fixture repository. The `cd`
# lives in a subshell, so the suite's own working directory never moves. Sets
# RC/OUT/ERR; OUT and ERR are captured separately so stdout purity is testable.
RC=0
OUT=""
ERR=""
in_repo() {
	local dir="$1"
	shift
	local err_file="$WORK/.stderr"
	set +e
	# The stderr redirection lives INSIDE the command substitution: on an
	# assignment it would be applied after the substitution had already run and
	# would capture nothing.
	OUT="$(
		{
			cd "$dir" || exit 97
			"$@"
		} 2>"$err_file"
	)"
	RC=$?
	set -e
	ERR="$(cat "$err_file")"
}

g() { git -c user.email=test@invalid -c user.name=Test "$@"; }

# The environment block above, asserted rather than assumed. `g` exists because
# the fixtures must commit where nothing offers an identity, and section (b)
# proves dc-enter fills that gap inside the clone — both are vacuous if some
# variable this list does not know about still supplies one. A leak makes those
# checks pass here and exit 128 on a clean runner, which is the single failure
# mode the environment block exists to prevent, so it is caught at the top of the
# run rather than diagnosed from a CI log.
git init -q -b main "$WORK/hermetic-probe"
assert_eq "env: no committer identity reaches git from the host" \
	"$(git -C "$WORK/hermetic-probe" var GIT_COMMITTER_IDENT 2>/dev/null || echo none)" "none"

# Carry the path dc-enter printed into a named variable, ABORTING the run rather
# than letting an unusable one flow onward. An empty $OUT is the danger: `git -C
# ''` is documented to leave the working directory unchanged, so it does not fail
# — it silently addresses whatever repository the suite is running in, which is
# THIS one, and the mutating assertions in sections (b), (f), (h) and (j) would
# then delete refs, force branches, and run `gc --prune=now` against a `.git`
# shared with every sibling worktree. `dirname ""` is the same trap one step on:
# it yields ".", which is how an empty path becomes `rm -rf .`. Both are the
# incident's own shape — an unchecked path from a step that did not do what the
# script assumed — so a suite about destructive-command safety fails closed here
# instead of asserting and carrying on.
# Every path this suite CARRIES FORWARD goes through here. The few places that
# use "$OUT" inline, in sections (c) and (d), are single read-only comparisons:
# an empty path there can only make an assertion fail, never mutate or remove
# anything.
require_clone() {
	local var="$1" label="$2"
	case "$OUT" in
	"$WORK"/*) ;;
	*)
		printf 'test-dc-helpers: %s: expected a clone path under %q, got %q — aborting before it reaches git -C or rm\n' \
			"$label" "$WORK" "$OUT" >&2
		exit 1
		;;
	esac
	[ -d "$OUT/.git" ] || {
		printf 'test-dc-helpers: %s: %q is not a clone — aborting before it reaches git -C or rm\n' \
			"$label" "$OUT" >&2
		exit 1
	}
	printf -v "$var" '%s' "$OUT"
}

# Inode number of a path, GNU stat first and BSD stat as the fallback.
inode_of() {
	local path="$1"
	stat -c '%i' -- "$path" 2>/dev/null || stat -f '%i' -- "$path"
}

# Permission bits of a path as octal digits, by the same GNU-then-BSD rule.
# BSD's `%Lp` is the three-digit permission field; its `%p` would include the
# file type and answer 40700 for a directory.
mode_of() {
	local path="$1"
	stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Lp' -- "$path"
}

# refs, and the full set of reachable objects, as comparable strings. The ref
# comparison includes %(symref), so a mirror that flattened a symbolic ref into a
# direct one at the same commit does not pass as exact.
refs_of() { git -C "$1" for-each-ref --format='%(refname) %(objectname) %(symref)'; }
objects_of() {
	local raw
	raw="$(git -C "$1" rev-list --objects --all)"
	sort <<<"$raw"
}

# A source repository carrying refs outside refs/heads/ and refs/tags/, an
# unreachable commit held only by one of them, a tag, a stash, and a linked
# worktree whose HEAD differs from the main worktree's.
make_source() {
	local dir="$1"
	git init -q -b main "$dir"
	g -C "$dir" commit -q --allow-empty -m one
	g -C "$dir" commit -q --allow-empty -m two
	printf 'tracked\n' >"$dir/file.txt"
	g -C "$dir" add file.txt
	g -C "$dir" commit -q -m three
	g -C "$dir" tag v1
	# An unreachable commit, reachable only through a non-standard namespace —
	# exactly the shape (refs/pruned/*) the run that produced this task tested.
	g -C "$dir" commit -q --allow-empty -m reserved
	git -C "$dir" update-ref refs/pruned/reserved HEAD
	g -C "$dir" reset -q --hard HEAD~1
	git -C "$dir" update-ref refs/pre-rebase/main HEAD
	# Through the `g` wrapper: `notes add` writes a notes COMMIT, so it needs an
	# identity the hermetic environment above deliberately withholds. Its stderr is
	# NOT swallowed: `set -e` aborts the whole run if this fails, and a run that
	# dies with no diagnostic at all is the "why did this die?" experience the
	# missing wrapper produced. Adding a fresh note prints nothing on stdout, so
	# only that side needs quieting.
	g -C "$dir" notes add -f -m "a note" HEAD >/dev/null
	printf 'stashed\n' >"$dir/file.txt"
	g -C "$dir" stash -q
	g -C "$dir" branch -q other HEAD~1
	# A symbolic ref — what every real clone has as refs/remotes/origin/HEAD.
	git -C "$dir" update-ref refs/remotes/origin/main HEAD
	git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	g -C "$dir" worktree add -q "$dir-wt" -b wtbranch HEAD~1
}

echo "== (a) stdout purity and the calling convention =="
SRC1="$WORK/a/src"
mkdir -p "$WORK/a"
make_source "$SRC1"
export DC_ROOT="$WORK/a/root"
in_repo "$SRC1" "$DC_ENTER" probe
assert_eq "a: exit status" "$RC" 0
case "$OUT" in
/*) assert_eq "a: stdout is an absolute path" true true ;;
*) assert_eq "a: stdout is an absolute path" "$OUT" "<absolute path>" ;;
esac
# `wc -l` is compared as a string, and BSD wc pads its count with leading spaces,
# so the whitespace is stripped rather than trusted to be absent.
assert_eq "a: stdout is exactly one line" "$(wc -l <<<"$OUT" | tr -d '[:space:]')" 1
require_clone CLONE_A "a: probe"
assert_true "a: clone is a git repository" "$([ -d "$CLONE_A/.git" ] && echo true || echo false)"
assert_true "a: clone is outside the source" "$(case "$CLONE_A" in "$SRC1"/*) echo false ;; *) echo true ;; esac)"
assert_eq "a: clone tree is clean" "$(git -C "$CLONE_A" status --porcelain)" ""
assert_eq "a: no remote points back at the source" "$(git -C "$CLONE_A" remote)" ""
# ... and no config left naming the remote the clone no longer has, which would
# make a stray push fail with "does not appear to be a git repository" rather
# than the honest "no upstream".
assert_eq "a: no stale remote or upstream config survives" \
	"$(git -C "$CLONE_A" config --get-regexp '^(remote|branch)\.' || true)" ""
assert_eq "a: uncommitted source changes are not carried" "$(cat "$CLONE_A/file.txt")" "tracked"
# An empty first argument is rejected as the empty SLUG it is, rather than
# sliding the next argument into the slug's place.
in_repo "$SRC1" "$DC_ENTER" "" probe
assert_ne "a: an empty slug is refused even with a second argument" "$RC" 0
assert_eq "a: the empty-slug refusal is silent on stdout" "$OUT" ""
in_repo "$SRC1" "$DC_ENTER" probe ""
assert_ne "a: an empty <ref> is refused" "$RC" 0
assert_eq "a: the empty-ref refusal is silent on stdout" "$OUT" ""
# The documented convention: command substitution yields a usable path.
cat >"$WORK/convention.sh" <<'SCRIPT'
set -euo pipefail
DC="$("$DC_ENTER_BIN" conv)"
[ -n "$DC" ] && [ -d "$DC/.git" ] || exit 1
printf '%s\n' "$DC"
SCRIPT
in_repo "$SRC1" env "DC_ENTER_BIN=$DC_ENTER" bash "$WORK/convention.sh"
assert_eq "a: DC=\$(dc-enter …) succeeds" "$RC" 0
assert_true "a: substituted path is usable" "$([ -d "$OUT/.git" ] && echo true || echo false)"
# --help is the one other thing allowed on stdout, and only on request.
in_repo "$SRC1" "$DC_ENTER" --help
assert_eq "a: --help exits 0" "$RC" 0
assert_contains "a: --help prints usage on stdout" "$OUT" "usage: dc-enter"
in_repo "$SRC1" "$DC_REMOVE" --help
assert_eq "a: dc-remove --help exits 0" "$RC" 0
assert_contains "a: dc-remove --help prints usage on stdout" "$OUT" "usage: dc-remove"

echo "== (b) the isolation guarantee =="
REFS_BEFORE="$(refs_of "$SRC1")"
OBJS_BEFORE="$(objects_of "$SRC1")"
git -C "$CLONE_A" update-ref refs/heads/x HEAD
git -C "$CLONE_A" branch -q -f other HEAD
git -C "$CLONE_A" update-ref -d refs/pruned/reserved
git -C "$CLONE_A" update-ref -d refs/pre-rebase/main
git -C "$CLONE_A" update-ref -d refs/stash
git -C "$CLONE_A" update-ref -d refs/tags/v1
git -C "$CLONE_A" checkout -q --detach HEAD
git -C "$CLONE_A" branch -q -D main
# Deliberately NOT through the `g` wrapper, which every other fixture commit
# uses: the wrapper supplies an identity of its own, so a clone whose fallback
# identity dc-enter failed to configure would commit just the same and the check
# below would prove nothing. Nothing else in this environment offers one — the
# probe at the top of the run asserts that — so this succeeds only because
# dc-enter filled the gap itself.
in_repo "$CLONE_A" git commit -q --allow-empty -m "clone-only commit"
assert_eq "b: the clone can commit with no identity available anywhere" "$RC" 0
git -C "$CLONE_A" reflog expire --expire=now --all
git -C "$CLONE_A" gc --prune=now --quiet
assert_eq "b: source refs unchanged" "$(refs_of "$SRC1")" "$REFS_BEFORE"
assert_eq "b: source reachable objects unchanged" "$(objects_of "$SRC1")" "$OBJS_BEFORE"
in_repo "$SRC1" git fsck --no-progress --no-dangling --connectivity-only
assert_eq "b: source still passes fsck" "$RC" 0
assert_eq "b: the unreachable ref's commit survives in the source" \
	"$(git -C "$SRC1" cat-file -t "$(git -C "$SRC1" rev-parse refs/pruned/reserved)")" "commit"
assert_contains "b: clone accepted a commit" "$(git -C "$CLONE_A" log -1 --format=%s)" "clone-only commit"

# A caller carrying `GIT_CONFIG` in its environment. `git config` is the only
# command that honours it, and `git config` is precisely what dc-enter uses to
# detach the clone's remote, clear its stale upstream configuration, and fill its
# identity — so an inherited one aims all of that at the caller's file. dc-enter
# drops the variable; without that it dies at the first of those calls with
# `no such section: remote.dc-source`, blaming the clone for the caller's
# environment, and produces no clone at all.
mkdir -p "$WORK/b"
GIT_CONFIG_EXTERNAL="$WORK/b/external.gitconfig"
printf '[dc]\n\tsentinel = untouched\n' >"$GIT_CONFIG_EXTERNAL"
GIT_CONFIG_EXTERNAL_BEFORE="$(cat "$GIT_CONFIG_EXTERNAL")"
in_repo "$SRC1" env "GIT_CONFIG=$GIT_CONFIG_EXTERNAL" "$DC_ENTER" gitconfigenv
assert_eq "b: an inherited GIT_CONFIG still yields a clone" "$RC" 0
require_clone CLONE_GITCONFIG "b: gitconfigenv"
assert_eq "b: ... whose identity landed in the CLONE's own config" \
	"$(git -C "$CLONE_GITCONFIG" config --local user.email)" "dc-enter@invalid"
assert_eq "b: ... and no stale remote or upstream config survived there either" \
	"$(git -C "$CLONE_GITCONFIG" config --local --get-regexp '^(remote|branch)\.' || true)" ""
assert_eq "b: ... leaving the file GIT_CONFIG named untouched" \
	"$(cat "$GIT_CONFIG_EXTERNAL")" "$GIT_CONFIG_EXTERNAL_BEFORE"
# ... and the caller IS warned about it, like the repository-targeting variables
# below. The helper's unset reached its own process only: the caller's shell
# still exports GIT_CONFIG, so their `git -C "$DC" config user.name x` writes
# into the file it names rather than into the clone they were handed.
assert_contains "b: ... while naming GIT_CONFIG in the warning on stderr" "$ERR" "GIT_CONFIG"

# The same boundary from the other side: a caller whose own global config carries
# a `branch.<name>.*` setting. `branch.main.rebase = true` is an everyday one, and
# the branch it names is the one the fixture's clone actually has. dc-enter
# enumerates the clone's stale upstream config `--local`; read merged instead, the
# loop is handed a key that lives only in the caller's file, `--unset-all` finds
# nothing local to remove, and the helper dies naming a key it never wrote. The
# clone still has to come out with no remote or upstream config of its own.
GLOBAL_BRANCH_CFG="$WORK/b/global-branch.gitconfig"
printf '[user]\n\tuseConfigOnly = true\n[branch "main"]\n\trebase = true\n' >"$GLOBAL_BRANCH_CFG"
in_repo "$SRC1" env "GIT_CONFIG_GLOBAL=$GLOBAL_BRANCH_CFG" "$DC_ENTER" globalbranchcfg
assert_eq "b: a caller's global branch.<name>.* still yields a clone" "$RC" 0
require_clone CLONE_GLOBALBRANCH "b: globalbranchcfg"
assert_eq "b: ... with no remote or upstream config of its own left behind" \
	"$(git -C "$CLONE_GLOBALBRANCH" config --local --get-regexp '^(remote|branch)\.' || true)" ""
assert_eq "b: ... and the caller's global config untouched" \
	"$(git config --file "$GLOBAL_BRANCH_CFG" --get branch.main.rebase)" "true"

# A caller carrying `GIT_DIR`, the variable that BEATS `git -C`. dc-enter aims
# its ref surgery at the clone with `git -C "$CLONE_DIR"`, and an inherited
# GIT_DIR overrides that for every one of those commands — so the transaction
# that clears the refs `git clone` created runs against the SOURCE and empties
# it, the isolation guarantee inverted by one variable in the environment.
# On a fixture of its own: the assertion here is precisely "the source still has
# its refs", and a regression would otherwise take the rest of the run's
# fixtures with it and bury the cause. The sanitize is driven by git's own `git
# rev-parse --local-env-vars` list, so GIT_DIR's siblings (GIT_WORK_TREE,
# GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY, …) go with it rather than one at a time.
GITDIR_SRC="$WORK/b/gitdir-src"
git init -q -b main "$GITDIR_SRC"
g -C "$GITDIR_SRC" commit -q --allow-empty -m one
g -C "$GITDIR_SRC" branch -q other
GITDIR_REFS_BEFORE="$(refs_of "$GITDIR_SRC")"
in_repo "$GITDIR_SRC" env "GIT_DIR=$GITDIR_SRC/.git" "$DC_ENTER" gitdirenv
assert_eq "b: an inherited GIT_DIR still yields a clone" "$RC" 0
require_clone CLONE_GITDIR "b: gitdirenv"
assert_eq "b: ... with the source's refs untouched" \
	"$(refs_of "$GITDIR_SRC")" "$GITDIR_REFS_BEFORE"
assert_eq "b: ... and the clone mirroring them rather than inheriting the source" \
	"$(refs_of "$CLONE_GITDIR")" "$GITDIR_REFS_BEFORE"
assert_ne "b: ... in a directory that is not the source's" "$CLONE_GITDIR" "$GITDIR_SRC"
# ... and the caller is TOLD, because that unset reached this helper's process
# and nothing else. The caller's own shell still exports GIT_DIR, it still beats
# `git -C`, and their `git -C "$DC" update-ref -d refs/heads/keepme` therefore
# deletes a ref in the SOURCE while the path they were handed says otherwise.
# dc-enter cannot fix that environment and does not refuse over it — git exports
# GIT_DIR to hooks and to `submodule foreach`, so refusing would lock the helper
# out of scripted contexts it is meant for — so the warning is the whole
# mitigation and its absence would be the bug.
assert_contains "b: ... and the caller is warned, on stderr, naming the variable" "$ERR" "GIT_DIR"
assert_contains "b: ... told the unset cannot reach their shell" "$ERR" "cannot reach your shell"
# The warning goes to stderr and NOTHING joins the path on stdout: the whole
# calling convention is DC="$(dc-enter probe)", and a warning that leaked there
# would be appended to the path a caller then hands to git or rm.
assert_eq "b: ... while stdout stays exactly the one clone path" \
	"$(wc -l <<<"$OUT" | tr -d '[:space:]')" 1
assert_eq "b: ... which is the path require_clone accepted" "$OUT" "$CLONE_GITDIR"
# The same convention end to end, under the hostile environment: the documented
# DC="$(dc-enter …)" must still yield a usable path, not a path with a warning
# glued to it.
in_repo "$GITDIR_SRC" env "GIT_DIR=$GITDIR_SRC/.git" "DC_ENTER_BIN=$DC_ENTER" \
	bash "$WORK/convention.sh"
assert_eq "b: ... so DC=\$(dc-enter …) still succeeds under an inherited GIT_DIR" "$RC" 0
assert_true "b: ... yielding a usable path uncontaminated by the warning" \
	"$([ -d "$OUT/.git" ] && echo true || echo false)"
# And no false alarm: a caller carrying none of those variables gets no warning
# at all, so the one above means what it says.
in_repo "$GITDIR_SRC" "$DC_ENTER" cleanenv
assert_eq "b: a clean environment still yields a clone" "$RC" 0
assert_eq "b: ... with no environment warning on stderr" "$ERR" ""
# Nor for the variables on git's list that AIM git nowhere. The warning's advice
# is "clear these or your own commands against the clone path act on what they
# name", so a variable that names nothing outside the current repository must not
# appear in it. `GIT_PREFIX` is the one that matters in practice: it carries the
# caller's subdirectory within the worktree, redirects nothing, and git exports it
# to every alias — so reporting it fires the entire warning on a plain `git
# someAlias` wrapper that has nothing dangerous set at all.
in_repo "$GITDIR_SRC" env "GIT_PREFIX=sub/" "$DC_ENTER" gitprefixenv
assert_eq "b: an inherited GIT_PREFIX still yields a clone" "$RC" 0
assert_eq "b: ... with no environment warning on stderr" "$ERR" ""
# Same for the entries on that list that are settings rather than locations: they
# change how git reads whichever repository it is already pointed at.
in_repo "$GITDIR_SRC" env "GIT_NO_REPLACE_OBJECTS=1" "$DC_ENTER" noreplaceenv
assert_eq "b: an inherited GIT_NO_REPLACE_OBJECTS still yields a clone" "$RC" 0
assert_eq "b: ... with no environment warning on stderr" "$ERR" ""

# A remote defined under dc-enter's own remote name OUTSIDE the clone's config.
# `git config --local --remove-section` can only remove what this helper's `git
# clone` wrote, so an outer definition survives it and stays live in the clone:
# `git push dc-source HEAD:leaked` then creates a branch in the invoking
# repository, which is the one thing the header promises has nowhere to go. No
# local write deletes an outer section, so the clone is refused rather than
# handed back with quietly weaker isolation than it claims.
GLOBAL_REMOTE_CFG="$WORK/b/global-remote.gitconfig"
printf '[user]\n\tuseConfigOnly = true\n[remote "dc-source"]\n\turl = %s\n' "$SRC1" >"$GLOBAL_REMOTE_CFG"
in_repo "$SRC1" env "GIT_CONFIG_GLOBAL=$GLOBAL_REMOTE_CFG" "$DC_ENTER" survivingremote
assert_ne "b: a remote surviving in the caller's global config is refused" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_contains "b: ... naming the remote that survived" "$ERR" "dc-source"
# The same from COMMAND-SCOPE configuration, which `git -c` exports to every
# subprocess and which therefore reaches the clone's later user too. Any
# surviving remote counts, not just the name this helper happens to use.
in_repo "$SRC1" env "GIT_CONFIG_COUNT=1" "GIT_CONFIG_KEY_0=remote.elsewhere.url" \
	"GIT_CONFIG_VALUE_0=$SRC1" "$DC_ENTER" survivingremote2
assert_ne "b: a remote surviving in command-scope config is refused" "$RC" 0
assert_eq "b: ... silently on stdout too" "$OUT" ""
assert_contains "b: ... naming that one as well" "$ERR" "elsewhere"

# A push target that is not a REMOTE at all, and so is invisible to the check
# above. With no <repository> argument `git push` consults
# branch.<current>.pushRemote, then remote.pushDefault, then
# branch.<current>.remote — and a value that names no configured remote is used
# as a path or URL directly, an anonymous remote `git remote` never lists. Each
# of the three, defined in the caller's own configuration where no `--local`
# write can reach it, leaves a bare `git push` in the clone writing branches
# straight into the invoking repository (measured with push.default=current, with
# branch.<name>.merge alongside, and with push.autoSetupRemote=true). Refused
# exactly as a surviving remote is.
PUSH_CFG_SRC="$WORK/b/push-src"
git init -q -b main "$PUSH_CFG_SRC"
g -C "$PUSH_CFG_SRC" commit -q --allow-empty -m one
PUSH_CFG_FILE="$WORK/b/push-target.gitconfig"
for push_entry in 'remote|pushDefault' 'branch "main"|pushRemote' 'branch "main"|remote'; do
	push_section="${push_entry%%|*}"
	push_var="${push_entry##*|}"
	push_slug="$(printf '%s' "$push_entry" | tr -dc 'A-Za-z' | tr '[:upper:]' '[:lower:]')"
	printf '[user]\n\tuseConfigOnly = true\n[%s]\n\t%s = %s\n' \
		"$push_section" "$push_var" "$PUSH_CFG_SRC" >"$PUSH_CFG_FILE"
	in_repo "$PUSH_CFG_SRC" env "GIT_CONFIG_GLOBAL=$PUSH_CFG_FILE" "$DC_ENTER" "pt-$push_slug"
	assert_ne "b: a push target surviving as [$push_section] $push_var is refused" "$RC" 0
	assert_eq "b: ... silently on stdout ($push_slug)" "$OUT" ""
	assert_contains "b: ... naming the setting that survived ($push_slug)" "$ERR" "push-target setting"
done
# ... and from COMMAND-SCOPE configuration too, which `git -c` exports to every
# subprocess and which the clone's later user therefore also sees.
in_repo "$PUSH_CFG_SRC" env "GIT_CONFIG_COUNT=1" "GIT_CONFIG_KEY_0=remote.pushDefault" \
	"GIT_CONFIG_VALUE_0=$PUSH_CFG_SRC" "$DC_ENTER" pt-cmdscope
assert_ne "b: a push target surviving in command-scope config is refused" "$RC" 0
assert_eq "b: ... silently on stdout as well" "$OUT" ""
assert_contains "b: ... naming remote.pushdefault" "$ERR" "remote.pushdefault"
# Not over-broad: `branch.<name>.rebase` is an everyday global setting and names
# no push destination, so the clone it produces is still handed back. That is the
# globalbranchcfg case above, which shares this boundary.
in_repo "$PUSH_CFG_SRC" env "GIT_CONFIG_GLOBAL=$GLOBAL_BRANCH_CFG" "$DC_ENTER" pt-notatarget
assert_eq "b: a global branch.<name>.rebase is not read as a push target" "$RC" 0
require_clone CLONE_NOTATARGET "b: pt-notatarget"
assert_eq "b: ... and that clone has no remote either" "$(git -C "$CLONE_NOTATARGET" remote)" ""

# A source that is ITSELF a borrowing clone. `git clone` of a local path carries
# `objects/info/alternates` across (a relative entry resolved to an absolute
# path rather than byte-for-byte), so undissociated the disposable clone goes
# on borrowing from a third repository: it holds no copy of the objects it is
# supposed to own and breaks outright when that store is pruned.
# The check that settles it is the destructive one — the external store is
# DELETED and the clone must still be whole.
ALT_BASE="$WORK/b/alt-base"
git init -q -b main "$ALT_BASE"
g -C "$ALT_BASE" commit -q --allow-empty -m one
ALT_SRC="$WORK/b/alt-src"
git clone -q --shared "$ALT_BASE" "$ALT_SRC"
assert_true "b: the alternate-backed fixture really does borrow" \
	"$([ -f "$ALT_SRC/.git/objects/info/alternates" ] && echo true || echo false)"
in_repo "$ALT_SRC" "$DC_ENTER" alternates
assert_eq "b: an alternate-backed source still yields a clone" "$RC" 0
require_clone CLONE_ALT "b: alternates"
assert_true "b: ... which borrows from nobody" \
	"$([ -e "$CLONE_ALT/.git/objects/info/alternates" ] && echo false || echo true)"
rm -rf "$ALT_BASE"
assert_eq "b: ... and still holds its history once the external store is deleted" \
	"$(git -C "$CLONE_ALT" rev-list --count --all)" "1"
in_repo "$CLONE_ALT" git fsck --no-progress --no-dangling --connectivity-only
assert_eq "b: ... passing fsck without it" "$RC" 0

# ... and the case that pins WHEN the borrowing stops. `git clone --dissociate`
# copies in only what the refs the initial clone fetched can reach — branches and
# tags — so an object reachable solely from a source ref in another namespace is
# not copied, and dropping the alternate then leaves the mirror with nothing to
# point its ref at ("trying to write ref ... with nonexistent object"). The
# fixture is exactly that: a commit that exists ONLY in the external store, named
# only by a `refs/pruned/*` ref in the borrowing source. Both halves of the
# contract are asserted — the ref arrives, and it still resolves once the store
# it came from is gone.
ALT2_BASE="$WORK/b/alt2-base"
git init -q -b main "$ALT2_BASE"
g -C "$ALT2_BASE" commit -q --allow-empty -m one
g -C "$ALT2_BASE" commit -q --allow-empty -m hidden
ALT2_HIDDEN="$(git -C "$ALT2_BASE" rev-parse HEAD)"
g -C "$ALT2_BASE" reset -q --hard HEAD~1
ALT2_SRC="$WORK/b/alt2-src"
git clone -q --shared "$ALT2_BASE" "$ALT2_SRC"
git -C "$ALT2_SRC" update-ref refs/pruned/hidden "$ALT2_HIDDEN"
assert_eq "b: the borrowed-object fixture really is borrowed" \
	"$(git -C "$ALT2_SRC" cat-file -t "$ALT2_HIDDEN")" "commit"
# Decisive, because a fixture whose source held the object itself would pass the
# final assertion below without the deferred dissociation doing anything: neither
# loosely nor in a pack of its own, so the ONLY way the clone can end up with it
# is by copying it out of the alternate.
assert_true "b: ... and the source's own store does not hold it loose" \
	"$([ -e "$ALT2_SRC/.git/objects/${ALT2_HIDDEN:0:2}/${ALT2_HIDDEN:2}" ] && echo false || echo true)"
assert_eq "b: ... nor in a pack of its own" \
	"$(find "$ALT2_SRC/.git/objects/pack" -name '*.pack' 2>/dev/null | wc -l | tr -d '[:space:]')" "0"
in_repo "$ALT2_SRC" "$DC_ENTER" altborrowedref
assert_eq "b: a ref reaching an object only the alternate holds still yields a clone" "$RC" 0
require_clone CLONE_ALT2 "b: altborrowedref"
assert_eq "b: ... with that ref mirrored" \
	"$(git -C "$CLONE_ALT2" rev-parse refs/pruned/hidden)" "$ALT2_HIDDEN"
assert_true "b: ... and borrowing from nobody" \
	"$([ -e "$CLONE_ALT2/.git/objects/info/alternates" ] && echo false || echo true)"
rm -rf "$ALT2_BASE"
assert_eq "b: ... the borrowed object surviving the external store's deletion" \
	"$(git -C "$CLONE_ALT2" cat-file -t "$ALT2_HIDDEN")" "commit"
in_repo "$CLONE_ALT2" git fsck --no-progress --no-dangling --connectivity-only
assert_eq "b: ... and fsck clean without it" "$RC" 0

# The object store the deferred dissociation CANNOT repair: a source that is a
# PARTIAL clone. `--filter=blob:none` leaves objects on a promisor remote and git
# tolerates their absence only because that remote can still serve them; a local
# clone copies what is present and inherits none of that configuration, so
# unrefused the mirror succeeded, dc-enter exited 0, and the clone answered
# `fatal: Not a valid object name` for a blob the source served — a verification
# baseline disagreeing with the repository it claimed to copy, and with a tree
# filter it answers `path ... does not exist` instead, which is worse: an error
# asserting something false of the source. The refusal has to land before
# anything is created, so the assertions are on the exit status, an empty stdout,
# the marker named in the diagnostic, and an untouched clone root.
PARTIAL_UP="$WORK/b/partial-upstream"
git init -q -b main "$PARTIAL_UP"
printf 'base\n' >"$PARTIAL_UP/f.txt"
g -C "$PARTIAL_UP" add f.txt
g -C "$PARTIAL_UP" commit -q -m base
g -C "$PARTIAL_UP" checkout -q -b other
printf 'fetched on demand\n' >"$PARTIAL_UP/big.txt"
g -C "$PARTIAL_UP" add big.txt
g -C "$PARTIAL_UP" commit -q -m big
g -C "$PARTIAL_UP" checkout -q main
# Without this the file-transport upload-pack ignores the filter entirely
# ("filtering not recognized by server, ignoring") and the fixture below is an
# ordinary complete clone — which is why both halves of it are asserted rather
# than assumed: a complete fixture would satisfy the refusal checks for a reason
# that has nothing to do with partial clones.
git -C "$PARTIAL_UP" config uploadpack.allowFilter true
PARTIAL_SRC="$WORK/b/partial-src"
# `--no-local` because a clone from a local PATH copies the object store
# wholesale and no filter applies to it at all.
git clone -q --filter=blob:none --no-local "$PARTIAL_UP" "$PARTIAL_SRC"
assert_eq "b: the partial-clone fixture really is one" \
	"$(git -C "$PARTIAL_SRC" config --type=bool --get remote.origin.promisor)" "true"
assert_ne "b: ... missing an object its refs reach" \
	"$(git -C "$PARTIAL_SRC" rev-list --objects --all --missing=print | grep -c '^?' | tr -d '[:space:]')" "0"
PARTIAL_ROOT="$WORK/b/partial-root"
in_repo "$PARTIAL_SRC" env "DC_ROOT=$PARTIAL_ROOT" "$DC_ENTER" partialclone
assert_ne "b: a partial-clone source is refused" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_contains "b: ... naming the configuration it was decided by" "$ERR" "remote.origin.promisor"
assert_true "b: ... before creating anything under the clone root" \
	"$([ -e "$PARTIAL_ROOT" ] && echo false || echo true)"

# The same source with `remote.origin.promisor` REMOVED. Git registers the
# promisor remote from `remote.<name>.partialclonefilter` too — measured, the
# source still lazily fetches the blob with only that key left — so a check
# reading the promisor key alone hands back the broken clone this refusal exists
# to prevent. Both halves are asserted: that the stripped fixture is still a
# lazily-fetching partial clone, and that dc-enter still refuses it.
PARTIAL_FILTER_SRC="$WORK/b/partial-filter-src"
git clone -q --filter=blob:none --no-local "$PARTIAL_UP" "$PARTIAL_FILTER_SRC"
git -C "$PARTIAL_FILTER_SRC" config --unset remote.origin.promisor
assert_eq "b: the filter-only fixture keeps no promisor key" \
	"$(git -C "$PARTIAL_FILTER_SRC" config --get remote.origin.promisor || echo unset)" "unset"
assert_ne "b: ... while still missing an object its refs reach" \
	"$(git -C "$PARTIAL_FILTER_SRC" rev-list --objects --all --missing=print | grep -c '^?' | tr -d '[:space:]')" "0"
PARTIAL_FILTER_ROOT="$WORK/b/partial-filter-root"
in_repo "$PARTIAL_FILTER_SRC" env "DC_ROOT=$PARTIAL_FILTER_ROOT" "$DC_ENTER" partialfilter
assert_ne "b: a filter-only partial-clone source is refused too" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_contains "b: ... naming the filter key it was decided by" "$ERR" "remote.origin.partialclonefilter"
assert_true "b: ... before creating anything under the clone root" \
	"$([ -e "$PARTIAL_FILTER_ROOT" ] && echo false || echo true)"
# Last, because it MATERIALIZES the object: git treating the filter key alone as
# a promisor remote is the whole reason the refusal has to read it, and proving
# it earlier would leave the assertions above running against a complete fixture.
assert_eq "b: ... git itself fetching lazily on that key alone" \
	"$(git -C "$PARTIAL_FILTER_SRC" cat-file -p refs/remotes/origin/other:big.txt)" "fetched on demand"

# The third marker, on its own. Neither git 2.36.6 nor 2.47.3 writes
# `extensions.partialClone` at all — both register the promisor remote through
# the two `remote.<name>.*` keys above instead — so a repository carrying it is
# the one shape those cases cannot reach, and without this one that branch of the
# code is never executed.
PARTIAL_EXT_SRC="$WORK/b/partial-ext-src"
git init -q -b main "$PARTIAL_EXT_SRC"
g -C "$PARTIAL_EXT_SRC" commit -q --allow-empty -m one
git -C "$PARTIAL_EXT_SRC" config core.repositoryformatversion 1
git -C "$PARTIAL_EXT_SRC" config extensions.partialClone origin
PARTIAL_EXT_ROOT="$WORK/b/partial-ext-root"
in_repo "$PARTIAL_EXT_SRC" env "DC_ROOT=$PARTIAL_EXT_ROOT" "$DC_ENTER" partialext
assert_ne "b: an extensions.partialClone source is refused too" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_contains "b: ... naming that marker rather than the promisor one" "$ERR" "extensions.partialClone"
assert_true "b: ... before creating anything under the clone root" \
	"$([ -e "$PARTIAL_EXT_ROOT" ] && echo false || echo true)"

# `promisor` is multivalued here, `true` then `false`. git registers the promisor
# remote on the FIRST and never unregisters it — measured, this source still
# fetches the blob lazily — so reading only the last value (what `git config
# --get` reports) would wave it through. The refusal must read every value.
PARTIAL_MULTI_SRC="$WORK/b/partial-multi-src"
git clone -q --filter=blob:none --no-local "$PARTIAL_UP" "$PARTIAL_MULTI_SRC"
git -C "$PARTIAL_MULTI_SRC" config --unset-all remote.origin.partialclonefilter
git -C "$PARTIAL_MULTI_SRC" config --add remote.origin.promisor false
assert_eq "b: the multivalued fixture's LAST promisor value is false" \
	"$(git -C "$PARTIAL_MULTI_SRC" config --type=bool --get remote.origin.promisor)" "false"
assert_ne "b: ... while it still misses an object its refs reach" \
	"$(git -C "$PARTIAL_MULTI_SRC" rev-list --objects --all --missing=print | grep -c '^?' | tr -d '[:space:]')" "0"
PARTIAL_MULTI_ROOT="$WORK/b/partial-multi-root"
in_repo "$PARTIAL_MULTI_SRC" env "DC_ROOT=$PARTIAL_MULTI_ROOT" "$DC_ENTER" partialmulti
assert_ne "b: a trailing promisor=false does not lift the refusal" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_true "b: ... before creating anything under the clone root" \
	"$([ -e "$PARTIAL_MULTI_ROOT" ] && echo false || echo true)"
# Last, because it materializes the object and rewrites the marker git decided by.
assert_eq "b: ... git itself still fetching lazily despite that trailing false" \
	"$(git -C "$PARTIAL_MULTI_SRC" cat-file -p refs/remotes/origin/other:big.txt)" "fetched on demand"

# A promisor marker in COMMAND-SCOPE config rather than a file. git's promisor
# parser reads ordinary merged configuration, so a marker in
# `GIT_CONFIG_COUNT`/`GIT_CONFIG_PARAMETERS` is as real as one in .git/config —
# measured, a source with no marker of its own fetches lazily under an injected
# one. dc-enter strips those variables from its own commands, which is why this
# check restores them. The refusal reason is asserted, not just the exit status:
# an injected `remote.<name>.*` marker also makes that remote visible to the
# surviving-remote check, so a helper that could not see it at all still exits
# non-zero — for the wrong reason, after building the clone.
PARTIAL_ENV_SRC="$WORK/b/partial-env-src"
git init -q -b main "$PARTIAL_ENV_SRC"
g -C "$PARTIAL_ENV_SRC" commit -q --allow-empty -m one
PARTIAL_ENV_ROOT="$WORK/b/partial-env-root"
in_repo "$PARTIAL_ENV_SRC" env "DC_ROOT=$PARTIAL_ENV_ROOT" \
	"GIT_CONFIG_COUNT=1" "GIT_CONFIG_KEY_0=remote.origin.promisor" "GIT_CONFIG_VALUE_0=true" \
	"$DC_ENTER" partialenv
assert_ne "b: a command-scope promisor marker is refused" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_contains "b: ... as a partial clone, naming that marker" "$ERR" "remote.origin.promisor"
assert_true "b: ... before creating anything under the clone root" \
	"$([ -e "$PARTIAL_ENV_ROOT" ] && echo false || echo true)"

# ... and the boundary on the other side, which is where git's two readers part
# company. `extensions.partialClone` is a repository-format extension, taken from
# the repository's OWN config file: in a GLOBAL one it is visible to a merged
# `git config --get` and means nothing to git, so a check reading it merged would
# refuse every repository on the machine. The global file is what makes this
# decisive — a command-scope injection could not, since dc-enter strips those
# variables from its own environment and a merged read would not see one either.
PARTIAL_EXTGLOBAL_SRC="$WORK/b/partial-extglobal-src"
git init -q -b main "$PARTIAL_EXTGLOBAL_SRC"
g -C "$PARTIAL_EXTGLOBAL_SRC" commit -q --allow-empty -m one
PARTIAL_EXTGLOBAL_CFG="$WORK/b/partial-extglobal-gitconfig"
printf '[extensions]\n\tpartialClone = origin\n' >"$PARTIAL_EXTGLOBAL_CFG"
assert_eq "b: the global-file extensions fixture is invisible to a --local read" \
	"$(GIT_CONFIG_GLOBAL="$PARTIAL_EXTGLOBAL_CFG" git -C "$PARTIAL_EXTGLOBAL_SRC" config --local --get extensions.partialClone || echo unset)" "unset"
assert_eq "b: ... while a merged read does see it" \
	"$(GIT_CONFIG_GLOBAL="$PARTIAL_EXTGLOBAL_CFG" git -C "$PARTIAL_EXTGLOBAL_SRC" config --get extensions.partialClone)" "origin"
in_repo "$PARTIAL_EXTGLOBAL_SRC" env "GIT_CONFIG_GLOBAL=$PARTIAL_EXTGLOBAL_CFG" "$DC_ENTER" extensionglobal
assert_eq "b: a global-file extensions.partialClone is not a partial clone" "$RC" 0
require_clone CLONE_EXTGLOBAL "b: extensionglobal"
assert_eq "b: ... and its clone holds the source's history" \
	"$(git -C "$CLONE_EXTGLOBAL" rev-list --count --all)" "1"

# A `false` promisor key beside a filter key. git's parser treats the two
# independently — a false `promisor` simply does not register the remote, and the
# `partialclonefilter` then does — so the false must not end the scan. Measured:
# such a source still fetches lazily. Without this case, giving up at the first
# false-reading key passes every other check, because the `false`-only fixture
# has no filter key and the multivalued one has had its filter key removed.
PARTIAL_FALSEFILTER_SRC="$WORK/b/partial-falsefilter-src"
git clone -q --filter=blob:none --no-local "$PARTIAL_UP" "$PARTIAL_FALSEFILTER_SRC"
git -C "$PARTIAL_FALSEFILTER_SRC" config remote.origin.promisor false
assert_eq "b: the false-beside-filter fixture reads false for its promisor key" \
	"$(git -C "$PARTIAL_FALSEFILTER_SRC" config --type=bool --get remote.origin.promisor)" "false"
assert_eq "b: ... while keeping its filter key" \
	"$(git -C "$PARTIAL_FALSEFILTER_SRC" config --get remote.origin.partialclonefilter)" "blob:none"
PARTIAL_FALSEFILTER_ROOT="$WORK/b/partial-falsefilter-root"
in_repo "$PARTIAL_FALSEFILTER_SRC" env "DC_ROOT=$PARTIAL_FALSEFILTER_ROOT" "$DC_ENTER" partialfalsefilter
assert_ne "b: a false promisor does not cancel the filter key beside it" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_contains "b: ... naming the filter key as what decided it" "$ERR" "remote.origin.partialclonefilter"
# Last, because it materializes the object: git registering the remote from the
# filter key alone is the reason the false must not stop the scan.
assert_eq "b: ... git itself still fetching lazily under that pair" \
	"$(git -C "$PARTIAL_FALSEFILTER_SRC" cat-file -p refs/remotes/origin/other:big.txt)" "fetched on demand"

# The unreadable-value branch: git would die on this value rather than decide it,
# so the helper treats it as set rather than as absent.
PARTIAL_BOGUS_SRC="$WORK/b/partial-bogus-src"
git init -q -b main "$PARTIAL_BOGUS_SRC"
g -C "$PARTIAL_BOGUS_SRC" commit -q --allow-empty -m one
git -C "$PARTIAL_BOGUS_SRC" config remote.origin.promisor banana
PARTIAL_BOGUS_ROOT="$WORK/b/partial-bogus-root"
in_repo "$PARTIAL_BOGUS_SRC" env "DC_ROOT=$PARTIAL_BOGUS_ROOT" "$DC_ENTER" partialbogus
assert_ne "b: a promisor value git cannot read as a boolean is refused" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_true "b: ... before creating anything under the clone root" \
	"$([ -e "$PARTIAL_BOGUS_ROOT" ] && echo false || echo true)"

# A SHALLOW source, the third shape whose object store a local clone does not
# copy wholesale — git declines the optimization for one entirely and negotiates
# a pack instead. It is bounded rather than refused, because what it loses is
# objects no ref names rather than objects the source's refs reach, and all three
# halves of that bound are pinned below: an ordinary shallow source clones with a
# matching boundary; one whose refs reach past what the fetch brought dies at the
# mirror with nothing handed back; and an object no ref reaches quietly does not
# come across, which is the one place a shallow clone is a weaker baseline than
# the source.
SHALLOW_UP="$WORK/b/shallow-upstream"
git init -q -b main "$SHALLOW_UP"
for shallow_n in 1 2 3 4; do
	g -C "$SHALLOW_UP" commit -q --allow-empty -m "c$shallow_n"
done
SHALLOW_SRC="$WORK/b/shallow-src"
git clone -q --depth 2 --no-local "$SHALLOW_UP" "$SHALLOW_SRC"
assert_true "b: the shallow fixture really is shallow" \
	"$(git -C "$SHALLOW_SRC" rev-parse --is-shallow-repository)"
in_repo "$SHALLOW_SRC" "$DC_ENTER" shallowok
assert_eq "b: an ordinary shallow source still yields a clone" "$RC" 0
require_clone CLONE_SHALLOW "b: shallowok"
assert_true "b: ... which is shallow in the same way" \
	"$(git -C "$CLONE_SHALLOW" rev-parse --is-shallow-repository)"
assert_eq "b: ... with the source's own history boundary, not a deeper claim" \
	"$(git -C "$CLONE_SHALLOW" rev-list --count HEAD)" "$(git -C "$SHALLOW_SRC" rev-list --count HEAD)"
in_repo "$CLONE_SHALLOW" git fsck --no-progress --no-dangling --connectivity-only
assert_eq "b: ... passing fsck" "$RC" 0

# The loud half, and the mechanism is the missing local COPY rather than the
# shallow boundary: `git clone` fetches refs/heads and refs/tags, and for an
# ordinary source the wholesale object copy carries everything else across
# anyway. A shallow source gets no such copy, so an object no fetched ref reaches
# is simply absent — here the stash COMMIT itself, which is inside the boundary
# and whose object id is the one the mirror then cannot write.
SHALLOW_STASH_SRC="$WORK/b/shallow-stash-src"
git clone -q --depth 2 --no-local "$SHALLOW_UP" "$SHALLOW_STASH_SRC"
printf 'work in progress\n' >"$SHALLOW_STASH_SRC/wip.txt"
g -C "$SHALLOW_STASH_SRC" add wip.txt
g -C "$SHALLOW_STASH_SRC" stash -q
assert_ne "b: the shallow-stash fixture really has a stash" \
	"$(git -C "$SHALLOW_STASH_SRC" rev-parse --verify --quiet refs/stash || echo none)" "none"
SHALLOW_STASH_ROOT="$WORK/b/shallow-stash-root"
in_repo "$SHALLOW_STASH_SRC" env "DC_ROOT=$SHALLOW_STASH_ROOT" "$DC_ENTER" shallowstash
assert_ne "b: a shallow source whose refs outrun the fetch fails rather than hands one back" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_contains "b: ... saying the mirror could not be completed" "$ERR" "could not mirror the source's refs into the clone"
# This one dies mid-run rather than refusing up front, so the clone root exists
# by then; what must not survive is the half-built clone itself, which the failed
# -session cleanup removes.
assert_eq "b: ... leaving no half-built clone behind" \
	"$(find "$SHALLOW_STASH_ROOT" -mindepth 1 -maxdepth 3 -name repo | wc -l | tr -d '[:space:]')" "0"

# The quiet half, and the one the header states as a BOUND rather than a
# guarantee: with no wholesale object copy, an object no ref reaches does not
# come across. The run exits 0 and says nothing, so this is the one place a
# shallow clone is a weaker baseline than its source. The control beside it is
# what makes that a statement about SHALLOWNESS rather than about dc-enter: the
# same probe on a full clone of the same upstream carries the object over. These
# two, and the borrowing-source pair further down, are where the no-ref-reaches
# property is pinned — section (d)'s unreachable-COMMIT case is not: that commit
# is one `refs/pruned/reserved` still names.
SHALLOW_DANGLE_SRC="$WORK/b/shallow-dangle-src"
git clone -q --depth 2 --no-local "$SHALLOW_UP" "$SHALLOW_DANGLE_SRC"
SHALLOW_DANGLE_OID="$(printf 'unreferenced\n' | git -C "$SHALLOW_DANGLE_SRC" hash-object -w --stdin)"
assert_eq "b: the dangling object really is in the shallow source" \
	"$(git -C "$SHALLOW_DANGLE_SRC" cat-file -t "$SHALLOW_DANGLE_OID")" "blob"
in_repo "$SHALLOW_DANGLE_SRC" "$DC_ENTER" shallowdangle
assert_eq "b: a shallow source with an unreferenced object still yields a clone" "$RC" 0
require_clone CLONE_SHALLOW_DANGLE "b: shallowdangle"
assert_eq "b: ... quietly, with nothing said on stderr" "$ERR" ""
assert_eq "b: ... but WITHOUT that object, which a self-contained source's clone carries" \
	"$(git -C "$CLONE_SHALLOW_DANGLE" cat-file -t "$SHALLOW_DANGLE_OID" 2>/dev/null || echo absent)" "absent"
SHALLOW_CONTROL_SRC="$WORK/b/shallow-control-src"
git clone -q --no-local "$SHALLOW_UP" "$SHALLOW_CONTROL_SRC"
SHALLOW_CONTROL_OID="$(printf 'unreferenced\n' | git -C "$SHALLOW_CONTROL_SRC" hash-object -w --stdin)"
in_repo "$SHALLOW_CONTROL_SRC" "$DC_ENTER" shallowcontrol
assert_eq "b: the control, a full clone of the same upstream, yields a clone too" "$RC" 0
require_clone CLONE_SHALLOW_CONTROL "b: shallowcontrol"
assert_eq "b: ... and DOES carry the same unreferenced object" \
	"$(git -C "$CLONE_SHALLOW_CONTROL" cat-file -t "$SHALLOW_CONTROL_OID" 2>/dev/null || echo absent)" "blob"

# And the boundary the refusal is held to: `remote.<name>.promisor` explicitly
# set to false is git saying this remote is NOT a promisor, so the repository is
# an ordinary complete one and still gets its clone. Without this case the check
# could be a presence test and the suite would not notice.
PARTIAL_OFF_SRC="$WORK/b/partial-off-src"
git init -q -b main "$PARTIAL_OFF_SRC"
g -C "$PARTIAL_OFF_SRC" commit -q --allow-empty -m one
git -C "$PARTIAL_OFF_SRC" config remote.up.promisor false
in_repo "$PARTIAL_OFF_SRC" "$DC_ENTER" promisoroff
assert_eq "b: a remote.<name>.promisor=false source is not refused" "$RC" 0
require_clone CLONE_PROMISOR_OFF "b: promisoroff"
assert_eq "b: ... and its clone holds the source's history" \
	"$(git -C "$CLONE_PROMISOR_OFF" rev-list --count --all)" "1"

# The bound on that repair, which the two cases above do not reach: it is limited
# to what `repack -a` can see, so an unreachable object held only by the donor,
# or PACKED in the source before it was stranded, does not survive it — while a
# loose one in the source's own store does, since that repack rewrites packs
# rather than deleting loose objects. The fixture is the shape that bites without
# anyone doing anything unusual: a commit packed while it was still on a branch,
# the branch then deleted and the reflog expired. Its control is the same history
# in a NON-borrowing source, which is what makes this a statement about borrowing
# rather than about dc-enter — there the object comes across.
# CHARACTERIZATION, not a fix pin: these assert the bound as it stands. `repack
# -A -d` would close the packed half — measured, that commit comes across under
# it — and the helper keeps `-a -d` anyway, to stay exactly the repack
# `--dissociate` itself runs. So the "absent" assertion below is the one that
# would need inverting if that call were ever revisited, not deleting.
ALT3_DONOR="$WORK/b/alt3-donor"
ALT3_PLAIN_DONOR="$WORK/b/alt3-plain-donor"
git init -q -b main "$ALT3_DONOR"
g -C "$ALT3_DONOR" commit -q --allow-empty -m one
git init -q -b main "$ALT3_PLAIN_DONOR"
g -C "$ALT3_PLAIN_DONOR" commit -q --allow-empty -m one
# Pack the commit while it is still reachable, then strand it. `repack -a -d`
# keeps unreachable LOOSE objects but not unreachable packed ones, so the loose
# spelling of this fixture would prove nothing.
strand_a_packed_commit() {
	local dir="$1"
	g -C "$dir" checkout -q -b temp
	g -C "$dir" commit -q --allow-empty -m doomed
	git -C "$dir" rev-parse HEAD
	git -C "$dir" repack -q -a -d
	g -C "$dir" checkout -q main
	git -C "$dir" branch -q -D temp
	git -C "$dir" reflog expire --expire=now --all
}
ALT3_SRC="$WORK/b/alt3-src"
# The other two shapes the bound distinguishes, written before the clone so both
# are in place for one run: an unreachable object the DONOR alone holds, and a
# LOOSE unreachable one in the source's own store. The first is lost with the
# packed one; the second survives, because `repack -a -d` rewrites packs and does
# not delete loose objects.
ALT3_DONOR_ONLY="$(printf 'donor-only unreachable\n' | git -C "$ALT3_DONOR" hash-object -w --stdin)"
git clone -q --shared "$ALT3_DONOR" "$ALT3_SRC"
ALT3_LOOSE="$(printf 'loose unreachable\n' | git -C "$ALT3_SRC" hash-object -w --stdin)"
ALT3_STRANDED="$(strand_a_packed_commit "$ALT3_SRC")"
assert_eq "b: the borrowing source can see the donor-only unreachable object" \
	"$(git -C "$ALT3_SRC" cat-file -t "$ALT3_DONOR_ONLY")" "blob"
assert_eq "b: ... and holds a loose unreachable one of its own" \
	"$(git -C "$ALT3_SRC" cat-file -t "$ALT3_LOOSE")" "blob"
ALT3_PLAIN_SRC="$WORK/b/alt3-plain-src"
git clone -q --no-hardlinks "$ALT3_PLAIN_DONOR" "$ALT3_PLAIN_SRC"
ALT3_PLAIN_STRANDED="$(strand_a_packed_commit "$ALT3_PLAIN_SRC")"
assert_eq "b: the borrowing source still holds its stranded packed commit" \
	"$(git -C "$ALT3_SRC" cat-file -t "$ALT3_STRANDED")" "commit"
assert_eq "b: ... and so does the non-borrowing control" \
	"$(git -C "$ALT3_PLAIN_SRC" cat-file -t "$ALT3_PLAIN_STRANDED")" "commit"
in_repo "$ALT3_SRC" "$DC_ENTER" altunreachable
assert_eq "b: a borrowing source with a stranded object still yields a clone" "$RC" 0
require_clone CLONE_ALT3 "b: altunreachable"
assert_eq "b: ... quietly, with nothing said on stderr" "$ERR" ""
assert_eq "b: ... but WITHOUT that object, which the dissociation's repack cannot reach" \
	"$(git -C "$CLONE_ALT3" cat-file -t "$ALT3_STRANDED" 2>/dev/null || echo absent)" "absent"
assert_eq "b: ... nor the one only the donor held" \
	"$(git -C "$CLONE_ALT3" cat-file -t "$ALT3_DONOR_ONLY" 2>/dev/null || echo absent)" "absent"
assert_eq "b: ... while the source's own LOOSE unreachable object does come across" \
	"$(git -C "$CLONE_ALT3" cat-file -t "$ALT3_LOOSE" 2>/dev/null || echo absent)" "blob"
in_repo "$ALT3_PLAIN_SRC" "$DC_ENTER" plainunreachable
assert_eq "b: the non-borrowing control yields a clone too" "$RC" 0
require_clone CLONE_ALT3_PLAIN "b: plainunreachable"
assert_eq "b: ... and DOES carry its stranded object" \
	"$(git -C "$CLONE_ALT3_PLAIN" cat-file -t "$ALT3_PLAIN_STRANDED" 2>/dev/null || echo absent)" "commit"

# `includeIf "onbranch:<pattern>"` makes part of the caller's merged
# configuration depend on the branch HEAD is on. A remote defined that way is
# invisible while the clone is detached and live the moment HEAD is attached to
# the requested branch, so an isolation check made before the checkout answers
# for a clone nobody receives — and the one handed back can `git push` into the
# invoking repository. The refusal must therefore hold for the conditional
# definition exactly as it does for an unconditional one.
ONBRANCH_SRC="$WORK/b/onbranch-src"
git init -q -b main "$ONBRANCH_SRC"
g -C "$ONBRANCH_SRC" commit -q --allow-empty -m one
ONBRANCH_INC="$WORK/b/onbranch-remote.inc"
printf '[remote "leak"]\n\turl = %s\n' "$ONBRANCH_SRC" >"$ONBRANCH_INC"
ONBRANCH_CFG="$WORK/b/onbranch.gitconfig"
printf '[user]\n\tuseConfigOnly = true\n[includeIf "onbranch:main"]\n\tpath = %s\n' \
	"$ONBRANCH_INC" >"$ONBRANCH_CFG"
in_repo "$ONBRANCH_SRC" env "GIT_CONFIG_GLOBAL=$ONBRANCH_CFG" "$DC_ENTER" onbranchremote main
assert_ne "b: a remote a conditional onbranch include defines is refused" "$RC" 0
assert_eq "b: ... silently on stdout" "$OUT" ""
assert_contains "b: ... naming the remote it would have carried" "$ERR" "leak"
# The same include defining a PUSH TARGET rather than a remote, which the second
# check is the one to catch.
printf '[remote]\n\tpushDefault = %s\n' "$ONBRANCH_SRC" >"$ONBRANCH_INC"
in_repo "$ONBRANCH_SRC" env "GIT_CONFIG_GLOBAL=$ONBRANCH_CFG" "$DC_ENTER" onbranchpush main
assert_ne "b: a push target a conditional onbranch include defines is refused" "$RC" 0
assert_eq "b: ... silently on stdout as well" "$OUT" ""
assert_contains "b: ... naming the setting" "$ERR" "remote.pushdefault"
# Not over-broad: the include is scoped to `main`, so requesting a branch it does
# not match leaves it inactive in the clone that is handed back, and that clone
# is legitimate. This is what makes the two refusals above evidence of the
# ordering rather than of a check that fires on the include's mere presence.
# It is also the bound the header states: this clone is clean as handed back, and
# a `git checkout main` inside it would activate the include again. That is not
# closable by checking more branches — an `onbranch:` pattern can name a branch
# that does not exist yet — so it is documented rather than approximated.
g -C "$ONBRANCH_SRC" branch other
in_repo "$ONBRANCH_SRC" env "GIT_CONFIG_GLOBAL=$ONBRANCH_CFG" "$DC_ENTER" onbranchmiss other
assert_eq "b: a conditional include the requested branch does not match still yields a clone" "$RC" 0
require_clone CLONE_ONBRANCH "b: onbranchmiss"
assert_eq "b: ... checked out on that branch" \
	"$(git -C "$CLONE_ONBRANCH" symbolic-ref HEAD)" "refs/heads/other"
assert_eq "b: ... and with no remote" "$(git -C "$CLONE_ONBRANCH" remote)" ""

# The default clone root is /tmp, which on a shared machine every account can
# walk. The directories this helper creates there hold a copy of the invoking
# repository — its source and its objects — so they are created 0700 rather than
# left to a 0022 umask's world-readable 0755.
# The umask is PINNED to 0022 for the invocation rather than inherited, because
# this test is only decisive under a permissive one: run from a shell that
# already masks group and other away, an unfixed helper produces 0700 by
# accident and the suite goes green on a broken helper. CI's 0022 is the
# environment the assertion is about, so it is set here rather than assumed.
# Set and restored around the call instead of wrapped in a subshell, because
# `in_repo` reports through the RC/OUT/ERR globals, which a subshell would
# discard.
MODE_SRC="$WORK/b/mode-src"
git init -q -b main "$MODE_SRC"
g -C "$MODE_SRC" commit -q --allow-empty -m one
MODE_ROOT="$WORK/b/mode-root"
MODE_UMASK_SAVED="$(umask)"
umask 0022
in_repo "$MODE_SRC" env "DC_ROOT=$MODE_ROOT" "$DC_ENTER" privatemode
umask "$MODE_UMASK_SAVED"
assert_eq "b: a clone under a fresh root exits 0" "$RC" 0
require_clone CLONE_PRIVATE "b: privatemode"
MODE_SESSION="$(dirname "$CLONE_PRIVATE")"
MODE_SCOPE="$(dirname "$MODE_SESSION")"
assert_eq "b: the per-agent scope directory is private under a 0022 umask" \
	"$(mode_of "$MODE_SCOPE")" "700"
assert_eq "b: the session directory holding the clone is private too" \
	"$(mode_of "$MODE_SESSION")" "700"

echo "== (c) the <ref> interface =="
SRC2="$WORK/c/src"
mkdir -p "$WORK/c"
make_source "$SRC2"
WT2="$WORK/c/src-wt"
export DC_ROOT="$WORK/c/root"
assert_ne "c: fixture worktree HEAD differs from the main worktree's" \
	"$(git -C "$WT2" rev-parse HEAD)" "$(git -C "$SRC2" rev-parse HEAD)"
in_repo "$WT2" "$DC_ENTER" fromwt
assert_eq "c: dc-enter from a linked worktree exits 0" "$RC" 0
require_clone CLONE_C "c: fromwt"
assert_eq "c: default ref is the INVOKING worktree's HEAD" \
	"$(git -C "$CLONE_C" rev-parse HEAD)" "$(git -C "$WT2" rev-parse HEAD)"
assert_eq "c: default ref keeps the invoking worktree's branch" \
	"$(git -C "$CLONE_C" symbolic-ref HEAD)" "refs/heads/wtbranch"
# From a nested subdirectory of the invoking worktree.
mkdir -p "$WT2/nested/deeper"
in_repo "$WT2/nested/deeper" "$DC_ENTER" nested
assert_eq "c: works from a nested subdirectory" "$RC" 0
assert_eq "c: nested invocation still uses the worktree's HEAD" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse HEAD)"
# An explicit branch name checks that branch out.
in_repo "$WT2" "$DC_ENTER" bybranch other
assert_eq "c: explicit branch exits 0" "$RC" 0
assert_eq "c: explicit branch is checked out" "$(git -C "$OUT" symbolic-ref HEAD)" "refs/heads/other"
assert_eq "c: explicit branch is at the source's commit" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$SRC2" rev-parse other)"
# A fully qualified local head names its branch just as plainly as the short
# form: it resolves as a commit like any other revision, so without normalization
# it would detach despite naming a branch.
in_repo "$WT2" "$DC_ENTER" byfullref refs/heads/other
assert_eq "c: a fully qualified refs/heads/ ref exits 0" "$RC" 0
assert_eq "c: a fully qualified refs/heads/ ref checks that branch out" \
	"$(git -C "$OUT" symbolic-ref HEAD)" "refs/heads/other"
# No other qualified form is normalized — a remote-tracking ref is not a local
# branch and detaches, which is what the header promises.
in_repo "$WT2" "$DC_ENTER" byremoteref refs/remotes/origin/main
assert_eq "c: a remote-tracking ref exits 0" "$RC" 0
assert_eq "c: a remote-tracking ref detaches" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
# A non-branch revision detaches at the resolved commit.
in_repo "$WT2" "$DC_ENTER" bytag v1
assert_eq "c: explicit tag exits 0" "$RC" 0
assert_eq "c: explicit tag detaches" "$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: explicit tag is at the tag's commit" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$SRC2" rev-parse "v1^{commit}")"
# A short name that is BOTH a local branch and a tag, at different commits.
# gitrevisions disambiguates it as the TAG, so a helper that resolved the commit
# from the bare name would check the branch out, see a HEAD that disagrees with
# the commit it resolved, and detach at the tag — verifying the wrong thing while
# blaming a ref that never moved. The documented contract is that a local branch
# is checked out, so the branch must win.
g -C "$SRC2" branch -q ambig main~1
g -C "$SRC2" tag ambig main
assert_ne "c: the ambiguous fixture's branch and tag differ" \
	"$(git -C "$SRC2" rev-parse "refs/heads/ambig")" "$(git -C "$SRC2" rev-parse "refs/tags/ambig^{commit}")"
in_repo "$WT2" "$DC_ENTER" ambig ambig
assert_eq "c: an ambiguous branch/tag name exits 0" "$RC" 0
assert_eq "c: an ambiguous name checks the BRANCH out, not the tag" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/ambig"
assert_eq "c: an ambiguous name is at the branch's commit" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$SRC2" rev-parse "refs/heads/ambig")"
# Only refs/heads/ is normalized, so the qualified tag form still detaches at the
# tag even though a same-named branch exists.
in_repo "$WT2" "$DC_ENTER" ambigtag refs/tags/ambig
assert_eq "c: the qualified tag form of an ambiguous name exits 0" "$RC" 0
assert_eq "c: the qualified tag form still detaches" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: the qualified tag form is at the tag's commit" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$SRC2" rev-parse "refs/tags/ambig^{commit}")"
# ... including in the pathological repository where a LOCAL BRANCH is named
# literally `refs/tags/ambig` or `tags/ambig`. Both are legal branch names, and
# both make the qualified form the caller wrote ALSO look like the short name of
# a branch. git resolves the caller's string first as a full ref name and then as
# `refs/<name>`, reaching the tag either way, so the helper must too: checking the
# branch out instead would verify a commit the caller's own ref does not point at
# — the wrong-commit conclusion the <ref> interface exists to prevent — and no
# refusal or warning would say so.
g -C "$SRC2" branch -q "refs/tags/ambig" main~1
g -C "$SRC2" branch -q "tags/ambig" main~1
assert_ne "c: the same-named branches sit at a different commit from the tag" \
	"$(git -C "$SRC2" rev-parse "refs/heads/refs/tags/ambig")" \
	"$(git -C "$SRC2" rev-parse "refs/tags/ambig^{commit}")"
in_repo "$WT2" "$DC_ENTER" qualtagbranch refs/tags/ambig
assert_eq "c: a branch named like the qualified tag exits 0" "$RC" 0
assert_eq "c: a branch named like the qualified tag does not win: HEAD detaches" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: ... at the tag's commit, not that branch's" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$SRC2" rev-parse "refs/tags/ambig^{commit}")"
in_repo "$WT2" "$DC_ENTER" halfqualbranch tags/ambig
assert_eq "c: a branch named like the refs/-relative tag exits 0" "$RC" 0
assert_eq "c: a branch named like the refs/-relative tag does not win: HEAD detaches" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: ... also at the tag's commit" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$SRC2" rev-parse "refs/tags/ambig^{commit}")"
g -C "$SRC2" branch -q -D "refs/tags/ambig"
g -C "$SRC2" branch -q -D "tags/ambig"
# ... and in the repository carrying a PSEUDO-REF beside a same-named branch.
# `ORIG_HEAD`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_HEAD` and
# the rest below live in `$GIT_DIR`, and git's rules reach them BEFORE
# `refs/heads/<name>` — so in a repository stopped mid-rebase, mid-merge,
# mid-cherry-pick, mid-bisect or mid-notes-merge that also
# carries a branch called `ORIG_HEAD`, the caller's `ORIG_HEAD` is the pseudo-ref.
# Detecting them is the one existence question `git show-ref --verify` cannot
# answer for dc-enter: that command only learned to report a bare root ref in git
# 2.45, and the helper supports 2.36+, so on 2.43 it answers "no" for every
# pseudo-ref here. dc-enter therefore asks `git rev-parse --symbolic-full-name`
# instead, which has no such limitation — but this suite pins the BEHAVIOR rather
# than the mechanism, so it stays valid whatever the helper asks. Getting it
# wrong hands back the branch's commit while the caller's own `git rev-parse
# ORIG_HEAD` names the other one.
# These are per-WORKTREE, which is the shape that matters: dc-enter resolves in
# the INVOKING worktree, so the fixture writes them into that worktree's own git
# directory rather than the shared one.
WT2_GIT_DIR="$(git -C "$WT2" rev-parse --absolute-git-dir)"
for pseudo in ORIG_HEAD MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_HEAD REBASE_HEAD AUTO_MERGE FETCH_HEAD \
	BISECT_EXPECTED_REV MERGE_AUTOSTASH NOTES_MERGE_PARTIAL NOTES_MERGE_REF BISECT_START; do
	pseudo_slug="$(printf '%s' "$pseudo" | tr 'A-Z_' 'a-z-')"
	g -C "$SRC2" branch -q "$pseudo" main
	git -C "$WT2" rev-parse --verify main~1 >"$WT2_GIT_DIR/$pseudo"
	assert_ne "c: the $pseudo fixture's pseudo-ref and branch differ" \
		"$(git -C "$WT2" rev-parse --verify "$pseudo")" \
		"$(git -C "$WT2" rev-parse --verify "refs/heads/$pseudo")"
	in_repo "$WT2" "$DC_ENTER" "pseudo-$pseudo_slug" "$pseudo"
	assert_eq "c: $pseudo beside a same-named branch exits 0" "$RC" 0
	assert_eq "c: the $pseudo branch does not win: HEAD detaches" \
		"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
	assert_eq "c: ... at the commit git rev-parse $pseudo names, not the branch's" \
		"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse --verify "$pseudo^{commit}")"
	# The other side of the same guard: with no pseudo-ref present the string is
	# an ordinary short branch name again and the branch IS checked out, so
	# clearing the candidate is never over-eager.
	rm -f -- "$WT2_GIT_DIR/$pseudo"
	in_repo "$WT2" "$DC_ENTER" "branch-$pseudo_slug" "$pseudo"
	assert_eq "c: $pseudo with no pseudo-ref present exits 0" "$RC" 0
	assert_eq "c: ... names the branch, which is checked out" \
		"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/$pseudo"
	g -C "$SRC2" branch -q -D "$pseudo"
done
# The boundary on the other side of that list: `$GIT_DIR` is full of ALL-CAPS
# files that are not refs at all. `COMMIT_EDITMSG` exists in every repository
# that has ever committed, and `MERGE_MSG`, `SQUASH_MSG` and `MERGE_MODE` share
# its shape — so a probe that admitted every all-caps name would answer a branch
# named after one with a detached HEAD, contradicting the documented "if it names
# a local branch, the clone checks that branch out" while `git rev-parse` in the
# source names the branch too. The commit would still be right; the branch
# attachment is what goes missing.
for nonref in COMMIT_EDITMSG MERGE_MSG SQUASH_MSG MERGE_MODE; do
	nonref_slug="$(printf '%s' "$nonref" | tr 'A-Z_' 'a-z-')"
	g -C "$SRC2" branch -q "$nonref" main~1
	printf 'not a ref\n' >"$WT2_GIT_DIR/$nonref"
	assert_eq "c: the $nonref fixture resolves to the branch in the source" \
		"$(git -C "$WT2" rev-parse --verify "$nonref")" \
		"$(git -C "$WT2" rev-parse --verify "refs/heads/$nonref")"
	in_repo "$WT2" "$DC_ENTER" "nonref-$nonref_slug" "$nonref"
	assert_eq "c: a branch named $nonref exits 0" "$RC" 0
	assert_eq "c: ... and is CHECKED OUT, not detached at its commit" \
		"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/$nonref"
	rm -f -- "$WT2_GIT_DIR/$nonref"
	g -C "$SRC2" branch -q -D "$nonref"
done
# ... and the same rule read the other way round, which is what pins that the
# decision is CONTENT rather than a list of blessed names: git resolves any
# one-level `$GIT_DIR` file whose content is a ref, whatever it is called, so a
# `COMMIT_EDITMSG` holding nothing but an object id — a commit message that is
# one — really is what `git rev-parse COMMIT_EDITMSG` names, and so is a
# lower-case name no root-ref list would ever carry. Answering either with the
# same-named branch is the wrong baseline in its usual shape.
# The two sit in different directories, which is the one place the name does
# decide something: an all-caps one-level name is a pseudo-ref and so is read
# per-WORKTREE, while any other one-level name is an ordinary ref read from the
# COMMON git directory. Both are still resolved from the invoking worktree.
for oidfile in COMMIT_EDITMSG dc_lower_one_level; do
	oidfile_slug="$(printf '%s' "$oidfile" | tr 'A-Z_' 'a-z-')"
	case "$oidfile" in
	COMMIT_EDITMSG) oidfile_dir="$WT2_GIT_DIR" ;;
	*) oidfile_dir="$(git -C "$WT2" rev-parse --path-format=absolute --git-common-dir)" ;;
	esac
	g -C "$SRC2" branch -q "$oidfile" main
	git -C "$WT2" rev-parse --verify main~1 >"$oidfile_dir/$oidfile"
	assert_ne "c: the $oidfile fixture's id and the same-named branch differ" \
		"$(git -C "$WT2" rev-parse --verify "$oidfile")" \
		"$(git -C "$WT2" rev-parse --verify "refs/heads/$oidfile")"
	in_repo "$WT2" "$DC_ENTER" "oidfile-$oidfile_slug" "$oidfile"
	assert_eq "c: a $oidfile holding an object id exits 0" "$RC" 0
	assert_eq "c: the $oidfile branch does not win over it: HEAD detaches" \
		"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
	assert_eq "c: ... at the commit git rev-parse $oidfile names, not the branch's" \
		"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse --verify "$oidfile^{commit}")"
	rm -f -- "$oidfile_dir/$oidfile"
	g -C "$SRC2" branch -q -D "$oidfile"
done
# `MERGE_RR` sits between those two groups. What rerere writes there is records
# rather than a ref — `<id><TAB><path><NUL>` — but git's root-ref rules read that
# leading id, so `git rev-parse MERGE_RR` names it while `MERGE_RR^{commit}` is
# fatal: the id hashes the conflict TEXT and matches no object. There is no
# baseline for the caller to be given, so dc-enter has to refuse the string their
# own git refuses rather than quietly substitute the same-named branch.
g -C "$SRC2" branch -q MERGE_RR main
printf '0123456789abcdef0123456789abcdef01234567\tsome/conflicted.txt\0' >"$WT2_GIT_DIR/MERGE_RR"
assert_ne "c: the MERGE_RR fixture's id is not the same-named branch's commit" \
	"$(git -C "$WT2" rev-parse --verify MERGE_RR)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/MERGE_RR)"
assert_eq "c: ... and the source's own MERGE_RR^{commit} is fatal" \
	"$(git -C "$WT2" rev-parse --verify --quiet 'MERGE_RR^{commit}' >/dev/null 2>&1 && echo resolves || echo fatal)" "fatal"
in_repo "$WT2" "$DC_ENTER" mergerr MERGE_RR
assert_ne "c: MERGE_RR beside a same-named branch is refused, not answered with the branch" "$RC" 0
assert_eq "c: ... silently on stdout" "$OUT" ""
# That refusal is conditional on the FILE, exactly like every other root ref
# here, and a repository not mid-rerere is the ordinary case: there `MERGE_RR` is
# a short name like any other and `git rev-parse MERGE_RR` names the branch, so
# refusing it would refuse a clone the caller's own git can produce.
rm -f -- "$WT2_GIT_DIR/MERGE_RR"
assert_eq "c: with no rerere file MERGE_RR resolves to the branch in the source" \
	"$(git -C "$WT2" rev-parse --verify MERGE_RR)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/MERGE_RR)"
in_repo "$WT2" "$DC_ENTER" mergerrbranch MERGE_RR
assert_eq "c: MERGE_RR with no rerere file exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not refused" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/MERGE_RR"
g -C "$SRC2" branch -q -D MERGE_RR
# And an EMPTY root-ref file is not a pseudo-ref either: git's rules fall through
# it to `refs/heads/<name>`. A fetch with nothing to fetch leaves `FETCH_HEAD`
# exactly like that, so a presence-only probe would detach a repository whose own
# `git rev-parse FETCH_HEAD` names the branch.
g -C "$SRC2" branch -q FETCH_HEAD main~1
: >"$WT2_GIT_DIR/FETCH_HEAD"
assert_eq "c: an empty FETCH_HEAD resolves to the branch in the source" \
	"$(git -C "$WT2" rev-parse --verify FETCH_HEAD)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/FETCH_HEAD)"
in_repo "$WT2" "$DC_ENTER" emptyfetchhead FETCH_HEAD
assert_eq "c: an empty FETCH_HEAD beside a same-named branch exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not detached" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/FETCH_HEAD"
rm -f -- "$WT2_GIT_DIR/FETCH_HEAD"
g -C "$SRC2" branch -q -D FETCH_HEAD
# Emptiness is only the extreme case of the real rule, which is that CONTENT
# decides, not the name. A listed name whose file holds PROSE is not a ref either:
# git's rules fall through it to `refs/heads/<name>`, exactly as they do for
# `COMMIT_EDITMSG` above, so a presence-only probe detaches a repository whose own
# `git rev-parse ORIG_HEAD` names the branch.
g -C "$SRC2" branch -q ORIG_HEAD main~1
printf 'not a ref\n' >"$WT2_GIT_DIR/ORIG_HEAD"
assert_eq "c: an ORIG_HEAD holding prose resolves to the branch in the source" \
	"$(git -C "$WT2" rev-parse --verify ORIG_HEAD)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/ORIG_HEAD)"
in_repo "$WT2" "$DC_ENTER" prosepseudoref ORIG_HEAD
assert_eq "c: an ORIG_HEAD holding prose beside a same-named branch exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not detached" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/ORIG_HEAD"
rm -f -- "$WT2_GIT_DIR/ORIG_HEAD"
g -C "$SRC2" branch -q -D ORIG_HEAD
# `BISECT_START` carries both sides of that rule under one name: a bisect started
# from a BRANCH writes that branch's name there, one started from a DETACHED HEAD
# writes the commit. Only the second is a ref, and the loop above already pinned
# that half; this is the other one, where the branch must survive.
g -C "$SRC2" branch -q BISECT_START main~1
printf 'main\n' >"$WT2_GIT_DIR/BISECT_START"
assert_eq "c: a BISECT_START holding a branch name resolves to the branch" \
	"$(git -C "$WT2" rev-parse --verify BISECT_START)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/BISECT_START)"
in_repo "$WT2" "$DC_ENTER" bisectstartname BISECT_START
assert_eq "c: a BISECT_START holding a branch name exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not detached" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/BISECT_START"
rm -f -- "$WT2_GIT_DIR/BISECT_START"
g -C "$SRC2" branch -q -D BISECT_START
# `NOTES_MERGE_REF` is the SYMREF among them: a conflicted `git notes merge`
# leaves it pointing at the notes ref being merged rather than holding an object
# id. A live one is a ref and wins; a DANGLING one — its notes ref deleted since,
# which is the state that outlives the operation — is a fall-through exactly like
# an empty file. So the target has to be RESOLVED, not merely read: "does this
# name hold something" and "does what it holds still resolve" are different
# questions here, and only the second one is the one git asks.
g -C "$SRC2" update-ref refs/notes/dc-merge "$(git -C "$SRC2" rev-parse main~1)"
g -C "$SRC2" branch -q NOTES_MERGE_REF main
printf 'ref: refs/notes/dc-merge\n' >"$WT2_GIT_DIR/NOTES_MERGE_REF"
assert_ne "c: the live NOTES_MERGE_REF and the same-named branch differ" \
	"$(git -C "$WT2" rev-parse --verify NOTES_MERGE_REF)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/NOTES_MERGE_REF)"
in_repo "$WT2" "$DC_ENTER" notesmergereflive NOTES_MERGE_REF
assert_eq "c: a live NOTES_MERGE_REF beside a same-named branch exits 0" "$RC" 0
assert_eq "c: the NOTES_MERGE_REF branch does not win: HEAD detaches" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: ... at the commit the symref names, not the branch's" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse --verify 'NOTES_MERGE_REF^{commit}')"
g -C "$SRC2" update-ref -d refs/notes/dc-merge
assert_eq "c: the dangling NOTES_MERGE_REF resolves to the branch in the source" \
	"$(git -C "$WT2" rev-parse --verify NOTES_MERGE_REF)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/NOTES_MERGE_REF)"
in_repo "$WT2" "$DC_ENTER" notesmergerefdangling NOTES_MERGE_REF
assert_eq "c: a dangling NOTES_MERGE_REF beside a same-named branch exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not detached" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/NOTES_MERGE_REF"
rm -f -- "$WT2_GIT_DIR/NOTES_MERGE_REF"
g -C "$SRC2" branch -q -D NOTES_MERGE_REF
# ... and the whitespace between `ref:` and its target is ANY run of it or none
# at all, because that is what git skips (`while (isspace(*buf))`) rather than the
# single space it writes itself. A one-space-only reading calls a live symref
# prose and hands back the branch, while `git rev-parse NOTES_MERGE_REF` in the
# source names the notes ref's commit — the wrong-baseline conclusion once more,
# and on git < 2.45 the parse is the whole decision.
g -C "$SRC2" update-ref refs/notes/dc-merge "$(git -C "$SRC2" rev-parse main~1)"
g -C "$SRC2" branch -q NOTES_MERGE_REF main
for spacing in tab none double; do
	case "$spacing" in
	tab) printf 'ref:\trefs/notes/dc-merge\n' >"$WT2_GIT_DIR/NOTES_MERGE_REF" ;;
	none) printf 'ref:refs/notes/dc-merge\n' >"$WT2_GIT_DIR/NOTES_MERGE_REF" ;;
	double) printf 'ref:  refs/notes/dc-merge\n' >"$WT2_GIT_DIR/NOTES_MERGE_REF" ;;
	esac
	assert_ne "c: the $spacing-spaced NOTES_MERGE_REF and the same-named branch differ" \
		"$(git -C "$WT2" rev-parse --verify NOTES_MERGE_REF)" \
		"$(git -C "$WT2" rev-parse --verify refs/heads/NOTES_MERGE_REF)"
	in_repo "$WT2" "$DC_ENTER" "notesmergeref$spacing" NOTES_MERGE_REF
	assert_eq "c: a $spacing-spaced NOTES_MERGE_REF beside a same-named branch exits 0" "$RC" 0
	assert_eq "c: the NOTES_MERGE_REF branch does not win over it: HEAD detaches" \
		"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
	assert_eq "c: ... at the commit the $spacing-spaced symref names, not the branch's" \
		"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse --verify 'NOTES_MERGE_REF^{commit}')"
done
# ... and that run of whitespace can contain a NEWLINE, because git rtrims the
# whole file and then walks it as one string: `while (isspace(*buf))` steps over
# a newline exactly like a space, so a `ref:` alone on the first line still names
# the ref written on the second. Reading only the first LINE finds an empty
# target there and hands the branch back, while `git rev-parse NOTES_MERGE_REF`
# in the source names the notes ref's commit.
printf 'ref:\nrefs/notes/dc-merge\n' >"$WT2_GIT_DIR/NOTES_MERGE_REF"
assert_ne "c: the newline-separated NOTES_MERGE_REF and the same-named branch differ" \
	"$(git -C "$WT2" rev-parse --verify NOTES_MERGE_REF)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/NOTES_MERGE_REF)"
in_repo "$WT2" "$DC_ENTER" notesmergereflf NOTES_MERGE_REF
assert_eq "c: a newline-separated NOTES_MERGE_REF beside a same-named branch exits 0" "$RC" 0
assert_eq "c: the NOTES_MERGE_REF branch does not win over it: HEAD detaches" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: ... at the commit the newline-separated symref names, not the branch's" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse --verify 'NOTES_MERGE_REF^{commit}')"
# The same rule read the other way, which is the half a line-wise reading gets
# wrong in the direction that LOSES a branch: everything after that whitespace
# run is the target, so a second line under a perfectly good first one is part of
# the name, and no ref answers to a name with a newline in it. git falls through
# to `refs/heads/<name>`; reading one line sees only the good first one, calls the
# symref live, and detaches where the source has the branch checked out.
printf 'ref: refs/notes/dc-merge\nrefs/heads/junk\n' >"$WT2_GIT_DIR/NOTES_MERGE_REF"
assert_eq "c: a NOTES_MERGE_REF with a second line resolves to the branch in the source" \
	"$(git -C "$WT2" rev-parse --verify NOTES_MERGE_REF)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/NOTES_MERGE_REF)"
in_repo "$WT2" "$DC_ENTER" notesmergereftwoline NOTES_MERGE_REF
assert_eq "c: a NOTES_MERGE_REF with a second line exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not detached" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/NOTES_MERGE_REF"
# A NUL is where "the whole file" stops for git, which parses the buffer it read
# as a C string — and the rtrim it does BEFORE that parse cannot reach back
# across one, a NUL not being whitespace. So the padding below stays inside the
# target, and a target with spaces in it is a name no ref has.
printf 'ref: refs/notes/dc-merge   \0refs/notes/dc-merge\n' >"$WT2_GIT_DIR/NOTES_MERGE_REF"
assert_eq "c: a NOTES_MERGE_REF whose padding sits behind a NUL resolves to the branch" \
	"$(git -C "$WT2" rev-parse --verify NOTES_MERGE_REF)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/NOTES_MERGE_REF)"
in_repo "$WT2" "$DC_ENTER" notesmergerefnul NOTES_MERGE_REF
assert_eq "c: a NOTES_MERGE_REF whose padding sits behind a NUL exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not detached" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/NOTES_MERGE_REF"
rm -f -- "$WT2_GIT_DIR/NOTES_MERGE_REF"
g -C "$SRC2" update-ref -d refs/notes/dc-merge
g -C "$SRC2" branch -q -D NOTES_MERGE_REF
# The symref cases above all aim at `refs/notes/...`, which is the referent a
# conflicted `git notes merge` writes — and holding the referent fixed is what
# hid a whole class: whether the symref is LIVE depends on resolving the target,
# and the target can be any of the things git can resolve, including another
# `$GIT_DIR` root ref. That one is the case a `show-ref --verify` on the target
# cannot answer below git 2.45 while `git rev-parse` resolves the chain on every
# version, so a helper that probed the referent that way handed back the
# same-named branch on three of this suite's four supported gits. Each shape here
# is asserted against the source's own resolution first, so the fixture is what
# it claims to be whatever git is running.
g -C "$SRC2" branch -q NOTES_MERGE_REF main
g -C "$SRC2" branch -q dc-referent main~1
git -C "$WT2" rev-parse --verify main~1 >"$WT2_GIT_DIR/ORIG_HEAD"
g -C "$SRC2" symbolic-ref refs/dc-chain refs/heads/dc-referent
for referent in ORIG_HEAD HEAD refs/heads/dc-referent refs/dc-chain; do
	referent_slug="$(printf '%s' "$referent" | tr 'A-Z_/' 'a-z--')"
	printf 'ref: %s\n' "$referent" >"$WT2_GIT_DIR/NOTES_MERGE_REF"
	assert_ne "c: the NOTES_MERGE_REF aimed at $referent and the same-named branch differ" \
		"$(git -C "$WT2" rev-parse --verify NOTES_MERGE_REF)" \
		"$(git -C "$WT2" rev-parse --verify refs/heads/NOTES_MERGE_REF)"
	in_repo "$WT2" "$DC_ENTER" "notesref-$referent_slug" NOTES_MERGE_REF
	assert_eq "c: a NOTES_MERGE_REF aimed at $referent exits 0" "$RC" 0
	assert_eq "c: the NOTES_MERGE_REF branch does not win over it: HEAD detaches" \
		"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
	assert_eq "c: ... at the commit the chain through $referent names, not the branch's" \
		"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse --verify 'NOTES_MERGE_REF^{commit}')"
done
rm -f -- "$WT2_GIT_DIR/NOTES_MERGE_REF" "$WT2_GIT_DIR/ORIG_HEAD"
# `--no-deref`, or the deletion follows the symref and removes its TARGET instead.
g -C "$SRC2" update-ref --no-deref -d refs/dc-chain
g -C "$SRC2" branch -q -D NOTES_MERGE_REF
g -C "$SRC2" branch -q -D dc-referent

# The root ref above is not the only name that can win ahead of
# `refs/heads/<name>`: the ladder puts exactly three there — `<name>` itself,
# `refs/<name>`, and `refs/tags/<name>` — and the two below are the other two.
# Aimed at the SAME-NAMED branch each is a symref git resolves THROUGH to that
# branch, so git's answer IS the branch and the clone checks it out rather than
# detaching, exactly as the root-ref shape does. Pinned because the header states
# all three coincide this way, and only the root-ref route was covered.
for winner in refs tags; do
	case "$winner" in
	refs) win_ref="refs/dc-symwin" ;;
	tags) win_ref="refs/tags/dc-symwin" ;;
	esac
	g -C "$SRC2" branch -q dc-symwin main~1
	g -C "$SRC2" symbolic-ref "$win_ref" refs/heads/dc-symwin
	assert_eq "c: the $win_ref fixture really is a symref onto the same-named branch" \
		"$(git -C "$SRC2" symbolic-ref "$win_ref")" "refs/heads/dc-symwin"
	in_repo "$WT2" "$DC_ENTER" "symwin-$winner" dc-symwin
	assert_eq "c: a $win_ref symref aimed at the same-named branch exits 0" "$RC" 0
	assert_eq "c: ... and that branch is checked out, not detached" \
		"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/dc-symwin"
	assert_eq "c: ... at the branch's commit" \
		"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$SRC2" rev-parse refs/heads/dc-symwin)"
	# `--no-deref` first, or the deletion follows the symref onto the branch.
	g -C "$SRC2" update-ref --no-deref -d "$win_ref"
	g -C "$SRC2" branch -q -D dc-symwin
done
# The whitespace git skips after `ref:`, and the whitespace that ends an object
# id, are ASCII whitespace: git's `isspace` is its own ASCII-only one
# (`sane-ctype.h`), never the locale's. A U+2003 EM SPACE is whitespace to a
# locale-aware class and not to git, so the two files below are BROKEN for git —
# the target `refs/heads/dc-wide ` is a name no ref has, and the id has a
# non-whitespace character stuck to it — and git's rules fall through both to
# `refs/heads/<name>`. A helper trimming them with a locale-aware class calls
# each one live and detaches where the source has the branch checked out.
g -C "$SRC2" branch -q dc-wide main~1
g -C "$SRC2" branch -q NOTES_MERGE_REF main
printf 'ref: refs/heads/dc-wide\xe2\x80\x83\n' >"$WT2_GIT_DIR/NOTES_MERGE_REF"
assert_eq "c: a symref target padded with U+2003 resolves to the branch in the source" \
	"$(git -C "$WT2" rev-parse --verify NOTES_MERGE_REF)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/NOTES_MERGE_REF)"
in_repo "$WT2" "$DC_ENTER" notesrefemspace NOTES_MERGE_REF
assert_eq "c: a symref target padded with U+2003 exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not detached" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/NOTES_MERGE_REF"
printf '%s\xe2\x80\x83\n' "$(git -C "$WT2" rev-parse --verify main~1)" >"$WT2_GIT_DIR/NOTES_MERGE_REF"
assert_eq "c: an object id followed by U+2003 resolves to the branch in the source" \
	"$(git -C "$WT2" rev-parse --verify NOTES_MERGE_REF)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/NOTES_MERGE_REF)"
in_repo "$WT2" "$DC_ENTER" oidemspace NOTES_MERGE_REF
assert_eq "c: an object id followed by U+2003 exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not detached" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/NOTES_MERGE_REF"
rm -f -- "$WT2_GIT_DIR/NOTES_MERGE_REF"
g -C "$SRC2" branch -q -D NOTES_MERGE_REF
g -C "$SRC2" branch -q -D dc-wide
# The deliberate branch-over-tag preference, held to the case it was meant for.
# A root ref is another way for git to arrive at `refs/tags/<name>` — a hand-
# written `$GIT_DIR/ORIG_HEAD` holding `ref: refs/tags/ORIG_HEAD` — and there the
# caller's own `git rev-parse ORIG_HEAD` names the TAG's commit while the
# same-named branch sits somewhere else. Preferring the branch on the strength of
# the tag being in the answer would substitute that other commit, which is the
# wrong baseline the preference was never meant to buy.
g -C "$SRC2" branch -q ORIG_HEAD main
g -C "$SRC2" tag ORIG_HEAD main~1
printf 'ref: refs/tags/ORIG_HEAD\n' >"$WT2_GIT_DIR/ORIG_HEAD"
assert_ne "c: the tag-aimed ORIG_HEAD and the same-named branch differ" \
	"$(git -C "$WT2" rev-parse --verify 'ORIG_HEAD^{commit}')" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/ORIG_HEAD)"
in_repo "$WT2" "$DC_ENTER" tagaimedpseudoref ORIG_HEAD
assert_eq "c: an ORIG_HEAD aimed at a same-named tag exits 0" "$RC" 0
assert_eq "c: the ORIG_HEAD branch does not win over it: HEAD detaches" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: ... at the tag's commit, not the branch's" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse --verify 'ORIG_HEAD^{commit}')"
rm -f -- "$WT2_GIT_DIR/ORIG_HEAD"
g -C "$SRC2" tag -d ORIG_HEAD >/dev/null
g -C "$SRC2" branch -q -D ORIG_HEAD
# The object-id half has two boundaries of the same kind, both of them shapes git
# ACCEPTS that a tighter reading would call prose. The first is CASE: git's hex
# parser is `hexval()`, which takes `A`-`F` as readily as `a`-`f`, even though git
# writes only lower case itself.
g -C "$SRC2" branch -q ORIG_HEAD main
git -C "$WT2" rev-parse --verify main~1 | tr 'a-f' 'A-F' >"$WT2_GIT_DIR/ORIG_HEAD"
assert_ne "c: the upper-case ORIG_HEAD and the same-named branch differ" \
	"$(git -C "$WT2" rev-parse --verify ORIG_HEAD)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/ORIG_HEAD)"
in_repo "$WT2" "$DC_ENTER" upperhexpseudoref ORIG_HEAD
assert_eq "c: an upper-case ORIG_HEAD beside a same-named branch exits 0" "$RC" 0
assert_eq "c: the ORIG_HEAD branch does not win over it: HEAD detaches" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: ... at the commit the upper-case id names, not the branch's" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse --verify 'ORIG_HEAD^{commit}')"
rm -f -- "$WT2_GIT_DIR/ORIG_HEAD"
g -C "$SRC2" branch -q -D ORIG_HEAD
# Reading the whole file rather than its first line has to stop where git stops,
# and for an object id that is the first whitespace: git parses the id and then
# accepts anything after it as long as a whitespace character separates the two,
# which is how `FETCH_HEAD` carries its extra columns. A newline is such a
# character, so a second line under the id leaves it a live pseudo-ref — the
# boundary a whole-file reading must not overshoot into calling broken.
g -C "$SRC2" branch -q ORIG_HEAD main
{
	git -C "$WT2" rev-parse --verify main~1
	echo refs/heads/junk
} >"$WT2_GIT_DIR/ORIG_HEAD"
assert_ne "c: the two-line ORIG_HEAD and the same-named branch differ" \
	"$(git -C "$WT2" rev-parse --verify ORIG_HEAD)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/ORIG_HEAD)"
in_repo "$WT2" "$DC_ENTER" twolinepseudoref ORIG_HEAD
assert_eq "c: a two-line ORIG_HEAD beside a same-named branch exits 0" "$RC" 0
assert_eq "c: the ORIG_HEAD branch does not win over it: HEAD detaches" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: ... at the commit the id on its first line names, not the branch's" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse --verify 'ORIG_HEAD^{commit}')"
rm -f -- "$WT2_GIT_DIR/ORIG_HEAD"
g -C "$SRC2" branch -q -D ORIG_HEAD
# The second is WIDTH, and it runs the other way: git parses exactly the length
# THIS repository's hash algorithm uses and treats the other one as broken, so a
# 64-character id in this sha1 fixture is not an object id at all and git's rules
# fall through it to `refs/heads/<name>`. Reading "40 or 64" instead detaches a
# repository whose own `git rev-parse ORIG_HEAD` names the branch — the same
# lost-branch-attachment the `COMMIT_EDITMSG` boundary above guards.
g -C "$SRC2" branch -q ORIG_HEAD main~1
printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' >"$WT2_GIT_DIR/ORIG_HEAD"
assert_eq "c: an ORIG_HEAD of the other hash width resolves to the branch in the source" \
	"$(git -C "$WT2" rev-parse --verify ORIG_HEAD)" \
	"$(git -C "$WT2" rev-parse --verify refs/heads/ORIG_HEAD)"
in_repo "$WT2" "$DC_ENTER" widehexpseudoref ORIG_HEAD
assert_eq "c: an ORIG_HEAD of the other hash width beside a same-named branch exits 0" "$RC" 0
assert_eq "c: ... and the branch is checked out, not detached" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/ORIG_HEAD"
rm -f -- "$WT2_GIT_DIR/ORIG_HEAD"
g -C "$SRC2" branch -q -D ORIG_HEAD
# And the far side of that width rule, on its own fixture because it is the one
# the repository under test cannot show: in a SHA-256 repository the 64-character
# id is the real one, and the pseudo-ref has to win there exactly as the 40 does
# here. A helper that decided the width for itself would read a live id as prose
# in one of these two repositories whichever width it picked.
S256="$WORK/c/sha256-src"
if git init -q -b main --object-format=sha256 "$S256" 2>/dev/null; then
	g -C "$S256" commit -q --allow-empty -m one
	g -C "$S256" commit -q --allow-empty -m two
	g -C "$S256" branch -q ORIG_HEAD main~1
	git -C "$S256" rev-parse --verify main >"$S256/.git/ORIG_HEAD"
	assert_ne "c: the sha256 ORIG_HEAD and the same-named branch differ" \
		"$(git -C "$S256" rev-parse --verify ORIG_HEAD)" \
		"$(git -C "$S256" rev-parse --verify refs/heads/ORIG_HEAD)"
	in_repo "$S256" "$DC_ENTER" sha256pseudoref ORIG_HEAD
	assert_eq "c: a sha256 ORIG_HEAD beside a same-named branch exits 0" "$RC" 0
	assert_eq "c: the sha256 ORIG_HEAD branch does not win: HEAD detaches" \
		"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
	assert_eq "c: ... at the commit the 64-character id names, not the branch's" \
		"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$S256" rev-parse --verify 'ORIG_HEAD^{commit}')"
	# The sha1 fixture's `MERGE_RR` shape again at the other width, because it is
	# the one root ref whose id names no object: `show-ref --verify` cannot resolve
	# it at any git version, so nothing but the resolution rules themselves can
	# decide it, and getting the width wrong here would hand back the branch.
	g -C "$S256" branch -q MERGE_RR main
	printf '%s\tsome/conflicted.txt\0' \
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" >"$S256/.git/MERGE_RR"
	in_repo "$S256" "$DC_ENTER" sha256mergerr MERGE_RR
	assert_ne "c: a sha256 MERGE_RR is refused, not answered with the branch" "$RC" 0
	assert_eq "c: ... silently on stdout" "$OUT" ""
	rm -f -- "$S256/.git/MERGE_RR"
	g -C "$S256" branch -q -D MERGE_RR
fi
# A local head whose name begins with a DASH. `refs/heads/-foo` passes `git
# check-ref-format`, so it is a legal branch, and the qualified-form
# normalization above correctly derives `-foo` from it — which git's own option
# parser then reads as a bundle of switches wherever it lands in an operand
# position, failing with `unknown switch 'o'`. A trailing `--` cannot rescue it:
# that separates paths, and the operand is parsed before git reaches it. Created
# with `update-ref`, because `git branch` refuses the name outright.
DASH_COMMIT="$(git -C "$SRC2" rev-parse main)"
git -C "$SRC2" update-ref "refs/heads/-foo" "$DASH_COMMIT"
in_repo "$WT2" "$DC_ENTER" dashbranch "refs/heads/-foo"
assert_eq "c: a qualified head whose name begins with a dash exits 0" "$RC" 0
require_clone CLONE_DASH "c: dashbranch"
assert_eq "c: ... with that branch checked out rather than parsed as options" \
	"$(git -C "$CLONE_DASH" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/-foo"
assert_eq "c: ... at its commit" "$(git -C "$CLONE_DASH" rev-parse HEAD)" "$DASH_COMMIT"
assert_eq "c: ... with a populated, clean working tree" \
	"$(git -C "$CLONE_DASH" status --porcelain)" ""
assert_eq "c: ... and the tracked file materialized" "$(cat "$CLONE_DASH/file.txt")" "tracked"
# The short form of the same name, reachable only past `--` because the argument
# parser refuses a leading dash before it.
in_repo "$WT2" "$DC_ENTER" dashbranchshort -- "-foo"
assert_eq "c: the same branch by short name after -- exits 0" "$RC" 0
require_clone CLONE_DASH_SHORT "c: dashbranchshort"
assert_eq "c: ... is checked out too" \
	"$(git -C "$CLONE_DASH_SHORT" symbolic-ref -q HEAD || echo DETACHED)" "refs/heads/-foo"
git -C "$SRC2" update-ref -d "refs/heads/-foo"

in_repo "$WT2" "$DC_ENTER" byrev "HEAD~1"
assert_eq "c: explicit revision exits 0" "$RC" 0
assert_eq "c: explicit revision resolves in the INVOKING worktree" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse "HEAD~1")"
# A detached invoking worktree produces a detached clone at the same commit.
git -C "$WT2" checkout -q --detach HEAD
in_repo "$WT2" "$DC_ENTER" detached
assert_eq "c: detached invoking HEAD exits 0" "$RC" 0
assert_eq "c: detached invoking HEAD yields a detached clone" \
	"$(git -C "$OUT" symbolic-ref -q HEAD || echo DETACHED)" "DETACHED"
assert_eq "c: detached clone is at the invoking commit" \
	"$(git -C "$OUT" rev-parse HEAD)" "$(git -C "$WT2" rev-parse HEAD)"
git -C "$WT2" checkout -q wtbranch
# A ref that does not resolve is refused, silently on stdout.
in_repo "$WT2" "$DC_ENTER" badref no/such/ref
assert_ne "c: unresolvable ref exits non-zero" "$RC" 0
assert_eq "c: unresolvable ref writes nothing to stdout" "$OUT" ""
assert_contains "c: unresolvable ref explains itself on stderr" "$ERR" "does not resolve to a commit"
# Outside a repository at all.
mkdir -p "$WORK/c/norepo"
in_repo "$WORK/c/norepo" "$DC_ENTER" norepo
assert_ne "c: outside a git worktree exits non-zero" "$RC" 0
assert_eq "c: outside a git worktree writes nothing to stdout" "$OUT" ""

echo "== (d) the ref namespace is an exact mirror =="
# A symbolic ref whose target does not exist: `for-each-ref` does not report one,
# so the enumeration cannot see it and it is the one documented gap in the
# mirror. Added only here, because `git fsck` reports it as a broken ref and
# sections (b) and (j) assert a clean source.
git -C "$SRC2" symbolic-ref refs/dangling/sym refs/heads/does-not-exist
in_repo "$SRC2" "$DC_ENTER" mirror
assert_eq "d: exits 0" "$RC" 0
require_clone CLONE_D "d: mirror"
assert_eq "d: every ref mirrored at its original name" "$(refs_of "$CLONE_D")" "$(refs_of "$SRC2")"
assert_contains "d: a non-standard namespace is present" "$(refs_of "$CLONE_D")" "refs/pruned/reserved"
assert_contains "d: pre-rebase reservations are present" "$(refs_of "$CLONE_D")" "refs/pre-rebase/main"
assert_contains "d: notes are present" "$(refs_of "$CLONE_D")" "refs/notes/commits"
assert_contains "d: the stash ref is present" "$(refs_of "$CLONE_D")" "refs/stash"
assert_eq "d: a symbolic source ref arrives symbolic, not flattened" \
	"$(git -C "$CLONE_D" symbolic-ref refs/remotes/origin/HEAD)" "refs/remotes/origin/main"
in_repo "$SRC2" git symbolic-ref --quiet "refs/dangling/sym"
assert_eq "d: the source really does hold a dangling symref" "$RC" 0
in_repo "$CLONE_D" git symbolic-ref --quiet "refs/dangling/sym"
assert_ne "d: a dangling source symref cannot come across (for-each-ref hides it)" "$RC" 0
assert_eq "d: the object behind an unreachable ref came across" \
	"$(git -C "$CLONE_D" cat-file -t "$(git -C "$SRC2" rev-parse refs/pruned/reserved)")" "commit"
# git clone's invented remote-tracking namespace is pruned away, so the mirror
# is exact rather than exact-plus-leftovers.
assert_eq "d: no leftover remote-tracking refs from the clone step" \
	"$(git -C "$CLONE_D" for-each-ref --format='%(refname)' 'refs/remotes/dc-source')" ""
# for-each-ref hides a DANGLING symbolic ref, so check the ref store directly too.
in_repo "$CLONE_D" git symbolic-ref -q "refs/remotes/dc-source/HEAD"
assert_ne "d: not even a dangling remote-tracking HEAD is left behind" "$RC" 0
# ... and a source that genuinely owns refs under the clone step's remote name
# keeps them: dropping the remote must not take mirrored refs with it.
git -C "$SRC2" update-ref refs/remotes/dc-source/main "$(git -C "$SRC2" rev-parse HEAD)"
git -C "$SRC2" update-ref refs/remotes/origin/main "$(git -C "$SRC2" rev-parse HEAD)"
in_repo "$SRC2" "$DC_ENTER" mirror2
assert_eq "d: a source owning the clone remote's namespace mirrors exactly" \
	"$(refs_of "$OUT")" "$(refs_of "$SRC2")"
assert_contains "d: the source's own dc-source refs survive" "$(refs_of "$OUT")" "refs/remotes/dc-source/main"
assert_contains "d: the source's own origin refs survive" "$(refs_of "$OUT")" "refs/remotes/origin/main"
assert_eq "d: the clone still has no remote to push to" "$(git -C "$OUT" remote)" ""
# The source's reflog is documented as absent — the clone keeps a fresh reflog of
# its own, so reflog-only recovery of the source's history is unavailable in it.
in_repo "$SRC2" git rev-parse --verify "HEAD@{4}"
assert_eq "d: the source's reflog reaches back several entries" "$RC" 0
in_repo "$CLONE_D" git rev-parse --verify "HEAD@{4}"
assert_ne "d: the source's reflog history is not carried" "$RC" 0
# A source that hides a namespace from upload-pack still mirrors exactly. This is
# what makes "exact" a property of the ref store rather than of what the source
# chooses to advertise: a `+refs/*:refs/*` fetch would silently drop these, and a
# subagent verifying behaviour IN refs/pruned/ would conclude the reservation
# vanished for entirely the wrong reason.
SRC_HIDDEN="$WORK/d/hidden"
mkdir -p "$WORK/d"
make_source "$SRC_HIDDEN"
git -C "$SRC_HIDDEN" config uploadpack.hideRefs refs/pruned
git -C "$SRC_HIDDEN" config transfer.hideRefs refs/pre-rebase
export DC_ROOT="$WORK/d/root"
assert_eq "d: the fixture really does hide those refs from upload-pack" \
	"$(git ls-remote "$SRC_HIDDEN" 'refs/pruned/*' 'refs/pre-rebase/*')" ""
in_repo "$SRC_HIDDEN" "$DC_ENTER" hidden
assert_eq "d: a source hiding refs from upload-pack exits 0" "$RC" 0
assert_eq "d: ... and still mirrors exactly" "$(refs_of "$OUT")" "$(refs_of "$SRC_HIDDEN")"
assert_contains "d: ... including the hidden namespace" "$(refs_of "$OUT")" "refs/pruned/reserved"
assert_eq "d: ... with the hidden ref's object present" \
	"$(git -C "$OUT" cat-file -t "$(git -C "$SRC_HIDDEN" rev-parse refs/pruned/reserved)")" "commit"

echo "== (e) clone-root refusals and a worktree listing that fails closed =="
SRC3="$WORK/e/src"
mkdir -p "$WORK/e"
make_source "$SRC3"
for bad in "$SRC3" "$SRC3/sub" "$SRC3/.git/dc" "$WORK/e/src-wt/inside" "$WORK/e/src-wt"; do
	DC_ROOT="$bad" in_repo "$SRC3" env "DC_ROOT=$bad" "$DC_ENTER" inside
	assert_ne "e: refuses DC_ROOT=$bad" "$RC" 0
	assert_eq "e: refuses DC_ROOT=$bad silently on stdout" "$OUT" ""
	assert_contains "e: refuses DC_ROOT=$bad with a reason" "$ERR" "inside the invoking repository"
done
# Nothing was created inside the repository on the way to refusing.
assert_eq "e: refusal creates nothing in the repository" "$(git -C "$SRC3" status --porcelain)" ""
assert_true "e: refusal created no directory inside the repository" \
	"$([ ! -e "$SRC3/sub" ] && [ ! -e "$SRC3/.git/dc" ] && echo true || echo false)"
# A symlinked root that lands inside the repository is refused too.
ln -s "$SRC3" "$WORK/e/link-to-repo"
in_repo "$SRC3" env "DC_ROOT=$WORK/e/link-to-repo/viaLink" "$DC_ENTER" vialink
assert_ne "e: refuses a symlinked root inside the repository" "$RC" 0
assert_eq "e: symlinked-root refusal is silent on stdout" "$OUT" ""
# A scope directory that is a symlink into the repository is refused before the
# clone is placed — the root check above is lexical, so resolving this component
# is what makes it binding.
in_repo "$SRC3" env "DC_ROOT=$WORK/e/root" "$DC_ENTER" scoped
require_clone CLONE_E "e: scoped"
SCOPE_E="$(dirname "$(dirname "$CLONE_E")")"
in_repo "$SRC3" env "DC_ROOT=$WORK/e/root" "$DC_REMOVE" scoped
rm -rf "$SCOPE_E"
mkdir -p "$SRC3/decoy"
ln -s "$SRC3/decoy" "$SCOPE_E"
in_repo "$SRC3" env "DC_ROOT=$WORK/e/root" "$DC_ENTER" scoped
assert_ne "e: refuses a symlinked scope directory" "$RC" 0
assert_eq "e: the symlinked-scope refusal is silent on stdout" "$OUT" ""
assert_contains "e: the symlinked-scope refusal says why" "$ERR" "symlink"
assert_eq "e: nothing was created inside the repository through the symlink" "$(ls -A "$SRC3/decoy")" ""
assert_eq "e: the repository is still clean" "$(git -C "$SRC3" status --porcelain)" ""
rm -f "$SCOPE_E"
rm -rf "$SRC3/decoy"

# A git that cannot enumerate worktrees unambiguously is refused rather than
# parsed with the newline form, which cannot distinguish a path containing a
# newline from a record boundary.
mkdir -p "$WORK/e/nozbin"
cat >"$WORK/e/nozbin/git" <<'SHIM'
#!/usr/bin/env bash
# Pretends to be a git predating `git worktree list -z`.
for a in "$@"; do
	if [ "$a" = "-z" ]; then
		for b in "$@"; do
			if [ "$b" = "worktree" ]; then
				echo "error: unknown option \`z'" >&2
				exit 129
			fi
		done
	fi
done
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$WORK/e/nozbin/git"
in_repo "$SRC3" env "REAL_GIT=$(command -v git)" "PATH=$WORK/e/nozbin:$PATH" "DC_ROOT=$WORK/e/root" "$DC_ENTER" noz
assert_ne "e: refuses a git that cannot list worktrees with -z" "$RC" 0
assert_eq "e: that refusal is silent on stdout" "$OUT" ""
assert_contains "e: that refusal names the missing capability" "$ERR" "worktree list --porcelain -z"
in_repo "$SRC3" env "REAL_GIT=$(command -v git)" "PATH=$WORK/e/nozbin:$PATH" "DC_ROOT=$WORK/e/root" "$DC_REMOVE" noz
assert_ne "e: dc-remove refuses the same git" "$RC" 0

# A listing that SUCCEEDS but reports no worktree records at all is not "this
# repository has no worktrees" — every repository has at least its main one. It
# is a listing that cannot be trusted, and trusting it would leave the clone free
# to land inside a worktree the helper never heard of.
mkdir -p "$WORK/e/emptybin"
cat >"$WORK/e/emptybin/git" <<'SHIM'
#!/usr/bin/env bash
# Pretends to be a git whose worktree listing comes back empty.
prev=""
for a in "$@"; do
	if [ "$prev" = "worktree" ] && [ "$a" = "list" ]; then exit 0; fi
	prev="$a"
done
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$WORK/e/emptybin/git"
in_repo "$SRC3" env "REAL_GIT=$(command -v git)" "PATH=$WORK/e/emptybin:$PATH" "DC_ROOT=$WORK/e/root" "$DC_ENTER" nowt
assert_ne "e: refuses a worktree listing carrying no records" "$RC" 0
assert_eq "e: that refusal is silent on stdout" "$OUT" ""
assert_contains "e: that refusal says the listing cannot be trusted" "$ERR" "reported no worktrees"
in_repo "$SRC3" env "REAL_GIT=$(command -v git)" "PATH=$WORK/e/emptybin:$PATH" "DC_ROOT=$WORK/e/root" "$DC_REMOVE" nowt
assert_ne "e: dc-remove refuses an empty listing too" "$RC" 0

# A listing that fails for a reason other than an old git must not be reported as
# a version problem: git's own message is carried through, or the reader chases
# the wrong bug.
mkdir -p "$WORK/e/errbin"
cat >"$WORK/e/errbin/git" <<'SHIM'
#!/usr/bin/env bash
# Pretends to be a current git tripping over a broken worktree registration.
prev=""
for a in "$@"; do
	if [ "$prev" = "worktree" ] && [ "$a" = "list" ]; then
		echo "fatal: could not read '.git/worktrees/broken/gitdir'" >&2
		exit 128
	fi
	prev="$a"
done
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$WORK/e/errbin/git"
in_repo "$SRC3" env "REAL_GIT=$(command -v git)" "PATH=$WORK/e/errbin:$PATH" "DC_ROOT=$WORK/e/root" "$DC_ENTER" brokenwt
assert_ne "e: refuses a worktree listing that errors" "$RC" 0
assert_eq "e: that refusal is silent on stdout" "$OUT" ""
assert_contains "e: that refusal carries git's own diagnosis" "$ERR" ".git/worktrees/broken/gitdir"

# A malformed slug never reaches the filesystem.
for badslug in "../escape" "a/b" "" "-x" ".hidden"; do
	in_repo "$SRC3" env "DC_ROOT=$WORK/e/root" "$DC_ENTER" "$badslug"
	assert_ne "e: refuses slug '$badslug'" "$RC" 0
	assert_eq "e: refuses slug '$badslug' silently on stdout" "$OUT" ""
done

echo "== (f) an existing clone is refused; --replace re-derives it pristine =="
export DC_ROOT="$WORK/f/root"
SRC4="$WORK/f/src"
mkdir -p "$WORK/f"
make_source "$SRC4"
in_repo "$SRC4" "$DC_ENTER" reuse
assert_eq "f: first call exits 0" "$RC" 0
require_clone CLONE_F "f: reuse"
# Wreck it the way an experiment would: delete refs, collect objects, dirty and
# litter the tree, and remove a tracked file.
git -C "$CLONE_F" update-ref -d refs/pruned/reserved
git -C "$CLONE_F" update-ref -d refs/pre-rebase/main
git -C "$CLONE_F" gc --prune=now --quiet
printf 'wrecked\n' >"$CLONE_F/file.txt"
printf 'litter\n' >"$CLONE_F/untracked.txt"
# A second call REFUSES rather than discarding it. That is what makes the helper
# safe for concurrent siblings: sibling subagents of one container share both an
# identity and a worktree, so they derive this very path, and a re-derivation
# would pull the refs and objects out from under one mid-verification.
in_repo "$SRC4" "$DC_ENTER" reuse
assert_ne "f: a second call on an existing clone exits non-zero" "$RC" 0
assert_eq "f: that refusal is silent on stdout" "$OUT" ""
assert_contains "f: that refusal says the slug is taken" "$ERR" "already has a clone"
assert_contains "f: that refusal offers --replace" "$ERR" "--replace"
assert_eq "f: the existing clone is left exactly as it was" "$(cat "$CLONE_F/file.txt")" "wrecked"
assert_true "f: including its litter" "$([ -e "$CLONE_F/untracked.txt" ] && echo true || echo false)"
# --replace is the explicit "that clone is mine and I am done with it".
in_repo "$SRC4" "$DC_ENTER" --replace reuse
assert_eq "f: --replace exits 0" "$RC" 0
assert_eq "f: --replace returns the same deterministic path" "$OUT" "$CLONE_F"
assert_eq "f: the wreckage is gone — refs are pristine again" "$(refs_of "$CLONE_F")" "$(refs_of "$SRC4")"
assert_eq "f: the wreckage is gone — tree is clean" "$(git -C "$CLONE_F" status --porcelain)" ""
assert_eq "f: the wreckage is gone — tracked content restored" "$(cat "$CLONE_F/file.txt")" "tracked"
assert_true "f: the wreckage is gone — litter removed" \
	"$([ ! -e "$CLONE_F/untracked.txt" ] && echo true || echo false)"
assert_contains "f: the discard is announced on stderr" "$ERR" "discarding the existing clone"
# Even a clone whose .git was destroyed is re-derived by --replace rather than
# refused: the marker that proves ownership lives beside the clone, not inside it.
rm -rf "$CLONE_F/.git"
in_repo "$SRC4" "$DC_ENTER" --replace reuse
assert_eq "f: a clone whose .git was destroyed is re-derived" "$RC" 0
assert_eq "f: re-derived clone is a repository again" \
	"$(git -C "$CLONE_F" rev-parse --is-inside-work-tree)" "true"
# The destructive helper applies the SAME ownership proof as dc-remove: a marker
# carrying the right magic but recording another clone path, or another source
# repository, is not this invocation's to discard even with --replace.
in_repo "$SRC4" "$DC_ENTER" mismatched
require_clone CLONE_MM "f: mismatched"
SESSION_MM="$(dirname "$CLONE_MM")"
printf 'precious\n' >"$SESSION_MM/precious.txt"
printf 'dc-clone-v2\0helper=dc-enter\0clone=/somewhere/else/repo\0source=%s\0' "$SRC4" \
	>"$SESSION_MM/dc-clone-meta"
in_repo "$SRC4" "$DC_ENTER" --replace mismatched
assert_ne "f: --replace refuses a marker recording another clone path" "$RC" 0
assert_eq "f: that refusal is silent on stdout" "$OUT" ""
assert_eq "f: the mis-marked directory's contents survive" "$(cat "$SESSION_MM/precious.txt")" "precious"
printf 'dc-clone-v2\0helper=dc-enter\0clone=%s\0source=/somewhere/else\0' "$CLONE_MM" \
	>"$SESSION_MM/dc-clone-meta"
in_repo "$SRC4" "$DC_ENTER" --replace mismatched
assert_ne "f: --replace refuses a marker recording another source repository" "$RC" 0
assert_eq "f: the mis-marked directory still survives" "$(cat "$SESSION_MM/precious.txt")" "precious"
# dc-remove refuses the source mismatch for the same reason: the scope component
# is a CRC32 of the worktree path, so comparing the path itself turns a hash
# collision between two worktrees into a refusal rather than a silent merge.
in_repo "$SRC4" "$DC_REMOVE" mismatched
assert_ne "f: dc-remove refuses the same source mismatch" "$RC" 0
assert_contains "f: and says which source it expected" "$ERR" "records source repository"
rm -rf "$SESSION_MM"
# A directory the helper did not create is refused, not deleted.
FOREIGN_DIR="$(dirname "$CLONE_F")/../foreign"
mkdir -p "$FOREIGN_DIR"
printf 'precious\n' >"$FOREIGN_DIR/keep.txt"
in_repo "$SRC4" "$DC_ENTER" foreign
assert_ne "f: refuses a directory it did not create" "$RC" 0
assert_eq "f: refusal is silent on stdout" "$OUT" ""
assert_contains "f: refusal names the missing marker" "$ERR" "dc-clone-meta"
assert_eq "f: the foreign directory is untouched" "$(cat "$FOREIGN_DIR/keep.txt")" "precious"
# A slug path that is a symlink is refused by both helpers rather than followed.
SCOPE_DIR_F="$(dirname "$(dirname "$CLONE_F")")"
ln -s "$FOREIGN_DIR" "$SCOPE_DIR_F/linked"
in_repo "$SRC4" "$DC_ENTER" linked
assert_ne "f: dc-enter refuses a symlinked slug path" "$RC" 0
assert_eq "f: the symlink refusal is silent on stdout" "$OUT" ""
in_repo "$SRC4" "$DC_REMOVE" linked
assert_ne "f: dc-remove refuses a symlinked slug path" "$RC" 0
assert_eq "f: the symlink's target survives" "$(cat "$FOREIGN_DIR/keep.txt")" "precious"
assert_true "f: the symlink itself is left in place" "$([ -L "$SCOPE_DIR_F/linked" ] && echo true || echo false)"
rm -f "$SCOPE_DIR_F/linked"

echo "== (g) per-agent and per-worktree scoping =="
in_repo "$SRC4" env "DC_AGENT=agent-one" "$DC_ENTER" shared
require_clone PATH_ONE "g: shared/agent-one"
in_repo "$SRC4" env "DC_AGENT=agent-two" "$DC_ENTER" shared
require_clone PATH_TWO "g: shared/agent-two"
assert_ne "g: two agents do not collide on one slug" "$PATH_ONE" "$PATH_TWO"
assert_true "g: both agents' clones exist at once" \
	"$([ -d "$PATH_ONE/.git" ] && [ -d "$PATH_TWO/.git" ] && echo true || echo false)"
in_repo "$WORK/f/src-wt" "$DC_ENTER" shared
assert_ne "g: two worktrees of one repository do not collide on a slug" "$OUT" "$PATH_ONE"
in_repo "$SRC4" "$DC_ENTER" stable
require_clone FIRST_STABLE "g: stable"
in_repo "$SRC4" "$DC_REMOVE" stable
in_repo "$SRC4" "$DC_ENTER" stable
assert_eq "g: the same agent, worktree, and slug resolve to one path" "$OUT" "$FIRST_STABLE"
# This repository's own fan-out model: several subagents of ONE container share
# $CONTAINER_NAME and a worktree, so nothing distinguishes them and they derive
# the same path. The second must refuse, leaving the first's clone whole — this
# is the case a per-agent path component alone cannot separate.
in_repo "$SRC4" env "DC_AGENT=" "CONTAINER_NAME=one-container" "$DC_ENTER" sibling
assert_eq "g: the first sibling gets a clone" "$RC" 0
require_clone SIBLING_ONE "g: sibling"
git -C "$SIBLING_ONE" update-ref refs/heads/mid-verification HEAD
in_repo "$SRC4" env "DC_AGENT=" "CONTAINER_NAME=one-container" "$DC_ENTER" sibling
assert_ne "g: an indistinguishable sibling is refused, not served" "$RC" 0
assert_eq "g: that refusal is silent on stdout" "$OUT" ""
assert_contains "g: that refusal warns about a concurrent sibling" "$ERR" "concurrent sibling"
assert_true "g: the first sibling's clone survives intact" \
	"$([ -d "$SIBLING_ONE/.git" ] && echo true || echo false)"
assert_eq "g: including the ref it was working on" \
	"$(git -C "$SIBLING_ONE" rev-parse --verify refs/heads/mid-verification)" \
	"$(git -C "$SIBLING_ONE" rev-parse HEAD)"
# Distinguishing them with DC_AGENT avoids the contention entirely.
in_repo "$SRC4" env "DC_AGENT=sibling-two" "CONTAINER_NAME=one-container" "$DC_ENTER" sibling
assert_eq "g: a sibling setting DC_AGENT gets its own clone" "$RC" 0
assert_ne "g: ... at a different path" "$OUT" "$SIBLING_ONE"

echo "== (h) dc-remove =="
in_repo "$SRC4" "$DC_ENTER" doomed
require_clone CLONE_H "h: doomed"
# Dirty in every way dc-remove promises not to care about.
printf 'dirty\n' >"$CLONE_H/file.txt"
printf 'litter\n' >"$CLONE_H/untracked.txt"
git -C "$CLONE_H" update-ref -d refs/stash
in_repo "$SRC4" "$DC_REMOVE" doomed
assert_eq "h: removes a dirty clone without complaint" "$RC" 0
assert_eq "h: dc-remove writes nothing to stdout" "$OUT" ""
assert_true "h: the clone is gone" "$([ ! -e "$CLONE_H" ] && echo true || echo false)"
assert_true "h: the slug directory dc-enter created is gone too" \
	"$([ ! -e "$(dirname "$CLONE_H")" ] && echo true || echo false)"
# Removing the same slug again is a no-op, so a cleanup trap can be unconditional.
in_repo "$SRC4" "$DC_REMOVE" doomed
assert_eq "h: an unknown slug is a no-op" "$RC" 0
assert_eq "h: the no-op writes nothing to stdout" "$OUT" ""
# It takes a slug, never a path — including the invoking repository's own path.
for badarg in "$SRC4" "$CLONE_H" ".." "." "/" "f/oo" "$WORK"; do
	in_repo "$SRC4" "$DC_REMOVE" "$badarg"
	assert_ne "h: refuses the path argument '$badarg'" "$RC" 0
	assert_contains "h: '$badarg' is refused as a path, not a slug" "$ERR" "expected a slug, not a path"
done
assert_true "h: the invoking repository is still intact" \
	"$([ -d "$SRC4/.git" ] && [ -f "$SRC4/file.txt" ] && echo true || echo false)"
# An empty first argument is the empty SLUG it is, not a placeholder the next
# argument slides through — the same check section (a) makes on dc-enter. Getting
# it wrong here is worse than there: this helper's answer to a malformed argument
# list would be to REMOVE the clone named by the argument it should have refused.
in_repo "$SRC4" "$DC_ENTER" bystander
require_clone CLONE_BYSTANDER "h: bystander"
in_repo "$SRC4" "$DC_REMOVE" "" bystander
assert_ne "h: an empty slug is refused even with a second argument" "$RC" 0
assert_true "h: the second argument's clone is untouched" \
	"$([ -d "$CLONE_BYSTANDER" ] && echo true || echo false)"
in_repo "$SRC4" "$DC_REMOVE" bystander
assert_eq "h: naming that slug properly still removes it" "$RC" 0
assert_true "h: ... and now it is gone" "$([ ! -e "$CLONE_BYSTANDER" ] && echo true || echo false)"
# A directory at a slug's path that the helper did not create is refused.
in_repo "$SRC4" "$DC_REMOVE" foreign
assert_ne "h: refuses a foreign directory" "$RC" 0
assert_eq "h: the foreign directory survives" "$(cat "$FOREIGN_DIR/keep.txt")" "precious"
# A marker whose recorded clone path is not the one this invocation derived is
# bookkeeping that does not match, so it is refused.
in_repo "$SRC4" "$DC_ENTER" mismarked
require_clone CLONE_MIS "h: mismarked"
MIS_SESSION="$(dirname "$CLONE_MIS")"
printf 'dc-clone-v2\0clone=/somewhere/else/repo\0source=%s\0' "$SRC4" >"$MIS_SESSION/dc-clone-meta"
in_repo "$SRC4" "$DC_REMOVE" mismarked
assert_ne "h: refuses a marker that records another clone path" "$RC" 0
assert_contains "h: the mismatch is explained" "$ERR" "records clone path"
assert_true "h: the mis-marked directory survives" "$([ -d "$CLONE_MIS" ] && echo true || echo false)"
# The two helpers' path derivations agree: dc-remove removes exactly the path
# dc-enter printed.
in_repo "$SRC4" "$DC_ENTER" pinned
require_clone CLONE_PINNED "h: pinned"
in_repo "$SRC4" "$DC_REMOVE" pinned
assert_eq "h: dc-remove removes what dc-enter printed" "$RC" 0
assert_true "h: dc-enter's printed path is gone" "$([ ! -e "$CLONE_PINNED" ] && echo true || echo false)"
# ... and they agree under the environment dc-enter drops. dc-remove drops the
# same set at the same point, so the repository paths it builds its refuse-list
# from come from the repository dc-enter was run in rather than from wherever the
# caller's `GIT_DIR` happens to point. The clone still goes; nothing else does.
in_repo "$SRC4" "$DC_ENTER" gitdirremove
require_clone CLONE_GITDIRREMOVE "h: gitdirremove"
in_repo "$SRC4" env "GIT_DIR=$SRC4/.git" "$DC_REMOVE" gitdirremove
assert_eq "h: dc-remove works under an inherited GIT_DIR" "$RC" 0
assert_eq "h: ... still writing nothing to stdout" "$OUT" ""
assert_true "h: ... and the clone is gone" \
	"$([ ! -e "$CLONE_GITDIRREMOVE" ] && echo true || echo false)"
assert_true "h: ... while the invoking repository is intact" \
	"$([ -d "$SRC4/.git" ] && [ -f "$SRC4/file.txt" ] && echo true || echo false)"
# The refusals still hold there, so the sanitize did not cost the ownership proof
# its teeth: a path argument is a malformed slug whatever the environment says.
in_repo "$SRC4" env "GIT_DIR=$SRC4/.git" "$DC_REMOVE" "$SRC4"
assert_ne "h: ... and a path argument is still refused under it" "$RC" 0
assert_contains "h: ... as a path, not a slug" "$ERR" "expected a slug, not a path"

echo "== (i) the incident's shape =="
SRC5="$WORK/i/src"
mkdir -p "$WORK/i"
make_source "$SRC5"
# The original: a clone step that failed inside a pipeline, so `set -e` saw
# `tail`'s status, execution continued with the working directory still at the
# repository root, and `rm -rf ./*` ran there. Both variants below point the
# clone root inside the repository so the clone step fails; the guarded calling
# convention must stop the script either way.
cat >"$WORK/i/guarded.sh" <<'SCRIPT'
set -euo pipefail
DC="$("$DC_ENTER_BIN" probe)"
[ -n "$DC" ] && [ -d "$DC/.git" ] || exit 1
cd "$DC" || exit 1
rm -rf ./*
SCRIPT
cat >"$WORK/i/piped.sh" <<'SCRIPT'
set -euo pipefail
# The incident's exact trap: a load-bearing command piped for output brevity.
DC="$("$DC_ENTER_BIN" probe 2>&1 | tail -n 1)"
[ -n "$DC" ] && [ -d "$DC/.git" ] || exit 1
cd "$DC" || exit 1
rm -rf ./*
SCRIPT
cat >"$WORK/i/piped-nopipefail.sh" <<'SCRIPT'
# The incident's exact configuration: `set -e` WITHOUT pipefail, so the pipeline
# reports tail's success and the failed clone step is invisible to the shell.
# The explicit path guard is then the only thing between it and the repo root.
set -eu
DC="$("$DC_ENTER_BIN" probe 2>&1 | tail -n 1)"
[ -n "$DC" ] && [ -d "$DC/.git" ] || exit 1
cd "$DC" || exit 1
rm -rf ./*
SCRIPT
for variant in guarded piped piped-nopipefail; do
	in_repo "$SRC5" env "DC_ENTER_BIN=$DC_ENTER" "DC_ROOT=$SRC5/inside" bash "$WORK/i/$variant.sh"
	assert_ne "i: the $variant script stops when the clone step fails" "$RC" 0
	assert_true "i: the $variant script did not delete the repository's files" \
		"$([ -f "$SRC5/file.txt" ] && [ -d "$SRC5/.git" ] && echo true || echo false)"
	assert_eq "i: the $variant script left the repository clean" "$(git -C "$SRC5" status --porcelain)" ""
done
# And when the clone step succeeds, the same script wrecks only the clone.
in_repo "$SRC5" env "DC_ENTER_BIN=$DC_ENTER" "DC_ROOT=$WORK/i/root" bash "$WORK/i/guarded.sh"
assert_eq "i: the guarded script succeeds against a real clone" "$RC" 0
assert_eq "i: the repository is untouched by the destructive step" "$(git -C "$SRC5" status --porcelain)" ""
assert_true "i: the repository's tracked file survives" "$([ -f "$SRC5/file.txt" ] && echo true || echo false)"

echo "== (j) hardlink policy =="
SRC6="$WORK/j/src"
mkdir -p "$WORK/j"
make_source "$SRC6"
export DC_ROOT="$WORK/j/root"
# A loose object both repositories will have.
LOOSE_REL="$(git -C "$SRC6" rev-parse HEAD)"
LOOSE_PATH=".git/objects/${LOOSE_REL:0:2}/${LOOSE_REL:2}"
assert_true "j: fixture has the commit as a loose object" \
	"$([ -f "$SRC6/$LOOSE_PATH" ] && echo true || echo false)"
in_repo "$SRC6" "$DC_ENTER" nolinks
require_clone CLONE_J "j: nolinks"
SRC_INODE="$(inode_of "$SRC6/$LOOSE_PATH")"
CLONE_INODE="$(inode_of "$CLONE_J/$LOOSE_PATH")"
assert_ne "j: objects are copied, not hardlinked, by default" "$SRC_INODE" "$CLONE_INODE"
in_repo "$SRC6" env "DC_HARDLINKS=1" "$DC_ENTER" links
require_clone CLONE_JL "j: links"
LINK_INODE="$(inode_of "$CLONE_JL/$LOOSE_PATH")"
assert_eq "j: DC_HARDLINKS=1 takes the hardlinked fast path" "$LINK_INODE" "$SRC_INODE"
# The isolation guarantee holds on the hardlinked path too.
REFS_BEFORE_J="$(refs_of "$SRC6")"
OBJS_BEFORE_J="$(objects_of "$SRC6")"
git -C "$CLONE_JL" update-ref -d refs/pruned/reserved
git -C "$CLONE_JL" reflog expire --expire=now --all
git -C "$CLONE_JL" gc --prune=now --quiet
assert_eq "j: hardlinked clone's gc leaves the source's refs alone" "$(refs_of "$SRC6")" "$REFS_BEFORE_J"
assert_eq "j: hardlinked clone's gc leaves the source's objects alone" "$(objects_of "$SRC6")" "$OBJS_BEFORE_J"
in_repo "$SRC6" git fsck --no-progress --no-dangling --connectivity-only
assert_eq "j: the source still passes fsck after the hardlinked clone's gc" "$RC" 0

echo "== (k) clone-root hygiene: separators, absoluteness, newlines, and quoting =="
SRC7="$WORK/k/src"
mkdir -p "$WORK/k/root"
make_source "$SRC7"
unset DC_ROOT
# A repeated separator must COLLAPSE, not vanish: a root of "<work>/k//root"
# resolves to "<work>/k/root", never "<work>/kroot".
in_repo "$SRC7" env "DC_ROOT=$WORK/k//root" "$DC_ENTER" seps
assert_eq "k: a doubled separator in the root is accepted" "$RC" 0
assert_contains "k: ... and collapses to a single one" "$OUT" "$WORK/k/root/"
assert_true "k: ... with the clone really there" "$([ -d "$OUT/.git" ] && echo true || echo false)"
require_clone CLONE_K "k: seps"
in_repo "$SRC7" env "DC_ROOT=$WORK/k///root/" "$DC_REMOVE" seps
assert_eq "k: dc-remove collapses separators identically" "$RC" 0
assert_true "k: ... and removed the clone dc-enter printed" "$([ ! -e "$CLONE_K" ] && echo true || echo false)"
# A RELATIVE root is refused by both helpers rather than resolved against
# whatever directory each happened to be invoked from. Canonicalizing it first
# would make the absolute-path guard unfalsifiable — canon() prepends $PWD and
# asserts its own result is absolute — and the two helpers would then derive
# DIFFERENT clones from one DC_ROOT: dc-enter explicitly supports being run from
# a nested subdirectory (section (c)), so the caller entering from a subdirectory
# and removing from the repository root is a reachable configuration. The clone
# would be created, left behind, and reported as "nothing to remove" with a zero
# exit.
mkdir -p "$SRC7/deep/er"
REL_TARGET="$WORK/k/relroot"
in_repo "$SRC7/deep/er" env "DC_ROOT=../../../relroot" "$DC_ENTER" relroot
assert_ne "k: dc-enter refuses a relative root" "$RC" 0
assert_eq "k: ... silently on stdout" "$OUT" ""
assert_contains "k: ... saying it must be absolute" "$ERR" "must be an absolute path"
assert_true "k: ... and creates nothing where it would have resolved" \
	"$([ ! -e "$REL_TARGET" ] && echo true || echo false)"
in_repo "$SRC7" env "DC_ROOT=../../../relroot" "$DC_REMOVE" relroot
assert_ne "k: dc-remove refuses a relative root too" "$RC" 0
assert_contains "k: ... rather than reporting nothing to remove" "$ERR" "must be an absolute path"
rm -rf "$SRC7/deep"
# A newline in the root is refused by BOTH helpers. dc-enter's whole calling
# convention is one path on one line of stdout — the incident's own script ended
# its clone step with `| tail -n 1` — and a clone created under such a root would
# be unusable through that convention.
NL_ROOT="$WORK/k/ro
ot"
mkdir -p "$NL_ROOT"
in_repo "$SRC7" env "DC_ROOT=$NL_ROOT" "$DC_ENTER" newline
assert_ne "k: dc-enter refuses a root containing a newline" "$RC" 0
assert_eq "k: ... silently on stdout" "$OUT" ""
assert_contains "k: ... saying why" "$ERR" "newline"
assert_eq "k: ... and leaves nothing behind under it" "$(ls -A "$NL_ROOT")" ""
in_repo "$SRC7" env "DC_ROOT=$NL_ROOT" "$DC_REMOVE" newline
assert_ne "k: dc-remove refuses the same root" "$RC" 0
# A root whose newline is the LAST byte is the one that escapes a check made
# after canonicalization: command substitution strips every trailing newline it
# captures, so the refusal saw a newline-free path and the clone landed under
# THAT path instead — succeeding in a directory the caller never named.
mkdir -p "$WORK/k/trailroot"
TRAIL_ROOT="$WORK/k/trailroot
"
in_repo "$SRC7" env "DC_ROOT=$TRAIL_ROOT" "$DC_ENTER" trailnl
assert_ne "k: dc-enter refuses a root ending in a newline" "$RC" 0
assert_eq "k: ... silently on stdout" "$OUT" ""
assert_contains "k: ... saying why" "$ERR" "newline"
assert_eq "k: ... rather than silently using the newline-free path" "$(ls -A "$WORK/k/trailroot")" ""
in_repo "$SRC7" env "DC_ROOT=$TRAIL_ROOT" "$DC_REMOVE" trailnl
assert_ne "k: dc-remove refuses a root ending in a newline" "$RC" 0
# ... and a root that acquires a newline only when RESOLVED — the raw value is
# clean, but a symlinked component points at a directory whose real name is not.
# This one can only be caught after canonicalization, which is why both helpers
# check the raw value AND the resolved one.
NL_REAL="$WORK/k/re
al"
mkdir -p "$NL_REAL"
ln -s "$NL_REAL" "$WORK/k/nl-link"
in_repo "$SRC7" env "DC_ROOT=$WORK/k/nl-link" "$DC_ENTER" vianl
assert_ne "k: dc-enter refuses a root RESOLVING into a newline-bearing path" "$RC" 0
assert_eq "k: ... silently on stdout" "$OUT" ""
assert_contains "k: ... saying why" "$ERR" "newline"
assert_eq "k: ... and leaves nothing behind under the real directory" "$(ls -A "$NL_REAL")" ""
in_repo "$SRC7" env "DC_ROOT=$WORK/k/nl-link" "$DC_REMOVE" vianl
assert_ne "k: dc-remove refuses the same resolved root" "$RC" 0
# The SOURCE repository's path is not the helper's to choose, so a newline there
# still works: the marker is NUL-delimited, so it records such a path
# unambiguously and dc-remove can still prove ownership from it.
NL_SRC="$WORK/k/sr
c"
make_source "$NL_SRC"
in_repo "$NL_SRC" env "DC_ROOT=$WORK/k/root" "$DC_ENTER" nlsource
assert_eq "k: a source path containing a newline is fine" "$RC" 0
assert_eq "k: ... and mirrors exactly" "$(refs_of "$OUT")" "$(refs_of "$NL_SRC")"
require_clone CLONE_NL "k: nlsource"
in_repo "$NL_SRC" env "DC_ROOT=$WORK/k/root" "$DC_REMOVE" nlsource
assert_eq "k: ... and dc-remove parses its marker and removes it" "$RC" 0
assert_true "k: ... leaving nothing" "$([ ! -e "$CLONE_NL" ] && echo true || echo false)"
# The source path a bare `$(git rev-parse --show-toplevel)` cannot survive: its
# newline is the LAST byte, and command substitution strips it, so the helper
# would derive a different directory. The decoy below IS that directory, and it
# is a repository too — so the mistake would not fail loudly, it would quietly
# clone the wrong repository and hand a subagent the wrong-baseline conclusion
# these helpers exist to prevent.
TRAIL_SRC="$WORK/k/tsrc
"
make_source "$TRAIL_SRC"
DECOY_SRC="$WORK/k/tsrc"
git init -q -b main "$DECOY_SRC"
g -C "$DECOY_SRC" commit -q --allow-empty -m "decoy only"
g -C "$DECOY_SRC" branch -q decoy-only
in_repo "$TRAIL_SRC" env "DC_ROOT=$WORK/k/root" "$DC_ENTER" trailsrc
assert_eq "k: a source path ENDING in a newline is fine" "$RC" 0
require_clone CLONE_TRAIL "k: trailsrc"
assert_eq "k: ... and mirrors that source exactly" "$(refs_of "$CLONE_TRAIL")" "$(refs_of "$TRAIL_SRC")"
assert_eq "k: ... at that source's HEAD" \
	"$(git -C "$CLONE_TRAIL" rev-parse HEAD)" "$(git -C "$TRAIL_SRC" rev-parse HEAD)"
assert_true "k: ... and not from the decoy repository at the newline-free path" \
	"$(git -C "$CLONE_TRAIL" show-ref --verify --quiet refs/heads/decoy-only && echo false || echo true)"
# dc-remove derives the same source — trailing newline and all — so its ownership
# proof still matches the marker dc-enter wrote.
in_repo "$TRAIL_SRC" env "DC_ROOT=$WORK/k/root" "$DC_REMOVE" trailsrc
assert_eq "k: ... and dc-remove derives the identical source and removes it" "$RC" 0
assert_true "k: ... leaving nothing" "$([ ! -e "$CLONE_TRAIL" ] && echo true || echo false)"
# A SINGLE QUOTE in the source's path. dc-enter grants git an ownership
# exception for the repository it was asked to clone, and has to repeat it for
# the `git-upload-pack` child `git clone` spawns — which it can only do through
# `--upload-pack`, a value git appends the source path to and runs through
# `sh -c`. An unescaped quote there closes the quoting early and hands that
# shell a different command, so the path that carries one is the case worth
# pinning; the newline cases above cover the rest of the same plumbing.
Q_SRC="$WORK/k/it's-src"
make_source "$Q_SRC"
in_repo "$Q_SRC" env "DC_ROOT=$WORK/k/root" "$DC_ENTER" quotesource
assert_eq "k: a source path containing a single quote is fine" "$RC" 0
require_clone CLONE_Q "k: quotesource"
assert_eq "k: ... and mirrors that source exactly" "$(refs_of "$CLONE_Q")" "$(refs_of "$Q_SRC")"
assert_eq "k: ... at that source's HEAD" \
	"$(git -C "$CLONE_Q" rev-parse HEAD)" "$(git -C "$Q_SRC" rev-parse HEAD)"
in_repo "$Q_SRC" env "DC_ROOT=$WORK/k/root" "$DC_REMOVE" quotesource
assert_eq "k: ... and dc-remove removes it" "$RC" 0
assert_true "k: ... leaving nothing" "$([ ! -e "$CLONE_Q" ] && echo true || echo false)"

if [ "$fails" -eq 0 ]; then
	printf 'test-dc-helpers: %d checks passed\n' "$checks"
else
	printf 'test-dc-helpers: %d of %d checks FAILED\n' "$fails" "$checks" >&2
	exit 1
fi
