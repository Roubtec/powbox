#!/usr/bin/env bash
# Runs INSIDE a throwaway powbox-agent container (see update-skills.sh /
# update-skills.ps1, which bind-mount this file and the config volumes).
#
# Force-refreshes the image-baked skills onto the persistent agent-config volumes,
# deliberately overriding the startup seeding's no-clobber. The copy logic and the
# .powbox-seeded ownership marker live in the shared /usr/local/bin/seed-skills.sh
# (baked into the image, also sourced by the entrypoint hooks) so the two never
# drift. This worker adds the refresh-only concerns: classifying each skill,
# resolving unmarked name-collisions, and pruning obsolete seeds.
#
# Ownership marker: the entrypoint seeds and this worker stamp every skill they
# place with <skill>/.powbox-seeded. The marker means "powbox owns this copy":
#   - marked  -> safe to refresh (overwrite) and to prune when no longer baked
#   - unmarked-> user-authored or hand-forked; never touched silently
#
# Output protocol: one TAB-separated record per line on STDOUT, consumed by the
# launcher which renders all human-facing text. Warnings go to STDERR.
#   would-seed|would-refresh|conflict|orphan   (classify mode: no changes)
#   seeded|refreshed|adopted|pruned|conflict|orphan|error   (apply mode)
# where each record is: <verb> <TAB> <agent> <TAB> <skill-name>.
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

emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# Classify (and, in apply mode, act on) one agent's baked skills against its
# on-volume skills dir. Returns nonzero if any copy/delete failed.
process_agent() {
	local agent="$1" src="$2" dest="$3" meta="$4"
	[ -d "$src" ] || return 0

	local marker rc=0 name target
	marker="$(seed_marker_content "$meta")"
	[ "$MODE" = apply ] && mkdir -p "$dest"

	# Set of baked skill names, for the orphan membership test below.
	local -A baked=()
	while IFS= read -r name; do
		[ -n "$name" ] && baked["$name"]=1
	done < <(seed_skill_names "$src")

	# Classify each baked skill: absent -> seed, marked directory -> refresh,
	# unmarked directory or non-directory collision -> conflict (adopt only when
	# explicitly allowed).
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		target="$dest/$name"
		# Truly absent only when no entry of any type exists (-e misses dangling
		# symlinks, so test -L too). A regular file or symlink at a baked skill's
		# name is a user-owned collision, handled by the conflict branch below.
		if [ ! -e "$target" ] && [ ! -L "$target" ]; then
			if [ "$MODE" = classify ]; then
				emit would-seed "$agent" "$name"
			elif seed_skill "$src/$name" "$target" "$marker"; then
				emit seeded "$agent" "$name"
			else
				emit error "$agent" "$name"
				rc=1
			fi
		elif [ -d "$target" ] && seed_is_marked "$target"; then
			if [ "$MODE" = classify ]; then
				emit would-refresh "$agent" "$name"
			elif seed_skill "$src/$name" "$target" "$marker"; then
				emit refreshed "$agent" "$name"
			else
				emit error "$agent" "$name"
				rc=1
			fi
		else
			# Unmarked directory, regular file, or symlink colliding with a baked
			# skill name: ambiguous (legacy seed vs. user fork). Never overwrite
			# silently.
			if [ "$MODE" = apply ] && [ "$ADOPT_ALL" = true ]; then
				if seed_skill "$src/$name" "$target" "$marker"; then
					emit adopted "$agent" "$name"
				else
					emit error "$agent" "$name"
					rc=1
				fi
			else
				emit conflict "$agent" "$name"
			fi
		fi
	done < <(seed_skill_names "$src")

	# Orphans: skills we previously seeded (marked) that are no longer baked.
	# Unmarked on-volume skills are user-authored and are left entirely alone.
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ -n "${baked[$name]:-}" ] && continue
		seed_is_marked "$dest/$name" || continue
		if [ "$MODE" = apply ] && [ "$PRUNE" = true ]; then
			if rm -rf "${dest:?}/${name:?}"; then
				emit pruned "$agent" "$name"
			else
				emit error "$agent" "$name"
				rc=1
			fi
		else
			emit orphan "$agent" "$name"
		fi
	done < <(seed_skill_names "$dest")

	return "$rc"
}

# agent | baked skills dir | destination skills dir | seed meta dir.
# Mirrors the entrypoint hooks: claude seeds into $CONFIG/skills, codex into
# $CONFIG/agents/skills (the ~/.agents symlink target).
rc=0
while read -r agent src dest meta; do
	[ -n "$agent" ] || continue
	process_agent "$agent" "$src" "$dest" "$meta" || rc=1
done <<'EOF'
claude /home/node/.agent-container/claude/skills /home/node/.claude/skills /home/node/.agent-container/claude
codex  /home/node/.agent-container/codex/skills  /home/node/.codex/agents/skills /home/node/.agent-container/codex
EOF

exit "$rc"
