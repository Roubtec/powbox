#!/usr/bin/env bash
# Print the name of the selected layer set, or nothing for the lean image.
#
# Usage: layers-select.sh [<repo-root>]   (default: this script's repo)
#
# The selector is the gitignored <repo-root>/.powbox-layers. Its first line that
# is neither blank nor a #-comment, trimmed of whitespace (which covers a CRLF
# line ending), is the set name; a leading UTF-8 BOM is ignored. A missing or
# effectively empty file selects no set. A name that does not match
# ^[a-z0-9][a-z0-9._-]*$, or one without docker/layers/<name>/Dockerfile, is a
# hard error (exit 1) that names the offending value or path: falling back to
# the lean image would build something other than what was asked for.
#
# The build, the update check and the smoke test all call this one script (or
# its .ps1 sibling, which must agree case for case), so they can never disagree
# about which set is selected; a disagreement would show as permanent false
# staleness in agent-check-updates.
set -euo pipefail
export LC_ALL=C

ROOT_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SELECTOR="${ROOT_DIR}/.powbox-layers"

fail() {
	echo "layers-select: $*" >&2
	exit 1
}

[ -e "$SELECTOR" ] || exit 0
[ -f "$SELECTOR" ] || fail "$SELECTOR is not a regular file"

name=""
first=true
while IFS= read -r line || [ -n "$line" ]; do
	if $first; then
		line="${line#$'\xef\xbb\xbf'}"
		first=false
	fi
	line="${line#"${line%%[![:space:]]*}"}"
	line="${line%"${line##*[![:space:]]}"}"
	case "$line" in
	"" | "#"*) continue ;;
	esac
	name="$line"
	break
done <"$SELECTOR"

[ -n "$name" ] || exit 0

if ! [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
	fail "invalid layer-set name '${name}' in ${SELECTOR} (must match ^[a-z0-9][a-z0-9._-]*\$)"
fi
if [ ! -f "${ROOT_DIR}/docker/layers/${name}/Dockerfile" ]; then
	fail "docker/layers/${name}/Dockerfile not found (layer set '${name}' is selected in ${SELECTOR})"
fi
printf '%s\n' "$name"
