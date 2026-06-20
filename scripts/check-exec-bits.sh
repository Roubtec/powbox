#!/usr/bin/env bash
# check-exec-bits.sh — fail if any tracked *.sh is committed without its
# executable bit (git mode 100644 instead of 100755).
#
# Why this exists: a shell script that is invoked directly (e.g. `./build.sh`)
# but committed non-executable breaks on a fresh native-Linux clone with
# "Permission denied" — the PR #51 regression. Windows/WSL masks this because
# git there ignores filemode and the bind mount reports 0755, so the defect only
# shows up on a real Linux host. This guard is the Tier-0 check that catches it
# in CI (and can be run by hand: `./scripts/check-exec-bits.sh`).
#
# Allowlist: scripts that are intentionally NOT executable in git because they
# are never run directly from a host clone — COPY'd into the image with
# `--chmod=755` (docker/base/Dockerfile) and only ever invoked via that baked
# /usr/local/bin path or `docker run --entrypoint`, so they need no committed
# host exec bit. The list is currently EMPTY: every shared baked-only script is
# committed 100755 to match its siblings. Keep any future entry tiny and
# justified — each one is a hole in the guard.
set -euo pipefail

# Exact tracked paths (repo-root-relative) exempt from the exec-bit requirement.
# Empty by default — add a path here only for a script genuinely never run from
# a host clone (see the note above).
ALLOWLIST=()

is_allowed() {
	local path="$1" entry
	[ "${#ALLOWLIST[@]}" -eq 0 ] && return 1
	for entry in "${ALLOWLIST[@]}"; do
		[ "$path" = "$entry" ] && return 0
	done
	return 1
}

violations=()
while IFS= read -r line; do
	# `git ls-files -s` prints: "<mode> <object> <stage>\t<path>".
	mode="${line%% *}"    # first whitespace-delimited token is the mode
	path="${line#*$'\t'}" # everything after the first TAB is the path
	[ "$mode" = "100644" ] || continue
	is_allowed "$path" && continue
	violations+=("$path")
done < <(git ls-files -s -- '*.sh')

if [ "${#violations[@]}" -gt 0 ]; then
	{
		echo "ERROR: the following tracked *.sh files are missing the executable bit (git mode 100644):"
		for path in "${violations[@]}"; do
			echo "  - $path"
		done
		echo
		echo "A directly-invoked script committed non-executable fails with 'Permission denied'"
		echo "on a fresh native-Linux clone (the PR #51 regression). Fix each with:"
		echo "    git update-index --chmod=+x <file>     # stages the mode change"
		echo "or: chmod +x <file> && git add <file>"
		echo
		echo "If a script is genuinely never run from a host clone (e.g. baked in with"
		echo "COPY --chmod), add it to the ALLOWLIST in scripts/check-exec-bits.sh instead."
	} >&2
	exit 1
fi

if [ "${#ALLOWLIST[@]}" -gt 0 ]; then
	echo "check-exec-bits: OK — every tracked *.sh has its executable bit (allowlisted: ${ALLOWLIST[*]})."
else
	echo "check-exec-bits: OK — every tracked *.sh has its executable bit."
fi
