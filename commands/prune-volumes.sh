#!/usr/bin/env bash
# Remove orphaned per-project Docker volumes that no longer belong to any
# existing container: agent-nm-* (node_modules) and agent-wt-* (worktrees +
# pnpm store). Also offers the deprecated shared agent-pnpm-store volume (the
# store is now per-project inside each agent-wt-* volume). This is the
# Linux/macOS counterpart of prune-volumes.ps1.
set -euo pipefail

# Collect expected per-project volumes from all existing claude-*/codex-*
# containers. Each container expects both an nm and a wt volume for its project.
expected=()
while IFS= read -r name; do
	[ -z "$name" ] && continue
	case "$name" in
	claude-*) suffix="${name#claude-}" ;;
	codex-*) suffix="${name#codex-}" ;;
	*) continue ;;
	esac
	expected+=("agent-nm-${suffix}" "agent-wt-${suffix}")
done < <(docker ps -a --filter "name=claude-" --filter "name=codex-" --format "{{.Names}}")

# Find all per-project candidate volumes, plus the deprecated shared store.
candidates=()
while IFS= read -r vol; do
	[ -z "$vol" ] && continue
	candidates+=("$vol")
done < <(docker volume ls --format "{{.Name}}" | grep -E '^agent-(nm|wt)-|^agent-pnpm-store$')

# Determine which volumes are orphaned. agent-pnpm-store is never "expected", so it
# is always a candidate when present — but if a pre-change container still mounts it,
# the removal below is skipped gracefully (Docker refuses to remove an in-use volume).
prune=()
for vol in "${candidates[@]}"; do
	orphaned=true
	for exp in "${expected[@]}"; do
		if [ "$vol" = "$exp" ]; then
			orphaned=false
			break
		fi
	done
	if [ "$orphaned" = true ]; then
		prune+=("$vol")
	fi
done

if [ "${#prune[@]}" -eq 0 ]; then
	echo "No orphaned agent-nm-*/agent-wt-* (or deprecated agent-pnpm-store) volumes found."
	exit 0
fi

echo "Prune candidates:"
for vol in "${prune[@]}"; do
	echo "  $vol"
done

printf '\nRemove these volumes? [y/N] '
read -r answer
case "$answer" in
[yY]*)
	removed=0
	skipped=0
	for vol in "${prune[@]}"; do
		# Capture stderr (discard the success-name on stdout). Run inside the `if`
		# condition so a non-zero exit does not trip `set -e` and abort the loop —
		# a volume still referenced by an existing container (e.g. a pre-change
		# container holding the deprecated agent-pnpm-store) can't be removed yet.
		if err="$(docker volume rm "$vol" 2>&1 >/dev/null)"; then
			echo "Removed $vol"
			removed=$((removed + 1))
		else
			echo "Skipped $vol — could not remove (still in use by a container?): ${err}" >&2
			skipped=$((skipped + 1))
		fi
	done
	echo "Removed $removed orphaned volume(s)."
	if [ "$skipped" -gt 0 ]; then
		echo "Skipped $skipped volume(s) still in use — remove or recreate the owning container, then re-run." >&2
	fi
	;;
*)
	echo "Aborted."
	;;
esac
