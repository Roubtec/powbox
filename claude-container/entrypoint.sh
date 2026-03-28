#!/usr/bin/env bash
set -euo pipefail

# Apply firewall
if command -v sudo >/dev/null 2>&1; then
  sudo /usr/local/bin/init-firewall.sh
else
  /usr/local/bin/init-firewall.sh
fi

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/home/node/.claude}"
CLAUDE_HOST_SEED_DIR="${CLAUDE_HOST_SEED_DIR:-/home/node/.claude-host}"
GH_CONFIG_DIR="${GH_CONFIG_DIR:-/home/node/.config/gh}"
GH_HOST_SEED_DIR="${GH_HOST_SEED_DIR:-/home/node/.config/gh-host}"

mkdir -p "$CLAUDE_CONFIG_DIR"
mkdir -p "$GH_CONFIG_DIR"

# Seed the persistent Claude config volume from a host config directory on the
# first run only. Subsequent runs keep the Docker-managed state untouched.
if [ -d "$CLAUDE_HOST_SEED_DIR" ] \
  && [ -n "$(find "$CLAUDE_HOST_SEED_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] \
  && [ ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
  cp -an "$CLAUDE_HOST_SEED_DIR"/. "$CLAUDE_CONFIG_DIR"/
  chmod 700 "$CLAUDE_CONFIG_DIR" || true
  if [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
    chmod 600 "$CLAUDE_CONFIG_DIR/.credentials.json" || true
  fi
fi

# Seed the persistent GitHub CLI config volume from a host config directory on
# the first run only. Subsequent runs keep the Docker-managed state untouched.
if [ -d "$GH_HOST_SEED_DIR" ] \
  && [ -n "$(find "$GH_HOST_SEED_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] \
  && [ ! -f "$GH_CONFIG_DIR/hosts.yml" ]; then
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
  : > "$GIT_CONFIG_GLOBAL"
fi

# Keep the container-wide CLAUDE.md in sync with the image on every startup.
if [ -f /home/node/.claude-container/CLAUDE.md ]; then
  cp /home/node/.claude-container/CLAUDE.md "$CLAUDE_CONFIG_DIR/CLAUDE.md"
fi

# If gh is authenticated, register it as the git credential helper
if command -v gh >/dev/null 2>&1 && gh auth status &>/dev/null; then
  if ! (cd "$HOME" && gh auth setup-git); then
    echo "Warning: gh auth is present, but git credential helper setup failed; continuing without automatic gh git integration." >&2
  fi
fi

if [ "$#" -eq 0 ]; then
  exec zsh
fi

exec "$@"
