#!/usr/bin/env bash
# Shared skill/workflow-seeding helper, baked to /usr/local/bin/seed-skills.sh.
#
# Single source of truth for copying image-baked skills (folders) and Claude
# dynamic workflows (flat `.js` files) onto a persistent config volume. Sourced
# (not executed) by:
#   - the Codex entrypoint hook (docker/shared/entrypoint-codex-hook.sh) in
#     `noclobber` mode — seed only skills whose destination is absent (the
#     Claude hook no longer seeds anything: Claude's skills and workflows all
#     arrive via the dev-skills@roubtec plugin channel),
#   - the start-time Codex plugin-clone sync (docker/shared/sync-codex-skills.sh),
#     which reuses the marker semantics and atomic per-skill copy, and
#   - the update-skills worker (docker/shared/update-skills-incontainer.sh), which uses
#     the primitives below to force-refresh, resolve conflicts, and prune.
#
# The workflow primitives further down are retained even though powbox no longer
# bakes any workflows: the update-skills worker still needs them to classify and
# prune the previously-seeded wf-*.js copies (and their sidecar markers) left on
# older claude-config volumes.
#
# Ownership marker: every skill/workflow this code PLACES gets a hidden
# `.powbox-seeded` marker recording the image build epoch, the powbox commit
# that built the image, and the UPSTREAM location the copy came from. A skill is
# a folder, so its marker is the in-folder file `<skill>/.powbox-seeded`; a
# workflow is a single file, which has no "inside", so its marker is a sibling
# sidecar `<dir>/.<workflow>.powbox-seeded`. Either way the marker means "powbox
# owns this copy": the refresher may overwrite or prune a marked item, while one
# WITHOUT the marker is treated as user-authored and is never touched. To adopt a
# seeded item as your own, delete its marker (or rename it).
#
# Marker format: one `key=value` per line. Consumers MUST parse by key (grep
# '^commit=' etc.) and never by line number or line count — the set of keys grows
# (see `source=` below) and an older image's markers are still on the volumes a
# newer image reads.
#
# This file is sourced, so it defines functions only and must not `set -e` or run
# side effects at load time.

POWBOX_SEED_MARKER=".powbox-seeded"

# --- Upstream source provenance -----------------------------------------------
# `epoch=`/`commit=` answer "which image build put this here"; `source=` answers
# the question an agent actually hits when it finds a DEFECT in a seeded skill
# mid-run: "where do I fix it?". The value is `<owner>/<repo>#<repo-relative
# path>` — the source-of-truth path in the OWNING repo, not the container
# destination — so it is greppable and pasteable straight into a report or PR.
#
# Everything powbox seeds today originates in Roubtec/agent-skills: the Codex
# skill palette is baked from that repo's `codex/dev-skills/skills/` (staged
# host-side into `.agent-skills-src/` by scripts/build-image.sh) and re-synced at
# start from the marketplace clone's copy of the same subtree; the Claude skills
# and `wf-*.js` workflows powbox once seeded live in the same repo under
# `plugins/dev-skills/` and now arrive via the dev-skills@roubtec plugin. A
# per-source-root constant is therefore enough — no git metadata has to be
# threaded through the seed path. Should powbox ever bake an asset it owns
# itself, give that call site its own `<owner>/<repo>#<path>` root.
POWBOX_SEED_SOURCE_REPO="${POWBOX_SEED_SOURCE_REPO:-Roubtec/agent-skills}"
# shellcheck disable=SC2034 # consumed by the scripts that SOURCE this library
POWBOX_SEED_SOURCE_CODEX_SKILLS="${POWBOX_SEED_SOURCE_REPO}#codex/dev-skills/skills"
# shellcheck disable=SC2034 # consumed by the scripts that SOURCE this library
POWBOX_SEED_SOURCE_CLAUDE_SKILLS="${POWBOX_SEED_SOURCE_REPO}#plugins/dev-skills/skills"
# shellcheck disable=SC2034 # consumed by the scripts that SOURCE this library
POWBOX_SEED_SOURCE_CLAUDE_WORKFLOWS="${POWBOX_SEED_SOURCE_REPO}#plugins/dev-skills/workflows"

# seed_source_ref <source_root> <item_name> -> the marker's `source=` VALUE for
# one item: `<source_root>/<item_name>`, where <source_root> is one of the
# `<owner>/<repo>#<dir>` constants above. Prints NOTHING (so the caller omits the
# line entirely) when the root is empty or the `-` placeholder used by call sites
# that have no upstream to name — an unknown source must be absent, never a
# misleading guess.
seed_source_ref() {
	local root="${1:-}" name="${2:-}"
	case "$root" in
	'' | '-') return 0 ;;
	esac
	[ -n "$name" ] || return 0
	printf '%s/%s' "${root%/}" "$name"
}

# seed_meta_dir <src_dir> -> the seed dir that holds build-epoch/build-commit.
# The baked layout is <seed>/skills and <seed>/workflows, so the meta dir is the
# parent of whichever source dir was passed.
seed_meta_dir() {
	dirname "$1"
}

# seed_marker_content <meta_dir> [<source_ref>] -> prints the marker body: the
# epoch + commit lines, plus a `source=<source_ref>` line when a non-empty
# <source_ref> (see seed_source_ref) is given. Missing metadata degrades to sane
# placeholders so seeding never fails on it; an absent <source_ref> omits the
# line rather than writing an empty/placeholder one, keeping the body identical
# to what pre-`source=` images wrote.
seed_marker_content() {
	local meta="$1" source_ref="${2:-}" epoch commit
	epoch="$(cat "$meta/build-epoch" 2>/dev/null || echo 0)"
	commit="$(cat "$meta/build-commit" 2>/dev/null || echo unknown)"
	[ -n "$epoch" ] || epoch=0
	[ -n "$commit" ] || commit=unknown
	printf 'epoch=%s\ncommit=%s\n' "$epoch" "$commit"
	if [ -n "$source_ref" ]; then
		printf 'source=%s\n' "$source_ref"
	fi
	return 0
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
# failure; an existing destination is normally preserved — the prior copy is renamed
# aside before the staged copy is published and moved back if the publish fails —
# EXCEPT in the narrow double-failure case where both the publish and the restoring
# rename fail: <dest_skill_dir> is then left absent and the prior copy survives as a
# hidden `.old.*` sibling backup (kept for recovery / the next start's re-sync).
seed_skill() {
	local src="${1%/}" dest="$2" marker="$3"
	local parent name tmp backup
	parent="$(dirname "$dest")"
	name="$(basename "$dest")"
	mkdir -p "$parent"
	tmp="$(mktemp -d "$parent/.${name}.tmp.XXXXXX")" || return 1
	if ! { cp -a "$src"/. "$tmp"/ && printf '%s' "$marker" >"$tmp/$POWBOX_SEED_MARKER"; }; then
		rm -rf "$tmp"
		return 1
	fi
	# Publish by swap, NOT by `rm -rf "$dest"; mv tmp dest`. The old form erased the
	# live copy UP FRONT: it exposed an absent window as wide as a recursive delete
	# (a real hazard for Codex, which reads skill files live and warns on churn) and
	# — worse — DESTROYED the prior copy outright if the rename then failed. Instead,
	# rename any existing $dest ASIDE into a hidden sibling first, publish the staged
	# copy, then delete the old one only once the new one is live. A reader now sees
	# either the old skill or the new one; the window with neither is one rename wide
	# (not a whole rm -rf), and a failed publish restores the prior copy rather than
	# losing it. The backup name is hidden (leading dot) so it is never enumerated as
	# a phantom skill by seed_skill_names.
	if [ -e "$dest" ] || [ -L "$dest" ]; then
		# Reserve a unique hidden backup PATH, then leave NOTHING at it: `mktemp -d`
		# claims a random, collision-free name, and `rmdir` removes the empty dir so
		# the target is ABSENT before the rename. That matters for wrong-type
		# destinations: `mv -T "$dest" "$backup"` renames $dest of ANY type — dir,
		# file, or symlink — onto an absent path uniformly. A pre-created backup
		# DIRECTORY instead makes that rename fail with EISDIR whenever $dest is a
		# file/symlink (rename() cannot replace a directory with a non-directory),
		# which would silently skip the swap and regress an --adopt-all refresh of a
		# wrong-type collision. The leading-dot name is never enumerated as a phantom
		# skill by seed_skill_names.
		backup="$(mktemp -d "$parent/.${name}.old.XXXXXX")" || {
			rm -rf "$tmp"
			return 1
		}
		rmdir "$backup" || {
			rm -rf "$tmp" "$backup"
			return 1
		}
		# -T (--no-target-directory) renames $dest to the now-absent $backup path.
		if ! mv -T "$dest" "$backup"; then
			rm -rf "$tmp" "$backup"
			return 1
		fi
		# Publish. -T makes mv REPLACE $dest rather than nest $tmp inside a $dest that
		# a concurrent seed may have recreated in the one-rename window, failing loudly
		# into the restore below instead of returning a false success with an orphaned
		# temp tree.
		if mv -T "$tmp" "$dest"; then
			rm -rf "$backup"
			return 0
		fi
		# Publish failed: move the prior copy back so $dest is never lost. Best-effort
		# — if a racing seed already refilled $dest, keep its copy rather than clobber.
		if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
			mv -T "$backup" "$dest" 2>/dev/null || true
		fi
		rm -rf "$tmp"
		# Reclaim the backup ONLY once $dest is confirmed live again (restore
		# succeeded, or a racing seed already refilled it). If BOTH the publish and
		# the restore failed — the narrow double-rename window — $dest is still
		# absent, so KEEP the .old backup as the sole surviving copy for recovery /
		# the next start's re-sync rather than deleting it here.
		if [ -e "$dest" ] || [ -L "$dest" ]; then
			rm -rf "$backup"
		fi
		return 1
	fi
	# No existing copy: a single atomic rename installs the skill.
	if mv -T "$tmp" "$dest"; then
		return 0
	fi
	rm -rf "$tmp"
	return 1
}

# seed_skills <src_skills_dir> <dest_skills_dir> <noclobber|refresh> [<meta_dir>]
#             [<source_root>]
# Convenience loop used by the entrypoint hooks. <source_root> is an
# `<owner>/<repo>#<dir>` constant (see the block near the top); each placed
# skill's marker records `<source_root>/<skill>`. Omit it (or pass `-`) to write
# a marker with no `source=` line.
#   noclobber: place only skills whose destination is ABSENT (preserves any existing
#              entry — directory, file, or symlink — marked or not).
#   refresh:   place absent skills and overwrite directories that carry our marker; an
#              unmarked directory, or any non-directory collision, is a conflict and is
#              left untouched (the update-skills worker is what surfaces and resolves
#              those).
# Returns nonzero if any copy failed.
seed_skills() {
	local src="$1" dest="$2" mode="$3" meta="${4:-}" source_root="${5:-}"
	[ -d "$src" ] || return 0
	[ -n "$meta" ] || meta="$(seed_meta_dir "$src")"
	mkdir -p "$dest"
	local rc=0 name target marker
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		target="$dest/$name"
		# Any existing entry blocks a blind overwrite — seed_skill replaces the
		# destination (renaming any existing copy aside, then publishing the staged
		# one), so we must only reach it for an absent target or a marked directory.
		# -e misses dangling symlinks, so test -L too.
		if [ -e "$target" ] || [ -L "$target" ]; then
			case "$mode" in
			noclobber) continue ;;
			# Only a directory we placed (carries the marker) may be refreshed; an
			# unmarked directory or any non-directory collision is user-owned.
			refresh) { [ -d "$target" ] && seed_is_marked "$target"; } || continue ;;
			esac
		fi
		# Per-ITEM marker: the `source=` line names this skill's own upstream
		# path, so the body cannot be hoisted out of the loop.
		marker="$(seed_marker_content "$meta" "$(seed_source_ref "$source_root" "$name")")"
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
	# and refreshed/pruned. Unlike seed_skill (which renames a directory aside
	# because rename() cannot replace a non-empty dir), a workflow is a single file,
	# so a plain rm-then-rename is enough and simplest here: rm any existing $dest
	# before the rename, so an --adopt-all run recovers EVERY collision type —
	# including a wrong-type directory, which `mv -fT` alone refuses to replace with
	# a file (it would fail loudly instead of adopting). -T still guards the tiny rm->mv
	# window on the shared volume: if a concurrent seed recreated $dest as a
	# directory, mv fails into the cleanup below rather than nesting the temp
	# inside it. If the file lands but its marker rename fails, the workflow is
	# left unmarked (treated as user-authored): unmanaged, but never destructive.
	if cp "$src" "$tmp" && printf '%s' "$marker" >"$markertmp"; then
		rm -rf "$dest"
		if mv -fT "$tmp" "$dest" && mv -fT "$markertmp" "$markerpath"; then
			return 0
		fi
	fi
	rm -f "$tmp" "$markertmp"
	return 1
}

# seed_workflows <src_dir> <dest_dir> <noclobber|refresh> [<meta_dir>]
#                [<source_root>]
# Workflow analogue of seed_skills, with identical mode and <source_root>
# semantics:
#   noclobber: place only workflows whose destination is ABSENT (preserves any
#              existing entry — file, dir, or symlink — marked or not).
#   refresh:   place absent workflows and overwrite plain files that carry our
#              sidecar marker; an unmarked file, or any non-file collision, is a
#              conflict and is left untouched.
# Returns nonzero if any copy failed.
seed_workflows() {
	local src="$1" dest="$2" mode="$3" meta="${4:-}" source_root="${5:-}"
	[ -d "$src" ] || return 0
	[ -n "$meta" ] || meta="$(seed_meta_dir "$src")"
	mkdir -p "$dest"
	local rc=0 name target marker
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
		# Per-ITEM marker, as in seed_skills: `source=` names this workflow's own
		# upstream path (sidecar marker, same key set).
		marker="$(seed_marker_content "$meta" "$(seed_source_ref "$source_root" "$name")")"
		seed_workflow "$src/$name" "$target" "$marker" || rc=1
	done < <(seed_workflow_names "$src")
	return "$rc"
}
