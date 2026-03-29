#!/usr/bin/env bash
# Remove orphaned agent-nm-* Docker volumes that no longer belong to any
# existing container. This is the Linux/macOS counterpart of prune-volumes.ps1.
set -euo pipefail

# Collect project suffixes from all existing claude-*/codex-* containers.
expected=()
while IFS= read -r name; do
	[ -z "$name" ] && continue
	case "$name" in
	claude-*) expected+=("agent-nm-${name#claude-}") ;;
	codex-*) expected+=("agent-nm-${name#codex-}") ;;
	esac
done < <(docker ps -a --filter "name=claude-" --filter "name=codex-" --format "{{.Names}}")

# Find all agent-nm-* volumes.
candidates=()
while IFS= read -r vol; do
	[ -z "$vol" ] && continue
	candidates+=("$vol")
done < <(docker volume ls --format "{{.Name}}" | grep '^agent-nm-')

# Determine which volumes are orphaned.
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
	echo "No orphaned agent-nm-* volumes found."
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
	echo "Removed $removed orphaned agent-nm-* volume(s)."
	;;
*)
	echo "Aborted."
	;;
esac
