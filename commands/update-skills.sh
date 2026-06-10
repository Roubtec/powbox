#!/usr/bin/env bash
set -euo pipefail

# Refresh the image-baked agent skills (and Claude workflows) onto the persistent
# config volumes.
#
# Skills (folders) and Claude dynamic workflows (flat .js files) are baked into
# powbox-agent:latest at build time and seeded onto the claude-config /
# codex-config volumes the first time each item is absent (no-clobber, see
# docker/shared/entrypoint-*-hook.sh). That no-clobber means a rebuilt image with
# updated skills/workflows does NOT overwrite the stale copies already on the
# volume. This command closes that gap: it runs a throwaway container that
# force-copies the freshly built items over the volume copies, removing the old
# "enter a container, delete skills, exit, relaunch" dance.
#
# Each item powbox places carries a hidden .powbox-seeded ownership marker (in a
# skill's folder; alongside a workflow as a sidecar), so this command can tell its
# own copies from items you authored:
#   - marked items are refreshed (and, with --prune, removed when no longer baked)
#   - an UNMARKED item whose name collides with a baked one is a CONFLICT and is
#     never overwritten silently; resolve it with --adopt-all (take the baked
#     version + track it) or by renaming yours.
#
# Rebuild the image first (e.g. `cc <project> --build`, `agent-update`, or
# `build.sh agent`) so the baked skills reflect your latest edits — this command
# seeds from whatever is currently in powbox-agent:latest.
#
# The config volumes are shared by every agent container, so this works whether
# or not any containers are running. A container that is already running picks up
# a refreshed skill the next time that skill is invoked; restart it for certainty.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="powbox-agent:latest"
WORKER="$ROOT_DIR/docker/shared/update-skills-incontainer.sh"

DRY_RUN=false
PRUNE=false
ADOPT_ALL=false
while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run | -n) DRY_RUN=true ;;
	--prune) PRUNE=true ;;
	--adopt-all) ADOPT_ALL=true ;;
	-h | --help)
		cat <<'USAGE'
Usage: update-skills.sh [--dry-run] [--prune] [--adopt-all]
  Refresh image-baked skills and Claude workflows onto the claude-config /
  codex-config volumes.

  --dry-run, -n   Show the plan (seed/refresh/conflicts/obsolete) without changing anything.
  --prune         Delete obsolete seeded items (marked, no longer baked into the image).
                  Without it they are reported; with it they are removed.
  --adopt-all     Overwrite UNMARKED items that collide with a baked skill/workflow name and
                  start tracking them as powbox-managed. Use only if those are stale seeds,
                  not your own customizations (rename those first).

  With a terminal attached, you are prompted before pruning or adopting; --prune /
  --adopt-all pre-approve those non-interactively.
USAGE
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
	shift
done

if ! docker info >/dev/null 2>&1; then
	echo "Docker daemon is not running. Start Docker Desktop (or the Docker daemon) and try again." >&2
	exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Image '$IMAGE' not found. Build it first (e.g. './build.sh agent' or 'cc <project> --build')." >&2
	exit 1
fi

if [ ! -f "$WORKER" ]; then
	echo "Worker script not found: $WORKER" >&2
	exit 1
fi

# Run the worker inside powbox-agent (the only image that carries the baked seed
# dirs and the shared seed-skills.sh) with both config volumes mounted. The
# worker is bind-mounted read-only; it prints TAB-separated records on stdout
# which we parse, while its warnings flow to stderr. --entrypoint bash bypasses
# the agent entrypoint. No -i/-t, so our own read prompts keep the terminal.
run_worker() {
	local mode="$1" adopt="$2" prune="$3"
	docker run --rm \
		-v "claude-config:/home/node/.claude" \
		-v "codex-config:/home/node/.codex" \
		-v "${WORKER}:/usr/local/bin/update-skills-incontainer.sh:ro" \
		-e "POWBOX_SEED_MODE=${mode}" \
		-e "POWBOX_ADOPT_ALL=${adopt}" \
		-e "POWBOX_PRUNE=${prune}" \
		--entrypoint bash \
		"$IMAGE" /usr/local/bin/update-skills-incontainer.sh
}

# --- Classify: build the plan and collect conflicts / orphans -----------------
n_seed=0 n_refresh=0
conflicts=()
orphans=()
records="$(run_worker classify false false)" || {
	echo "Refresh failed during planning." >&2
	exit 1
}
while IFS=$'\t' read -r verb agent kind name; do
	[ -n "${verb:-}" ] || continue
	case "$verb" in
	would-seed) n_seed=$((n_seed + 1)) ;;
	would-refresh) n_refresh=$((n_refresh + 1)) ;;
	conflict) conflicts+=("$agent/$name ($kind)") ;;
	orphan) orphans+=("$agent/$name ($kind)") ;;
	esac
done <<<"$records"

echo "Image: $IMAGE"
echo "Plan: ${n_seed} to seed, ${n_refresh} to refresh."
if [ "${#conflicts[@]}" -gt 0 ]; then
	echo "Conflicts (unmarked items shadowing a baked skill/workflow — left untouched):"
	printf '  - %s\n' "${conflicts[@]}"
fi
if [ "${#orphans[@]}" -gt 0 ]; then
	echo "Obsolete seeded items (marked, no longer baked into the image):"
	printf '  - %s\n' "${orphans[@]}"
fi

# --- Decide adopt / prune (flags pre-approve; otherwise prompt on a TTY) -------
if [ "${#conflicts[@]}" -gt 0 ] && [ "$ADOPT_ALL" != true ] && [ "$DRY_RUN" != true ] && [ -t 0 ]; then
	printf 'Adopt the %d conflicting skill(s) above (overwrite with the baked version + track them)?\n' "${#conflicts[@]}"
	printf 'Answer N and rename any you want to keep as your own. [y/N] '
	read -r reply
	case "$reply" in [yY] | [yY][eE][sS]) ADOPT_ALL=true ;; esac
fi
if [ "${#orphans[@]}" -gt 0 ] && [ "$PRUNE" != true ] && [ "$DRY_RUN" != true ] && [ -t 0 ]; then
	printf 'Remove the %d obsolete seeded skill(s) above? [y/N] ' "${#orphans[@]}"
	read -r reply
	case "$reply" in [yY] | [yY][eE][sS]) PRUNE=true ;; esac
fi

if [ "$DRY_RUN" = true ]; then
	echo "(dry run — no changes made)"
	[ "${#conflicts[@]}" -gt 0 ] && echo "Re-run with --adopt-all to take the baked version of the conflicts."
	[ "${#orphans[@]}" -gt 0 ] && echo "Re-run with --prune to remove the obsolete seeded skills."
	exit 0
fi

# --- Apply --------------------------------------------------------------------
rc=0
records="$(run_worker apply "$ADOPT_ALL" "$PRUNE")" || rc=$?
applied=0 failed=0 kept_conflicts=0 kept_orphans=0
while IFS=$'\t' read -r verb agent kind name; do
	[ -n "${verb:-}" ] || continue
	case "$verb" in
	seeded)
		echo "[$agent] seeded $kind: $name"
		applied=$((applied + 1))
		;;
	refreshed)
		echo "[$agent] refreshed $kind: $name"
		applied=$((applied + 1))
		;;
	adopted)
		echo "[$agent] adopted $kind: $name"
		applied=$((applied + 1))
		;;
	pruned)
		echo "[$agent] pruned obsolete $kind: $name"
		applied=$((applied + 1))
		;;
	conflict) kept_conflicts=$((kept_conflicts + 1)) ;;
	orphan) kept_orphans=$((kept_orphans + 1)) ;;
	error)
		echo "[$agent] WARNING: failed to update $kind: $name" >&2
		failed=$((failed + 1))
		;;
	esac
done <<<"$records"

echo "${applied} item(s) updated."
[ "$kept_conflicts" -gt 0 ] && echo "${kept_conflicts} conflict(s) left untouched (run with --adopt-all to take the baked version)."
[ "$kept_orphans" -gt 0 ] && echo "${kept_orphans} obsolete seeded item(s) kept (run with --prune to remove)."
if [ "$failed" -gt 0 ] || [ "$rc" -ne 0 ]; then
	echo "Refresh completed with ${failed} failure(s)." >&2
	exit 1
fi
