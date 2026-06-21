#!/usr/bin/env bash
# Remove orphaned agent Docker volumes that no longer belong to any existing
# container: agent-nm-* (node_modules), agent-wt-* (worktrees + pnpm store),
# agent-ws-* (the self-hosted per-instance workspace clone), and agent-podman-*
# (rootless Podman storage) — ALL keyed per container (agent + project) so a
# project's Claude and Codex containers never share one (a shared writable
# node_modules / pnpm store corrupts two live agents). Also offers the deprecated
# shared agent-pnpm-store volume (the store is now per-container inside each
# agent-wt-* volume). This is the Linux/macOS counterpart of prune-volumes.ps1.
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

# When invoked via `agent-prune`, the stopped-container prune removes exited
# claude-*/codex- containers before us. In a real run they are already gone from
# `docker ps -a` here, but in a --dry-run nothing was removed, so agent-prune
# passes their names in POWBOX_PRUNE_REMOVED_CONTAINERS and we treat them as
# already-removed — otherwise the preview would count their full-name-keyed
# agent-ws-*/agent-podman-* volumes as expected and hide removals a real --yes
# would perform. Unset (standalone prune-volumes) -> every existing container,
# exited or not, still pins its volumes (Docker would refuse to remove them).
removed_containers=()
if [ -n "${POWBOX_PRUNE_REMOVED_CONTAINERS:-}" ]; then
	while IFS= read -r rname; do
		[ -n "$rname" ] && removed_containers+=("$rname")
	done <<-EOF
		${POWBOX_PRUNE_REMOVED_CONTAINERS}
	EOF
fi

# Collect expected (protected) volumes from all existing claude-*/codex-*
# containers by deriving them from each container's ACTUAL mounts, not by
# constructing agent-{nm,wt,ws,podman}-<name> from the container name. The
# name-construction approach over-expected volumes a container does not really
# mount: a dir-mounted container relaunched without a package.json mounts no
# nm/wt (MOUNT_WORKSPACE_VOLUMES=false), and a self-hosted (--isolated) container
# keeps its data in agent-ws-<name> with no nm/wt — yet any leftover
# agent-nm-<name>/agent-wt-<name> from a prior launch was marked expected and so
# never reported as an orphan. Conversely, a pre-rename container still mounting
# its legacy agent-nm-<project>/agent-wt-<project> was NOT protected by the
# new-name construction, so prune mislisted genuinely-mounted volumes. Reading
# real mounts fixes both: a container protects exactly what it mounts (legacy or
# new), and a volume no existing container mounts becomes an orphan candidate
# (the confirm prompt + Docker's in-use refusal are the backstop).
expected=()
while IFS= read -r name; do
	[ -z "$name" ] && continue
	# Skip containers agent-prune is removing this run so their volumes are
	# correctly reported as orphans (exact, case-sensitive match). On a real run
	# they are already gone from `docker ps -a`; on a --dry-run they still exist,
	# but we must NOT inspect them here, or their mounts would be re-protected and
	# hide removals a real --yes would perform.
	for removed in "${removed_containers[@]}"; do
		[ "$name" = "$removed" ] && continue 2
	done
	case "$name" in
	claude-* | codex-*) ;;
	*) continue ;;
	esac
	# `docker inspect` emits one mount Name per line (bind mounts render an empty
	# Name, skipped below; anonymous volumes carry a hex name that never matches
	# the agent-* prefixes). stderr is dropped so a container that vanished between
	# `docker ps -a` and here (a rare race) is a harmless no-op, not a hard error.
	while IFS= read -r vol; do
		case "$vol" in
		agent-nm-* | agent-wt-* | agent-ws-* | agent-podman-*)
			expected+=("$vol")
			;;
		esac
	done < <(docker inspect --format '{{range .Mounts}}{{println .Name}}{{end}}' "$name" 2>/dev/null)
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
