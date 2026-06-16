#!/usr/bin/env bash
# Remove orphaned agent Docker volumes that no longer belong to any existing
# container: agent-nm-* (node_modules) and agent-wt-* (worktrees + pnpm store),
# both project-keyed (shared by a project's two agents); agent-ws-* (the
# self-hosted per-instance workspace clone) and agent-podman-* (rootless Podman
# storage), both keyed per container (agent + project) so Claude and Codex never
# share one. Also offers the deprecated shared agent-pnpm-store volume (the store
# is now per-project inside each agent-wt-* volume). This is the Linux/macOS
# counterpart of prune-volumes.ps1.
set -euo pipefail

# Parse flags. By default the removal is confirmed once interactively; --yes skips
# that prompt (for scripted/agent-driven GC) and --dry-run lists the orphans and
# exits without removing anything. Mirrors prune-volumes.ps1 (-Yes / -WhatIf).
assume_yes=false
dry_run=false
for arg in "$@"; do
	case "$arg" in
	-y | --yes) assume_yes=true ;;
	-n | --dry-run) dry_run=true ;;
	-h | --help)
		cat <<'EOF'
Usage: prune-volumes.sh [-y|--yes] [-n|--dry-run] [-h|--help]

Remove orphaned agent Docker volumes (agent-nm-*/agent-wt-*/agent-ws-*/agent-podman-*
plus the deprecated agent-pnpm-store) that no longer belong to any existing container.

  -y, --yes       Remove without the interactive confirmation prompt.
  -n, --dry-run   List the volumes that would be removed, then exit (removes nothing).
  -h, --help      Show this help and exit.
EOF
		exit 0
		;;
	*)
		echo "Unknown argument: $arg" >&2
		echo "Run 'prune-volumes.sh --help' for usage." >&2
		exit 2
		;;
	esac
done

# Collect expected volumes from all existing claude-*/codex-* containers. Each
# container expects an nm and a wt volume for its project (project-keyed, shared
# between the project's two agents) plus its own agent-podman-* store and (for a
# self-hosted container) its agent-ws-* workspace, both keyed by the FULL
# container name so a project's concurrently-running Claude and Codex containers
# never share one. agent-ws-* is over-expected for dir-mounted containers too
# (which never create one), which is harmless — nothing by that name exists.
expected=()
while IFS= read -r name; do
	[ -z "$name" ] && continue
	case "$name" in
	claude-*) suffix="${name#claude-}" ;;
	codex-*) suffix="${name#codex-}" ;;
	*) continue ;;
	esac
	expected+=("agent-nm-${suffix}" "agent-wt-${suffix}" "agent-ws-${name}" "agent-podman-${name}")
done < <(docker ps -a --filter "name=claude-" --filter "name=codex-" --format "{{.Names}}")

# The global shared image store is infra shared by every container (like the
# config volumes), not a per-container store — it matches the agent-podman-*
# candidate glob below but is never an orphan. Always expect it.
expected+=("agent-podman-imagestore")

# Find all candidate volumes, plus the deprecated shared store.
candidates=()
while IFS= read -r vol; do
	[ -z "$vol" ] && continue
	candidates+=("$vol")
done < <(docker volume ls --format "{{.Name}}" | grep -E '^agent-(nm|wt|ws|podman)-|^agent-pnpm-store$' | sort)

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
	echo "No orphaned agent-nm-*/agent-wt-*/agent-ws-*/agent-podman-* (or deprecated agent-pnpm-store) volumes found."
	exit 0
fi

echo "Prune candidates:"
for vol in "${prune[@]}"; do
	echo "  $vol"
done

if [ "$dry_run" = true ]; then
	printf '\nDry run — %d volume(s) would be removed; nothing was touched. Re-run with --yes (or confirm the prompt) to remove them.\n' "${#prune[@]}"
	exit 0
fi

if [ "$assume_yes" = true ]; then
	answer=y
else
	printf '\nRemove these volumes? [y/N] '
	read -r answer
fi
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
