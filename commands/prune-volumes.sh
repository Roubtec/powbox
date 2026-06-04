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

# Determine which volumes are orphaned. agent-pnpm-store is never "expected",
# so it is always pruned when present.
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
	for vol in "${prune[@]}"; do
		docker volume rm "$vol" >/dev/null
		echo "Removed $vol"
		removed=$((removed + 1))
	done
	echo "Removed $removed orphaned volume(s)."
	;;
*)
	echo "Aborted."
	;;
esac
