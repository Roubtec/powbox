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

	# Ignore file-mode (chmod) differences between the container and the
	# host filesystem.  Windows hosts in particular report every file as
	# executable, which causes noisy diffs and accidental mode-change
	# commits when working from inside the container.
	git config --global core.filemode false || true
fi

# If gh is authenticated, register it as the git credential helper.
if command -v gh >/dev/null 2>&1 && gh auth status &>/dev/null; then
	if ! (cd "$HOME" && gh auth setup-git); then
		echo "Warning: gh auth is present, but git credential helper setup failed; continuing without automatic gh git integration." >&2
	fi
fi

if [ "$#" -eq 0 ]; then
	exec zsh
fi

exec "$@"
