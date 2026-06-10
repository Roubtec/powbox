#!/usr/bin/env bash
# Runs INSIDE a throwaway powbox-agent container (see update-skills.sh /
# update-skills.ps1, which bind-mount this file and the config volumes).
#
# Force-refreshes the image-baked skills (folders) and Claude dynamic workflows
# (flat `.js` files) onto the persistent agent-config volumes, deliberately
# overriding the startup seeding's no-clobber. The copy logic and the
# .powbox-seeded ownership marker live in the shared /usr/local/bin/seed-skills.sh
# (baked into the image, also sourced by the entrypoint hooks) so the two never
# drift. This worker adds the refresh-only concerns: classifying each item,
# resolving unmarked name-collisions, and pruning obsolete seeds.
#
# Ownership marker: the entrypoint seeds and this worker stamp every item they
# place with a .powbox-seeded marker (a skill carries it in-folder as
# <skill>/.powbox-seeded; a workflow has no "inside", so it carries a sibling
# sidecar <dir>/.<workflow>.powbox-seeded). The marker means "powbox owns this
# copy":
#   - marked  -> safe to refresh (overwrite) and to prune when no longer baked
#   - unmarked-> user-authored or hand-forked; never touched silently
#
# Output protocol: one TAB-separated record per line on STDOUT, consumed by the
# launcher which renders all human-facing text. Warnings go to STDERR.
#   would-seed|would-refresh|conflict|orphan   (classify mode: no changes)
#   seeded|refreshed|adopted|pruned|conflict|orphan|error   (apply mode)
# where each record is: <verb> <TAB> <agent> <TAB> <kind> <TAB> <name>, and
# <kind> is `skill` or `workflow` so the launcher can name the item correctly.
#
# Modes (env):
#   POWBOX_SEED_MODE  classify | apply           (default apply)
#   POWBOX_ADOPT_ALL  true | false               (apply: overwrite+adopt unmarked
#                                                  name-collisions; default false)
#   POWBOX_PRUNE      true | false               (apply: delete orphaned seeds;
#                                                  default false)
set -euo pipefail

# shellcheck source=docker/shared/seed-skills.sh
. /usr/local/bin/seed-skills.sh

MODE="${POWBOX_SEED_MODE:-apply}"
ADOPT_ALL="${POWBOX_ADOPT_ALL:-false}"
PRUNE="${POWBOX_PRUNE:-false}"

emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# --- Kind dispatch ------------------------------------------------------------
# Skills are folders and workflows are flat files, but the classify/seed/prune
# flow is identical; these thin wrappers select the right seed-skills.sh
# primitive so process_items below is written once for both kinds.

# item_names <kind> <dir> -> the baked/on-volume item names under <dir>.
item_names() {
	case "$1" in
	skill) seed_skill_names "$2" ;;
	workflow) seed_workflow_names "$2" ;;
	esac
}

# item_seed <kind> <src> <dest> <marker> -> place one item (atomic, stamps marker).
item_seed() {
	case "$1" in
	skill) seed_skill "$2" "$3" "$4" ;;
	workflow) seed_workflow "$2" "$3" "$4" ;;
	esac
}

# item_is_marked <kind> <target> -> 0 when the on-volume item carries our marker.
item_is_marked() {
	case "$1" in
	skill) seed_is_marked "$2" ;;
	workflow) seed_workflow_is_marked "$2" ;;
	esac
}

# item_is_refreshable <kind> <target> -> 0 when an existing target is a marked
# item OF THE RIGHT TYPE (a folder for skills, a plain file for workflows). Any
# other collision (unmarked, or wrong type) is user-owned and never overwritten.
item_is_refreshable() {
	case "$1" in
	skill) [ -d "$2" ] && seed_is_marked "$2" ;;
	workflow) [ -f "$2" ] && seed_workflow_is_marked "$2" ;;
	esac
}

# item_prune <kind> <target> -> remove the item and its marker. For a skill the
# marker lives inside the folder; for a workflow the sidecar must go too.
item_prune() {
	case "$1" in
	skill) rm -rf "$2" ;;
	workflow) rm -f "$2" "$(seed_workflow_marker_path "$2")" ;;
	esac
}

# Classify (and, in apply mode, act on) one agent's baked items of one kind
# against its on-volume dir. Returns nonzero if any copy/delete failed.
process_items() {
	local agent="$1" kind="$2" src="$3" dest="$4" meta="$5"
	[ -d "$src" ] || return 0

	local marker rc=0 name target
	marker="$(seed_marker_content "$meta")"
	[ "$MODE" = apply ] && mkdir -p "$dest"

	# Set of baked item names, for the orphan membership test below.
	local -A baked=()
	while IFS= read -r name; do
		[ -n "$name" ] && baked["$name"]=1
	done < <(item_names "$kind" "$src")

	# Classify each baked item: absent -> seed, marked item of the right type ->
	# refresh, unmarked or wrong-type collision -> conflict (adopt only when
	# explicitly allowed).
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		target="$dest/$name"
		# Truly absent only when no entry of any type exists (-e misses dangling
		# symlinks, so test -L too). A regular file or symlink at a baked item's
		# name is a user-owned collision, handled by the conflict branch below.
		if [ ! -e "$target" ] && [ ! -L "$target" ]; then
			if [ "$MODE" = classify ]; then
				emit would-seed "$agent" "$kind" "$name"
			elif item_seed "$kind" "$src/$name" "$target" "$marker"; then
				emit seeded "$agent" "$kind" "$name"
			else
				emit error "$agent" "$kind" "$name"
				rc=1
			fi
		elif item_is_refreshable "$kind" "$target"; then
			if [ "$MODE" = classify ]; then
				emit would-refresh "$agent" "$kind" "$name"
			elif item_seed "$kind" "$src/$name" "$target" "$marker"; then
				emit refreshed "$agent" "$kind" "$name"
			else
				emit error "$agent" "$kind" "$name"
				rc=1
			fi
		else
			# Unmarked item, wrong-type entry, or symlink colliding with a baked
			# name: ambiguous (legacy seed vs. user fork). Never overwrite silently.
			if [ "$MODE" = apply ] && [ "$ADOPT_ALL" = true ]; then
				if item_seed "$kind" "$src/$name" "$target" "$marker"; then
					emit adopted "$agent" "$kind" "$name"
				else
					emit error "$agent" "$kind" "$name"
					rc=1
				fi
			else
				emit conflict "$agent" "$kind" "$name"
			fi
		fi
	done < <(item_names "$kind" "$src")

	# Orphans: items we previously seeded (marked) that are no longer baked.
	# Unmarked on-volume items are user-authored and are left entirely alone.
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ -n "${baked[$name]:-}" ] && continue
		item_is_marked "$kind" "$dest/$name" || continue
		if [ "$MODE" = apply ] && [ "$PRUNE" = true ]; then
			if item_prune "$kind" "${dest:?}/${name:?}"; then
				emit pruned "$agent" "$kind" "$name"
			else
				emit error "$agent" "$kind" "$name"
				rc=1
			fi
		else
			emit orphan "$agent" "$kind" "$name"
		fi
	done < <(item_names "$kind" "$dest")

	# Marker-only orphans (workflows only). A workflow's ownership marker is a
	# sibling sidecar, not an in-folder file, so a vanished `.js` can strand its
	# `.<name>.js.powbox-seeded`. seed_workflow stamps the marker only AFTER the
	# file lands, so this code never creates one — but a hand-deleted `.js` (or a
	# pre-fix volume) can, and the `*.js` enumeration above is blind to it. A
	# stale marker would later mis-flag a same-named user workflow as
	# powbox-owned, so sweep sidecars whose `.js` is gone and prune/report them.
	if [ "$kind" = workflow ]; then
		local markerfile mbase wf
		for markerfile in "$dest"/.*"$POWBOX_SEED_MARKER"; do
			[ -e "$markerfile" ] || continue
			mbase="$(basename "$markerfile")"
			wf="${mbase#.}"
			wf="${wf%"$POWBOX_SEED_MARKER"}"
			[ -n "$wf" ] || continue
			# A live workflow file is already handled by the loops above; act only
			# when the `.js` is truly absent (-e misses dangling symlinks, -L too).
			{ [ -e "$dest/$wf" ] || [ -L "$dest/$wf" ]; } && continue
			if [ "$MODE" = apply ] && [ "$PRUNE" = true ]; then
				if rm -f "$markerfile"; then
					emit pruned "$agent" "$kind" "$wf"
				else
					emit error "$agent" "$kind" "$wf"
					rc=1
				fi
			else
				emit orphan "$agent" "$kind" "$wf"
			fi
		done
	fi

	return "$rc"
}

# --- Driver -------------------------------------------------------------------
# agent | kind | baked source dir | on-volume destination dir | seed meta dir.
# Mirrors the entrypoint hooks: claude seeds skills into $CONFIG/skills and
# workflows into $CONFIG/workflows; codex seeds skills into $CONFIG/agents/skills
# (the ~/.agents symlink target) and has no workflow runtime.
seed_targets() {
	cat <<'EOF'
claude skill    /home/node/.agent-container/claude/skills    /home/node/.claude/skills       /home/node/.agent-container/claude
claude workflow /home/node/.agent-container/claude/workflows /home/node/.claude/workflows    /home/node/.agent-container/claude
codex  skill    /home/node/.agent-container/codex/skills     /home/node/.codex/agents/skills /home/node/.agent-container/codex
EOF
}

run_all() {
	local rc=0 agent kind src dest meta
	while read -r agent kind src dest meta; do
		[ -n "$agent" ] || continue
		process_items "$agent" "$kind" "$src" "$dest" "$meta" || rc=1
	done < <(seed_targets)
	return "$rc"
}

# Run main only when executed (the launchers do `bash …/update-skills-incontainer.sh`),
# never when sourced — so the helpers above can be unit-tested in isolation.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	run_all
	exit "$?"
fi
