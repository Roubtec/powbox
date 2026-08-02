#!/usr/bin/env bash
# Unit tests for the `.powbox-seeded` marker's UPSTREAM SOURCE line — the
# `source=<owner>/<repo>#<repo-relative-path>` field that answers "I found a
# defect in this seeded skill; where do I fix it?" in one `cat`.
#
# Covers both marker PRODUCERS that run against a real source tree:
#   - docker/shared/seed-skills.sh        (seed_skills / seed_workflows, the
#                                          entrypoint hooks' seeding path), and
#   - docker/shared/update-skills-incontainer.sh (process_items, the
#                                          agent-update-skills refresh worker),
# plus the BACKWARD-COMPATIBILITY contract every marker CONSUMER must honor:
# markers are parsed by key, never by line number or line count, so the two-line
# markers older images wrote still classify and refresh correctly.
#
# (The third producer, docker/shared/sync-codex-skills.sh, is covered by
# scripts/test-sync-codex-skills.sh.)
#
# Runs directly against the repo copies — no image build, no Docker daemon, and
# nothing outside a private mktemp tree is read or written. In particular the
# worker is SOURCED with $0 != its own path so its run_all guard stays false and
# the live container's config volumes are never touched.
#
# Usage: scripts/test-seed-marker-source.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED_LIB="$SCRIPT_DIR/../docker/shared/seed-skills.sh"
WORKER="$SCRIPT_DIR/../docker/shared/update-skills-incontainer.sh"

for f in "$SEED_LIB" "$WORKER"; do
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

# check <description> <test-command...> — run the command, record pass/fail.
check() {
	local desc="$1"
	shift
	if "$@"; then ok "$desc"; else no "$desc"; fi
}

# has_line <file> <exact-line> — the marker is key=value lines; assert one is present.
has_line() {
	grep -qxF "$2" "$1" 2>/dev/null
}

# make_skill <dir> <body>
make_skill() {
	mkdir -p "$1"
	printf '%s\n' "$2" >"$1/SKILL.md"
}

# make_meta <dir> <epoch> <commit> — a baked seed meta dir.
make_meta() {
	mkdir -p "$1"
	printf '%s\n' "$2" >"$1/build-epoch"
	printf '%s\n' "$3" >"$1/build-commit"
}

# seed_lib_case <fn> — run <fn> in a subshell that has sourced the seed library,
# isolated from the parent's shell state. shellcheck cannot follow the runtime path.
seed_lib_case() {
	(
		# shellcheck disable=SC1090
		. "$SEED_LIB"
		"$@"
	)
}

# ================================================================================
# Test 1: seed_source_ref joins a source root and an item name, and stays SILENT
#         for an unknown source (empty or the `-` placeholder) so the marker omits
#         the line rather than recording a misleading guess.
# ================================================================================
t1() {
	[ "$(seed_source_ref 'Roubtec/agent-skills#codex/dev-skills/skills' 'address-review')" \
		= 'Roubtec/agent-skills#codex/dev-skills/skills/address-review' ] || return 1
	# A trailing slash on the root must not double up.
	[ "$(seed_source_ref 'Owner/repo#a/b/' 'x')" = 'Owner/repo#a/b/x' ] || return 1
	[ -z "$(seed_source_ref '' 'x')" ] || return 1
	[ -z "$(seed_source_ref '-' 'x')" ] || return 1
	[ -z "$(seed_source_ref 'Owner/repo#a' '')" ] || return 1
}
check "seed_source_ref joins root+name and is silent for an unknown source" seed_lib_case t1

# ================================================================================
# Test 2: seed_marker_content is backward compatible — WITHOUT a source ref it
#         emits exactly the historical two lines (no empty `source=`), and WITH one
#         it appends a third.
# ================================================================================
t2() {
	make_meta "$WORK_ROOT/meta" 12345 abc123
	local two three
	two="$(seed_marker_content "$WORK_ROOT/meta")"
	[ "$two" = "epoch=12345
commit=abc123" ] || return 1
	three="$(seed_marker_content "$WORK_ROOT/meta" 'Owner/repo#dir/item')"
	[ "$three" = "epoch=12345
commit=abc123
source=Owner/repo#dir/item" ] || return 1
	# Missing metadata still degrades to placeholders, with the source intact.
	[ "$(seed_marker_content "$WORK_ROOT/nosuchmeta" 'Owner/repo#dir/item')" = "epoch=0
commit=unknown
source=Owner/repo#dir/item" ] || return 1
}
check "seed_marker_content: 2 lines without a source ref, +source= with one" seed_lib_case t2

# ================================================================================
# Test 3: seed_skills stamps each placed skill with ITS OWN upstream path.
# ================================================================================
t3() {
	local root="$WORK_ROOT/t3"
	make_meta "$root/meta" 42 deadbeef
	make_skill "$root/src/alpha" "alpha v1"
	make_skill "$root/src/beta" "beta v1"
	seed_skills "$root/src" "$root/dest" noclobber "$root/meta" \
		"$POWBOX_SEED_SOURCE_CODEX_SKILLS" || return 1
	has_line "$root/dest/alpha/.powbox-seeded" \
		'source=Roubtec/agent-skills#codex/dev-skills/skills/alpha' || return 1
	has_line "$root/dest/beta/.powbox-seeded" \
		'source=Roubtec/agent-skills#codex/dev-skills/skills/beta' || return 1
	# The pre-existing provenance lines are still there and unchanged.
	has_line "$root/dest/alpha/.powbox-seeded" 'epoch=42' || return 1
	has_line "$root/dest/alpha/.powbox-seeded" 'commit=deadbeef' || return 1
}
check "seed_skills stamps a per-skill source= line (repo#path/<name>)" seed_lib_case t3

# ================================================================================
# Test 4: seed_workflows stamps the SIDECAR marker with the workflow's own
#         upstream path (the workflows live under plugins/dev-skills/workflows).
# ================================================================================
t4() {
	local root="$WORK_ROOT/t4"
	make_meta "$root/meta" 7 c0ffee
	mkdir -p "$root/src"
	printf '// wf\n' >"$root/src/wf-address-tasks.js"
	seed_workflows "$root/src" "$root/dest" noclobber "$root/meta" \
		"$POWBOX_SEED_SOURCE_CLAUDE_WORKFLOWS" || return 1
	local sidecar="$root/dest/.wf-address-tasks.js.powbox-seeded"
	[ -f "$sidecar" ] || return 1
	has_line "$sidecar" \
		'source=Roubtec/agent-skills#plugins/dev-skills/workflows/wf-address-tasks.js' || return 1
	seed_workflow_is_marked "$root/dest/wf-address-tasks.js" || return 1
}
check "seed_workflows stamps the sidecar marker with the workflow's source=" seed_lib_case t4

# ================================================================================
# Test 5: omitting the source root keeps the OLD marker shape exactly (no stray
#         `source=` line), so a call site with no upstream to name degrades
#         cleanly rather than writing a wrong one.
# ================================================================================
t5() {
	local root="$WORK_ROOT/t5"
	make_meta "$root/meta" 9 abc
	make_skill "$root/src/alpha" "alpha v1"
	seed_skills "$root/src" "$root/dest" noclobber "$root/meta" || return 1
	seed_is_marked "$root/dest/alpha" || return 1
	! grep -q '^source=' "$root/dest/alpha/.powbox-seeded" || return 1
	[ "$(wc -l <"$root/dest/alpha/.powbox-seeded")" -le 2 ] || return 1
}
check "seed_skills without a source root writes the legacy marker shape" seed_lib_case t5

# --- The refresh worker (update-skills-incontainer.sh) ---------------------------
# process_items is invoked in a child bash that SOURCES the worker. $0 is
# deliberately NOT the worker path, so the worker's `BASH_SOURCE[0] == $0` guard
# stays false and run_all (which targets the real /home/node config volumes) never
# runs.
# run_worker <mode> <adopt_all> <prune> <kind> <src> <dest> <meta> <source_root>
# -> the worker's TAB-separated records on stdout.
run_worker() {
	local mode="$1" adopt="$2" prune="$3"
	shift 3
	POWBOX_SEED_SKILLS_LIB="$SEED_LIB" \
		POWBOX_SEED_MODE="$mode" \
		POWBOX_ADOPT_ALL="$adopt" \
		POWBOX_PRUNE="$prune" \
		POWBOX_WORKER="$WORKER" \
		bash -c '
			# shellcheck disable=SC1090
			. "$POWBOX_WORKER"
			process_items testagent "$1" "$2" "$3" "$4" "$5" || true
		' _ "$@"
}

# ================================================================================
# Test 6: the worker refreshes a LEGACY two-line marker (written by an older
#         image) and rewrites it with the upstream source line. This is the
#         key-based-parsing contract: ownership hinges on the marker's PRESENCE,
#         never on its line count.
# ================================================================================
root="$WORK_ROOT/t6"
make_meta "$root/meta" 55 newcommit
make_skill "$root/src/alpha" "alpha v2"
make_skill "$root/dest/alpha" "alpha STALE"
printf 'epoch=1\ncommit=old\n' >"$root/dest/alpha/.powbox-seeded"
out="$(run_worker apply false false skill "$root/src" "$root/dest" "$root/meta" \
	'Roubtec/agent-skills#codex/dev-skills/skills')"
if printf '%s\n' "$out" | grep -q '^refreshed	testagent	skill	alpha$' &&
	[ "$(cat "$root/dest/alpha/SKILL.md")" = "alpha v2" ] &&
	has_line "$root/dest/alpha/.powbox-seeded" \
		'source=Roubtec/agent-skills#codex/dev-skills/skills/alpha' &&
	has_line "$root/dest/alpha/.powbox-seeded" 'commit=newcommit'; then
	ok "worker refreshes a legacy 2-line marker and stamps source="
else
	no "worker refreshes a legacy 2-line marker and stamps source="
fi

# ================================================================================
# Test 7: a marker that ALREADY carries the new source line is still just a marker
#         — ownership, refresh, and the unmarked-collision conflict are unchanged
#         by the extra line.
# ================================================================================
root="$WORK_ROOT/t7"
make_meta "$root/meta" 56 c7
make_skill "$root/src/alpha" "alpha v3"
make_skill "$root/src/gamma" "gamma v1"
make_skill "$root/dest/alpha" "alpha STALE"
printf 'epoch=1\ncommit=old\nsource=Roubtec/agent-skills#codex/dev-skills/skills/alpha\n' \
	>"$root/dest/alpha/.powbox-seeded"
# gamma exists on the volume WITHOUT a marker -> user-owned -> conflict, untouched.
make_skill "$root/dest/gamma" "USER FORK gamma"
out="$(run_worker apply false false skill "$root/src" "$root/dest" "$root/meta" \
	'Roubtec/agent-skills#codex/dev-skills/skills')"
if printf '%s\n' "$out" | grep -q '^refreshed	testagent	skill	alpha$' &&
	printf '%s\n' "$out" | grep -q '^conflict	testagent	skill	gamma$' &&
	[ "$(cat "$root/dest/alpha/SKILL.md")" = "alpha v3" ] &&
	[ "$(cat "$root/dest/gamma/SKILL.md")" = "USER FORK gamma" ] &&
	[ ! -f "$root/dest/gamma/.powbox-seeded" ]; then
	ok "source-bearing marker: refresh/conflict classification unchanged"
else
	no "source-bearing marker: refresh/conflict classification unchanged"
fi

# ================================================================================
# Test 8: orphan classification + prune still work for BOTH marker shapes (legacy
#         two-line and source-bearing), including with an absent baked source dir
#         — the whole-kind-removed case the forfeit relies on.
# ================================================================================
root="$WORK_ROOT/t8"
make_meta "$root/meta" 57 c8
make_skill "$root/dest/legacy" "legacy seed"
printf 'epoch=1\ncommit=old\n' >"$root/dest/legacy/.powbox-seeded"
make_skill "$root/dest/modern" "modern seed"
printf 'epoch=1\ncommit=old\nsource=Roubtec/agent-skills#plugins/dev-skills/skills/modern\n' \
	>"$root/dest/modern/.powbox-seeded"
make_skill "$root/dest/mine" "user skill"
out="$(run_worker classify false false skill "$root/src-absent" "$root/dest" "$root/meta" \
	'Roubtec/agent-skills#plugins/dev-skills/skills')"
if printf '%s\n' "$out" | grep -q '^orphan	testagent	skill	legacy$' &&
	printf '%s\n' "$out" | grep -q '^orphan	testagent	skill	modern$' &&
	! printf '%s\n' "$out" | grep -q 'skill	mine$'; then
	ok "orphan sweep classifies both marker shapes, ignores unmarked user skills"
else
	no "orphan sweep classifies both marker shapes, ignores unmarked user skills"
fi
out="$(run_worker apply false true skill "$root/src-absent" "$root/dest" "$root/meta" \
	'Roubtec/agent-skills#plugins/dev-skills/skills')"
if [ ! -e "$root/dest/legacy" ] && [ ! -e "$root/dest/modern" ] &&
	[ -f "$root/dest/mine/SKILL.md" ]; then
	ok "--prune retires both marker shapes and keeps the user skill"
else
	no "--prune retires both marker shapes and keeps the user skill"
fi

# ================================================================================
# Test 9: the worker's real driver table names an upstream source root for every
#         row, and each is a `<owner>/<repo>#<path>` — a row silently missing one
#         would ship markers with no "where do I fix it" answer.
# ================================================================================
rows="$(POWBOX_SEED_SKILLS_LIB="$SEED_LIB" POWBOX_WORKER="$WORKER" bash -c '
	# shellcheck disable=SC1090
	. "$POWBOX_WORKER"
	seed_targets')"
bad=0
while read -r _agent _kind _src _dest _meta source_root; do
	[ -n "$_agent" ] || continue
	case "$source_root" in
	*/*'#'*) ;;
	*) bad=1 ;;
	esac
done <<<"$rows"
if [ "$bad" -eq 0 ] && [ "$(printf '%s\n' "$rows" | grep -c .)" -eq 3 ]; then
	ok "every seed_targets row carries an <owner>/<repo>#<path> source root"
else
	no "every seed_targets row carries an <owner>/<repo>#<path> source root"
fi

# ================================================================================
# Test 10: BUILD-SKEW guard — `commands/update-skills.*` bind-mounts the worker
#          from the CHECKOUT but takes seed-skills.sh from the IMAGE, so a newer
#          worker can run against an older baked library with no source= support.
#          It must degrade to source-less markers, not abort under `set -u`.
#
#          The legacy library is emulated faithfully by sourcing the real one and
#          then removing exactly what a pre-source= image lacked.
# ================================================================================
LEGACY_LIB="$WORK_ROOT/legacy-seed-skills.sh"
cat >"$LEGACY_LIB" <<EOF
# Emulates the pre-\`source=\` baked seed library.
. "$SEED_LIB"
unset -f seed_source_ref
unset POWBOX_SEED_SOURCE_REPO POWBOX_SEED_SOURCE_CODEX_SKILLS
unset POWBOX_SEED_SOURCE_CLAUDE_SKILLS POWBOX_SEED_SOURCE_CLAUDE_WORKFLOWS
seed_marker_content() {
	local meta="\$1" epoch commit
	epoch="\$(cat "\$meta/build-epoch" 2>/dev/null || echo 0)"
	commit="\$(cat "\$meta/build-commit" 2>/dev/null || echo unknown)"
	printf 'epoch=%s\ncommit=%s\n' "\$epoch" "\$commit"
}
EOF
root="$WORK_ROOT/t10"
make_meta "$root/meta" 58 c10
make_skill "$root/src/alpha" "alpha v9"
make_skill "$root/dest/alpha" "alpha STALE"
printf 'epoch=1\ncommit=old\n' >"$root/dest/alpha/.powbox-seeded"
if out="$(POWBOX_SEED_SKILLS_LIB="$LEGACY_LIB" \
	POWBOX_SEED_MODE=apply POWBOX_ADOPT_ALL=false POWBOX_PRUNE=false \
	POWBOX_WORKER="$WORKER" bash -c '
		# shellcheck disable=SC1090
		. "$POWBOX_WORKER"
		process_items testagent "$1" "$2" "$3" "$4" "$5"
	' _ skill "$root/src" "$root/dest" "$root/meta" \
	'Roubtec/agent-skills#codex/dev-skills/skills' 2>&1)" &&
	printf '%s\n' "$out" | grep -q '^refreshed	testagent	skill	alpha$' &&
	[ "$(cat "$root/dest/alpha/SKILL.md")" = "alpha v9" ] &&
	! grep -q '^source=' "$root/dest/alpha/.powbox-seeded"; then
	ok "worker against a pre-source= baked library degrades instead of aborting"
else
	no "worker against a pre-source= baked library degrades instead of aborting"
fi
# …and the driver table itself must still expand: it interpolates the source-root
# constants, so under `set -u` an older library without them would abort the run
# before a single item is classified.
if legacy_rows="$(POWBOX_SEED_SKILLS_LIB="$LEGACY_LIB" POWBOX_WORKER="$WORKER" bash -c '
	# shellcheck disable=SC1090
	. "$POWBOX_WORKER"
	seed_targets' 2>&1)" &&
	[ "$(printf '%s\n' "$legacy_rows" | grep -c .)" -eq 3 ]; then
	ok "seed_targets still expands against a pre-source= baked library"
else
	no "seed_targets still expands against a pre-source= baked library"
fi

printf '\nseed marker source tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
