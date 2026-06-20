#!/usr/bin/env bash
set -euo pipefail

# heal-workspace-perms.sh — the extracted entrypoint workspace perms-heal DECISION step.
#
# This is the "decide WHETHER and WITH WHAT path/sudo mechanism to call
# fix-workspace-perms.sh" logic that used to live inline in entrypoint-core.sh (the node
# write probe + the node-owned-root nested-uid-0 scan + the mountinfo pruning + the final
# `sudo /usr/local/bin/fix-workspace-perms.sh "${_unwritable[@]}"` call). It is baked into
# the BASE image — alongside fix-workspace-perms.sh — so that BOTH the entrypoint AND the
# dir-mount ownership smoke (scripts/smoke-test-dirmount.sh) invoke the IDENTICAL decision
# code. The smoke therefore guards the genuine probe/scan/heal decision path, not a
# hand-rolled re-implementation: a regression confined to this decision logic (the probe
# stops detecting an unwritable mount, the workspace stops being added to _unwritable, the
# helper stops being invoked or is invoked with a wrong path) is now caught by the smoke.
#
# It runs AS node, iterating /workspace/*/ exactly as the inline block did.
#
# GUARD PLACEMENT (deliberate, for byte-for-byte entrypoint equivalence): the
# self-hosted / image-store-writer / sudo-exists guard that wrapped the inline block stays in
# entrypoint-core.sh AROUND the call to this helper, so the entrypoint only invokes it when
# not self-hosted, not the writer role, and sudo exists — the entrypoint's observable
# behavior is unchanged. This helper ADDITIONALLY tolerates being run directly: the smoke
# invokes it with `--user node` where POWBOX_SELF_HOSTED / POWBOX_IMAGE_STORE_ROLE are unset
# and sudo exists, so it must run its full probe/scan/heal path in that environment. Its only
# privileged action is `sudo fix-workspace-perms.sh`, so it re-checks `command -v sudo` and
# no-ops when sudo is absent — keeping it safe to run directly anywhere.
#
# Claim dir-mounted workspaces the node user cannot write. On a native-Linux host the
# bind-mounted project keeps its host uid (commonly root's, when the repo lives under
# /root), leaving the agent — which runs as node (uid 1000) — unable to change ANY
# repo state: git pull/commit/checkout and file edits fail with EACCES (e.g.
# `cannot open '.git/FETCH_HEAD': Permission denied`). We hand such a workspace to node
# via the fix-workspace-perms.sh sudo helper — but only when its root is owned by root
# (uid 0) or node (uid 1000); the helper refuses and warns for any other foreign host uid
# rather than locking a real user out of their own repo.
#
# Two triggers feed the same helper:
#   (a) the root-level WRITE PROBE below catches an all-root-owned mount (node cannot even
#       write the top dir); and
#   (b) a nested-uid-0 SCAN catches the mixed-ownership case the probe misses — a node-owned
#       root that nonetheless hides root-owned files. That arises when a host operation runs
#       as root against the bind mount WHILE the container exists (most often `sudo git
#       pull`): it re-owns to uid 0 exactly the paths it writes (new/updated .git/objects/*,
#       refs, the changed working-tree files) but leaves the top dir node-owned, so the probe
#       passes yet `git commit`/`add` still fails with `insufficient permission for adding an
#       object to repository database`. The scan short-circuits (find -uid 0 -print -quit) and
#       prunes the nested node-owned volume mounts exactly as the helper does, so a clean
#       (node-owned, no uid-0) workspace pays only for one find that stops at the first hit.
# The helper re-owns ONLY uid-0 entries in both cases, so a genuine non-root host uid is
# never touched.
#
# The entrypoint calls this BEFORE its git/safe.directory steps so they operate on a
# node-owned tree. It is gated on a real write probe / the uid-0 scan (done here, as node),
# so it is a no-op on Windows/WSL — whose FUSE bind mounts already honour node's writes —
# and on Linux hosts whose mount uid already matches node with no nested uid-0 entries;
# neither pays for a recursive chown. Self-hosted ("--isolated") mode and the detached
# image-store writer are exempt via the entrypoint-side guard described above. Best-effort:
# a warning is logged if the claim cannot be completed.

# Tolerate being run directly: the only privileged action below is the sudo call to
# fix-workspace-perms.sh, so no-op when sudo is absent. When the entrypoint invokes this the
# surrounding guard already required sudo, so this is a redundant safety check there.
command -v sudo >/dev/null 2>&1 || exit 0

_unwritable=()
for _dir in /workspace/*/; do
	[ -d "$_dir" ] || continue
	_dir="${_dir%/}"
	# Probe write access as node by actually creating a file: `[ -w ]` only reads
	# the mode bits, which can disagree with what the host FS truly permits (e.g.
	# Docker Desktop's FUSE), so a real write is the ground truth. Use mktemp rather
	# than a fixed `: >.powbox-write-probe.$PID`: that predictable name lives in a
	# workspace dir we do not yet trust, so a planted symlink/collision could make
	# the probe follow it and truncate the target as node — or report a false
	# "unwritable" if the name pre-exists unwritable. mktemp creates a freshly,
	# randomly named file with O_EXCL: it never clobbers or follows an existing path
	# and succeeds only on a genuinely writable directory.
	if _probe="$(mktemp "${_dir}/.powbox-write-probe.XXXXXX" 2>/dev/null)"; then
		rm -f "$_probe" || echo "Warning: could not remove write-probe file $_probe; continuing." >&2
		# The root is node-writable, but the mixed-ownership case (see the block comment:
		# a host `sudo git pull` re-owning nested paths to uid 0 while the top dir stays
		# node-owned) slips past the probe above. Scan for any uid-0 entry and, if found,
		# hand the workspace to the same helper, which re-owns ONLY those uid-0 entries.
		#
		# Gate the scan to a NODE-OWNED root. A writable root that is NOT node-owned is
		# either a root-owned-but-writable FUSE bind mount (Docker Desktop / WSL / macOS,
		# where the owner reports uid 0 yet node may write — the no-op case the block
		# comment promises) or a foreign-owned root we deliberately refuse to chown. The
		# mixed-ownership heal applies to neither, and an UNGATED `find -uid 0` would match
		# the uid-0 root itself and wrongly hand such a mount to the helper (recursively
		# chowning host metadata / emitting warnings on platforms the probe used to skip).
		# Restricting to a node-owned root preserves the documented no-op there while still
		# catching nested uid-0 entries under a genuinely node-owned root.
		# Prune the separately mounted, already-node-owned node_modules/.worktrees volumes
		# exactly as the helper does (mountinfo-derived -path … -prune, with -xdev as a
		# backstop for a genuinely different filesystem) so the scan never walks them — those
		# are the bulky dirs, so pruning them is what keeps this cheap. -print -quit stops at
		# the FIRST uid-0 entry (the dirty case is detected instantly); a clean workspace has
		# no match and so does one bounded walk of the pruned source tree + .git at startup.
		if [ "$(stat -c %u "$_dir" 2>/dev/null)" = "$(id -u)" ]; then
			_prune=()
			while IFS= read -r _mp; do
				case "$_mp" in
				"$_dir"/?*) _prune+=(-path "$_mp" -prune -o) ;;
				esac
			done < <(awk '{print $5}' /proc/self/mountinfo 2>/dev/null)
			if [ -n "$(find "$_dir" -xdev "${_prune[@]}" -uid 0 -print -quit 2>/dev/null)" ]; then
				_unwritable+=("$_dir")
			fi
		fi
	else
		_unwritable+=("$_dir")
	fi
done
if [ "${#_unwritable[@]}" -gt 0 ]; then
	if ! sudo /usr/local/bin/fix-workspace-perms.sh "${_unwritable[@]}"; then
		echo "Warning: could not make all dir-mounted workspaces writable by node; git and file writes may still fail (see the lines above)." >&2
	fi
fi
