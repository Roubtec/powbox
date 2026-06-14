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
# with remedies, leaving host state untouched. The tree is chowned to node:node bounded
# with `find -xdev` so it stays on the bind mount and does NOT descend into the
# separately mounted, already-node-owned node_modules / .worktrees volumes. -h chowns
# symlinks themselves, never their targets. Idempotent: once the host files are uid 1000
# a later launch's write probe passes and this never runs again. Mirrors
# init-firewall.sh / shadow-mounts.sh: a narrowly scoped, image-immutable,
# sudoers-allowed root helper that refuses to act outside /workspace/.
set -euo pipefail

NODE_OWNER="node:node"

if [ "$#" -eq 0 ]; then
	echo "fix-workspace-perms: no workspace given; nothing to do." >&2
	exit 0
fi

status=0
for ws in "$@"; do
	case "$ws" in
	/workspace/*) ;;
	*)
		echo "fix-workspace-perms: refusing to touch '$ws' (not under /workspace/)." >&2
		status=1
		continue
		;;
	esac
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
		echo "fix-workspace-perms: NOT changing its ownership (that would lock out that host user). Remedies: run powbox as root or as uid 1000, chown the repo to uid 1000 on the host, or use --isolated (self-hosted) mode." >&2
		status=1
		continue
	fi
	echo "fix-workspace-perms: claiming root-owned $ws for $NODE_OWNER so the agent can write it (git, edits) ..." >&2
	# -xdev keeps the chown on the bind mount; the nested node_modules / .worktrees
	# volume mounts are separate filesystems (already node-owned) and are left alone.
	if ! find "$ws" -xdev -print0 2>/dev/null | xargs -0 --no-run-if-empty chown -h "$NODE_OWNER" 2>/dev/null; then
		echo "fix-workspace-perms: warning: could not fully chown $ws; some files may remain unwritable by node." >&2
		status=1
	fi
done
exit "$status"
