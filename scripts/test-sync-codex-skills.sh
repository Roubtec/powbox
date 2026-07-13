#!/usr/bin/env bash
# Unit tests for docker/shared/sync-codex-skills.sh — the start-time refresh that
# brings Codex's copies of the 8 shared dev-skills to the same agent-skills commit
# the Claude plugin serves, synced LOCALLY from the plugin's marketplace clone.
#
# Focus: the marker-gated overwrite (only powbox-owned copies), the SHA-gated
# no-op (unchanged palette writes nothing), user-adopted / powbox-specific skills
# left untouched, absent-skill placement, and the cold-clone skip.
#
# Runs directly against the repo copies of sync-codex-skills.sh + seed-skills.sh —
# no image build needed. The agent-skills SHA is injected via
# POWBOX_CODEX_SKILL_CLONE_SHA so no git repo is required. Requires only bash.
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
		POWBOX_CLAUDE_PLUGIN_LOCK_FILE="$dest/.claude-plugin.lock" \
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
#         content is updated, and the marker records the synced sha + source.
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
	grep -q '^source=plugin-clone$' "$R/dest/a/.powbox-seeded"; then
	ok "marked stale copy refreshed to clone content + sha, source=plugin-clone"
else
	no "marked stale copy refreshed to clone content + sha, source=plugin-clone"
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
# Test 4: a powbox-specific Codex skill (NOT in the clone) is never a candidate.
# ================================================================================
R="$(new_case t4)"
make_skill "$R/dest/session-learnings" "powbox-specific v1"
printf 'epoch=1\ncommit=baked\n' >"$R/dest/session-learnings/.powbox-seeded"
before="$(stat -c %Y "$R/dest/session-learnings/SKILL.md")"
sleep 1.1
run_sync "$R/clone" "$R/dest" "NEWSHA333"
after="$(stat -c %Y "$R/dest/session-learnings/SKILL.md")"
if [ "$before" = "$after" ] && [ "$(cat "$R/dest/session-learnings/SKILL.md")" = "powbox-specific v1" ]; then
	ok "powbox-specific skill (absent from clone) never touched"
else
	no "powbox-specific skill (absent from clone) never touched"
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
	POWBOX_CLAUDE_PLUGIN_LOCK_FILE="$R/dest/.claude-plugin.lock" \
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
		POWBOX_CLAUDE_PLUGIN_LOCK_FILE="$CLAUDE_LOCK" \
		POWBOX_CLAUDE_PLUGIN_LOCK_WAIT=1 \
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
leaked="$(find "$R/dest" -maxdepth 1 -name '.a.tmp.*' -o -maxdepth 1 -name '.a.old.*' 2>/dev/null)"
if [ -f "$R/dest/a/SKILL.md" ] && [ -f "$R/dest/a/.powbox-seeded" ] &&
	[ "$(cat "$R/dest/a/SKILL.md")" = "shared skill a v1" ] && [ -z "$leaked" ]; then
	ok "atomic replace leaves a complete dir and no stray temp/backup siblings"
else
	no "atomic replace leaves a complete dir and no stray temp/backup siblings"
fi

echo
echo "sync-codex-skills tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
