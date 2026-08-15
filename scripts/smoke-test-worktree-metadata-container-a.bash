#!/usr/bin/env bash
# Container A of the durable worktree-metadata smoke stage: establish the durable
# .git/worktrees bind, create a dirty linked worktree, and exercise the
# shadow-mounts.sh mountpoint-ownership chown (task 053).
#
# This file is SOURCE TEXT, not a program to run. Both drivers of the stage --
# scripts/smoke-test-worktree-metadata.sh and its PowerShell mirror
# scripts/smoke-test-worktree-metadata.ps1 -- read it verbatim and hand it to
# `docker run ... --entrypoint /bin/bash <image> -c "<this file>" powbox-wtmeta ...`,
# so it always runs INSIDE the throwaway container, never on the host. It lives in
# ONE file because a copy per driver is exactly what let the PowerShell mirror miss
# the task 053 ownership coverage for a release (task 053a); the host-side half of
# those assertions is still written natively in each driver, which is cheap to keep
# in parity and cannot be shared without making the .ps1 shell out to bash.
# The shebang is consequently never honoured. It is here so shellcheck reads this as
# bash -- Tier 0 lints non-`.sh` tracked files by matching their shebang -- and it
# costs nothing, since `bash -c` treats it as a comment. The file is deliberately NOT
# executable: running it on a host would point shadow-mounts.sh at host paths.
#
# Contract with BOTH drivers (change it in both):
#   * positional args: $1 = the dir-mounted repo, $2 = the per-worktree branch/slug,
#     $3 = the container subdir under .worktrees;
#   * the host fixture must already be a git repo carrying tracked.txt AND a
#     host-created proj/ directory, so that shadowing proj/bin below creates exactly
#     one new component whose deepest existing ancestor is invoker-owned;
#   * exit codes: 0 = set up a dirty durable worktree; 42 = self-skip, emitted ONLY
#     by the independent capability preflight (no bind-mount capability / no
#     persistent .worktrees volume); any OTHER non-zero = genuine failure, INCLUDING
#     a durable-bind regression detected after the preflight proved the runtime can
#     mount;
#   * LF line endings only: a CR survives into the `bash -c` payload and breaks it.
#     .gitattributes pins LF, and the PowerShell driver strips CRLF defensively in
#     case a checkout mangles it anyway.

set -u
WS="$1"
SLUG="$2"
CONT="$3"
export HOME=/root
# The fixture is created on the host by whoever runs the smoke; inside the
# container we touch it as root, so silence git dubious-ownership on the borrowed
# checkout (a throwaway smoke fixture, safe to trust).
git config --global --add safe.directory "*" >/dev/null 2>&1 || true

# Independent mount-capability PREFLIGHT (does NOT touch shadow-mounts.sh /
# bind_git_worktrees): a throwaway temp-over-temp mount --bind with the same cap
# wiring. ONLY its failure is a legitimate "cannot test here" skip (exit 42), so a
# regression in the durable bind can no longer masquerade as a missing capability.
pfsrc="$(mktemp -d)"
pfdst="$(mktemp -d)"
if ! mount --bind "$pfsrc" "$pfdst" 2>/dev/null; then
	echo "  skip: runtime cannot perform mount --bind (no CAP_SYS_ADMIN / EPERM) - the durable-bind lifecycle cannot be exercised here"
	rmdir "$pfdst" "$pfsrc" 2>/dev/null || true
	exit 42
fi
umount "$pfdst" 2>/dev/null || umount -l "$pfdst" 2>/dev/null || true
rmdir "$pfdst" "$pfsrc" 2>/dev/null || true
# The persistent .worktrees volume must genuinely be mounted; otherwise there is
# nothing durable to co-locate into (a legit skip). The outer driver always mounts it.
if ! mountpoint -q "$WS/.worktrees"; then
	echo "  skip: the persistent .worktrees volume is not mounted at $WS/.worktrees - nothing durable to exercise"
	exit 42
fi
echo "  ok: mount capability confirmed and the persistent .worktrees volume is present (preflight)"

# Capability + volume are established. From HERE any failure to materialize the
# durable bind is a REGRESSION and a HARD FAILURE (exit 1, NOT a skip) - the case this
# stage exists to catch. Establish the bind exactly as the entrypoint does: bind the
# .gitworktrees subdir of the persistent .worktrees volume over .git/worktrees.
smerr="$(mktemp)"
if ! /usr/local/bin/shadow-mounts.sh "$WS/.git/worktrees" 2>"$smerr"; then
	echo "FAIL: shadow-mounts.sh failed to establish the durable bind despite mount capability being present - durable-bind REGRESSION" >&2
	sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true
	exit 1
fi
if ! mountpoint -q "$WS/.git/worktrees"; then
	echo "FAIL: .git/worktrees is not a mountpoint after shadow-mounts.sh - the durable bind did not materialize (REGRESSION)" >&2
	exit 1
fi
# A tmpfs here means shadow-mounts.sh fell back instead of binding the persistent
# volume - a regression now that capability + volume are both proven present.
fstype="$(findmnt -nro FSTYPE -T "$WS/.git/worktrees" 2>/dev/null || true)"
if [ "$fstype" = tmpfs ]; then
	echo "FAIL: durable bind fell back to tmpfs despite the persistent .worktrees volume being present - durable-bind REGRESSION" >&2
	exit 1
fi
# Prove the bind maps .git/worktrees onto the volume .gitworktrees dir (not merely
# onto some non-tmpfs fs): a sentinel written on the volume side must be visible
# through .git/worktrees; a mismatch means the bind points at the wrong source.
probe=".bindprobe.$$"
if ! : >"$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null; then
	echo "FAIL: cannot write into the volume .gitworktrees dir to verify the durable bind (REGRESSION)" >&2
	exit 1
fi
if [ ! -e "$WS/.git/worktrees/$probe" ]; then
	rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true
	echo "FAIL: .git/worktrees does not reflect the volume .gitworktrees dir - durable bind maps the wrong source (REGRESSION)" >&2
	exit 1
fi
rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true
echo "  ok: durable .git/worktrees bind established from the persistent .worktrees volume (verified maps .gitworktrees)"

WTDIR="$WS/.worktrees/$CONT/$SLUG"
if ! git -C "$WS" worktree add -q "$WTDIR" -b "$SLUG" >/dev/null 2>&1; then
	echo "FAIL: git worktree add failed while creating the linked worktree" >&2
	git -C "$WS" worktree add "$WTDIR" -b "$SLUG" >&2 || true
	exit 1
fi
# The admin metadata must have landed in the durable volume (via the bind), not on
# the host checkout.
if [ ! -e "$WS/.worktrees/.gitworktrees/$SLUG/gitdir" ]; then
	echo "FAIL: worktree metadata did not land in the durable volume (.worktrees/.gitworktrees/$SLUG missing)" >&2
	exit 1
fi
# Leave the worktree DIRTY: a tracked modification AND an untracked new file. The
# fixture commit ships tracked.txt, so appending to it is a tracked change.
echo "durable-change-A" >>"$WTDIR/tracked.txt"
echo "untracked-content-A" >"$WTDIR/UNTRACKED_NEW.txt"
echo "  ok: linked worktree created and left dirty (tracked mod + untracked file)"

# Mountpoint-ownership coverage (task 053), MULTI-component case. $WS/.git/worktrees
# above created ONE component (its .git parent already existed); this target has to
# create TWO ($WS/.claude and $WS/.claude/worktrees), so shadow-mounts.sh must walk
# up past both to $WS and hand that owner to each. It is also a real powbox shadow:
# .claude/worktrees is the harness worktree root the entrypoint tmpfs-shadows.
# Mount capability is already proven above, so a failure here is a hard failure.
if ! /usr/local/bin/shadow-mounts.sh "$WS/.claude/worktrees" 2>"$smerr"; then
	echo "FAIL: shadow-mounts.sh failed on the multi-component target $WS/.claude/worktrees despite mount capability being present" >&2
	sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true
	exit 1
fi
if ! mountpoint -q "$WS/.claude/worktrees"; then
	echo "FAIL: $WS/.claude/worktrees is not a mountpoint after shadow-mounts.sh - the multi-component shadow did not materialize" >&2
	exit 1
fi
# The INTERMEDIATE $WS/.claude was created but is not itself a mountpoint, so its
# ownership is readable right here with no unmount needed. The two mountpoints
# themselves are asserted on the host once this container exits (see below).
# Sentinels rather than a bare fallback: the image always has GNU stat, so a
# failure here is itself a fault and must not read as "both unknown, so equal".
own="$(stat -c %u:%g "$WS/.claude" 2>/dev/null || echo "UNREADABLE")"
parent="$(stat -c %u:%g "$WS" 2>/dev/null || echo "UNREADABLE")"
if [ "$own" = UNREADABLE ] || [ "$parent" = UNREADABLE ]; then
	echo "FAIL: cannot read the ownership of $WS/.claude and/or $WS inside the container (stat -c failed) - the mountpoint-ownership check cannot be evaluated" >&2
	exit 1
fi
if [ "$own" != "$parent" ]; then
	echo "FAIL: the created intermediate directory $WS/.claude is owned by $own but its pre-existing parent $WS is owned by $parent - the shadow-mounts.sh mountpoint chown REGRESSED" >&2
	exit 1
fi
echo "  ok: multi-component shadow created; the intermediate .claude inherited the tree owner ($own)"

# Mountpoint-ownership coverage (task 053), SINGLE-component case on the ORDINARY
# tmpfs path. $WS/proj is created on the host by the driver, so only $WS/proj/bin is
# new and its deepest existing ancestor is $WS/proj. This is the exact shape the
# chown was written for - a .NET project bin/obj artifact dir that detect-shadows.sh
# emits automatically - and it takes the plain tmpfs branch, not the special
# /.git/worktrees durable-bind branch, so it is not a duplicate of the assertion at
# the top of this script. Mount capability is proven, so a failure here is hard.
if ! /usr/local/bin/shadow-mounts.sh "$WS/proj/bin" 2>"$smerr"; then
	echo "FAIL: shadow-mounts.sh failed on the single-component target $WS/proj/bin despite mount capability being present" >&2
	sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true
	exit 1
fi
if ! mountpoint -q "$WS/proj/bin"; then
	echo "FAIL: $WS/proj/bin is not a mountpoint after shadow-mounts.sh - the artifact shadow did not materialize" >&2
	exit 1
fi
echo "  ok: single-component artifact shadow created at proj/bin (ownership asserted on the host after this container exits)"
exit 0
