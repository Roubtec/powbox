#!/usr/bin/env bash
set -euo pipefail

if command -v sudo >/dev/null 2>&1; then
	sudo /usr/local/bin/init-firewall.sh
else
	/usr/local/bin/init-firewall.sh
fi

# Claude dev-skills plugin (dev-skills@roubtec, the 8 shared skills) — converge it HERE,
# AFTER init-firewall.sh, so its network ops (marketplace add/install/update, all to the
# PUBLIC Roubtec/agent-skills over HTTPS) are ordered after the firewall — and fully
# DETACHED, for EVERY launch, whether Claude is the primary agent or not (the Claude hook
# never touches the plugin).
#
# Detached is a CORRECTNESS requirement, not just latency hygiene: the claude CLI HANGS
# (SIGTERM-immune; only SIGKILL ends it) when invoked with the container TTY as stdin, so
# even a read-only `claude plugin list` on the entrypoint's foreground burned its full
# 30s+5s bound on every start — task 015g's synchronous cold install never survived a TTY
# launch either. So everything plugin-related runs with stdin </dev/null and stdio on the
# log. The bounded, marker-based wait at the END of this script (before the final exec)
# gives the refresh a chance to land before Claude enumerates plugins, so a warm update
# usually applies THIS session; past that cap, on a COLD claude-config volume the FIRST
# session starts without the /dev-skills:* skills until a /reload-plugins or restart, and
# a slow warm update lands one session late (plugins load once at session start).
#
# The log is pointed at Claude's config dir (CLAUDE_CONFIG_DIR is a Dockerfile ENV), which
# for a primary-Claude launch is also the primary's AGENT_CONFIG_DIR. `setsid` reparents
# the detached run past the entrypoint's final `exec`. Best-effort: it must never affect
# startup. APPEND to the log, never truncate: it lives on the claude-config volume, a
# SINGLE named volume shared by EVERY powbox container, so truncation would wipe a PEER
# container's in-progress bootstrap log; the dated, container-tagged separator keeps each
# boot's block easy to find instead.
#
# SKIPPED for the image-store WRITER role: that container is short-lived by design —
# Docker reaps it the moment seed-image-store.sh exits, which would SIGKILL a detached
# plugin install/update MID-MUTATION against the shared claude-config volume (SIGKILL
# also skips the seeder's EXIT trap), racing every peer container's bootstrap and
# risking partial plugin state. The writer needs no skills anyway — it only pulls
# images.
#
# Handshake for entrypoint-claude-hook.sh's build-skew shim: exporting this BEFORE the
# setup-hook call below tells the hook that THIS core owns the plugin bootstrap for
# every launch, so the hook must not. An OLDER base's core (which converged only
# NON-primary Claude, leaving primary Claude to the hook) never sets it — that absence
# is what tells a newer agent layer's hook to cover primary Claude itself. Exported
# unconditionally (not inside the gate below): the hook re-checks the same
# claude/seed-script preconditions, so "core owns it" is true whether or not the gate
# fires.
export POWBOX_PLUGIN_BOOTSTRAP=core
if [ "${POWBOX_IMAGE_STORE_ROLE:-}" != "writer" ] &&
	command -v claude >/dev/null 2>&1 && [ -x /usr/local/bin/seed-claude-plugins.sh ]; then
	_claude_cfg="${CLAUDE_CONFIG_DIR:-/home/node/.claude}"
	_claude_plugin_log="$_claude_cfg/.powbox-plugin-bootstrap.log"
	mkdir -p "$_claude_cfg" 2>/dev/null || true
	# Container-LOCAL done-marker (never the shared volume — a peer's bootstrap must not
	# release our wait). $$ keeps it unique per boot; the rm clears a stale same-pid file.
	_plugin_done="/tmp/.powbox-plugin-bootstrap.$$.done"
	rm -f "$_plugin_done" 2>/dev/null || true
	# stderr first: a failed open of the log itself must stay silent too
	# (redirections apply left-to-right).
	{
		echo "===== $(date -u +%FT%TZ 2>/dev/null || echo '-') core post-firewall Claude plugin bootstrap (${CONTAINER_NAME:-${HOSTNAME:-?}}) ====="
		echo "[core] dev-skills@roubtec plugin: converging post-firewall, detached (log: $_claude_plugin_log)"
	} 2>/dev/null >>"$_claude_plugin_log" || true
	# SC2094: POWBOX_PLUGIN_LOG and the stdio redirect name the same path, but the script
	# only appends to it (never reads), so there is no read/write conflict.
	# stderr first on the launch too: a failed open of the log must stay silent (the
	# spawn is then skipped); on success the trailing 2>&1 re-points the seeder's
	# stderr back into the log.
	if command -v setsid >/dev/null 2>&1; then
		# shellcheck disable=SC2094
		POWBOX_PLUGIN_LOG="$_claude_plugin_log" POWBOX_PLUGIN_DONE_FILE="$_plugin_done" \
			setsid bash /usr/local/bin/seed-claude-plugins.sh </dev/null 2>/dev/null >>"$_claude_plugin_log" 2>&1 &
	else
		# Fallback if setsid is somehow unavailable: still detach from the entrypoint.
		# shellcheck disable=SC2094
		POWBOX_PLUGIN_LOG="$_claude_plugin_log" POWBOX_PLUGIN_DONE_FILE="$_plugin_done" \
			bash /usr/local/bin/seed-claude-plugins.sh </dev/null 2>/dev/null >>"$_claude_plugin_log" 2>&1 &
	fi
	unset _claude_cfg _claude_plugin_log
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

# Claim dir-mounted workspaces the node user cannot write, BEFORE the git/safe.directory
# steps below so they operate on a node-owned tree. On a native-Linux host the bind-mounted
# project keeps its host uid (commonly root's, when the repo lives under /root), leaving the
# agent — which runs as node (uid 1000) — unable to change ANY repo state: git
# pull/commit/checkout and file edits fail with EACCES (e.g. `cannot open '.git/FETCH_HEAD':
# Permission denied`). A subtler mixed-ownership variant — a node-owned root that hides nested
# root-owned files left by a host `sudo git pull` against a live bind mount — is caught too.
#
# The decide-whether-and-how-to-heal logic (the node write probe, the node-owned-root
# nested-uid-0 scan, the mountinfo pruning, and the final `sudo fix-workspace-perms.sh` call)
# is factored into the base-baked /usr/local/bin/heal-workspace-perms.sh so the entrypoint and
# the dir-mount ownership smoke (scripts/smoke-test-dirmount.sh) exercise the IDENTICAL
# decision code — see that script for the full rationale.
#
# Record the project workspace's TRUE absolute host bind-mount source in the per-boot marker
# map BEFORE the heal below reads it. The heal (heal-workspace-perms.sh) AND the privileged
# helper (fix-workspace-perms.sh) classify sensitivity on this recorded true source, using
# /proc/self/mountinfo only as a fallback — which is what lets them refuse a /home/<user> bind
# on a separate-mount layout (where mountinfo field 4 reads back shallow, e.g. /alice) and
# heal a whole-filesystem-mount checkout (where field 4 is a degenerate `/`); see
# sensitive-host-path.sh and tasks/009. The launcher forwards POWBOX_WORKSPACE_DIR (the
# /workspace/<slug> mountpoint) and POWBOX_WORKSPACE_HOST_PATH (its `pwd -P`-resolved host
# source) only in dir-mounted, non-isolated mode, so this no-ops in self-hosted mode (no bind
# to classify) and when the launcher is not involved. Recorded HERE, at trusted startup as
# node, so the FILE survives the helper's later sudo env_reset (an env var would not). Sourcing
# the shared library defines only functions; best-effort — a marker it cannot write just falls
# the consumers back to mountinfo.
if [ -n "${POWBOX_WORKSPACE_DIR:-}" ] && [ -n "${POWBOX_WORKSPACE_HOST_PATH:-}" ]; then
	_shp="$(dirname "$0")/sensitive-host-path.sh"
	[ -r "$_shp" ] || _shp=/usr/local/bin/sensitive-host-path.sh
	# Guard the source: the marker is best-effort, so a missing/unreadable library (it is
	# image-baked, so this is not expected) must never abort container startup under set -e.
	if [ -r "$_shp" ]; then
		# shellcheck source=docker/shared/sensitive-host-path.sh
		# shellcheck disable=SC1091
		. "$_shp"
		powbox_record_workspace_source "$POWBOX_WORKSPACE_DIR" "$POWBOX_WORKSPACE_HOST_PATH"
	fi
	unset _shp
fi

# The self-hosted / image-store-writer / sudo-exists guard stays HERE, around the call, so the
# entrypoint's observable behavior is byte-for-byte unchanged: self-hosted ("--isolated") mode
# is exempt (its workspace is a container-local volume the launcher already pre-seeds
# node-owned) and the detached image-store writer (POWBOX_IMAGE_STORE_ROLE=writer) is exempt
# (it mounts the workspace but NOT the per-container node_modules/.worktrees volumes, so a
# recursive chown there would descend into the host's copies of those dirs — and it never
# writes the workspace anyway). The helper itself also re-checks `command -v sudo` so it
# tolerates being run directly (as the smoke does). Best-effort: the helper logs a warning if
# the claim cannot be completed.
if [ "${POWBOX_SELF_HOSTED:-}" != "1" ] && [ "${POWBOX_IMAGE_STORE_ROLE:-}" != "writer" ] && command -v sudo >/dev/null 2>&1; then
	/usr/local/bin/heal-workspace-perms.sh
fi

# Mark workspace bind-mounts as git safe directories. Host-owned project
# directories under /workspace/ have a different UID than the container's
# 'node' user, which triggers git's dubious-ownership check.
# This step is best-effort: a warning is logged if the config is not writable.
# Redirect stderr first so a failed open of the target does not leak a raw
# shell error before 2>/dev/null takes effect (redirections apply left-to-right).
if ! : 2>/dev/null >>"$GIT_CONFIG_GLOBAL"; then
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
		# Route SSH-form GitHub remotes through HTTPS so the gh credential helper
		# above authenticates them — host-mounted repos often carry an SSH origin,
		# and the container has no SSH keys. Both the scp-style (git@github.com:…)
		# and ssh:// (ssh://git@github.com/…) forms are rewritten to the same
		# https://github.com/ base; the ssh:// form also covers a self-hosted clone
		# whose --repo/origin is an ssh:// URL. Because the two map to one base they
		# are values of one multi-valued insteadOf key — reset-then-add keeps it
		# idempotent across container restarts (a plain `git config <key> <value>`
		# errors once the key holds multiple values). Written only to the
		# container-local GIT_CONFIG_GLOBAL; the host repo's remote URL is untouched.
		git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
		if ! git config --global --add url."https://github.com/".insteadOf "git@github.com:" ||
			! git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"; then
			echo "Warning: failed to configure SSH→HTTPS rewrite for GitHub remotes; continuing." >&2
		fi
	fi
fi

# Self-hosted ("--isolated") mode: clone the repo into the per-instance workspace
# volume. Runs AFTER gh auth (above) so a private clone has credentials, and BEFORE
# the shadow/pnpm steps below. On any clone failure seed-workspace.sh announces the
# remedies (loudly) and exits non-zero; we then drop to a plain zsh rather than
# execing the agent into an empty workspace — no retry by design. A no-op when not
# self-hosted (including the image-store writer role).
if [ "${POWBOX_SELF_HOSTED:-}" = "1" ]; then
	if ! /usr/local/bin/seed-workspace.sh; then
		exec zsh
	fi
fi

# Shadow nested node_modules in monorepo workspaces with tmpfs so that
# container-native (Linux) binaries never mix with host-native binaries.
# The root node_modules is already shadowed by a Docker volume mount;
# this covers subpackage directories detected from pnpm-workspace.yaml,
# package.json workspaces, or .powbox.yml.  See README.md for details.
#
# One declared shadow is special-cased inside shadow-mounts.sh: .git/worktrees is
# BIND-mounted from the persistent .worktrees volume's .gitworktrees subdir (not
# tmpfs) when that volume is present, so linked-worktree git metadata survives a
# container recycle alongside the working trees it describes (task 017); it falls
# back to tmpfs when no persistent .worktrees volume is mounted. The loop here is
# unchanged — the mount-kind decision lives in the one privileged helper.
#
# Skipped entirely in self-hosted mode: there is no host filesystem to shadow (the
# whole workspace is one container-local volume), and a tmpfs over a subpackage's
# node_modules would break the hardlinking that the single-volume layout exists to
# enable (the store and every node_modules already share one mount).
#
# Also skipped for the image-store WRITER role: that short-lived container mounts the
# host workspace BIND (compose.shared.yml) but NOT the agent-nm-*/agent-wt-* volumes,
# so here $_dir/node_modules is the host checkout's own tree. Shadowing it (and, worse,
# deleting its .pnpm-workspace-state-v1.json below) would churn host-side pnpm state on
# every fuse-enabled launch — and the writer only needs egress + a Podman that can pull.
if [ "${POWBOX_SELF_HOSTED:-}" != "1" ] && [ "${POWBOX_IMAGE_STORE_ROLE:-}" != "writer" ]; then
	for _dir in /workspace/*/; do
		[ -d "$_dir" ] || continue
		_dir="${_dir%/}"
		mapfile -t _targets < <(detect-shadows.sh "$_dir" 2> >(grep -Fx 'detect-shadows: shadow list overridden by .powbox.local.yml' >&2 || true) || true)
		if [ "${#_targets[@]}" -gt 0 ]; then
			if sudo --preserve-env=SHADOW_TMPFS_SIZE /usr/local/bin/shadow-mounts.sh "${_targets[@]}"; then
				# The subpackage node_modules just (re)mounted above are ephemeral tmpfs:
				# empty at every container start. The ROOT node_modules, however, is a
				# persistent named volume, so it still carries pnpm's workspace-state
				# cache (node_modules/.pnpm-workspace-state-v1.json) from a prior
				# lifecycle. With that cache present and the lockfile unchanged, EVERY
				# flavor of `pnpm install` (--frozen-lockfile, --force, ...) short-circuits
				# to "Already up to date" and never relinks the now-empty subpackage
				# shadows — so vitest/tsc/eslint/next and friends fail to resolve, and no
				# reinstall repairs it. The cache is stale BY CONSTRUCTION here (the shadows
				# it claims are populated were just wiped), so drop it: the agent's next
				# natural `pnpm install` then does a real, relinking install. We deliberately
				# do NOT run an install ourselves — many sessions never build/test (or never
				# touch a repo at all), so forcing one at start would be wasted work.
				#
				# Gated on at least one shadow being a subpackage */node_modules: detect-shadows.sh
				# can also return non-node_modules custom shadows (.worktrees, .git/worktrees,
				# .claude/worktrees from .powbox.yml). A repo whose shadows are ALL non-node_modules
				# (e.g. a single-package repo that only opts into worktree shadows) has no
				# empty-shadow trap, so dropping its root workspace-state cache would just force a
				# needless relink on the next install. The empty-shadow trap can only arise when a
				# subpackage node_modules was wiped, so key the invalidation on exactly that. Also
				# gated on the mount succeeding so we never clobber state on a host tree that went
				# un-shadowed (e.g. missing mount capability).
				_has_nm_shadow=false
				for _t in "${_targets[@]}"; do
					case "$_t" in */node_modules)
						_has_nm_shadow=true
						break
						;;
					esac
				done
				# Final gate: the ROOT node_modules must itself be a mounted volume. The
				# invalidation is safe ONLY because that root is the PERSISTENT named
				# volume carrying a stale workspace-state cache across lifecycles. If it is
				# NOT a mountpoint — a legacy/misconfigured launch with no agent-nm-* volume,
				# so $_dir/node_modules is the host checkout's own tree — dropping its cache
				# would churn host-side pnpm state, the same harm the writer-role skip avoids.
				if [ "$_has_nm_shadow" = true ] && mountpoint -q "$_dir/node_modules" 2>/dev/null; then
					rm -f "$_dir/node_modules/.pnpm-workspace-state-v1.json"
				fi
			else
				echo "Warning: failed to shadow workspace directories in $_dir; continuing." >&2
			fi
		fi
	done
	unset _dir _targets _t _has_nm_shadow
fi

# Co-locate the pnpm store with the per-container worktrees volume so that
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

# Pre-create the Go caches and the ccache compiler cache when the launcher
# pointed them into the persistent worktrees mount (GOMODCACHE/GOCACHE/CCACHE_DIR
# env — the PNPM_STORE_DIR precedent above; set for dir-mounted JS/powbox/Go
# projects and in self-hosted mode, omitted for non-dev folders so nothing is
# mkdir-ed onto a host bind mount). Plain env is all `go`/`ccache` need — no
# `go env -w`, no ccache config — so this mkdir only surfaces a bad value LOUDLY
# at startup instead of as a confusing mid-session build failure. Guarded so a
# bad value never aborts the container start: on failure the var is unset (the
# exec'd agent inherits the cleared env), so the tool falls back to its
# image-default, container-ephemeral cache path and keeps working.
for _cache_var in GOMODCACHE GOCACHE CCACHE_DIR; do
	_cache_dir="${!_cache_var:-}"
	[ -n "$_cache_dir" ] || continue
	if ! mkdir -p "$_cache_dir" 2>/dev/null; then
		echo "Warning: cannot create cache dir $_cache_dir; unsetting ${_cache_var} so its tool falls back to the image-default cache path." >&2
		unset "$_cache_var"
	fi
done
unset _cache_var _cache_dir

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

	# Dedicated image-store seeder (launch-agent.{sh,ps1} runs a short-lived,
	# detached writer container with POWBOX_IMAGE_STORE_ROLE=writer). It runs
	# seed-image-store.sh against the shared store as its PRIMARY `--root`, so
	# listing that same path under additionalimagestores would be circular. Use
	# Podman's built-in overlay default (no storage.conf) and skip the consumer
	# driver-pinning dance entirely; the seeder script forces the overlay driver.
	if [ "${POWBOX_IMAGE_STORE_ROLE:-}" = "writer" ]; then
		rm -f "$HOME/.config/containers/storage.conf"
		if [ "$#" -eq 0 ]; then
			exec zsh
		fi
		exec "$@"
	fi

	# Storage driver: fuse-overlayfs needs /dev/fuse; without it Podman uses the
	# slower vfs driver. The driver is baked into the persistent graphroot on
	# first use, and Podman requires `podman system reset` before changing
	# storage.conf's `driver`, so silently flipping it when /dev/fuse availability
	# changes (moved host, POWBOX_PODMAN toggled, outer container recreated) would
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
			if [ "$_chosen_driver" = "overlay" ] && [ ! -e /dev/fuse ]; then
				# Overlay was pinned but /dev/fuse is now gone (moved host,
				# POWBOX_PODMAN=off, outer container recreated). Overlay needs
				# fuse-overlayfs, so Podman is NON-FUNCTIONAL until the store is
				# reset — flag it loudly rather than implying a mere slowdown.
				echo "Warning: Podman storage was initialised with the 'overlay' driver but /dev/fuse is not available now, so rootless Podman will FAIL until the store is reset. Run 'podman system reset' (or drop this project's agent-podman-* volume) and relaunch to reinitialise on 'vfs' — or restore /dev/fuse (POWBOX_PODMAN=on)." >&2
			else
				echo "Note: Podman storage was initialised with the '$_chosen_driver' driver; keeping it (current /dev/fuse state would pick '$_desired_driver'). Changing drivers needs a clean store — run 'podman system reset' (or drop this project's agent-podman-* volume) and relaunch to switch to '$_desired_driver'." >&2
			fi
		fi
		;;
	*)
		_chosen_driver="$_desired_driver"
		;;
	esac
	# Best-effort record of the committed driver for subsequent launches.
	mkdir -p "$_containers_root" 2>/dev/null || true
	# stderr redirected first so a failed marker open leaks nothing to stderr.
	printf '%s\n' "$_chosen_driver" 2>/dev/null >"$_driver_marker" || true

	if [ "$_chosen_driver" = "overlay" ]; then
		# Overlay path — the CONSUMER (read) side. The image ships no system
		# storage.conf, so Podman uses its built-in rootless defaults (overlay +
		# auto-selected fuse-overlayfs). When the global image store is mounted
		# (READ-ONLY here — a dedicated detached writer is what populates it), write a
		# storage.conf that keeps overlay AND layers that store on top via
		# additionalimagestores. The store is only referenced on overlay: its driver
		# must match the consumer's, and a vfs consumer never sees it (see the vfs
		# branch). Drop any stale override when the store isn't mounted and fall back
		# to the built-in default.
		_imgstore="/mnt/podman-imagestore"
		if [ -d "$_imgstore" ]; then
			# additionalimagestores wants the graphroot (the bare mount dir), NOT a
			# driver subdir — verified on overlay and vfs (see
			# docs/podman-shared-image-store.md). No mount_program is set on purpose:
			# rootless Podman auto-selects fuse-overlayfs here just as it does with
			# the built-in default (the image has no system storage.conf).
			printf '[storage]\ndriver = "overlay"\n\n[storage.options]\nadditionalimagestores = ["%s"]\n' \
				"$_imgstore" >"$HOME/.config/containers/storage.conf"
		else
			rm -f "$HOME/.config/containers/storage.conf"
		fi
	else
		if [ ! -e /dev/fuse ]; then
			echo "Note: /dev/fuse not available; Podman will use the slower vfs storage driver. Pass it through with POWBOX_PODMAN=on, or it is auto-detected from the host." >&2
		fi
		printf '[storage]\ndriver = "vfs"\n' >"$HOME/.config/containers/storage.conf"
	fi
	unset _xdg _containers_root _driver_marker _desired_driver _chosen_driver _imgstore
fi

# Bounded best-effort wait for the detached plugin bootstrap (primary Claude only —
# a Codex prompt never uses the Claude plugin, so it should not wait for it). Claude
# enumerates plugins ONCE at session start, so letting the (typically ~2-3s) refresh
# finish BEFORE the exec means updated skills usually apply THIS session instead of one
# session late. The wait sits HERE, at the end of startup, so the refresh overlaps all
# the setup above and the typical added latency is well under the cap. Strictly bounded
# and marker-based: we never wait ON the claude CLI (it can hang SIGTERM-immune on a
# TTY — see the plugin block at the top), only poll for the done-marker the detached
# run's EXIT trap touches; past the cap we proceed on the volume's current plugin state
# (the refresh still lands for the next session). A cold-volume install usually
# outlives the cap — that first session needs /reload-plugins, as documented.
# POWBOX_PLUGIN_WAIT tunes the cap in whole seconds; 0 disables the wait.
if [ -n "${_plugin_done:-}" ] && [ "${PRIMARY_AGENT:-claude}" = claude ]; then
	_plugin_wait="${POWBOX_PLUGIN_WAIT:-4}"
	case "$_plugin_wait" in
	*[!0-9]* | '') _plugin_wait_ticks=40 ;;             # non-numeric override: fall back to the 4s default
	*) _plugin_wait_ticks=$((10#$_plugin_wait * 10)) ;; # 10# so a leading zero can't trip octal parsing
	esac
	while [ "$_plugin_wait_ticks" -gt 0 ] && [ ! -e "$_plugin_done" ]; do
		sleep 0.1
		_plugin_wait_ticks=$((_plugin_wait_ticks - 1))
	done
	rm -f "$_plugin_done" 2>/dev/null || true
	unset _plugin_done _plugin_wait _plugin_wait_ticks
fi

if [ "$#" -eq 0 ]; then
	exec zsh
fi

exec "$@"
