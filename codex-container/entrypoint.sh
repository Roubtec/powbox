#!/usr/bin/env bash
set -euo pipefail

# Apply firewall
if command -v sudo >/dev/null 2>&1; then
  sudo /usr/local/bin/init-firewall.sh
else
  /usr/local/bin/init-firewall.sh
fi

CODEX_CONFIG_DIR="${CODEX_CONFIG_DIR:-/home/node/.codex}"
CODEX_HOST_SEED_DIR="${CODEX_HOST_SEED_DIR:-/home/node/.codex-host}"
GH_CONFIG_DIR="${GH_CONFIG_DIR:-/home/node/.config/gh}"
GH_HOST_SEED_DIR="${GH_HOST_SEED_DIR:-/home/node/.config/gh-host}"

mkdir -p "$CODEX_CONFIG_DIR"
mkdir -p "$GH_CONFIG_DIR"

# Seed the persistent Codex config volume from a host config directory on the
# first run only. Subsequent runs keep the Docker-managed state untouched.
if [ -d "$CODEX_HOST_SEED_DIR" ] \
  && [ -n "$(find "$CODEX_HOST_SEED_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] \
  && [ ! -f "$CODEX_CONFIG_DIR/config.toml" ]; then
  cp -an "$CODEX_HOST_SEED_DIR"/. "$CODEX_CONFIG_DIR"/
  chmod 700 "$CODEX_CONFIG_DIR" || true
  if [ -f "$CODEX_CONFIG_DIR/config.toml" ]; then
    chmod 600 "$CODEX_CONFIG_DIR/config.toml" || true
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

# Keep the container-wide AGENTS.md in sync with the image on every startup.
if [ -f /home/node/.codex-container/AGENTS.md ]; then
  cp /home/node/.codex-container/AGENTS.md "$CODEX_CONFIG_DIR/AGENTS.md"
fi

# If gh is authenticated, register it as the git credential helper
if command -v gh >/dev/null 2>&1 && gh auth status &>/dev/null; then
  if ! (cd "$HOME" && gh auth setup-git); then
    echo "Warning: gh auth is present, but git credential helper setup failed; continuing without automatic gh git integration." >&2
  fi
fi

# Warn if OPENAI_API_KEY is not set
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "Warning: OPENAI_API_KEY is not set. Codex CLI will not be able to authenticate with OpenAI." >&2
  echo "Pass it via: -e OPENAI_API_KEY=\$OPENAI_API_KEY when launching the container." >&2
fi

if [ "$#" -eq 0 ]; then
  exec zsh
fi

exec "$@"
