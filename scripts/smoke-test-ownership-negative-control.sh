#!/usr/bin/env bash
# Negative control for Stage 6's mountpoint-ownership coverage (task 053c).
#
# Stage 6 (scripts/smoke-test-worktree-metadata.sh and its PowerShell mirror)
# asserts that every mountpoint shadow-mounts.sh creates inherits the owner of
# its deepest pre-existing ancestor. A passing assertion is not proof that it
# can fail: if a refactor made both sides of a comparison read the same path, or
# made owner_of / Get-PathOwnerId return one sentinel for both, Stage 6 would
# stay green forever. This harness proves the other direction. It builds a
# derived image whose only difference from the real one is that shadow-mounts.sh
# no longer chowns the mountpoint it creates, runs ONE unchanged Stage 6 driver
# against it, and passes only if that driver goes red for the right reason.
#
# The mutation is narrow on purpose. Only the statement that chowns the
# mountpoint itself is removed; the chown of created ANCESTORS stays. Container
# A's in-container check of the intermediate .claude therefore still passes,
# and the run reaches the driver's own host-side assertions, which are the code
# this control exists to protect. Each driver stops at its first failing
# assertion (proj/bin), so a run proves that driver's assertion helper can fail,
# not that each of its three call sites can.
#
# Usage:
#   smoke-test-ownership-negative-control.sh run <image> <sh|ps1>
#       The control. <image> is the real built agent image; it is never
#       modified. The derived image is tagged $POWBOX_NEGCTL_TAG (default
#       powbox-negctl-ownership:mutated) and removed on exit.
#   smoke-test-ownership-negative-control.sh mutate <file>
#       Remove the mountpoint chown from <file> in place, match-or-fail. The
#       derived image's build runs this on the baked copy.
#   smoke-test-ownership-negative-control.sh drive <sh|ps1> <image> <log> <marker>
#   smoke-test-ownership-negative-control.sh classify <sh|ps1> <rc> <log> <marker> <image>
#       The two halves of `run` after the build, exposed so
#       scripts/test-ownership-negative-control.sh can pin them hermetically.
#
# Exit status: 0 = the mutated run went red for the right reason; 1 = the
# control failed (the mutation did not apply, the run passed, or it failed for
# another reason); 2 = inconclusive, because the ownership assertions cannot
# fail on this host (rootless engine, root invoker, squashing filesystem) or the
# driver self-skipped. 2 is never a pass: on the Tier 1 runner none of those
# conditions can hold, so the workflow step fails on it.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SELF="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"

BAKED_SHADOW_MOUNTS=/usr/local/bin/shadow-mounts.sh

# Whole-line matches against docker/shared/shadow-mounts.sh. The first is the
# mutation target; the second must survive it, or Container A aborts on the
# intermediate .claude before any host-side assertion runs.
MOUNTPOINT_CHOWN=$'\tif [ "$created" = 1 ]; then adopt_owner; fi'
ANCESTOR_CHOWN=$'\t\tif [ "$created" = 1 ] && [ "$i" -lt "$last" ]; then adopt_owner; fi'

# Text the drivers and the shared Container A script print. A change to any of
# them must be mirrored here; scripts/test-ownership-negative-control.sh checks
# that each one still occurs in its source file.
DRIVER_BANNER_PREFIX='Worktree durable-metadata smoke test (image: '
CONTAINER_A_ANCESTOR_OK='ok: multi-component shadow created; the intermediate .claude inherited the tree owner'
CONTAINER_A_DONE_OK='ok: single-component artifact shadow created at proj/bin'
CONTAINER_A_REGRESSED='the shadow-mounts.sh mountpoint chown REGRESSED'
CONTAINER_A_ABORT='Container A could not set up the durable worktree'
HOST_OWNERSHIP_OK='ok: mountpoint ownership ('
VACUITY_ROOTLESS='this container engine is ROOTLESS'
VACUITY_ROOT='this smoke is running as ROOT on the host'
OWNERSHIP_LABELS='single created component, tmpfs path|multi-component creation|single created component, durable-bind path'

passed() {
	echo "NEGATIVE CONTROL PASSED: $*"
	exit 0
}

failed() {
	echo "NEGATIVE CONTROL FAILED: $*" >&2
	exit 1
}

inconclusive() {
	echo "NEGATIVE CONTROL INCONCLUSIVE: $*" >&2
	exit 2
}

usage() {
	echo "usage: ${0##*/} run <image> <sh|ps1> | mutate <file> | drive <sh|ps1> <image> <log> <marker> | classify <sh|ps1> <rc> <log> <marker> <image>" >&2
	exit 64
}

count_lines() {
	local n
	n="$(grep -cxF -- "$1" "$2")" || true
	printf '%s' "${n:-0}"
}

# The host-side assertion's failure line. The .sh driver writes an em dash and
# the ASCII-only .ps1 a hyphen, so each driver is held to its own spelling.
host_anchor() {
	local dash q="'"
	case "$1" in
	sh) dash='—' ;;
	ps1) dash='-' ;;
	*) usage ;;
	esac
	printf '%s' "^FAIL: mountpoint ownership \\(($OWNERSHIP_LABELS)\\): ${q}[^${q}]*${q} is owned by [0-9]+:[0-9]+ but its deepest pre-existing ancestor ${q}[^${q}]*${q} is owned by [0-9]+:[0-9]+ ${dash} the created mountpoint did NOT inherit the tree${q}s ownership\\."
}

cmd_mutate() {
	local file="$1" tmp n_mp n_anc lines_before lines_after
	{ [ -f "$file" ] && [ -r "$file" ] && [ -w "$file" ]; } || failed "cannot read and write '$file'"
	n_mp="$(count_lines "$MOUNTPOINT_CHOWN" "$file")"
	n_anc="$(count_lines "$ANCESTOR_CHOWN" "$file")"
	[ "$n_mp" = 1 ] || failed "the mutation cannot apply: '$file' has $n_mp lines equal to the mountpoint chown (expected exactly 1). shadow-mounts.sh changed shape; point MOUNTPOINT_CHOWN in scripts/smoke-test-ownership-negative-control.sh at the statement that chowns the mountpoint itself."
	[ "$n_anc" = 1 ] || failed "the mutation cannot stay narrow: '$file' has $n_anc lines equal to the ancestor chown (expected exactly 1). Without it Container A aborts before the host-side assertions run; update ANCESTOR_CHOWN in scripts/smoke-test-ownership-negative-control.sh."
	tmp="$(mktemp)"
	grep -vxF -- "$MOUNTPOINT_CHOWN" "$file" >"$tmp" || true
	lines_before="$(wc -l <"$file")"
	lines_after="$(wc -l <"$tmp")"
	if [ "$(count_lines "$MOUNTPOINT_CHOWN" "$tmp")" != 0 ] || [ "$(count_lines "$ANCESTOR_CHOWN" "$tmp")" != 1 ] || [ "$lines_after" -ne "$((lines_before - 1))" ]; then
		rm -f "$tmp"
		failed "the mutation of '$file' did not remove exactly the one mountpoint chown line"
	fi
	if ! bash -n "$tmp"; then
		rm -f "$tmp"
		failed "the mutated '$file' no longer parses"
	fi
	# Rewritten through the existing inode, so mode and owner stay the baked ones.
	cat "$tmp" >"$file"
	rm -f "$tmp"
	[ "$(count_lines "$MOUNTPOINT_CHOWN" "$file")" = 0 ] || failed "the mutated '$file' still holds the mountpoint chown"
	echo "mutation applied: removed the mountpoint chown from $file; the ancestor chown is kept"
}

# A container's root creates a directory on a bind mount of an invoker-owned
# directory. If it comes back with its parent's owner, a missing chown is
# invisible here too, whatever the cause (rootless engine, root invoker,
# squashing filesystem), and the mutated run would pass without proving
# anything. The drivers' fixtures live under the same temp root.
check_teeth() {
	local image="$1" dir parent child
	[ "$(uname -s)" = Linux ] || inconclusive "this host is not Linux, so a bind mount may squash uid:gid and the ownership assertions cannot fail here."
	dir="$(mktemp -d "${TMPDIR:-/tmp}/powbox-negctl-teeth-XXXXXX")"
	if ! docker run --rm --user root --entrypoint /bin/sh -v "$dir:/negctl-teeth" "$image" -c 'mkdir /negctl-teeth/created'; then
		rmdir "$dir" 2>/dev/null || true
		inconclusive "the teeth probe container could not create a directory on a bind mount."
	fi
	parent="$(stat -c '%u:%g' "$dir" 2>/dev/null)" || parent=""
	child="$(stat -c '%u:%g' "$dir/created" 2>/dev/null)" || child=""
	rmdir "$dir/created" "$dir" 2>/dev/null || true
	{ [ -n "$parent" ] && [ -n "$child" ]; } || inconclusive "cannot read ownership with GNU 'stat -c' on this host."
	[ "$child" != "$parent" ] || inconclusive "a directory created by the container's root on a bind mount came back owned by $child, the same as its parent, so an unchowned mountpoint would look correctly owned (a rootless engine, a root invoker, or a squashing filesystem). Run this control as an unprivileged user on a rootful Linux engine."
	echo "  ok: teeth probe - a directory created by the container's root lands $child under a $parent parent, so the ownership assertions can fail here"
}

# The installed shadow-mounts.sh of <image>: its mode and owner on the first
# line, then its bytes.
read_baked() {
	docker run --rm --entrypoint /bin/sh "$1" -c 'stat -c "%a %u:%g" "$1" && cat "$1"' sh "$BAKED_SHADOW_MOUNTS" >"$2"
}

config_of() {
	docker image inspect --format '{{json .Config}}' "$1" | jq -S -c '{User, Entrypoint, Cmd, Env, WorkingDir, Labels}'
}

build_derived() {
	local base="$1" tag="$2" ctx="$3"
	cp -- "$SELF" "$ctx/negctl.sh"
	# USER root for the RUN only: both image stages end on USER node, and the
	# baked helper is root-owned under a root-owned directory. Restoring node
	# keeps the mutation the only difference from <base>.
	cat >"$ctx/Dockerfile" <<EOF
ARG NEGCTL_BASE
FROM \${NEGCTL_BASE}
USER root
RUN --mount=type=bind,source=negctl.sh,target=/tmp/powbox-negctl.sh bash /tmp/powbox-negctl.sh mutate $BAKED_SHADOW_MOUNTS
USER node
EOF
	docker build --build-arg "NEGCTL_BASE=$base" -t "$tag" -f "$ctx/Dockerfile" "$ctx" || failed "the derived image did not build (a mutation that cannot apply fails the build; see above)"
}

verify_derived() {
	local base="$1" tag="$2" work="$3"
	read_baked "$base" "$work/base.baked" || failed "cannot read $BAKED_SHADOW_MOUNTS from $base"
	read_baked "$tag" "$work/derived.baked" || failed "cannot read $BAKED_SHADOW_MOUNTS from $tag"
	[ "$(head -n 1 "$work/base.baked")" = "$(head -n 1 "$work/derived.baked")" ] || failed "the mutated $BAKED_SHADOW_MOUNTS has mode/owner '$(head -n 1 "$work/derived.baked")', not the baked '$(head -n 1 "$work/base.baked")'"
	tail -n +2 "$work/base.baked" >"$work/base.sh"
	tail -n +2 "$work/derived.baked" >"$work/derived.sh"
	[ "$(count_lines "$MOUNTPOINT_CHOWN" "$work/base.sh")" = 1 ] || failed "$base's $BAKED_SHADOW_MOUNTS does not hold exactly one mountpoint chown"
	grep -vxF -- "$MOUNTPOINT_CHOWN" "$work/base.sh" >"$work/expected.sh" || true
	cmp -s "$work/expected.sh" "$work/derived.sh" || failed "$tag's $BAKED_SHADOW_MOUNTS is not $base's minus exactly the mountpoint chown line"
	[ "$(config_of "$base")" = "$(config_of "$tag")" ] || failed "$tag's image config (user, entrypoint, cmd, env, workdir, labels) differs from $base's, so the mutation is not the only difference"
	echo "  ok: $tag differs from $base only by the removed mountpoint chown in $BAKED_SHADOW_MOUNTS"
}

# Run one Stage 6 driver exactly as the control does; returns its exit status.
# The .ps1 goes through a try/catch wrapper because pwsh's error view wraps a
# terminating error at the console width and colours it, which no line anchor
# survives; the wrapper writes the driver's own message on one line instead.
cmd_drive() {
	local driver="$1" image="$2" log="$3" marker="$4" rc wrapper
	: >"$marker"
	case "$driver" in
	sh)
		set +e
		POWBOX_SMOKE_REQUIRE_IMAGE=1 POWBOX_SMOKE_SKIP_MARKER="$marker" \
			"$ROOT_DIR/scripts/smoke-test-worktree-metadata.sh" "$image" 2>&1 | tee "$log"
		rc="${PIPESTATUS[0]}"
		set -e
		;;
	ps1)
		command -v pwsh >/dev/null 2>&1 || inconclusive "pwsh is not installed, so the PowerShell driver cannot run."
		wrapper="$(mktemp "${TMPDIR:-/tmp}/powbox-negctl-XXXXXX.ps1")"
		cat >"$wrapper" <<'EOF'
param([Parameter(Mandatory = $true)][string]$Driver, [Parameter(Mandatory = $true)][string]$Image)
try { & $Driver -Image $Image }
catch { [Console]::Out.WriteLine($_.Exception.Message); exit 1 }
exit 0
EOF
		set +e
		POWBOX_SMOKE_REQUIRE_IMAGE=1 POWBOX_SMOKE_SKIP_MARKER="$marker" \
			pwsh -NoProfile -File "$wrapper" -Driver "$ROOT_DIR/scripts/smoke-test-worktree-metadata.ps1" -Image "$image" 2>&1 | tee "$log"
		rc="${PIPESTATUS[0]}"
		set -e
		rm -f "$wrapper"
		;;
	*) usage ;;
	esac
	return "$rc"
}

cmd_classify() {
	local driver="$1" rc="$2" log="$3" marker="$4" image="$5" anchor hits oks label
	anchor="$(host_anchor "$driver")"
	if [ -s "$marker" ]; then
		inconclusive "the $driver driver self-skipped ($(cat "$marker")), so it never reached its ownership assertions."
	fi
	if grep -qF -- "$VACUITY_ROOTLESS" "$log" || grep -qF -- "$VACUITY_ROOT" "$log"; then
		inconclusive "the $driver driver reports that its ownership assertions are vacuous on this host (see its note above)."
	fi
	grep -qxF -- "$DRIVER_BANNER_PREFIX$image)" "$log" || failed "the $driver driver never started against the derived image $image"
	[ "$rc" != 0 ] || failed "the $driver driver PASSED against $image, whose shadow-mounts.sh leaves every created mountpoint unchowned: its mountpoint-ownership assertions cannot fail."
	if grep -qF -- "$CONTAINER_A_REGRESSED" "$log" || grep -qF -- "$CONTAINER_A_ABORT" "$log"; then
		failed "the $driver driver aborted in Container A (exit $rc), before its host-side assertions ran: either the mutation reached the ancestor chown or Container A broke for another reason. The host-side assertions are unproven."
	fi
	grep -qF -- "$CONTAINER_A_ANCESTOR_OK" "$log" || failed "Container A never confirmed the intermediate .claude's ownership, so the $driver run failed (exit $rc) for a reason other than the host-side assertions."
	grep -qF -- "$CONTAINER_A_DONE_OK" "$log" || failed "Container A did not finish, so the $driver run failed (exit $rc) for a reason other than the host-side assertions."
	oks="$(grep -cF -- "$HOST_OWNERSHIP_OK" "$log")" || oks=0
	[ "$oks" = 0 ] || failed "$oks host-side ownership assertion(s) of the $driver driver PASSED on a mountpoint the mutation left unchowned."
	hits="$(LC_ALL=C grep -cE -- "$anchor" "$log")" || hits=0
	[ "$hits" = 1 ] || failed "the $driver driver failed (exit $rc) without exactly one host-side mountpoint-ownership failure line (found $hits), so it went red for another reason."
	label="$(LC_ALL=C grep -E -- "$anchor" "$log" | sed -E 's/^FAIL: mountpoint ownership \(([^)]*)\).*/\1/')"
	passed "with the mountpoint chown removed, the $driver driver's host-side ownership assertion failed ($label) after Container A's intermediate-directory check passed."
}

cmd_run() {
	local image="$1" driver="$2" tag="${POWBOX_NEGCTL_TAG:-powbox-negctl-ownership:mutated}" work rc
	case "$driver" in sh | ps1) ;; *) usage ;; esac
	[ "$tag" != "$image" ] || failed "the derived tag must differ from the image under test ($image)"
	docker image inspect "$image" >/dev/null 2>&1 || failed "image '$image' not found; build it first"
	if [ "$driver" = ps1 ]; then
		command -v pwsh >/dev/null 2>&1 || inconclusive "pwsh is not installed, so the PowerShell driver cannot run."
	fi
	echo "Stage 6 ownership negative control ($driver driver, image: $image, derived: $tag)"
	check_teeth "$image"
	work="$(mktemp -d "${TMPDIR:-/tmp}/powbox-negctl-XXXXXX")"
	# shellcheck disable=SC2064 # expand now: the paths are fixed for this run
	trap "docker image rm -f '$tag' >/dev/null 2>&1 || true; rm -f '$work'/*; rmdir '$work' 2>/dev/null || true" EXIT
	build_derived "$image" "$tag" "$work"
	verify_derived "$image" "$tag" "$work"
	rc=0
	cmd_drive "$driver" "$tag" "$work/driver.log" "$work/marker" || rc=$?
	cmd_classify "$driver" "$rc" "$work/driver.log" "$work/marker" "$tag"
}

main() {
	[ "$#" -ge 1 ] || usage
	local cmd="$1"
	shift
	case "$cmd" in
	run)
		[ "$#" -eq 2 ] || usage
		cmd_run "$@"
		;;
	mutate)
		[ "$#" -eq 1 ] || usage
		cmd_mutate "$@"
		;;
	drive)
		[ "$#" -eq 4 ] || usage
		cmd_drive "$@"
		;;
	classify)
		[ "$#" -eq 5 ] || usage
		cmd_classify "$@"
		;;
	*) usage ;;
	esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
