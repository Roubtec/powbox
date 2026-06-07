#!/usr/bin/env bash
# Shared skill-seeding helper, baked to /usr/local/bin/seed-skills.sh.
#
# Single source of truth for copying image-baked skills onto a persistent config
# volume. Sourced (not executed) by:
#   - the agent entrypoint hooks (docker/shared/entrypoint-{claude,codex}-hook.sh)
#     in `noclobber` mode — seed only skills whose folder is absent, and
#   - the update-skills worker (docker/shared/update-skills-incontainer.sh), which uses
#     the primitives below to force-refresh, resolve conflicts, and prune.
#
# Ownership marker: every skill this code PLACES gets a hidden
# `<skill>/.powbox-seeded` file recording the image build epoch and the powbox
# commit that built the image. The marker means "powbox owns this copy": the
# refresher may overwrite or prune a marked skill, while a skill WITHOUT the
# marker is treated as user-authored and is never touched. To adopt a seeded
# skill as your own, delete its marker (or rename the folder).
#
# This file is sourced, so it defines functions only and must not `set -e` or run
# side effects at load time.

POWBOX_SEED_MARKER=".powbox-seeded"

# seed_meta_dir <src_skills_dir> -> the seed dir that holds build-epoch/build-commit.
# The baked layout is <seed>/skills, so the meta dir is the parent of the skills dir.
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
		# The window between rm and mv is tiny and an agent re-reads SKILL.md at
		# invoke time; mv is an atomic rename within the same volume.
		rm -rf "$dest"
		if mv "$tmp" "$dest"; then
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
