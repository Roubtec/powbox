#!/usr/bin/env bash
# Unit tests for the mountpoint-ownership decision logic in
# docker/shared/shadow-mounts.sh.
#
# What is under test
# ------------------
# When shadow-mounts.sh has to CREATE a mountpoint it does so as root (it only
# ever runs via sudo), so on a native-Linux bind mount the directory outlives the
# container as a root-owned 0755 dir once the tmpfs goes away — and the host user
# can then neither populate nor remove it (e.g. a later host `dotnet build`
# writing into bin/obj).  The fix is the chown block: every component the mkdir
# creates inherits the uid:gid of the DEEPEST ALREADY-EXISTING ancestor, before
# the mount goes on top, with at most ONE warning per run when that fails.
# BOTH routes to a mount are covered: the ordinary tmpfs one and the
# `.git/worktrees` durable-BIND branch, which reaches its mount through
# bind_git_worktrees and could otherwise lose the chown unnoticed.
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
#     PATH shims that LOG their argv and answer from fixtures.  Real `mkdir`,
#     `dirname` and `realpath` are kept, so the directory walk is the real one.
#   * `stat` is shimmed specifically so different ancestors can report different
#     owners — that is what makes "the DEEPEST existing ancestor" assertable at
#     all, since an unprivileged test cannot create differently-owned dirs.
#
# Needs only bash + coreutils.  No image, no Docker, no root.  $TMPDIR may contain
# spaces, quotes, '#', '&' or backslashes; ':' and newlines are refused up front
# (see the WORK_ROOT guard).
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
# newline cannot survive the one-record-per-line fixture files.
NL='
'
case "$WORK_ROOT" in
*:* | *"$NL"*)
	echo "FATAL: the temporary directory '$WORK_ROOT' contains ':' or a newline; this suite puts its shim dir on PATH and keeps line-based fixtures, so neither can be represented. Set TMPDIR to a path without them." >&2
	exit 1
	;;
esac

# The relocated /workspace.
WS_ROOT="$WORK_ROOT/workspace"
mkdir -p "$WS_ROOT"

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

# Every shim appends "<tool> <argv...>" to $SHIM_LOG, so a test can assert the
# exact emitted sequence and its ORDER (chown must precede mount).
cat >"$BIN/id" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "-u" ] && [ "$2" = "node" ]; then printf '%s\n' "$FAKE_NODE_UID"; exit 0; fi
if [ "$1" = "-g" ] && [ "$2" = "node" ]; then printf '%s\n' "$FAKE_NODE_GID"; exit 0; fi
# Not reached by shadow-mounts.sh (it only ever looks up `node`); kept so the
# shim is a faithful stand-in if that ever changes.
exec /usr/bin/id "$@"
SHIM

# stat: answer `-c %u:%g <path>` from $OWNER_MAP; anything unlisted falls back to
# $DEFAULT_OWNER.  Other invocations go to the real stat.  Fails (like the real
# stat on a missing path) when the path is listed as "MISSING", which drives the
# chown_failed branch.
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
if [ "$1" = "-c" ] && [ "$2" = "%u:%g" ] && [ "$#" -eq 3 ]; then
	printf 'stat %s\n' "$3" >>"$SHIM_LOG"
	if [ -n "${OWNER_MAP:-}" ] && [ -f "$OWNER_MAP" ]; then
		while IFS= read -r rec; do
			[ -n "$rec" ] || continue
			o="${rec%% *}"
			p="${rec#* }"
			if [ "$p" = "$3" ]; then
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
# assertion is on the argv the script emits.
cat >"$BIN/chown" <<'SHIM'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >>"$SHIM_LOG"
[ -n "${FAKE_CHOWN_FAIL:-}" ] && exit 1
exit 0
SHIM

cat >"$BIN/mount" <<'SHIM'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"$SHIM_LOG"
exit 0
SHIM

# mountpoint -q <path>: true only for paths listed in $MOUNTPOINTS, ONE PER LINE
# (not whitespace-separated — a TMPDIR containing a space would otherwise split a
# fixture path into two entries and silently stop matching).
cat >"$BIN/mountpoint" <<'SHIM'
#!/usr/bin/env bash
target="${!#}"
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
printf 'findmnt %s\n' "$*" >>"$SHIM_LOG"
if [ -n "${FAKE_FINDMNT_FSTYPE:-}" ]; then
	printf '%s\n' "$FAKE_FINDMNT_FSTYPE"
fi
exit 0
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
		OWNER_MAP="${OWNER_MAP:-}" \
		DEFAULT_OWNER="${DEFAULT_OWNER:-1000:1000}" \
		MOUNTPOINTS="${MOUNTPOINTS:-}" \
		FAKE_CHOWN_FAIL="${FAKE_CHOWN_FAIL:-}" \
		FAKE_FINDMNT_FSTYPE="${FAKE_FINDMNT_FSTYPE:-}" \
		FAKE_NODE_UID="$FAKE_NODE_UID" \
		FAKE_NODE_GID="$FAKE_NODE_GID" \
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
if calls chown | grep -qF -- "chown -h 4242:4242 $ws/proj/bin"; then
	ok "the created mountpoint is chowned to the existing parent's uid:gid"
else
	ko "expected 'chown -h 4242:4242 $ws/proj/bin', got: $(calls chown)"
fi
if calls stat | grep -qF "stat $ws/proj"; then
	ok "ownership is read from the deepest EXISTING ancestor (<ws>/proj)"
else
	ko "expected the owner probe to stat <ws>/proj, got: $(calls stat)"
fi
if [ "$(count mount)" = "1" ] && calls mount | grep -qF -- "-t tmpfs"; then
	ok "the target is then tmpfs-mounted"
else
	ko "expected one tmpfs mount, got: $(calls mount)"
fi
if calls mount | grep -qF "uid=$FAKE_NODE_UID,gid=$FAKE_NODE_GID"; then
	ok "the tmpfs is mounted with the node uid/gid"
else
	ko "tmpfs mount options lost the node uid/gid: $(calls mount)"
fi
# The chown must land on the underlying directory, so it has to happen BEFORE
# the mount — afterwards it would re-own the tmpfs root instead.
# `|| true` on both: with `set -o pipefail` a grep that matches nothing fails the
# whole substitution and would abort the suite under `set -e` — which is exactly
# the state a regression puts us in, so the assertion below must be allowed to
# run and REPORT it rather than killing the run.
chown_line="$(grep -n '^chown ' "$LOG" | head -n1 | cut -d: -f1 || true)"
mount_line="$(grep -n '^mount ' "$LOG" | head -n1 | cut -d: -f1 || true)"
if [ -n "$chown_line" ] && [ -n "$mount_line" ] && [ "$chown_line" -lt "$mount_line" ]; then
	ok "the chown is emitted BEFORE the mount (owns the dir, not the tmpfs root)"
else
	ko "expected chown before mount; log was: $(cat "$LOG")"
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
	if calls chown | grep -qF -- "chown -h 4242:4242 $d"; then
		ok "created level $d inherits 4242:4242"
	else
		ko "no 'chown -h 4242:4242 $d' in: $(calls chown)"
	fi
done
if calls stat | grep -qF "stat $ws" && ! calls stat | grep -qxF "stat $WS_ROOT"; then
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
mkdir -p "$ws/.git"
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
if calls findmnt | grep -qF -- "-T $ws/.worktrees"; then
	ok "the durable-bind branch really was entered (findmnt probed the .worktrees fstype)"
else
	ko "findmnt was not reached, so this case never exercised the bind branch: $(calls findmnt)"
fi
if calls chown | grep -qF -- "chown -h 4242:4242 $ws/.git/worktrees"; then
	ok "the created .git/worktrees mountpoint inherits its existing .git parent's ownership"
else
	ko "expected 'chown -h 4242:4242 $ws/.git/worktrees', got: $(calls chown)"
fi
if calls mount | grep -qF -- "mount --bind $ws/.worktrees/.gitworktrees $ws/.git/worktrees"; then
	ok "the mount is the durable bind from the volume, not a tmpfs"
else
	ko "expected a --bind of the volume's .gitworktrees, got: $(calls mount)"
fi
if ! calls mount | grep -qF -- "-t tmpfs"; then
	ok "the target did not silently fall back to tmpfs"
else
	ko "the target fell back to tmpfs: $(calls mount)"
fi
# bind_git_worktrees separately chowns its bind SOURCE to node (git runs as node).
# That is a different chown with a different target and no -h; assert it explicitly
# so the two are never conflated, and so a future change to either is visible here.
if calls chown | grep -qF -- "chown $FAKE_NODE_UID:$FAKE_NODE_GID $ws/.worktrees/.gitworktrees"; then
	ok "the bind SOURCE is still chowned to node, distinct from the mountpoint chown"
else
	ko "expected the bind source to be chowned to node, got: $(calls chown)"
fi
# Same ordering invariant as the tmpfs path: the mountpoint chown must land on the
# underlying directory, so it has to precede the bind that covers it.
chown_line="$(grep -n '^chown -h ' "$LOG" | head -n1 | cut -d: -f1 || true)"
mount_line="$(grep -n '^mount ' "$LOG" | head -n1 | cut -d: -f1 || true)"
if [ -n "$chown_line" ] && [ -n "$mount_line" ] && [ "$chown_line" -lt "$mount_line" ]; then
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
if [ "$(count mount)" = "1" ]; then
	ok "it is still mounted"
else
	ko "expected one mount, got: $(calls mount)"
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

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
