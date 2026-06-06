#!/usr/bin/env bash
# Runs INSIDE a throwaway powbox-agent container (see update-skills.sh /
# update-skills.ps1, which bind-mount this file and the config volumes).
#
# Refreshes the image-baked skills onto the persistent agent-config volumes,
# deliberately overriding the startup seeding's no-clobber. The entrypoint hooks
# only seed a skill folder when it is absent (docker/shared/entrypoint-*-hook.sh),
# so a rebuilt image with updated skill text never replaces the stale copy left
# on the volume by an earlier container start. This worker copies each baked
# skill over the volume copy so the next agent run sees the latest version.
#
# The copy is staged in a sibling temp dir and swapped in with mv so a
# concurrently running agent never observes a half-written skill. Skills present
# on the volume but NOT baked into the image (user-authored, or removed from the
# image since the last seed) are left untouched.
set -euo pipefail

DRY_RUN="${POWBOX_DRY_RUN:-false}"

# Copy every skill baked into $src over the matching folder in $dest.
refresh_agent() {
	local agent="$1" src="$2" dest="$3"
	if [ ! -d "$src" ]; then
		echo "[$agent] no baked skills found at $src; skipping."
		return 0
	fi

	local count=0 failed=0 skill_dir name target tmp
	mkdir -p "$dest"
	for skill_dir in "$src"/*/; do
		[ -d "$skill_dir" ] || continue
		name="$(basename "$skill_dir")"
		target="$dest/$name"

		if [ "$DRY_RUN" = true ]; then
			if [ -d "$target" ]; then
				echo "[$agent] would refresh skill: $name"
			else
				echo "[$agent] would add skill:     $name"
			fi
			count=$((count + 1))
			continue
		fi

		tmp="$(mktemp -d "$dest/.${name}.tmp.XXXXXX")"
		if cp -a "$skill_dir"/. "$tmp"/; then
			# Drop the stale copy and swap the fresh one in. The window between
			# rm and mv is tiny, and an agent re-reads SKILL.md at invoke time.
			rm -rf "$target"
			if mv "$tmp" "$target"; then
				echo "[$agent] refreshed skill: $name"
				count=$((count + 1))
				continue
			fi
		fi
		rm -rf "$tmp"
		echo "[$agent] WARNING: failed to refresh skill: $name" >&2
		failed=$((failed + 1))
	done

	if [ "$DRY_RUN" = true ]; then
		echo "[$agent] $count skill(s) would be refreshed in $dest."
	else
		echo "[$agent] $count skill(s) refreshed in $dest."
	fi
	[ "$failed" -eq 0 ]
}

# agent | baked seed skills dir | destination skills dir on the config volume.
# Mirrors the SKILLS_SRC/SKILLS_DEST pairs in entrypoint-{claude,codex}-hook.sh
# and the AGENT_SEED_DIR mapping in entrypoint-agent.sh.
rc=0
while read -r agent src dest; do
	[ -n "$agent" ] || continue
	refresh_agent "$agent" "$src" "$dest" || rc=1
done <<'EOF'
claude /home/node/.agent-container/claude/skills /home/node/.claude/skills
codex  /home/node/.agent-container/codex/skills  /home/node/.codex/agents/skills
EOF

exit "$rc"
