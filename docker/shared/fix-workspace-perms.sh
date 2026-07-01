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
# Each argument must be a /workspace/<slug> bind mount. We act when the workspace root is
# owned by ROOT (uid 0) — the reported and overwhelmingly common case (a repo under /root,
# or a host that runs powbox as root) — OR by NODE (uid 1000) itself: a node-owned root can
# still hide nested root-owned files when a host operation ran as root against the bind
# mount WHILE the container existed (most often a `sudo git pull` on native Linux, which
# re-owns to uid 0 exactly the paths it writes — new/updated .git/objects/*, refs, and the
# changed working-tree files — leaving the top dir node-owned). Chowning root-owned entries
# to node is safe: root keeps full host-side access (it bypasses DAC). Both cases reduce to
# a single re-own of `find -uid 0` entries — for a root-owned root that is the whole tree;
# for a node-owned root it is just the nested uid-0 entries (the root, already node, is
# untouched). We deliberately do NOT chown a tree whose root is owned by some OTHER, non-node
# uid, because that would strip a real, non-root host user of ownership of their own repo;
# that case is warned about instead, with remedies, leaving host state untouched. The same
# protection holds WITHIN a claimed tree: the recursive chown matches only root-owned entries
# (find -uid 0), so a nested file/dir owned by some other host uid (e.g. a service user's
# cache or artifact) keeps its owner rather than being silently re-owned to node. The tree is chowned to node:node
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

# Shared sensitive-host-path predicate (also sourced by heal-workspace-perms.sh). Baked
# beside this script in the image; the repo copy is the fallback for a direct dev run.
_shp="$(dirname "$0")/sensitive-host-path.sh"
[ -r "$_shp" ] || _shp=/usr/local/bin/sensitive-host-path.sh
# shellcheck source=docker/shared/sensitive-host-path.sh
. "$_shp"

NODE_OWNER="node:node"
# node's uid, used to tell apart a node-owned root (which we may still self-heal of nested
# root-owned files) from a genuine foreign host uid (which we refuse). Falls back to the
# well-known 1000 if the lookup ever fails.
NODE_UID="$(id -u node 2>/dev/null || echo 1000)"

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
	# SAFETY BACKSTOP (the VPS-lockout incident): refuse to chown a workspace whose HOST
	# bind-mount source is a system or home directory (/, /root, /home/<user>, /etc, ...).
	# A `cc`/`cx` launched by mistake from ~ bind-mounts the whole home tree as the
	# "project"; re-owning it to node breaks sshd's StrictModes chain on ~/.ssh and locks
	# the user out of the host. Classify on the launcher's TRUE absolute source via
	# powbox_resolve_host_src: (1) the startup marker map (/run/powbox/workspace-sources),
	# written per mountpoint from the launcher's `pwd -P`-resolved host path by the un-sudo'd
	# trusted startup — so it survives this helper's sudo env_reset (a FILE, not an env var)
	# and is the real absolute path on every mount layout; (2) /proc/self/mountinfo as the
	# fallback when no marker was recorded (a direct call in a container the launcher did not
	# set up). Preferring the marker fixes task 009 Gap A: on a separate-mount layout a
	# /home/alice bind reads back from mountinfo field 4 as the shallow /alice and slips past
	# the predicate, but its recorded true source /home/alice is caught. The heal layer
	# (heal-workspace-perms.sh) is still the AUTHORITATIVE, first-line guard on the automatic
	# path (it skips a sensitive mount before ever calling this helper); this remains a
	# best-effort, defense-in-depth re-check for a DIRECT `sudo fix-workspace-perms.sh`.
	host_src="$(powbox_resolve_host_src "$ws")"
	# Fail CLOSED when the source cannot be determined. In production every /workspace/<slug>
	# is a real bind mount recorded in the marker map (or at least present in
	# /proc/self/mountinfo), so the resolved source is non-empty; an empty result means we
	# could confirm neither — so we cannot prove the source is NOT a system/home dir. A wrong
	# refuse here is a loud, recoverable inconvenience (node cannot write a genuine project); a
	# wrong chown can brick host login — so refuse rather than proceed blind. The heal path is
	# unaffected: it only ever hands us real bind mounts, whose source resolves non-empty.
	if [ -z "$host_src" ]; then
		echo "fix-workspace-perms: refusing to chown $ws — could not determine its host bind-mount source (no marker-map entry and no matching /proc/self/mountinfo mount), so cannot confirm it is a project checkout rather than a system or home directory. Refusing as a safety precaution (a wrong chown could break host login, e.g. SSH via a re-owned ~/.ssh)." >&2
		status=1
		continue
	fi
	# Pass POWBOX_WORKSPACE_HOST_HOME (the launcher's physically-resolved $HOME) as the
	# predicate's optional home arg so a home at a NON-standard location still classifies
	# sensitive. Under sudo's env_reset it is empty (the resolved marker/mountinfo source is
	# then the only signal, exactly as described above); it can only ever ADD a refusal
	# (fail-closed), never permit a chown, so honouring a caller-provided value here is safe.
	if powbox_is_sensitive_host_path "$host_src" "${POWBOX_WORKSPACE_HOST_HOME:-}"; then
		echo "fix-workspace-perms: refusing to chown $ws — its host bind-mount source (${host_src}) is a system or home directory, not a project checkout. Re-owning it to node could break host login (e.g. SSH via a re-owned ~/.ssh). Mount a project subdirectory instead, or use --isolated (self-hosted) mode." >&2
		status=1
		continue
	fi
	owner_uid="$(stat -c '%u' "$ws" 2>/dev/null || echo "")"
	if [ "$owner_uid" != "0" ] && [ "$owner_uid" != "$NODE_UID" ]; then
		# Owned by a non-root, non-node host uid. Chowning to node would lock that host
		# user out of their own repo, so refuse and explain. (A root-owned root is the
		# common native-Linux case; a node-owned root is the mixed-ownership case — a
		# host `sudo git pull` left the top dir node-owned but some nested entries uid 0
		# — and is handled below by the same uid-0-only re-own.)
		echo "fix-workspace-perms: $ws is owned by host uid ${owner_uid:-?} (neither root nor node) and the agent (uid ${NODE_UID}) cannot safely claim it." >&2
		echo "fix-workspace-perms: NOT changing its ownership (that would lock out that host user). Remedies: chown the repo to uid ${NODE_UID} (node) on the host, or relaunch in --isolated (self-hosted) mode, which clones into a private node-owned volume instead of bind-mounting this tree." >&2
		status=1
		continue
	fi
	if [ "$owner_uid" = "0" ]; then
		echo "fix-workspace-perms: claiming root-owned $ws for $NODE_OWNER so the agent can write it (git, edits) ..." >&2
	else
		echo "fix-workspace-perms: $ws root is node-owned but contains nested root-owned entries (e.g. from a host 'sudo git pull'); claiming those uid-0 entries for $NODE_OWNER ..." >&2
	fi
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
