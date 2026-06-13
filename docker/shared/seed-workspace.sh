#!/usr/bin/env bash
# seed-workspace.sh — clone the repo into the per-instance workspace volume for
# self-hosted ("--isolated") launches.
#
# In self-hosted mode the launcher mounts an EMPTY per-instance named volume at the
# workspace path instead of bind-mounting a host directory; this script makes the
# container fetch the repo into it ITSELF. entrypoint-core.sh calls it AFTER gh auth
# is established (so a private clone has credentials) and BEFORE the shadow/pnpm
# steps. The egress model is push / PR — the host never sees the working tree.
#
# Inputs (env, set by the launcher at container creation; frozen for the container's
# life, which is why --reclone recreates the container):
#   POWBOX_SELF_HOSTED   "1" enables this script; anything else is a no-op (exit 0)
#   POWBOX_CLONE_REPO    repo spec — an owner/repo slug or a clone URL (required)
#   POWBOX_CLONE_REF     optional branch/tag to start on (default: the repo default)
#   POWBOX_RECLONE       "1" wipes the existing checkout and re-clones
#   POWBOX_WORKSPACE_DIR target dir (the workspace mount); defaults to $PWD
#
# Reuse semantics: clone once on first creation; on a restart of a named container,
# an existing .git means the agent already owns its branches/worktrees, so the tree
# is left exactly as it was (skip). --reclone is the explicit "wipe and re-seed"
# escape hatch; it re-clones into the cleaned dir (the volume itself is kept).
#
# By DESIGN there is no clone/auth failsafe and no retry: gh auth is a one-time
# manual setup that holds until the token expires. On any clone failure this prints
# a loud, unmissable announcement of the three remedies and exits non-zero;
# entrypoint-core.sh then drops to a plain zsh rather than execing the agent into an
# empty workspace. The fix is done once and never again until the token expires.
set -euo pipefail

# Not self-hosted → nothing to do. Lets entrypoint-core call this unconditionally.
[ "${POWBOX_SELF_HOSTED:-}" = "1" ] || exit 0

WS="${POWBOX_WORKSPACE_DIR:-$PWD}"
REPO="${POWBOX_CLONE_REPO:-}"
REF="${POWBOX_CLONE_REF:-}"
RECLONE="${POWBOX_RECLONE:-0}"

# Resolve a clone URL from an owner/repo slug or a full URL, for display + cloning.
clone_url() {
	case "$1" in
	*://* | git@*) printf '%s' "$1" ;;
	*) printf 'https://github.com/%s.git' "${1%.git}" ;;
	esac
}

announce_failure() {
	local url="$1"
	cat >&2 <<EOF

================================================================================
  POWBOX SELF-HOSTED CLONE FAILED
================================================================================
  Could not clone the repository into this container's private workspace:

      repo:   ${REPO:-(unset)}
      url:    ${url}
      target: ${WS}

  This is almost always because GitHub CLI (gh) is not authenticated in the
  shared agent-gh-config volume, so a private clone has no credentials.

  No agent was started. You are now in a plain shell. Pick ONE remedy:

    1. Use NORMAL (dir-mounted) mode instead — drop --isolated and launch
       against a host checkout.

    2. Fix it ONCE, here, in this shell:
           gh auth login
       then exit and relaunch the same --isolated command (it clones again).

    3. Seed the shared agent-gh-config volume from a machine that is already
       authenticated.

  gh auth is a one-time setup that holds until the token expires; there is no
  retry loop by design.
================================================================================

EOF
}

URL="$(clone_url "$REPO")"

if [ -z "$REPO" ]; then
	echo "seed-workspace: POWBOX_SELF_HOSTED=1 but POWBOX_CLONE_REPO is empty." >&2
	announce_failure "$URL"
	exit 1
fi

mkdir -p "$WS"

# --reclone: wipe the working tree (keep the volume mount) before re-seeding.
if [ "$RECLONE" = "1" ] && [ -e "$WS/.git" ]; then
	echo "seed-workspace: --reclone — wiping $WS before re-cloning." >&2
	find "$WS" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
fi

# Reuse: an existing checkout is left exactly as the agent left it.
if [ -e "$WS/.git" ]; then
	echo "seed-workspace: existing checkout in $WS — reusing it (skipping clone)." >&2
	exit 0
fi

echo "seed-workspace: cloning $URL into $WS ..." >&2
clone_args=(clone)
[ -n "$REF" ] && clone_args+=(--branch "$REF")
clone_args+=("$URL" "$WS")

if git "${clone_args[@]}"; then
	echo "seed-workspace: clone complete." >&2
	exit 0
fi

echo "seed-workspace: clone FAILED (exit $?)." >&2
announce_failure "$URL"
exit 1
