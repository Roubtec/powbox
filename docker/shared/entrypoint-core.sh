#!/usr/bin/env bash
set -euo pipefail

if command -v sudo >/dev/null 2>&1; then
	sudo /usr/local/bin/init-firewall.sh
else
	/usr/local/bin/init-firewall.sh
fi

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:?AGENT_CONFIG_DIR must be set}"
AGENT_SETUP_HOOK="${AGENT_SETUP_HOOK:-}"
GH_CONFIG_DIR="${GH_CONFIG_DIR:-/home/node/.config/gh}"
GH_HOST_SEED_DIR="${GH_HOST_SEED_DIR:-/home/node/.config/gh-host}"

mkdir -p "$AGENT_CONFIG_DIR" "$GH_CONFIG_DIR"

if [ -n "$AGENT_SETUP_HOOK" ] && [ -x "$AGENT_SETUP_HOOK" ]; then
	"$AGENT_SETUP_HOOK"
fi

# Seed the persistent GitHub CLI config volume from a host config directory on
# the first run only. Subsequent runs keep the Docker-managed state untouched.
if [ -d "$GH_HOST_SEED_DIR" ] &&
	[ -n "$(find "$GH_HOST_SEED_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] &&
	[ ! -f "$GH_CONFIG_DIR/hosts.yml" ]; then
	cp -an "$GH_HOST_SEED_DIR"/. "$GH_CONFIG_DIR"/
	chmod 700 "$GH_CONFIG_DIR" || true
	if [ -f "$GH_CONFIG_DIR/hosts.yml" ]; then
		chmod 600 "$GH_CONFIG_DIR/hosts.yml" || true
	fi
fi

# Seed a writable global git config from the host copy if one was mounted read-only.
if [ -f /home/node/.gitconfig-host ]; then
	mkdir -p "$(dirname "$GIT_CONFIG_GLOBAL")"
	cp /home/node/.gitconfig-host "$GIT_CONFIG_GLOBAL"
elif [ ! -f "$GIT_CONFIG_GLOBAL" ]; then
	mkdir -p "$(dirname "$GIT_CONFIG_GLOBAL")"
	: >"$GIT_CONFIG_GLOBAL"
fi

# Mark workspace bind-mounts as git safe directories. Host-owned project
# directories under /workspace/ have a different UID than the container's
# 'node' user, which triggers git's dubious-ownership check.
# This step is best-effort: a warning is logged if the config is not writable.
if ! : >>"$GIT_CONFIG_GLOBAL" 2>/dev/null; then
	echo "Warning: unable to update global git config at $GIT_CONFIG_GLOBAL; skipping safe.directory registration." >&2
else
	for _dir in /workspace/*/; do
		[ -d "$_dir" ] || continue
		_dir="${_dir%/}"
		if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$_dir"; then
			if ! git config --global --add safe.directory "$_dir"; then
				echo "Warning: failed to add git safe.directory for $_dir; continuing." >&2
			fi
		fi
	done
	unset _dir
fi

# On Windows hosts (detected via the WSL2 kernel's "microsoft" release
# string), every file mounted from the host appears executable to the
# Linux container, which produces spurious mode-change diffs.  Disable
# file-mode tracking locally in each workspace repository so that the
# host/container mismatch does not pollute diffs or commits.
# Set CORE_FILEMODE=false to force this behaviour on Windows hosts that
# use the older Hyper-V backend (where the kernel check does not fire).
if uname -r 2>/dev/null | grep -qi microsoft || [ "${CORE_FILEMODE:-}" = "false" ]; then
	for _dir in /workspace/*/; do
		[ -d "$_dir" ] || continue
		_dir="${_dir%/}"
		if git -C "$_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
			if ! git -C "$_dir" config --local core.filemode false; then
				echo "Warning: failed to set git core.filemode=false for $_dir; continuing." >&2
			fi
		fi
	done
	unset _dir
fi

# If gh is authenticated, register it as the git credential helper.
if command -v gh >/dev/null 2>&1 && gh auth status &>/dev/null; then
	if ! (cd "$HOME" && gh auth setup-git); then
		echo "Warning: gh auth is present, but git credential helper setup failed; continuing without automatic gh git integration." >&2
	else
		# Route SSH-form GitHub remotes (git@github.com:...) through HTTPS so the
		# gh credential helper above authenticates them — host-mounted repos often
		# carry an SSH origin, and the container has no SSH keys. This rewrite is
		# written only to the container-local GIT_CONFIG_GLOBAL; the host repo's
		# remote URL is left untouched.
		if ! git config --global url."https://github.com/".insteadOf "git@github.com:"; then
			echo "Warning: failed to configure SSH→HTTPS rewrite for GitHub remotes; continuing." >&2
		fi
	fi
fi

# Shadow nested node_modules in monorepo workspaces with tmpfs so that
# container-native (Linux) binaries never mix with host-native binaries.
# The root node_modules is already shadowed by a Docker volume mount;
# this covers subpackage directories detected from pnpm-workspace.yaml,
# package.json workspaces, or .powbox.yml.  See README.md for details.
for _dir in /workspace/*/; do
	[ -d "$_dir" ] || continue
	_dir="${_dir%/}"
	mapfile -t _targets < <(detect-shadows.sh "$_dir" 2>/dev/null || true)
	if [ "${#_targets[@]}" -gt 0 ]; then
		if ! sudo --preserve-env=SHADOW_TMPFS_SIZE /usr/local/bin/shadow-mounts.sh "${_targets[@]}"; then
			echo "Warning: failed to shadow workspace directories in $_dir; continuing." >&2
		fi
	fi
done
unset _dir _targets

# Co-locate the pnpm store with the per-project worktrees volume so that
# `pnpm install` inside a worktree HARDLINKS package files from the store
# instead of copying them.  pnpm can only hardlink when the store and the
# target node_modules live under the SAME mount (not merely the same device),
# so the launcher mounts an ext4 volume at <workspace>/.worktrees and passes
# its store path here; the store then sits beside every .worktrees/<task>/
# node_modules under that one mount.  Guarded so a bad value never aborts the
# container start — pnpm just keeps the image-default store and copies.
if [ -n "${PNPM_STORE_DIR:-}" ]; then
	if mkdir -p "$PNPM_STORE_DIR" 2>/dev/null; then
		pnpm config --global set store-dir "$PNPM_STORE_DIR" ||
			echo "Warning: failed to set pnpm store-dir to $PNPM_STORE_DIR; keeping default." >&2
		# Re-assert auto here too so an image built before this default still
		# hardlinks once the store and worktrees share a mount.
		pnpm config --global set package-import-method auto ||
			echo "Warning: failed to set pnpm package-import-method=auto; continuing." >&2
	else
		echo "Warning: cannot create pnpm store dir $PNPM_STORE_DIR; leaving store-dir at default." >&2
	fi
fi

# Prepare rootless Podman (only present once the image gained container-engine
# support). XDG_RUNTIME_DIR must exist, be private, and be exported so Podman
# uses it for the runtime/runroot instead of falling back to a /run/user/<uid>
# that does not exist in this container. The graphroot
# (~/.local/share/containers) is a per-container Docker volume (keyed by agent +
# project) mounted by launch-agent.sh, so images and named volumes persist across
# restarts while Claude and Codex keep separate, non-clobbering stores.
if command -v podman >/dev/null 2>&1; then
	_xdg="${XDG_RUNTIME_DIR:-/home/node/.local/run}"
	if mkdir -p "$_xdg" && chmod 700 "$_xdg"; then
		export XDG_RUNTIME_DIR="$_xdg"
	else
		echo "Warning: could not prepare XDG_RUNTIME_DIR ($_xdg) for Podman; continuing." >&2
	fi
	mkdir -p "$HOME/.config/containers"

	# Storage driver: fuse-overlayfs needs /dev/fuse; without it Podman uses the
	# slower vfs driver. The driver is baked into the persistent graphroot on
	# first use, and Podman requires `podman system reset` before changing
	# storage.conf's `driver`, so silently flipping it when /dev/fuse availability
	# changes (moved host, POWBOX_FUSE toggled, outer container recreated) would
	# orphan the existing images and volumes. So pick a driver from /dev/fuse only
	# on first init, record it on the persistent volume, and honour that recorded
	# choice on every later launch — warning instead of switching on a mismatch.
	_containers_root="$HOME/.local/share/containers"
	_driver_marker="$_containers_root/.powbox-storage-driver"
	if [ -e /dev/fuse ]; then
		_desired_driver="overlay"
	else
		_desired_driver="vfs"
	fi
	_chosen_driver=""
	if [ -f "$_driver_marker" ]; then
		_chosen_driver="$(cat "$_driver_marker" 2>/dev/null || true)"
	elif [ -d "$_containers_root/storage/overlay" ]; then
		_chosen_driver="overlay"
	elif [ -d "$_containers_root/storage/vfs" ]; then
		_chosen_driver="vfs"
	fi
	case "$_chosen_driver" in
	overlay | vfs)
		if [ "$_chosen_driver" != "$_desired_driver" ]; then
			echo "Note: Podman storage was initialised with the '$_chosen_driver' driver; keeping it (current /dev/fuse state would pick '$_desired_driver'). Changing drivers needs a clean store — run 'podman system reset' (or drop this project's agent-podman-* volume) and relaunch to switch to '$_desired_driver'." >&2
		fi
		;;
	*)
		_chosen_driver="$_desired_driver"
		;;
	esac
	# Best-effort record of the committed driver for subsequent launches.
	mkdir -p "$_containers_root" 2>/dev/null || true
	printf '%s\n' "$_chosen_driver" >"$_driver_marker" 2>/dev/null || true

	if [ "$_chosen_driver" = "overlay" ]; then
		# Overlay path. The image ships no system storage.conf, so Podman uses its
		# built-in rootless defaults (overlay + auto-selected fuse-overlayfs). When the
		# global read-only image store is mounted, write a storage.conf that keeps
		# overlay AND layers that store on top via additionalimagestores. The store is
		# only referenced on overlay: its driver must match the consumer's, and a vfs
		# consumer never sees it (see the vfs branch). Drop any stale override when the
		# store isn't mounted and fall back to the built-in default.
		_imgstore="/mnt/podman-imagestore"
		if [ -d "$_imgstore" ]; then
			# additionalimagestores wants the graphroot (the bare mount dir), NOT a
			# driver subdir — verified on vfs; re-confirm on overlay. No mount_program
			# is set on purpose: rootless Podman auto-selects fuse-overlayfs here just
			# as it does with the built-in default (the image has no system storage.conf).
			printf '[storage]\ndriver = "overlay"\n\n[storage.options]\nadditionalimagestores = ["%s"]\n' \
				"$_imgstore" >"$HOME/.config/containers/storage.conf"
			# First-run seed in the background so container start isn't blocked on pulls.
			# Reparented after the entrypoint's `exec "$@"`; the seeder flock serializes
			# concurrent writers across containers.
			if [ ! -f "$_imgstore/.powbox-image-store-seeded" ] && command -v seed-image-store.sh >/dev/null 2>&1; then
				seed-image-store.sh seed >/tmp/powbox-image-store-seed.log 2>&1 &
			fi
		else
			rm -f "$HOME/.config/containers/storage.conf"
		fi
	else
		if [ ! -e /dev/fuse ]; then
			echo "Note: /dev/fuse not available; Podman will use the slower vfs storage driver. Pass it through with POWBOX_FUSE=on, or it is auto-detected from the host." >&2
		fi
		printf '[storage]\ndriver = "vfs"\n' >"$HOME/.config/containers/storage.conf"
	fi
	unset _xdg _containers_root _driver_marker _desired_driver _chosen_driver _imgstore
fi

if [ "$#" -eq 0 ]; then
	exec zsh
fi

exec "$@"
