#!/usr/bin/env bash
# Seed/refresh the GLOBAL shared rootless-Podman image store.
#
# Live: the entrypoint (docker/shared/entrypoint-core.sh) runs `seed` once in the
# background on the first overlay-capable start, the launcher
# (scripts/launch-agent.{sh,ps1}) mounts the single `agent-podman-imagestore`
# Docker volume here, prune-volumes keeps that volume, and per-container Podman
# stores reference it read-only via the storage.conf `additionalimagestores` entry
# the entrypoint writes. Cross-container sharing and read-while-write were validated
# on overlay — see docs/podman-shared-image-store.md.
#
# What it does: pulls a small CURATED set of common dev backing images into one
# host-wide containers/storage layout (a Docker volume mounted at
# POWBOX_IMAGE_STORE_DIR), which every per-container Podman graphroot then
# consumes READ-ONLY via `additionalimagestores`. The writable per-container
# stores stay isolated (see scripts/launch-agent.sh); this only shares the
# read path so agents stop re-pulling the same base images per container.
#
# Single-writer: a flock guarantees only one seeder mutates the store at a time;
# consumers only ever read it. Idempotent: `seed` pulls only missing images;
# `update` re-pulls everything to refresh tags.
#
# Usage: seed-image-store.sh [seed|update|list|status]
#   seed    (default) pull any curated image not already in the store
#   update  re-pull every curated image (refresh to latest tag contents)
#   list    print the curated image set and whether each is present
#   status  print store path, driver gate, marker state
set -euo pipefail

# Where the global image-store volume is mounted inside the container. The
# launcher mounts the single `agent-podman-imagestore` Docker volume here (RW to
# the seeder; consumers reference the same path read-only via storage.conf).
STORE="${POWBOX_IMAGE_STORE_DIR:-/mnt/podman-imagestore}"
LOCK="${STORE}/.powbox-seed.lock"
# Marker mirrors the seed-skills.sh idiom: its presence means first-run auto-seed
# already ran, so the entrypoint can skip it. `update` ignores the marker.
MARKER="${STORE}/.powbox-image-store-seeded"

# Curated set. Override with POWBOX_IMAGE_STORE_IMAGES (whitespace/newline
# separated) to add project-specific bases without editing this file. Keep this
# small and deliberate — only ubiquitous dev backing services earn a slot, since
# every image here costs store space shared by all projects.
default_images() {
	cat <<-'EOF'
		docker.io/library/postgres:16-alpine
		docker.io/library/redis:7-alpine
		docker.io/library/mariadb:11
		docker.io/library/adminer:latest
	EOF
}

curated_images() {
	if [ -n "${POWBOX_IMAGE_STORE_IMAGES:-}" ]; then
		# Split the override on any whitespace into one image per line.
		printf '%s' "$POWBOX_IMAGE_STORE_IMAGES" | xargs -n1
	else
		default_images
	fi
}

# The shared store is only useful on the overlay path: an additional image store
# must match the consumer's storage driver, and consumers only enable overlay when
# /dev/fuse is present. On the vfs fallback the entrypoint writes a plain vfs
# storage.conf with no additionalimagestores entry, so a vfs consumer never
# references this store at all — seeding it would produce a store nothing consumes,
# so skip cleanly instead.
overlay_available() {
	[ -e /dev/fuse ]
}

# podman against the shared store as a PRIMARY root (this is the writer path).
# Validated on overlay: --root with the default runroot under XDG_RUNTIME_DIR is the
# right invocation, and consumers point additionalimagestores at STORE (the bare
# graphroot), not STORE/<driver> — see docs/podman-shared-image-store.md.
store_podman() {
	podman --root "$STORE" --storage-driver overlay "$@"
}

image_present() {
	store_podman image exists "$1" 2>/dev/null
}

ensure_store() {
	if [ ! -d "$STORE" ]; then
		echo "Error: image-store mount ${STORE} is missing. Is the agent-podman-imagestore volume mounted? (See docs/podman-shared-image-store.md.)" >&2
		exit 1
	fi
}

# Resolve the seed dir that holds build-epoch/build-commit. The real provenance
# lives per-agent under /home/node/.agent-container/<agent>/, written identically
# for every agent in the same build (docker/agent/Dockerfile). Prefer the running
# agent's dir ($AGENT_SEED_DIR, exported by entrypoint-agent.sh), else any agent's.
# Prints nothing (returns 1) when no metadata is present, so callers fall back.
build_meta_dir() {
	if [ -n "${AGENT_SEED_DIR:-}" ] && [ -f "${AGENT_SEED_DIR}/build-epoch" ]; then
		printf '%s\n' "$AGENT_SEED_DIR"
		return 0
	fi
	local d
	for d in /home/node/.agent-container/*/; do
		[ -f "${d}build-epoch" ] || continue
		printf '%s\n' "${d%/}"
		return 0
	done
	return 1
}

cmd_seed() {
	local force="${1:-false}" img pulled=0 skipped=0 failed=0
	if ! overlay_available; then
		echo "Note: /dev/fuse absent; consumers use the vfs driver and won't read an overlay image store. Skipping seed (nothing to consume it)." >&2
		exit 0
	fi
	ensure_store

	# Single-writer lock so a concurrent launch can't pull into the store at the
	# same time. Non-blocking: if another seed holds it, bow out quietly.
	exec 9>"$LOCK"
	if ! flock -n 9; then
		echo "Another seed is in progress; skipping." >&2
		exit 0
	fi

	while IFS= read -r img; do
		[ -n "$img" ] || continue
		if [ "$force" != true ] && image_present "$img"; then
			echo "present  $img"
			skipped=$((skipped + 1))
			continue
		fi
		if store_podman pull "$img"; then
			echo "pulled   $img"
			pulled=$((pulled + 1))
		else
			echo "FAILED   $img" >&2
			failed=$((failed + 1))
		fi
	done < <(curated_images)

	# Record the marker so first-run auto-seed is one-shot — but ONLY when every
	# curated image landed. A transient registry blip on first run must not write the
	# marker, or the entrypoint's one-shot guard would skip the seed forever and leave
	# the store permanently missing those images. Leaving the marker absent makes the
	# next launch retry. (`update` ignores the marker, so a manual refresh re-pulls
	# regardless.)
	if [ "$failed" -eq 0 ]; then
		local meta
		meta="$(build_meta_dir || true)"
		{
			echo "epoch=$(cat "${meta}/build-epoch" 2>/dev/null || echo 0)"
			echo "commit=$(cat "${meta}/build-commit" 2>/dev/null || echo unknown)"
		} >"$MARKER" 2>/dev/null || true
	fi

	echo "Image store: ${pulled} pulled, ${skipped} present, ${failed} failed."
	[ "$failed" -eq 0 ]
}

cmd_list() {
	local img mark store_ready=false
	# Only probe the store when it is actually mounted. Otherwise `podman --root
	# "$STORE" ...` (via image_present) would create a stray graphroot at $STORE on
	# the container's own filesystem and report misleading "present"/"absent" results.
	if overlay_available && [ -d "$STORE" ]; then
		store_ready=true
	fi
	while IFS= read -r img; do
		[ -n "$img" ] || continue
		if [ "$store_ready" = true ] && image_present "$img"; then
			mark="present"
		else
			mark="absent"
		fi
		printf '%-8s %s\n' "$mark" "$img"
	done < <(curated_images)
}

cmd_status() {
	echo "store dir : ${STORE}"
	echo "mounted   : $([ -d "$STORE" ] && echo yes || echo no)"
	echo "overlay   : $(overlay_available && echo "yes (/dev/fuse present)" || echo "no (vfs fallback; store unused)")"
	echo "seeded    : $([ -f "$MARKER" ] && echo yes || echo no)"
}

case "${1:-seed}" in
seed) cmd_seed false ;;
update) cmd_seed true ;;
list) cmd_list ;;
status) cmd_status ;;
*)
	echo "Usage: $(basename "$0") [seed|update|list|status]" >&2
	exit 2
	;;
esac
