#!/usr/bin/env bash
# Shared skill/workflow-seeding helper, baked to /usr/local/bin/seed-skills.sh.
#
# Single source of truth for copying image-baked skills (folders) and Claude
# dynamic workflows (flat `.js` files) onto a persistent config volume. Sourced
# (not executed) by:
#   - the agent entrypoint hooks (docker/shared/entrypoint-{claude,codex}-hook.sh)
#     in `noclobber` mode — seed only skills/workflows whose destination is
#     absent, and
#   - the update-skills worker (docker/shared/update-skills-incontainer.sh), which uses
#     the primitives below to force-refresh, resolve conflicts, and prune.
#
# Ownership marker: every skill/workflow this code PLACES gets a hidden
# `.powbox-seeded` marker recording the image build epoch and the powbox commit
# that built the image. A skill is a folder, so its marker is the in-folder file
# `<skill>/.powbox-seeded`; a workflow is a single file, which has no "inside",
# so its marker is a sibling sidecar `<dir>/.<workflow>.powbox-seeded`. Either
# way the marker means "powbox owns this copy": the refresher may overwrite or
# prune a marked item, while one WITHOUT the marker is treated as user-authored
# and is never touched. To adopt a seeded item as your own, delete its marker
# (or rename it).
#
# This file is sourced, so it defines functions only and must not `set -e` or run
# side effects at load time.

POWBOX_SEED_MARKER=".powbox-seeded"

# seed_meta_dir <src_dir> -> the seed dir that holds build-epoch/build-commit.
# The baked layout is <seed>/skills and <seed>/workflows, so the meta dir is the
# parent of whichever source dir was passed.
seed_meta_dir() {
	dirname "$1"
}

# seed_marker_content <meta_dir> -> prints the marker body (epoch + commit lines).
# Missing metadata degrades to sane placeholders so seeding never fails on it.
seed_marker_content() {
	local meta="$1" epoch commit
	epoch="$(cat "$meta/build-epoch" 2>/dev/null || echo 0)"
	commit="$(cat "$meta/build-commit" 2>/dev/null || echo unknown)"
	[ -n "$epoch" ] || epoch=0
	[ -n "$commit" ] || commit=unknown
	printf 'epoch=%s\ncommit=%s\n' "$epoch" "$commit"
}

# seed_is_marked <dest_skill_dir> -> 0 when the ownership marker is present.
seed_is_marked() {
	[ -f "$1/$POWBOX_SEED_MARKER" ]
}

# seed_skill_names <dir> -> prints the immediate sub-directory names (one per line).
# Used to enumerate both baked skills and on-volume skills. Quiet when empty.
seed_skill_names() {
	local dir="$1" d
	[ -d "$dir" ] || return 0
	for d in "$dir"/*/; do
		[ -d "$d" ] || continue
		basename "$d"
	done
}

# seed_skill <src_skill_dir> <dest_skill_dir> <marker_body>
# Copy one skill (cp -a) into a sibling temp dir, stamp the ownership marker, then
# atomically swap it into place so a concurrently-invoking agent never observes a
# half-written skill. Overwrites <dest_skill_dir> if it exists. Returns nonzero on
# failure, leaving any existing destination untouched.
seed_skill() {
	local src="${1%/}" dest="$2" marker="$3"
	local parent name tmp
	parent="$(dirname "$dest")"
	name="$(basename "$dest")"
	mkdir -p "$parent"
	tmp="$(mktemp -d "$parent/.${name}.tmp.XXXXXX")" || return 1
	if cp -a "$src"/. "$tmp"/ && printf '%s' "$marker" >"$tmp/$POWBOX_SEED_MARKER"; then
		# mv is an atomic rename within the same volume, and an agent re-reads
		# SKILL.md at invoke time, so it never observes a half-written skill. The
		# window between rm and mv is tiny but the config volumes are shared, so a
		# concurrent seed could recreate $dest in it; -T (--no-target-directory)
		# makes mv replace $dest rather than nest $tmp inside a reappeared
		# directory, failing loudly into the cleanup below instead of returning a
		# false success with an orphaned .${name}.tmp.* tree.
		rm -rf "$dest"
		if mv -T "$tmp" "$dest"; then
			return 0
		fi
	fi
	rm -rf "$tmp"
	return 1
}

# seed_skills <src_skills_dir> <dest_skills_dir> <noclobber|refresh> [<meta_dir>]
# Convenience loop used by the entrypoint hooks.
#   noclobber: place only skills whose destination is ABSENT (preserves any existing
#              entry — directory, file, or symlink — marked or not).
#   refresh:   place absent skills and overwrite directories that carry our marker; an
#              unmarked directory, or any non-directory collision, is a conflict and is
#              left untouched (the update-skills worker is what surfaces and resolves
#              those).
# Returns nonzero if any copy failed.
seed_skills() {
	local src="$1" dest="$2" mode="$3" meta="${4:-}"
	[ -d "$src" ] || return 0
	[ -n "$meta" ] || meta="$(seed_meta_dir "$src")"
	local marker
	marker="$(seed_marker_content "$meta")"
	mkdir -p "$dest"
	local rc=0 name target
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		target="$dest/$name"
		# Any existing entry blocks a blind overwrite — seed_skill rm -rf's the
		# destination before installing, so we must only reach it for an absent
		# target or a marked directory. -e misses dangling symlinks, so test -L too.
		if [ -e "$target" ] || [ -L "$target" ]; then
			case "$mode" in
			noclobber) continue ;;
			# Only a directory we placed (carries the marker) may be refreshed; an
			# unmarked directory or any non-directory collision is user-owned.
			refresh) { [ -d "$target" ] && seed_is_marked "$target"; } || continue ;;
			esac
		fi
		seed_skill "$src/$name" "$target" "$marker" || rc=1
	done < <(seed_skill_names "$src")
	return "$rc"
}

# --- Workflows (flat `.js` files) ---------------------------------------------
# Claude dynamic workflows are single files, not folders, so the ownership marker
# can't live "inside" the item. Instead each seeded workflow gets a hidden sibling
# sidecar marker; everything else mirrors the skill helpers above, so a future
# refresh/prune worker can treat workflows exactly like skills.

# seed_workflow_marker_path <dest_workflow_file> -> its sidecar marker path.
# Hidden (leading dot) and suffixed with the marker name, so it is never matched
# by the `*.js` enumeration in seed_workflow_names. e.g.
#   .../workflows/foo.js -> .../workflows/.foo.js.powbox-seeded
seed_workflow_marker_path() {
	local dir name
	dir="$(dirname "$1")"
	name="$(basename "$1")"
	printf '%s/.%s%s' "$dir" "$name" "$POWBOX_SEED_MARKER"
}

# seed_workflow_is_marked <dest_workflow_file> -> 0 when its sidecar marker exists.
seed_workflow_is_marked() {
	[ -f "$(seed_workflow_marker_path "$1")" ]
}

# seed_workflow_names <dir> -> prints the `*.js` file names (one per line). The
# glob skips dotfiles, so sidecar markers never leak into the enumeration. Quiet
# when the dir is absent or holds no workflows.
seed_workflow_names() {
	local dir="$1" f
	[ -d "$dir" ] || return 0
	for f in "$dir"/*.js; do
		[ -e "$f" ] || continue
		basename "$f"
	done
}

# seed_workflow <src_workflow_file> <dest_workflow_file> <marker_body>
# Copy one workflow into a sibling temp file, then atomically rename it into
# place so a concurrently-invoking agent never reads a half-written `.js`. The
# sidecar marker is renamed into place only AFTER the workflow rename succeeds,
# so a marker never outlives its `.js`. Overwrites <dest_workflow_file> if it
# exists. Returns nonzero on failure, leaving any existing destination untouched.
seed_workflow() {
	local src="$1" dest="$2" marker="$3"
	local dir name tmp markerpath markertmp
	dir="$(dirname "$dest")"
	name="$(basename "$dest")"
	mkdir -p "$dir"
	markerpath="$(seed_workflow_marker_path "$dest")"
	tmp="$(mktemp "$dir/.${name}.tmp.XXXXXX")" || return 1
	markertmp="$(mktemp "$dir/.${name}.marker.XXXXXX")" || {
		rm -f "$tmp"
		return 1
	}
	# Publish the workflow first, THEN stamp its sidecar marker, so a marker can
	# never outlive its `.js`. An orphan marker (marker, no file) is the dangerous
	# direction: a later user-created <name>.js would be misread as powbox-owned
	# and refreshed/pruned. -T makes mv replace $dest rather than nest the temp
	# inside a directory collision (a wrong-type --adopt-all target), failing
	# loudly into the cleanup below instead of a false success — mirroring
	# seed_skill. If the file lands but its marker rename fails, the workflow is
	# left unmarked (treated as user-authored): unmanaged, but never destructive.
	if cp "$src" "$tmp" && printf '%s' "$marker" >"$markertmp"; then
		if mv -fT "$tmp" "$dest" && mv -fT "$markertmp" "$markerpath"; then
			return 0
		fi
	fi
	rm -f "$tmp" "$markertmp"
	return 1
}

# seed_workflows <src_dir> <dest_dir> <noclobber|refresh> [<meta_dir>]
# Workflow analogue of seed_skills, with identical mode semantics:
#   noclobber: place only workflows whose destination is ABSENT (preserves any
#              existing entry — file, dir, or symlink — marked or not).
#   refresh:   place absent workflows and overwrite plain files that carry our
#              sidecar marker; an unmarked file, or any non-file collision, is a
#              conflict and is left untouched.
# Returns nonzero if any copy failed.
seed_workflows() {
	local src="$1" dest="$2" mode="$3" meta="${4:-}"
	[ -d "$src" ] || return 0
	[ -n "$meta" ] || meta="$(seed_meta_dir "$src")"
	local marker
	marker="$(seed_marker_content "$meta")"
	mkdir -p "$dest"
	local rc=0 name target
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		target="$dest/$name"
		# Any existing entry blocks a blind overwrite — seed_workflow renames over
		# the destination, so we must only reach it for an absent target or a marked
		# plain file. -e misses dangling symlinks, so test -L too.
		if [ -e "$target" ] || [ -L "$target" ]; then
			case "$mode" in
			noclobber) continue ;;
			# Only a plain file we placed (carries the sidecar marker) may be
			# refreshed; an unmarked file or any non-file collision is user-owned.
			refresh) { [ -f "$target" ] && seed_workflow_is_marked "$target"; } || continue ;;
			esac
		fi
		seed_workflow "$src/$name" "$target" "$marker" || rc=1
	done < <(seed_workflow_names "$src")
	return "$rc"
}
