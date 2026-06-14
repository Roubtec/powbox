#!/usr/bin/env bash
# fix-workspace-perms.sh — make a dir-mounted workspace writable by the node user.
#
# On a NATIVE-LINUX host the bind-mounted project directory keeps its host uid/gid
# (commonly root's, when the repo lives under /root or is otherwise root-owned). The
# container's agent runs as `node` (uid 1000), so it then cannot write the working
# tree or .git — every state change (git pull/commit/checkout, file edits) fails with
# EACCES, e.g. `error: cannot open '.git/FETCH_HEAD': Permission denied`. The agent is
# `node` and cannot chown root-owned files itself, hence this small root helper.
#
# Windows/WSL masks the problem: its gRPC-FUSE / virtiofs bind mounts honour writes
# from any container uid regardless of the displayed owner. entrypoint-core.sh probes
# write access AS node and only calls this for a workspace node truly cannot write, so
# on Windows/WSL — and on Linux hosts whose mount uid already matches node — it is
# never invoked and there is no needless recursive chown.
#
# Each argument must be a /workspace/<slug> bind mount. We chown ONLY a workspace whose
# root is owned by ROOT (uid 0) — the reported and overwhelmingly common case (a repo
# under /root, or a host that runs powbox as root). Chowning a root-owned tree to node
# is safe: root keeps full host-side access (it bypasses DAC). We deliberately do NOT
# chown a tree owned by some OTHER non-node uid, because that would strip a real,
# non-root host user of ownership of their own repo; that case is warned about instead,
# with remedies, leaving host state untouched. The same protection holds WITHIN a claimed
# tree: the recursive chown matches only root-owned entries (find -uid 0), so a nested
# file/dir owned by some other host uid (e.g. a service user's cache or artifact) keeps
# its owner rather than being silently re-owned to node. The tree is chowned to node:node
# bounded so it stays on the bind mount and does NOT descend into the separately mounted,
# already-node-owned node_modules / .worktrees volumes: each real mountpoint nested under
# the workspace is pruned explicitly (from /proc/self/mountinfo), with `find -xdev` as a
# backstop. -xdev alone is insufficient — it only refuses to cross onto a DIFFERENT
# filesystem, but a Docker volume whose backing store shares the bind-mount source's
# filesystem (e.g. both under / on a native-Linux host) has the SAME st_dev, so -xdev
# would walk straight into it. -h chowns symlinks themselves, never their targets.
# Idempotent: once the host files are uid 1000
# a later launch's write probe passes and this never runs again. Mirrors
# init-firewall.sh / shadow-mounts.sh: a narrowly scoped, image-immutable,
# sudoers-allowed root helper that refuses to act outside /workspace/.
set -euo pipefail

NODE_OWNER="node:node"

# Canonical /workspace root, mirroring shadow-mounts.sh, so a `..`-laden or
# symlinked argument is normalised before the containment check in the loop.
workspace_root="$(realpath /workspace 2>/dev/null || echo /workspace)"

if [ "$#" -eq 0 ]; then
	echo "fix-workspace-perms: no workspace given; nothing to do." >&2
	exit 0
fi

status=0
for ws in "$@"; do
	# Canonicalize first: a raw string prefix check lets `/workspace/../etc` (and
	# symlinked args) slip past a `/workspace/*` glob, and this helper is sudo-
	# allowlisted and node-invokable with arbitrary arguments. Resolve the path, then
	# require it to be a DIRECT child of /workspace — a /workspace/<slug> bind mount,
	# which is all the entrypoint ever passes — so nothing nested or outside the
	# workspace is ever chowned. Mirrors shadow-mounts.sh's realpath containment.
	if ! resolved="$(realpath -m -- "$ws" 2>/dev/null)"; then
		echo "fix-workspace-perms: refusing to touch '$ws' (unable to resolve path)." >&2
		status=1
		continue
	fi
	if [ "$(dirname "$resolved")" != "$workspace_root" ]; then
		echo "fix-workspace-perms: refusing to touch '$ws' (not a /workspace/<slug> bind mount; resolved to '$resolved')." >&2
		status=1
		continue
	fi
	ws="$resolved"
	if [ ! -d "$ws" ]; then
		echo "fix-workspace-perms: '$ws' is not a directory; skipping." >&2
		continue
	fi
	owner_uid="$(stat -c '%u' "$ws" 2>/dev/null || echo "")"
	if [ "$owner_uid" != "0" ]; then
		# Owned by a non-root, non-node host uid (a node-owned tree never reaches here —
		# the entrypoint only passes workspaces node cannot write). Chowning to node
		# would lock that host user out of their own repo, so refuse and explain.
		echo "fix-workspace-perms: $ws is owned by host uid ${owner_uid:-?} (not root) and the agent (uid 1000) cannot write it." >&2
		echo "fix-workspace-perms: NOT changing its ownership (that would lock out that host user). Remedies: chown the repo to uid 1000 (node) on the host, or relaunch in --isolated (self-hosted) mode, which clones into a private node-owned volume instead of bind-mounting this tree." >&2
		status=1
		continue
	fi
	echo "fix-workspace-perms: claiming root-owned $ws for $NODE_OWNER so the agent can write it (git, edits) ..." >&2
	# Keep the chown ON the bind mount and OFF the separately mounted, already-node-owned
	# node_modules / .worktrees / tmpfs volumes nested under it. `find -xdev` is NOT
	# enough on its own (it only refuses to cross onto a DIFFERENT filesystem, and a
	# Docker volume sharing the bind-mount source's filesystem presents the same st_dev),
	# so enumerate the real mountpoints nested under $ws and -prune them explicitly; -xdev
	# stays as a backstop for the genuinely-different-filesystem case.
	prune=()
	while IFS= read -r _mp; do
		case "$_mp" in
		"$ws"/?*) prune+=(-path "$_mp" -prune -o) ;;
		esac
	done < <(awk '{print $5}' /proc/self/mountinfo 2>/dev/null)
	# Restrict the recursive chown to ROOT-owned entries (-uid 0). The gate above only
	# checks $ws itself; a root-owned tree can still hold files/dirs created by another
	# host uid (a service user's caches or artifacts). Chowning those to node would strip
	# that user — exactly what the root-level refusal avoids — so claim only uid-0 entries
	# and leave any foreign-owned ones to their owner. (find still descends through a
	# foreign-owned dir, so root-owned files nested inside it are still claimed.)
	if ! find "$ws" -xdev "${prune[@]}" -uid 0 -print0 2>/dev/null | xargs -0 --no-run-if-empty chown -h "$NODE_OWNER" 2>/dev/null; then
		echo "fix-workspace-perms: warning: could not fully chown $ws; some files may remain unwritable by node." >&2
		status=1
	fi
done
exit "$status"
