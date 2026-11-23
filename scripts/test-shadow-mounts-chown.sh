#!/usr/bin/env bash
# Unit tests for the mountpoint-ownership decision logic and the path-swap
# safety of docker/shared/shadow-mounts.sh.
#
# What is under test
# ------------------
# When shadow-mounts.sh has to CREATE a mountpoint it does so as root (it only
# ever runs via sudo), so on a native-Linux bind mount the directory outlives the
# container as a root-owned 0755 dir once the tmpfs goes away — and the host user
# can then neither populate nor remove it (e.g. a later host `dotnet build`
# writing into bin/obj).  The fix is the chown: every component the helper
# creates inherits the uid:gid of the DEEPEST ALREADY-EXISTING ancestor, before
# the mount goes on top, with at most ONE warning per run when that fails.
# BOTH routes to a mount are covered: the ordinary tmpfs one and the
# `.git/worktrees` durable-BIND branch, which reaches its mount through
# bind_git_worktrees and could otherwise lose the chown unnoticed.
#
# The second half is the path-swap race (task 081a): node may run the helper
# with any path and owns every component below /workspace/<slug>, so it can swap
# one for a symlink between the helper's validation and its use.  The race
# sweep at the end swaps a component at every point the helper calls out to a
# shimmed tool and asserts that nothing was created, chowned or mounted outside
# the workspace root.
#
# The privileged end-to-end path (real root, real tmpfs, a real bind-mounted
# checkout) is covered in the smoke tier by scripts/smoke-test-worktree-metadata.sh.
# This suite covers the DECISION LOGIC hermetically: no root, no mounts, no image.
#
# How it stays hermetic
# ---------------------
#   * The script under test is copied to a tmpdir with its `/workspace` literal
#     relocated to a throwaway root, so nothing outside the tmpdir is touched.
#     The rewrite is verified (see relocate below) — a rename of that assignment
#     makes this suite FATAL rather than silently testing an unrelocated copy.
#   * `id`, `stat`, `chown`, `mount`, `mountpoint` and `findmnt` are replaced by
#     PATH shims that LOG their argv and answer from fixtures.  `mkdir` and
#     `realpath` get pass-through shims that only add the race hook; the real
#     binaries still do the work, so the directory walk is the real one.
#   * The helper acts on its held cwd ("." and /proc/self/fd/N), so argv alone no
#     longer says WHERE a chown or mount lands.  Each shim therefore also logs an
#     `at-<tool>` line with the physical location the kernel would act on at that
#     moment — following symlinks the way that call would — which is what tells
#     a relocated mount from a correct one whatever the call shape.
#   * `stat` is shimmed specifically so different ancestors can report different
#     owners — that is what makes "the DEEPEST existing ancestor" assertable at
#     all, since an unprivileged test cannot create differently-owned dirs.
#
# Needs only bash + coreutils + /proc.  No image, no Docker, no root.  $TMPDIR may
# contain spaces, quotes, '#', '&' or backslashes; ':' and newlines are refused up
# front (see the WORK_ROOT guard).
#
# Usage: scripts/test-shadow-mounts-chown.sh
#   SHADOW_MOUNTS_SH=<path>  test that copy instead of ../docker/shared/shadow-mounts.sh
#                            (commands/smoke-test.sh Stage 0h points it at the BAKED
#                            /usr/local/bin/shadow-mounts.sh inside the image).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SHADOW_MOUNTS_SH:-$SCRIPT_DIR/../docker/shared/shadow-mounts.sh}"

if [ ! -f "$SRC" ]; then
	echo "FATAL: shadow-mounts.sh not found at $SRC" >&2
	exit 1
fi

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

WORK_ROOT="$(mktemp -d)"
WORK_ROOT="$(realpath "$WORK_ROOT")"
trap 'rm -rf "$WORK_ROOT"' EXIT

# $TMPDIR is the user's to choose, so WORK_ROOT may legitimately contain spaces,
# quotes, '#', '&' and backslashes — everything below is written to survive those.
# Exactly two characters it genuinely cannot carry, so refuse LOUDLY rather than
# misbehave: ':' would split the PATH entry that puts the shims in front, and a
# newline cannot survive the one-record-per-line fixture and log files.
NL='
'
case "$WORK_ROOT" in
*:* | *"$NL"*)
	echo "FATAL: the temporary directory '$WORK_ROOT' contains ':' or a newline; this suite puts its shim dir on PATH and keeps line-based fixtures, so neither can be represented. Set TMPDIR to a path without them." >&2
	exit 1
	;;
esac

# The relocated /workspace, and a sibling tree standing in for everything
# outside it (what a swapped-in symlink points at in the race sweep).
WS_ROOT="$WORK_ROOT/workspace"
ELSEWHERE="$WORK_ROOT/elsewhere"
mkdir -p "$WS_ROOT" "$ELSEWHERE"

# Fake uid/gid for the `node` user the script looks up with `id -u node`.
FAKE_NODE_UID=4001
FAKE_NODE_GID=4002

# --- the relocated copy of the script under test ------------------------------
# Only the `workspace_root=` assignment is functional; the /workspace strings in
# the diagnostics are cosmetic and deliberately left alone.
#
# The rewrite is a pure-bash line substitution, deliberately NOT sed: a sed
# expression would interpolate $WS_ROOT into a pattern and a replacement, where
# '#', '&', '\' and the delimiter itself are metacharacters — so a $TMPDIR
# containing any of them would silently produce broken or injected shell text.
# Here the path never reaches a pattern language at all: `printf %q` renders it in
# bash's own re-input-safe form, and that token is placed inside `$( … )`, where
# quoting restarts, so it is parsed exactly as one argument.  The FATAL below is
# the backstop either way — an unrelocated copy never runs.
SUT="$WORK_ROOT/shadow-mounts.sh"
printf -v ws_quoted '%q' "$WS_ROOT"
relocation="workspace_root=\"\$(realpath -- $ws_quoted)\""
relocated=0
: >"$SUT"
# `|| [ -n "$line" ]` so a final line without a trailing newline is not dropped.
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
	workspace_root=*)
		printf '%s\n' "$relocation" >>"$SUT"
		relocated=$((relocated + 1))
		;;
	*)
		printf '%s\n' "$line" >>"$SUT"
		;;
	esac
done <"$SRC"
if [ "$relocated" -ne 1 ]; then
	echo "FATAL: expected exactly one 'workspace_root=' assignment to relocate in $SRC, found $relocated — the assignment this suite rewrites has moved, been renamed, or been duplicated. Fix the rewrite above; do NOT let the suite run against an unrelocated copy (it would operate on the real /workspace)." >&2
	exit 1
fi
if ! grep -qF -- "$relocation" "$SUT"; then
	echo "FATAL: the relocated 'workspace_root=' line is not present in $SUT — refusing to run." >&2
	exit 1
fi
if grep -qE '^workspace_root=.*realpath /workspace' "$SUT"; then
	echo "FATAL: the relocated copy still resolves the real /workspace — refusing to run." >&2
	exit 1
fi

# --- PATH shims ----------------------------------------------------------------
BIN="$WORK_ROOT/bin"
mkdir -p "$BIN"

# The real binaries the pass-through shims (and the shim library) delegate to,
# looked up before the shim dir goes on PATH.  The library must never call a
# shimmed name itself, or resolving a location would bump a race counter.
REAL_MKDIR="$(command -v mkdir)"
REAL_REALPATH="$(command -v realpath)"

# Sourced by every shim.  phys_follow / phys_nofollow print the physical path a
# call would act on right now: from the shim's cwd (the helper's, inherited), with
# /proc/self/fd/N resolving through the descriptor the shim inherited, and with
# or without following a final-component symlink.  race_point is the race hook:
# when $RACE_AT names "<tool>:<pre|post>:<n>" — the n-th call of that tool, just
# before or just after it runs — it replaces $RACE_SWAP with a symlink to
# $RACE_DEST (moving any real directory there aside, still inside the root), once.
SHIM_LIB="$WORK_ROOT/shimlib.bash"
cat >"$SHIM_LIB" <<'LIB'
phys_follow() {
	"$REAL_REALPATH" -m -- "$1"
}
phys_nofollow() {
	local base
	base="$(basename -- "$1")"
	case "$base" in
	. | .. | /) phys_follow "$1" ;;
	*) printf '%s/%s\n' "$(phys_follow "$(dirname -- "$1")")" "$base" ;;
	esac
}
race_point() {
	[ -n "${RACE_AT:-}" ] || return 0
	local f="$RACE_DIR/count.$1" n
	if [ "$2" = pre ]; then
		n=$(($(cat "$f" 2>/dev/null || echo 0) + 1))
		echo "$n" >"$f"
	else
		n="$(cat "$f" 2>/dev/null || echo 0)"
	fi
	[ "$RACE_AT" = "$1:$2:$n" ] || return 0
	[ ! -e "$RACE_DIR/fired" ] || return 0
	if [ -e "$RACE_SWAP" ] || [ -L "$RACE_SWAP" ]; then
		mv -- "$RACE_SWAP" "$RACE_SWAP.displaced" 2>/dev/null || return 0
	fi
	ln -s -- "$RACE_DEST" "$RACE_SWAP" 2>/dev/null && : >"$RACE_DIR/fired"
	return 0
}
LIB

cat >"$BIN/id" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "-u" ] && [ "$2" = "node" ]; then printf '%s\n' "$FAKE_NODE_UID"; exit 0; fi
if [ "$1" = "-g" ] && [ "$2" = "node" ]; then printf '%s\n' "$FAKE_NODE_GID"; exit 0; fi
# Not reached by shadow-mounts.sh (it only ever looks up `node`); kept so the
# shim is a faithful stand-in if that ever changes.
exec /usr/bin/id "$@"
SHIM

# stat: answer `-c %u:%g <path>` from $OWNER_MAP, keyed by the PHYSICAL path (so
# "." finds the held directory); anything unlisted falls back to $DEFAULT_OWNER.
# Other invocations go to the real stat.  Fails (like the real stat on a missing
# path) when the path is listed as "MISSING", which drives the chown_failed branch.
#
# Record format: one per line, OWNER FIRST — "<uid>:<gid> <path>" (or
# "MISSING <path>").  Owner-first, split on the FIRST space, path = the whole
# remainder: a $TMPDIR containing spaces then still yields the right path, whereas
# a path-first `read -r p o` would split it into two fields and every lookup would
# fall through to $DEFAULT_OWNER (a silently vacuous suite).  Even `read -r o p`
# would be wrong, since read strips leading/trailing IFS whitespace from the last
# field.  A path containing a NEWLINE cannot be expressed in a line-based fixture
# at all — hence the WORK_ROOT guard near the top.
cat >"$BIN/stat" <<'SHIM'
#!/usr/bin/env bash
. "$SHIM_LIB"
race_point stat pre
if [ "$1" = "-c" ] && [ "$2" = "%u:%g" ] && [ "$#" -eq 3 ]; then
	where="$(phys_nofollow "$3")"
	printf 'stat %s\n' "$where" >>"$SHIM_LOG"
	if [ -n "${OWNER_MAP:-}" ] && [ -f "$OWNER_MAP" ]; then
		while IFS= read -r rec; do
			[ -n "$rec" ] || continue
			o="${rec%% *}"
			p="${rec#* }"
			if [ "$p" = "$where" ]; then
				[ "$o" = "MISSING" ] && exit 1
				printf '%s\n' "$o"
				exit 0
			fi
		done <"$OWNER_MAP"
	fi
	printf '%s\n' "${DEFAULT_OWNER:-1000:1000}"
	exit 0
fi
exec /usr/bin/stat "$@"
SHIM

# chown: log and succeed, or fail when FAKE_CHOWN_FAIL is set (the warn-once
# case).  An unprivileged test cannot really chown to a foreign uid, so the
# assertion is on what the script emits: the argv, plus "at-chown <owner> <where>".
cat >"$BIN/chown" <<'SHIM'
#!/usr/bin/env bash
. "$SHIM_LIB"
race_point chown pre
printf 'chown %s\n' "$*" >>"$SHIM_LOG"
nofollow=0
args=()
for a in "$@"; do
	case "$a" in
	-h) nofollow=1 ;;
	-*) ;;
	*) args+=("$a") ;;
	esac
done
if [ "$nofollow" = 1 ]; then where="$(phys_nofollow "${args[-1]}")"; else where="$(phys_follow "${args[-1]}")"; fi
printf 'at-chown %s %s\n' "${args[0]}" "$where" >>"$SHIM_LOG"
[ -n "${FAKE_CHOWN_FAIL:-}" ] && exit 1
exit 0
SHIM

# mount: log argv, then "at-mount <where>" for the target (mount(2) follows
# symlinks there) and, for --bind, "at-bindsrc <where>" for the source.
cat >"$BIN/mount" <<'SHIM'
#!/usr/bin/env bash
. "$SHIM_LIB"
race_point mount pre
printf 'mount %s\n' "$*" >>"$SHIM_LOG"
printf 'at-mount %s\n' "$(phys_follow "${!#}")" >>"$SHIM_LOG"
for a in "$@"; do
	if [ "$a" = --bind ]; then
		printf 'at-bindsrc %s\n' "$(phys_follow "${@: -2:1}")" >>"$SHIM_LOG"
	fi
done
exit 0
SHIM

# mountpoint -q <path>: true only when the PHYSICAL path is listed in
# $MOUNTPOINTS, ONE PER LINE (not whitespace-separated — a TMPDIR containing a
# space would otherwise split a fixture path into two entries and silently stop
# matching).
cat >"$BIN/mountpoint" <<'SHIM'
#!/usr/bin/env bash
. "$SHIM_LIB"
race_point mountpoint pre
target="$(phys_follow "${!#}")"
printf 'mountpoint %s\n' "$target" >>"$SHIM_LOG"
if [ -n "${MOUNTPOINTS:-}" ]; then
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		[ "$m" = "$target" ] && exit 0
	done <<<"$MOUNTPOINTS"
fi
exit 1
SHIM

# findmnt: reached only on the .git/worktrees durable-bind path, where
# bind_git_worktrees asks for the sibling .worktrees fstype to decide whether a
# PERSISTENT volume is present.  $FAKE_FINDMNT_FSTYPE is what selects the branch:
# a non-tmpfs answer (e.g. "ext4") takes the durable bind, while the default —
# reporting nothing — is read as "no persistent volume" and falls back to tmpfs.
cat >"$BIN/findmnt" <<'SHIM'
#!/usr/bin/env bash
. "$SHIM_LIB"
race_point findmnt pre
printf 'findmnt %s\n' "$*" >>"$SHIM_LOG"
prev=""
for a in "$@"; do
	[ "$prev" = -T ] && printf 'at-findmnt %s\n' "$(phys_follow "$a")" >>"$SHIM_LOG"
	prev="$a"
done
if [ -n "${FAKE_FINDMNT_FSTYPE:-}" ]; then
	printf '%s\n' "$FAKE_FINDMNT_FSTYPE"
fi
exit 0
SHIM

# Pass-through shims: the real tool does the work; the shim only offers the race
# hook a moment just before and just after it, and logs where mkdir creates.
cat >"$BIN/mkdir" <<'SHIM'
#!/usr/bin/env bash
. "$SHIM_LIB"
race_point mkdir pre
printf 'at-mkdir %s\n' "$(phys_nofollow "${!#}")" >>"$SHIM_LOG"
rc=0
"$REAL_MKDIR" "$@" || rc=$?
race_point mkdir post
exit "$rc"
SHIM

cat >"$BIN/realpath" <<'SHIM'
#!/usr/bin/env bash
. "$SHIM_LIB"
race_point realpath pre
rc=0
"$REAL_REALPATH" "$@" || rc=$?
race_point realpath post
exit "$rc"
SHIM

chmod +x "$BIN"/*

# --- driver --------------------------------------------------------------------
# run_sut <case-name> <target...> — run the relocated script with the shims in
# front of PATH.  Sets LOG (emitted call sequence) and ERR (stderr) for the
# caller to assert on.  Each case gets its own log/stderr files.
LOG=""
ERR=""
run_sut() {
	local name="$1"
	shift
	LOG="$WORK_ROOT/$name.log"
	ERR="$WORK_ROOT/$name.err"
	: >"$LOG"
	PATH="$BIN:$PATH" \
		SHIM_LOG="$LOG" \
		SHIM_LIB="$SHIM_LIB" \
		REAL_MKDIR="$REAL_MKDIR" \
		REAL_REALPATH="$REAL_REALPATH" \
		OWNER_MAP="${OWNER_MAP:-}" \
		DEFAULT_OWNER="${DEFAULT_OWNER:-1000:1000}" \
		MOUNTPOINTS="${MOUNTPOINTS:-}" \
		FAKE_CHOWN_FAIL="${FAKE_CHOWN_FAIL:-}" \
		FAKE_FINDMNT_FSTYPE="${FAKE_FINDMNT_FSTYPE:-}" \
		FAKE_NODE_UID="$FAKE_NODE_UID" \
		FAKE_NODE_GID="$FAKE_NODE_GID" \
		RACE_AT="${RACE_AT:-}" \
		RACE_DIR="${RACE_DIR:-}" \
		RACE_SWAP="${RACE_SWAP:-}" \
		RACE_DEST="${RACE_DEST:-}" \
		bash "$SUT" "$@" >/dev/null 2>"$ERR" || true
}

# calls <tool> — the logged invocations of one tool, in order.
calls() {
	grep "^$1 " "$LOG" 2>/dev/null || true
}

# count <tool> — how many times it was invoked.
count() {
	calls "$1" | grep -c . || true
}

# has <line> — the log holds exactly this line (fixed string, whole line).
has() {
	grep -qxF -- "$1" "$LOG"
}

# line_of <line> — the 1-based log line number of its first exact occurrence.
# `|| true`: with `set -o pipefail` a grep that matches nothing would fail the
# substitution and abort the suite under `set -e` — exactly the state a
# regression puts us in, so the assertion must be allowed to run and REPORT it.
line_of() {
	grep -nxF -- "$1" "$LOG" | head -n1 | cut -d: -f1 || true
}

# before <line-a> <line-b> — both are logged, and a comes first.
before() {
	local a b
	a="$(line_of "$1")"
	b="$(line_of "$2")"
	[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# reset_fixture <case> — a fresh workspace dir under the relocated root.
reset_fixture() {
	local ws="$WS_ROOT/$1"
	rm -rf "$ws"
	mkdir -p "$ws"
	printf '%s' "$ws"
}

# ---------------------------------------------------------------------------
echo "Test: a single created component inherits its existing parent's ownership"
# <ws>/proj exists and is owned by 4242:4242; <ws>/proj/bin does not exist. Only
# bin is created, so only bin is chowned — to proj's owner, not the workspace's.
ws="$(reset_fixture single)"
mkdir -p "$ws/proj"
OWNER_MAP="$WORK_ROOT/owners-single"
# printf, not a heredoc: an unquoted heredoc would process backslash escapes in
# the interpolated path, so a $TMPDIR containing '\' would be silently mangled.
printf '%s %s\n' 4242:4242 "$ws/proj" 7:7 "$ws" >"$OWNER_MAP"
run_sut single "$ws/proj/bin"
if [ "$(count chown)" = "1" ]; then
	ok "exactly one chown for the one created component"
else
	ko "expected 1 chown, got $(count chown):"
	calls chown
fi
if has "at-chown 4242:4242 $ws/proj/bin"; then
	ok "the created mountpoint is chowned to the existing parent's uid:gid"
else
	ko "expected 'at-chown 4242:4242 $ws/proj/bin', got: $(calls at-chown)"
fi
if has "stat $ws/proj"; then
	ok "ownership is read from the deepest EXISTING ancestor (<ws>/proj)"
else
	ko "expected the owner probe to stat <ws>/proj, got: $(calls stat)"
fi
if [ "$(count mount)" = "1" ] && calls mount | grep -qF -- "-t tmpfs" && has "at-mount $ws/proj/bin"; then
	ok "the target is then tmpfs-mounted, at the target"
else
	ko "expected one tmpfs mount at $ws/proj/bin, got: $(calls mount) $(calls at-mount)"
fi
if calls mount | grep -qF "uid=$FAKE_NODE_UID,gid=$FAKE_NODE_GID"; then
	ok "the tmpfs is mounted with the node uid/gid"
else
	ko "tmpfs mount options lost the node uid/gid: $(calls mount)"
fi
# The chown must land on the underlying directory, so it has to happen BEFORE
# the mount — afterwards it would re-own the tmpfs root instead.
if before "at-chown 4242:4242 $ws/proj/bin" "at-mount $ws/proj/bin"; then
	ok "the chown is emitted BEFORE the mount (owns the dir, not the tmpfs root)"
else
	ko "expected chown before mount; log was: $(cat "$LOG")"
fi
# The mount must act on the directory the helper holds, never on a path the
# kernel would walk again: "." as the target, and util-linux told not to turn
# it back into an absolute path (its default), or a component swapped after the
# walk would redirect the mount.
if calls mount | grep -q -- '--no-canonicalize .* \.$'; then
	ok "the tmpfs targets the held directory ('.') with --no-canonicalize"
else
	ko "expected 'mount --no-canonicalize … .', got: $(calls mount)"
fi

# ---------------------------------------------------------------------------
echo "Test: a multi-component creation chowns EVERY new level"
# Neither <ws>/.claude nor <ws>/.claude/worktrees exists: two levels are created
# and both must inherit <ws>'s ownership.
ws="$(reset_fixture multi)"
OWNER_MAP="$WORK_ROOT/owners-multi"
printf '%s %s\n' 4242:4242 "$ws" 7:7 "$WS_ROOT" >"$OWNER_MAP"
run_sut multi "$ws/.claude/worktrees"
if [ "$(count chown)" = "2" ]; then
	ok "exactly two chowns for the two created components"
else
	ko "expected 2 chowns, got $(count chown): $(calls chown)"
fi
for d in "$ws/.claude" "$ws/.claude/worktrees"; do
	if has "at-chown 4242:4242 $d"; then
		ok "created level $d inherits 4242:4242"
	else
		ko "no 'at-chown 4242:4242 $d' in: $(calls at-chown)"
	fi
done
if has "stat $ws" && ! has "stat $WS_ROOT"; then
	ok "ownership comes from <ws> (the deepest existing ancestor), not the workspace root"
else
	ko "owner probe read the wrong ancestor: $(calls stat)"
fi

# ---------------------------------------------------------------------------
echo "Test: a three-level creation still uses the deepest existing ancestor"
ws="$(reset_fixture deep)"
mkdir -p "$ws/proj"
OWNER_MAP="$WORK_ROOT/owners-deep"
printf '%s %s\n' 4242:4242 "$ws/proj" 7:7 "$ws" >"$OWNER_MAP"
run_sut deep "$ws/proj/a/b/c"
if [ "$(count chown)" = "3" ]; then
	ok "three created levels produce three chowns"
else
	ko "expected 3 chowns, got $(count chown): $(calls chown)"
fi
if [ "$(calls chown | grep -c '4242:4242')" = "3" ]; then
	ok "all three inherit the deepest existing ancestor's ownership"
else
	ko "not every level got 4242:4242: $(calls chown)"
fi
if ! calls chown | grep -q '7:7'; then
	ok "no level inherits a shallower ancestor's ownership"
else
	ko "a level inherited the wrong ancestor: $(calls chown)"
fi

# ---------------------------------------------------------------------------
echo "Test: the durable .git/worktrees BIND branch chowns the created mountpoint too"
# A target ending in /.git/worktrees does NOT reach the tmpfs line: when the sibling
# .worktrees is a PERSISTENT (non-tmpfs) mount, shadow-mounts.sh binds that volume's
# .gitworktrees over it instead.  That is a second route to a mount, so the
# mountpoint chown has to be pinned there as well — a regression that moved the
# chown down into the tmpfs branch would leave every durable .git/worktrees
# mountpoint root-owned and pass every other case in this file.
# Driving this branch is also what makes the findmnt shim reachable at all: it
# answers the fstype probe that chooses durable-bind over tmpfs.
ws="$(reset_fixture gitwt)"
mkdir -p "$ws/.git" "$ws/.worktrees"
OWNER_MAP="$WORK_ROOT/owners-gitwt"
printf '%s %s\n' 4242:4242 "$ws/.git" 7:7 "$ws" >"$OWNER_MAP"
# .worktrees is a mountpoint (it stands in for the persistent volume) but the
# TARGET is not, so the target is still processed rather than skipped.
MOUNTPOINTS="$ws/.worktrees"
FAKE_FINDMNT_FSTYPE=ext4
run_sut gitwt "$ws/.git/worktrees"
MOUNTPOINTS=""
FAKE_FINDMNT_FSTYPE=""
OWNER_MAP=""
if has "at-findmnt $ws/.worktrees"; then
	ok "the durable-bind branch really was entered (findmnt probed the .worktrees fstype)"
else
	ko "findmnt was not reached, so this case never exercised the bind branch: $(calls at-findmnt)"
fi
if has "at-chown 4242:4242 $ws/.git/worktrees"; then
	ok "the created .git/worktrees mountpoint inherits its existing .git parent's ownership"
else
	ko "expected 'at-chown 4242:4242 $ws/.git/worktrees', got: $(calls at-chown)"
fi
if calls mount | grep -qF -- "--bind" && has "at-bindsrc $ws/.worktrees/.gitworktrees" && has "at-mount $ws/.git/worktrees"; then
	ok "the mount is the durable bind from the volume, not a tmpfs"
else
	ko "expected a --bind of the volume's .gitworktrees over .git/worktrees, got: $(calls mount) $(calls at-bindsrc) $(calls at-mount)"
fi
if ! calls mount | grep -qF -- "-t tmpfs"; then
	ok "the target did not silently fall back to tmpfs"
else
	ko "the target fell back to tmpfs: $(calls mount)"
fi
# Both ends are held: the source through a descriptor, the target as the cwd.
if calls mount | grep -q -- '--no-canonicalize --bind /proc/self/fd/[0-9][0-9]* \.$'; then
	ok "the bind passes the held source as /proc/self/fd/N and the held target as '.', uncanonicalized"
else
	ko "expected 'mount --no-canonicalize --bind /proc/self/fd/N .', got: $(calls mount)"
fi
# bind_git_worktrees separately chowns its bind SOURCE to node (git runs as node).
# That is a different chown with a different target; assert it explicitly so the
# two are never conflated, and so a future change to either is visible here.
if has "at-chown $FAKE_NODE_UID:$FAKE_NODE_GID $ws/.worktrees/.gitworktrees"; then
	ok "the bind SOURCE is still chowned to node, distinct from the mountpoint chown"
else
	ko "expected the bind source to be chowned to node, got: $(calls at-chown)"
fi
# Same ordering invariant as the tmpfs path: the mountpoint chown must land on the
# underlying directory, so it has to precede the bind that covers it.
if before "at-chown 4242:4242 $ws/.git/worktrees" "at-mount $ws/.git/worktrees"; then
	ok "on the bind branch too the chown is emitted BEFORE the mount"
else
	ko "expected chown before mount on the bind branch; log was: $(cat "$LOG")"
fi

# ---------------------------------------------------------------------------
echo "Test: nothing created → nothing chowned"
ws="$(reset_fixture existing)"
mkdir -p "$ws/proj/bin"
OWNER_MAP=""
run_sut existing "$ws/proj/bin"
if [ "$(count chown)" = "0" ]; then
	ok "an already-existing mountpoint is not re-chowned"
else
	ko "expected no chown, got: $(calls chown)"
fi
if [ "$(count mount)" = "1" ] && has "at-mount $ws/proj/bin"; then
	ok "it is still mounted"
else
	ko "expected one mount at $ws/proj/bin, got: $(calls mount) $(calls at-mount)"
fi

# ---------------------------------------------------------------------------
echo "Test: a target reached through a symlink is shadowed at its resolved location"
# A .powbox.yml literal may go through a symlink that exists at validation time;
# the helper resolves it once and then walks the physical path, as before.
ws="$(reset_fixture legitlink)"
mkdir -p "$ws/real"
ln -s real "$ws/link"
OWNER_MAP=""
run_sut legitlink "$ws/link/bin"
if has "at-mount $ws/real/bin" && has "at-chown 1000:1000 $ws/real/bin" && [ "$(count mount)" = "1" ]; then
	ok "the mount and the chown land on the resolved <ws>/real/bin"
else
	ko "expected the resolved location to be created, chowned and mounted; log was: $(cat "$LOG")"
fi

# ---------------------------------------------------------------------------
echo "Test: an existing mountpoint is skipped entirely (idempotent re-run)"
ws="$(reset_fixture idempotent)"
mkdir -p "$ws/proj/bin"
MOUNTPOINTS="$ws/proj/bin"
run_sut idempotent "$ws/proj/bin"
MOUNTPOINTS=""
if [ "$(count chown)" = "0" ] && [ "$(count mount)" = "0" ]; then
	ok "no chown and no mount for a path that is already a mountpoint"
else
	ko "expected neither chown nor mount; got chown=$(calls chown) mount=$(calls mount)"
fi

# ---------------------------------------------------------------------------
echo "Test: a failing chown warns ONCE per run, not once per directory"
# Two targets, each needing a fresh component, with chown failing for all of
# them: on a Windows/FUSE bind mount chown is a no-op or EPERM, and a repo full
# of never-built projects must not print dozens of identical lines at startup.
ws="$(reset_fixture warnonce)"
OWNER_MAP=""
FAKE_CHOWN_FAIL=1
run_sut warnonce "$ws/one/bin" "$ws/two/bin"
FAKE_CHOWN_FAIL=""
warns="$(grep -c 'could not give one or more created mountpoint directories' "$ERR" || true)"
if [ "$(count chown)" -ge 3 ]; then
	ok "every created directory was attempted ($(count chown) chown calls)"
else
	ko "expected at least 3 chown attempts across both targets, got $(count chown)"
fi
if [ "$warns" = "1" ]; then
	ok "exactly one warning for many failed chowns"
else
	ko "expected exactly 1 warning line, got $warns:"
	cat "$ERR" >&2
fi
if [ "$(count mount)" = "2" ]; then
	ok "a failed chown is never fatal — both targets are still mounted"
else
	ko "expected both targets mounted, got: $(calls mount)"
fi

# ---------------------------------------------------------------------------
echo "Test: an unreadable ancestor warns once and never guesses an owner"
ws="$(reset_fixture statfail)"
OWNER_MAP="$WORK_ROOT/owners-statfail"
printf 'MISSING %s\n' "$ws" >"$OWNER_MAP"
run_sut statfail "$ws/nested/bin"
OWNER_MAP=""
if [ "$(count chown)" = "0" ]; then
	ok "no chown is attempted when the ancestor's ownership cannot be read"
else
	ko "expected no chown after a failed owner probe, got: $(calls chown)"
fi
if [ "$(grep -c 'could not give one or more created mountpoint directories' "$ERR" || true)" = "1" ]; then
	ok "the failed owner probe still produces the single warning"
else
	ko "expected exactly one warning; stderr was: $(cat "$ERR")"
fi
if [ "$(count mount)" = "1" ]; then
	ok "the target is mounted regardless"
else
	ko "expected the target to still be mounted, got: $(calls mount)"
fi

# ---------------------------------------------------------------------------
echo "Test: a rejected target is neither created nor chowned"
# Depth-1 (the workspace itself) and outside-the-root targets are refused before
# any mkdir, so no ownership decision is ever made for them.
ws="$(reset_fixture rejected)"
OWNER_MAP=""
run_sut rejected "$WS_ROOT/toplevel" "$WORK_ROOT/outside/bin"
if [ "$(count chown)" = "0" ] && [ "$(count mount)" = "0" ]; then
	ok "a depth-1 target and an out-of-root target produce no chown and no mount"
else
	ko "expected neither; got chown=$(calls chown) mount=$(calls mount)"
fi
if [ ! -e "$WORK_ROOT/outside/bin" ]; then
	ok "the out-of-root target was not created on disk"
else
	ko "the out-of-root target was created: $WORK_ROOT/outside/bin"
fi

# ---------------------------------------------------------------------------
echo "Test: a component swapped for a symlink right after validation is refused"
# The canonical race: the target validates (realpath, the helper's second call)
# and THEN its existing intermediate <ws>/proj becomes a symlink out of the root.
# A path-string helper would create, chown and mount through it.
ws="$(reset_fixture swapnow)"
mkdir -p "$ws/proj" "$ELSEWHERE/swapnow"
RACE_DIR="$WORK_ROOT/race-swapnow"
mkdir -p "$RACE_DIR"
RACE_AT="realpath:post:2" RACE_SWAP="$ws/proj" RACE_DEST="$ELSEWHERE/swapnow" \
	run_sut swapnow "$ws/proj/bin"
RACE_DIR=""
if [ -e "$WORK_ROOT/race-swapnow/fired" ]; then
	ok "the swap happened between validation and use"
else
	ko "the race hook never fired, so this case tested nothing"
fi
if [ "$(count mount)" = "0" ] && [ "$(count chown)" = "0" ] && [ -z "$(ls -A "$ELSEWHERE/swapnow")" ]; then
	ok "nothing was mounted, chowned or created"
else
	ko "expected no effect at all; log was: $(cat "$LOG"); elsewhere holds: $(ls -A "$ELSEWHERE/swapnow")"
fi
if grep -qF "is a symlink or was swapped while being entered" "$ERR"; then
	ok "the refusal names the swapped component"
else
	ko "expected the swapped-component refusal on stderr, got: $(cat "$ERR")"
fi

# ---------------------------------------------------------------------------
echo "Test: race sweep — a component swapped at ANY call-out never escapes the root"
# For each target shape and each component of it (existing, about to be created,
# the mountpoint itself, and on the bind branch the source side too), swap that
# component for a symlink out of the root at every point the helper calls a
# shimmed tool — just before or just after — and require that every mkdir,
# chown, mount target and bind source still lands under the root, and that
# nothing appeared outside it.  A point the helper never reaches for a given
# shape simply does not fire; each component must be swapped at least once.
RACE_POINTS="realpath:post:2 mountpoint:pre:1 mountpoint:pre:2 stat:pre:1 mkdir:pre:1 mkdir:post:1 mkdir:pre:2 mkdir:post:2 mkdir:pre:3 mkdir:post:3 chown:pre:1 chown:pre:2 chown:pre:3 findmnt:pre:1 mount:pre:1"

# escaped — print every logged location outside the root (nothing on success).
escaped() {
	local rec where
	while IFS= read -r rec; do
		case "$rec" in
		at-mkdir\ * | at-mount\ * | at-bindsrc\ *) where="${rec#* }" ;;
		at-chown\ *)
			where="${rec#* }"
			where="${where#* }"
			;;
		*) continue ;;
		esac
		case "$where" in
		"$WS_ROOT"/*) ;;
		*) printf '%s\n' "$rec" ;;
		esac
	done <"$LOG"
}

# race_case <shape> <component-relative-to-ws> — one sweep over RACE_POINTS.
race_case() {
	local shape="$1" comp="$2" point ws dest n=0 fired=0 bad=0 out
	for point in $RACE_POINTS; do
		n=$((n + 1))
		ws="$(reset_fixture "race-$shape")"
		dest="$ELSEWHERE/race-$shape"
		rm -rf "$dest"
		mkdir -p "$dest/sub"
		MOUNTPOINTS=""
		FAKE_FINDMNT_FSTYPE=""
		case "$shape" in
		single)
			mkdir -p "$ws/proj"
			target="$ws/proj/bin"
			;;
		multi) target="$ws/.claude/worktrees" ;;
		gitwt)
			mkdir -p "$ws/.git" "$ws/.worktrees"
			MOUNTPOINTS="$ws/.worktrees"
			FAKE_FINDMNT_FSTYPE=ext4
			target="$ws/.git/worktrees"
			;;
		esac
		RACE_DIR="$WORK_ROOT/race-$shape-$n"
		rm -rf "$RACE_DIR"
		mkdir -p "$RACE_DIR"
		before_tree="$(find "$ELSEWHERE" -print | LC_ALL=C sort)"
		RACE_AT="$point" RACE_SWAP="$ws/$comp" RACE_DEST="$dest" \
			run_sut "race-$shape-$n" "$target"
		[ -e "$RACE_DIR/fired" ] || continue
		fired=$((fired + 1))
		out="$(escaped)"
		if [ -n "$out" ]; then
			bad=$((bad + 1))
			ko "$shape, $comp swapped at $point: acted outside the root: $out"
		fi
		if [ "$(find "$ELSEWHERE" -print | LC_ALL=C sort)" != "$before_tree" ]; then
			bad=$((bad + 1))
			ko "$shape, $comp swapped at $point: created something outside the root"
		fi
	done
	MOUNTPOINTS=""
	FAKE_FINDMNT_FSTYPE=""
	RACE_DIR=""
	if [ "$fired" -eq 0 ]; then
		ko "$shape, $comp: no race point fired, so the sweep tested nothing"
	elif [ "$bad" -eq 0 ]; then
		ok "$shape: $comp swapped at $fired call-outs, nothing escaped the root"
	fi
}

race_case single proj
race_case single proj/bin
race_case multi .claude
race_case multi .claude/worktrees
race_case gitwt .git
race_case gitwt .git/worktrees
race_case gitwt .worktrees
race_case gitwt .worktrees/.gitworktrees

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
