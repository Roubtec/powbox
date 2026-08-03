#!/usr/bin/env bash
# Unit tests for docker/shared/sync-codex-skills.sh — the start-time refresh that
# brings Codex's copies of the shared dev-skills palette to the same agent-skills
# commit the Claude plugin serves, synced LOCALLY from the plugin's marketplace clone.
#
# Focus: the marker-gated overwrite (only powbox-owned copies), the SHA-gated
# no-op (unchanged palette writes nothing), user-adopted / not-in-clone skills
# left untouched, absent-skill placement, and the cold-clone skip.
#
# Runs directly against the repo copies of sync-codex-skills.sh + seed-skills.sh —
# no image build needed. The agent-skills SHA is injected via
# POWBOX_CODEX_SKILL_CLONE_SHA so no git repo is required. Requires bash plus common
# POSIX userland — mktemp, stat, grep, find, and the cp/mv/rmdir the sourced
# seed-skills.sh primitives call; flock is optional (the two clone-read race-guard
# cases are skipped when no flock binary is present).
#
# Usage: scripts/test-sync-codex-skills.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC="$SCRIPT_DIR/../docker/shared/sync-codex-skills.sh"
SEED_LIB="$SCRIPT_DIR/../docker/shared/seed-skills.sh"

for f in "$SYNC" "$SEED_LIB"; do
	if [ ! -f "$f" ]; then
		echo "FATAL: required script not found at $f" >&2
		exit 1
	fi
done

pass=0
fail=0

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

ok() {
	pass=$((pass + 1))
	printf 'ok   - %s\n' "$1"
}
no() {
	fail=$((fail + 1))
	printf 'FAIL - %s\n' "$1"
}

# marker_sha <skill_dir> — echo the agent_skills_commit recorded in the skill's
# .powbox-seeded marker (empty when absent/unrecorded).
marker_sha() {
	local m="$1/.powbox-seeded"
	[ -f "$m" ] || return 0
	grep -a '^agent_skills_commit=' "$m" 2>/dev/null | head -n1 | cut -d= -f2
}

# make_skill <dir> <body> — create a minimal skill folder with a SKILL.md.
make_skill() {
	mkdir -p "$1"
	printf '%s\n' "$2" >"$1/SKILL.md"
}

# run_sync <clone_skills_parent> <dest> <sha> — invoke the sync with temp paths.
# The clone root is the parent of codex/dev-skills/skills; here we pass a prebuilt
# clone tree. Meta points at a dir with no build-epoch/commit → placeholders.
# The claude-plugin lock is pinned into WORK_ROOT too, so the test never touches the
# real ~/.claude default and each case's inner lock is self-contained.
run_sync() {
	local clone="$1" dest="$2" sha="$3"
	POWBOX_SEED_SKILLS_LIB="$SEED_LIB" \
		POWBOX_CODEX_SKILL_CLONE="$clone" \
		POWBOX_CODEX_SKILLS_DEST="$dest" \
		POWBOX_CODEX_SEED_META="$WORK_ROOT/nometa" \
		POWBOX_CODEX_SYNC_LOG="$WORK_ROOT/sync.log" \
		POWBOX_CODEX_SYNC_LOCK_FILE="$dest/.sync.lock" \
		POWBOX_PLUGIN_LOCK_FILE="$dest/.claude-plugin.lock" \
		POWBOX_CODEX_SKILL_CLONE_SHA="$sha" \
		bash "$SYNC"
}

# --- Fixture: a clone with two shared skills (a, b) -------------------------------
new_case() {
	local root="$WORK_ROOT/$1"
	mkdir -p "$root/clone/codex/dev-skills/skills" "$root/dest"
	make_skill "$root/clone/codex/dev-skills/skills/a" "shared skill a v1"
	make_skill "$root/clone/codex/dev-skills/skills/b" "shared skill b v1"
	echo "$root"
}

# ================================================================================
# Test 1: a powbox-owned (marked) copy at an OLD sha is refreshed to the clone sha,
#         content is updated, and the marker records the synced sha, the writing
#         channel, and the UPSTREAM source path of that specific skill.
#
#         The pre-seeded fixture markers deliberately use the LEGACY spelling
#         (`source=plugin-clone`, no upstream path) that images before this split
#         wrote: an old marker must still classify as powbox-owned and refresh —
#         every consumer parses by key, never by line number or count.
# ================================================================================
R="$(new_case t1)"
# Pre-seed dest with marked copies at an OLD sha and stale content.
for s in a b; do
	make_skill "$R/dest/$s" "STALE $s"
	printf 'epoch=1\ncommit=old\nagent_skills_commit=OLDSHA\nsource=plugin-clone\n' >"$R/dest/$s/.powbox-seeded"
done
run_sync "$R/clone" "$R/dest" "NEWSHA111"
if [ "$(cat "$R/dest/a/SKILL.md")" = "shared skill a v1" ] &&
	[ "$(marker_sha "$R/dest/a")" = "NEWSHA111" ] &&
	grep -q '^channel=plugin-clone$' "$R/dest/a/.powbox-seeded"; then
	ok "legacy marker refreshed to clone content + sha, channel=plugin-clone"
else
	no "legacy marker refreshed to clone content + sha, channel=plugin-clone"
fi
# The `source=` line names the item's own upstream path in agent-skills — the
# "where do I fix this?" answer — and is per-skill, not per-run.
if grep -q '^source=Roubtec/agent-skills#codex/dev-skills/skills/a$' "$R/dest/a/.powbox-seeded" &&
	grep -q '^source=Roubtec/agent-skills#codex/dev-skills/skills/b$' "$R/dest/b/.powbox-seeded"; then
	ok "marker records the per-skill upstream source path (repo#path/<name>)"
else
	no "marker records the per-skill upstream source path (repo#path/<name>)"
fi
# The legacy channel spelling must be GONE from a rewritten marker: `source=` now
# means the upstream path, so a stale `source=plugin-clone` would be ambiguous.
if ! grep -q '^source=plugin-clone$' "$R/dest/a/.powbox-seeded"; then
	ok "rewritten marker no longer spells the channel as source=plugin-clone"
else
	no "rewritten marker no longer spells the channel as source=plugin-clone"
fi
# Shape guard for the two-part composition (seed_marker_content's body + this
# channel's own lines): the body is captured through `$(...)`, which strips ALL
# trailing newlines, so the composing `printf '%s\n…'` supplies exactly the one
# separator needed. Pin BOTH halves of that invariant — no blank line may creep
# in, and no two keys may collide onto one line — because either direction
# silently breaks the key-anchored parsing every consumer relies on.
marker_lines="$(cat "$R/dest/a/.powbox-seeded")"
expected_lines="$(printf 'epoch=\ncommit=\nsource=Roubtec/agent-skills#codex/dev-skills/skills/a\nagent_skills_commit=NEWSHA111\nchannel=plugin-clone')"
if [ "$(printf '%s\n' "$marker_lines" | grep -c '^$')" -eq 0 ] &&
	[ "$(printf '%s\n' "$marker_lines" | sed 's/^\(epoch=\|commit=\).*/\1/')" = "$expected_lines" ]; then
	ok "marker is one key=value per line: no blank lines, no run-together keys"
else
	no "marker is one key=value per line: no blank lines, no run-together keys"
fi

# ================================================================================
# Test 2: SHA-gated no-op — a second sync at the SAME sha writes NOTHING
#         (mtimes of SKILL.md and marker stable).
# ================================================================================
before_skill="$(stat -c %Y "$R/dest/a/SKILL.md")"
before_marker="$(stat -c %Y "$R/dest/a/.powbox-seeded")"
sleep 1.1
run_sync "$R/clone" "$R/dest" "NEWSHA111"
after_skill="$(stat -c %Y "$R/dest/a/SKILL.md")"
after_marker="$(stat -c %Y "$R/dest/a/.powbox-seeded")"
if [ "$before_skill" = "$after_skill" ] && [ "$before_marker" = "$after_marker" ]; then
	ok "unchanged palette (same sha) is a no-op: mtimes stable across two syncs"
else
	no "unchanged palette (same sha) is a no-op: mtimes stable across two syncs"
fi

# ================================================================================
# Test 3: a user-adopted skill (marker deleted) is NEVER touched, even when the
#         clone sha moves.
# ================================================================================
R="$(new_case t3)"
make_skill "$R/dest/a" "USER FORK a"
# no marker => user-owned
make_skill "$R/dest/b" "STALE b"
printf 'epoch=1\ncommit=old\nagent_skills_commit=OLDSHA\nsource=plugin-clone\n' >"$R/dest/b/.powbox-seeded"
run_sync "$R/clone" "$R/dest" "NEWSHA222"
if [ "$(cat "$R/dest/a/SKILL.md")" = "USER FORK a" ] && [ ! -f "$R/dest/a/.powbox-seeded" ]; then
	ok "user-adopted (unmarked) skill left untouched and unmarked"
else
	no "user-adopted (unmarked) skill left untouched and unmarked"
fi
if [ "$(cat "$R/dest/b/SKILL.md")" = "shared skill b v1" ] && [ "$(marker_sha "$R/dest/b")" = "NEWSHA222" ]; then
	ok "sibling marked skill still refreshed in the same pass"
else
	no "sibling marked skill still refreshed in the same pass"
fi

# ================================================================================
# Test 4: a dest skill NOT in the clone is never a candidate — the sync iterates
#         the clone's names only, so an on-volume skill the clone does not carry
#         (e.g. a leftover from an older bake) is untouched even when marked.
# ================================================================================
R="$(new_case t4)"
make_skill "$R/dest/legacy-baked" "legacy baked v1"
printf 'epoch=1\ncommit=baked\n' >"$R/dest/legacy-baked/.powbox-seeded"
before="$(stat -c %Y "$R/dest/legacy-baked/SKILL.md")"
sleep 1.1
run_sync "$R/clone" "$R/dest" "NEWSHA333"
after="$(stat -c %Y "$R/dest/legacy-baked/SKILL.md")"
if [ "$before" = "$after" ] && [ "$(cat "$R/dest/legacy-baked/SKILL.md")" = "legacy baked v1" ]; then
	ok "skill absent from clone never touched"
else
	no "skill absent from clone never touched"
fi

# ================================================================================
# Test 5: an absent shared skill is placed (converge), marked at the clone sha.
# ================================================================================
R="$(new_case t5)"
# dest starts empty; both a and b should be placed.
run_sync "$R/clone" "$R/dest" "NEWSHA444"
if [ -f "$R/dest/a/SKILL.md" ] && [ -f "$R/dest/b/SKILL.md" ] &&
	[ "$(marker_sha "$R/dest/a")" = "NEWSHA444" ] && [ "$(marker_sha "$R/dest/b")" = "NEWSHA444" ]; then
	ok "absent shared skills placed and marked at the clone sha"
else
	no "absent shared skills placed and marked at the clone sha"
fi

# ================================================================================
# Test 6: cold clone (no codex/dev-skills/skills) -> skip, baked dest intact.
# ================================================================================
R="$WORK_ROOT/t6"
mkdir -p "$R/clone" "$R/dest"
make_skill "$R/dest/a" "BAKED a"
printf 'epoch=1\ncommit=baked\nagent_skills_commit=BAKED\nsource=bake\n' >"$R/dest/a/.powbox-seeded"
before="$(stat -c %Y "$R/dest/a/SKILL.md")"
sleep 1.1
run_sync "$R/clone" "$R/dest" "NEWSHA555"
after="$(stat -c %Y "$R/dest/a/SKILL.md")"
if [ "$before" = "$after" ] && [ "$(cat "$R/dest/a/SKILL.md")" = "BAKED a" ]; then
	ok "cold clone (missing codex skills dir) skips; baked copy intact"
else
	no "cold clone (missing codex skills dir) skips; baked copy intact"
fi

# ================================================================================
# Test 7: no clone SHA resolvable (not a git repo, no override) -> skip, intact.
# ================================================================================
R="$(new_case t7)"
make_skill "$R/dest/a" "BAKED a"
printf 'epoch=1\ncommit=baked\n' >"$R/dest/a/.powbox-seeded"
before="$(stat -c %Y "$R/dest/a/SKILL.md")"
sleep 1.1
# empty CLONE_SHA override + non-git clone dir => rev-parse fails => skip.
POWBOX_SEED_SKILLS_LIB="$SEED_LIB" \
	POWBOX_CODEX_SKILL_CLONE="$R/clone" \
	POWBOX_CODEX_SKILLS_DEST="$R/dest" \
	POWBOX_CODEX_SEED_META="$WORK_ROOT/nometa" \
	POWBOX_CODEX_SYNC_LOG="$WORK_ROOT/sync.log" \
	POWBOX_CODEX_SYNC_LOCK_FILE="$R/dest/.sync.lock" \
	POWBOX_PLUGIN_LOCK_FILE="$R/dest/.claude-plugin.lock" \
	bash "$SYNC"
after="$(stat -c %Y "$R/dest/a/SKILL.md")"
if [ "$before" = "$after" ] && [ "$(cat "$R/dest/a/SKILL.md")" = "BAKED a" ]; then
	ok "unresolvable clone HEAD skips; baked copy intact"
else
	no "unresolvable clone HEAD skips; baked copy intact"
fi

# ================================================================================
# Test 8: clone-read race guard — while a PEER holds the claude-plugin lock (its
#         marketplace pull is in flight), the sync must NOT read the clone or write
#         the dest. Simulated by holding the claude-plugin lockfile from another
#         process with a short LOCK_WAIT so the inner lock times out → skip.
# ================================================================================
if command -v flock >/dev/null 2>&1; then
	R="$(new_case t8)"
	make_skill "$R/dest/a" "BAKED a"
	printf 'epoch=1\ncommit=old\nagent_skills_commit=OLDSHA\nsource=plugin-clone\n' >"$R/dest/a/.powbox-seeded"
	before="$(stat -c %Y "$R/dest/a/SKILL.md")"
	CLAUDE_LOCK="$R/dest/.claude-plugin.lock"
	: >"$CLAUDE_LOCK"
	# Hold the claude-plugin lock in a background subshell for ~3s.
	(
		flock 9
		sleep 3
	) 9>"$CLAUDE_LOCK" &
	holder=$!
	# Give the holder a moment to acquire before the sync tries.
	sleep 0.3
	POWBOX_SEED_SKILLS_LIB="$SEED_LIB" \
		POWBOX_CODEX_SKILL_CLONE="$R/clone" \
		POWBOX_CODEX_SKILLS_DEST="$R/dest" \
		POWBOX_CODEX_SEED_META="$WORK_ROOT/nometa" \
		POWBOX_CODEX_SYNC_LOG="$WORK_ROOT/sync.log" \
		POWBOX_CODEX_SYNC_LOCK_FILE="$R/dest/.sync.lock" \
		POWBOX_PLUGIN_LOCK_FILE="$CLAUDE_LOCK" \
		POWBOX_PLUGIN_LOCK_WAIT=1 \
		POWBOX_CODEX_SKILL_CLONE_SHA="NEWSHA888" \
		bash "$SYNC"
	wait "$holder" 2>/dev/null || true
	after="$(stat -c %Y "$R/dest/a/SKILL.md")"
	if [ "$before" = "$after" ] && [ "$(cat "$R/dest/a/SKILL.md")" = "BAKED a" ] &&
		[ "$(marker_sha "$R/dest/a")" = "OLDSHA" ]; then
		ok "clone-read race: peer holds claude-plugin lock -> sync skips, dest untouched"
	else
		no "clone-read race: peer holds claude-plugin lock -> sync skips, dest untouched"
	fi
	# Follow-up: once the peer releases the lock, a re-run converges normally.
	run_sync "$R/clone" "$R/dest" "NEWSHA999"
	if [ "$(cat "$R/dest/a/SKILL.md")" = "shared skill a v1" ] && [ "$(marker_sha "$R/dest/a")" = "NEWSHA999" ]; then
		ok "clone-read race: after the peer releases the lock, a re-run converges"
	else
		no "clone-read race: after the peer releases the lock, a re-run converges"
	fi
else
	ok "clone-read race guard skipped (no flock binary)"
	ok "clone-read race re-run skipped (no flock binary)"
fi

# ================================================================================
# Test 9: atomic replace never DESTROYS the prior copy — seed_skill (via the sync)
#         leaves a valid skill dir at every observable moment. Here we assert the
#         post-refresh dir is complete (SKILL.md + marker) and no stray temp/backup
#         siblings (.a.tmp.* / .a.old.*) leak into the skills dir.
# ================================================================================
R="$(new_case t9)"
make_skill "$R/dest/a" "STALE a"
printf 'epoch=1\ncommit=old\nagent_skills_commit=OLDSHA\nsource=plugin-clone\n' >"$R/dest/a/.powbox-seeded"
run_sync "$R/clone" "$R/dest" "NEWSHAA10"
leaked="$(find "$R/dest" -maxdepth 1 \( -name '.a.tmp.*' -o -name '.a.old.*' \) 2>/dev/null)"
if [ -f "$R/dest/a/SKILL.md" ] && [ -f "$R/dest/a/.powbox-seeded" ] &&
	[ "$(cat "$R/dest/a/SKILL.md")" = "shared skill a v1" ] && [ -z "$leaked" ]; then
	ok "atomic replace leaves a complete dir and no stray temp/backup siblings"
else
	no "atomic replace leaves a complete dir and no stray temp/backup siblings"
fi

# ================================================================================
# Test 10: forfeited-skill regression guard — enable-worktrees and
#          session-learnings used to be protected by a bake-owned denylist while
#          they were baked exclusively from this repo. They now live in
#          agent-skills and arrive via the clone, so a marked stale copy of them
#          must be refreshed like ANY other shared skill (no denylist remains),
#          while a user-adopted (unmarked) copy stays protected by the marker gate.
# ================================================================================
R="$(new_case t10)"
make_skill "$R/clone/codex/dev-skills/skills/enable-worktrees" "clone enable-worktrees v2"
make_skill "$R/clone/codex/dev-skills/skills/session-learnings" "clone session-learnings v2"
# Marked stale copy (e.g. from an older bake) → must refresh.
make_skill "$R/dest/enable-worktrees" "STALE bake-era enable-worktrees"
printf 'epoch=1\ncommit=baked\nagent_skills_commit=OLDSHA\nsource=bake\n' >"$R/dest/enable-worktrees/.powbox-seeded"
# User-adopted copy (marker deleted) → must stay untouched.
make_skill "$R/dest/session-learnings" "USER FORK session-learnings"
run_sync "$R/clone" "$R/dest" "NEWSHAB11"
if [ "$(cat "$R/dest/enable-worktrees/SKILL.md")" = "clone enable-worktrees v2" ] &&
	[ "$(marker_sha "$R/dest/enable-worktrees")" = "NEWSHAB11" ]; then
	ok "forfeited skill (now in clone): marked stale copy refreshed like any other"
else
	no "forfeited skill (now in clone): marked stale copy refreshed like any other"
fi
if [ "$(cat "$R/dest/session-learnings/SKILL.md")" = "USER FORK session-learnings" ] &&
	[ ! -f "$R/dest/session-learnings/.powbox-seeded" ]; then
	ok "forfeited skill (now in clone): user-adopted copy still never touched"
else
	no "forfeited skill (now in clone): user-adopted copy still never touched"
fi

# ================================================================================
# Test 11: seed_skill wrong-type collision — the shared primitive must replace a
#          destination of ANY type (dir, file, or symlink) uniformly. This is the
#          path exercised by `update-skills-incontainer.sh --adopt-all` when a skill
#          dest is a file/symlink, not the sync's own path (which only reaches
#          seed_skill for an absent or a marked-DIRECTORY target). Regression guard
#          for the backup-target fix: a pre-created backup DIRECTORY made
#          `mv -T <file> <backup-dir>` fail with EISDIR, silently skipping the swap.
# ================================================================================
seed_skill_wrongtype_case() (
	# Subshell: source the seed lib and exercise seed_skill directly, isolated from
	# the parent's state. shellcheck can't follow the runtime-resolved lib path.
	# shellcheck disable=SC1090
	. "$SEED_LIB"
	R="$WORK_ROOT/t11"
	mkdir -p "$R/src" "$R/dest"
	printf 'NEW\n' >"$R/src/SKILL.md"

	# (a) dest is a SYMLINK (dangling) — the classic wrong-type collision.
	ln -s /nonexistent/target "$R/dest/symlinked"
	seed_skill "$R/src" "$R/dest/symlinked" "epoch=1
commit=x" || return 1
	[ -d "$R/dest/symlinked" ] && [ ! -L "$R/dest/symlinked" ] || return 1
	[ "$(cat "$R/dest/symlinked/SKILL.md")" = "NEW" ] || return 1
	[ -f "$R/dest/symlinked/.powbox-seeded" ] || return 1

	# (b) dest is a plain FILE — also a non-directory collision.
	printf 'stale file\n' >"$R/dest/filed"
	seed_skill "$R/src" "$R/dest/filed" "epoch=1
commit=x" || return 1
	[ -d "$R/dest/filed" ] && [ "$(cat "$R/dest/filed/SKILL.md")" = "NEW" ] || return 1

	# No stray temp/backup siblings leak into the dest dir.
	leaked="$(find "$R/dest" -maxdepth 1 \( -name '.*.tmp.*' -o -name '.*.old.*' \) 2>/dev/null)"
	[ -z "$leaked" ] || return 1
)
if seed_skill_wrongtype_case; then
	ok "seed_skill replaces a wrong-type dest (symlink, file) with the staged skill dir"
else
	no "seed_skill replaces a wrong-type dest (symlink, file) with the staged skill dir"
fi

echo
echo "sync-codex-skills tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
