#!/usr/bin/env bash
# Compose the agent instruction template the agent image bakes for both agents:
# docker/shared/container-agent.md.tmpl, followed by the selected layer set's
# hand-written notes, written to the gitignored .powbox-staging/agent.md.tmpl
# that docker/agent/Dockerfile COPYs.
#
# Usage: stage-agent-template.sh [<set> [<repo-root>]]
#   <set>        the layer set from scripts/layers-select.sh; empty or absent
#                means none
#   <repo-root>  default: this script's repo
#
# Output: the core template's bytes unchanged, then, only when a set is named
# and docker/layers/<set>/agent-notes.md holds more than whitespace, a blank
# line, the heading "## Additional tooling from the `<set>` layer set", a blank
# line and the notes. The notes lose a leading UTF-8 BOM, CRLF and lone CR
# become LF, leading whitespace-only lines and all trailing whitespace are
# dropped, and the file ends with exactly one LF. No set, or a set without
# notes, stages the core template byte for byte.
#
# The output must be a pure function of those inputs: Docker keys the COPY of
# this file on its content, so identical inputs must give identical bytes to
# keep that layer cached, and changed notes must change them so the build-epoch
# layer above reruns and containers re-render the instruction file. The file is
# rewritten only when its content changes. scripts/stage-agent-template.ps1 must
# produce the same bytes for the same inputs.
set -euo pipefail
# Byte-wise string operations, whatever the notes' encoding.
export LC_ALL=C

SET="${1:-}"
ROOT_DIR="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
TEMPLATE="${ROOT_DIR}/docker/shared/container-agent.md.tmpl"
STAGING_DIR="${ROOT_DIR}/.powbox-staging"
OUT="${STAGING_DIR}/agent.md.tmpl"

fail() {
	echo "stage-agent-template: $*" >&2
	exit 1
}

[ -f "$TEMPLATE" ] || fail "$TEMPLATE not found"

notes=""
if [ -n "$SET" ]; then
	# The name lands in a path and in a Markdown heading; layers-select enforces
	# the same pattern, so this only guards a direct caller.
	[[ "$SET" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "invalid layer-set name '${SET}'"
	notes_file="${ROOT_DIR}/docker/layers/${SET}/agent-notes.md"
	if [ -e "$notes_file" ]; then
		[ -f "$notes_file" ] || fail "$notes_file is not a regular file"
		# A shell variable cannot hold NUL, so the PowerShell twin would keep bytes
		# this one drops; refuse in both rather than diverge.
		if [ "$(tr -d '\000' <"$notes_file" | wc -c)" -ne "$(wc -c <"$notes_file")" ]; then
			fail "$notes_file contains a NUL byte"
		fi
		notes="$(cat "$notes_file")"
		notes="${notes#$'\xef\xbb\xbf'}"
		notes="${notes//$'\r\n'/$'\n'}"
		notes="${notes//$'\r'/$'\n'}"
		notes="${notes%"${notes##*[!$' \t\n']}"}"
		while :; do
			line="${notes%%$'\n'*}"
			if [ "$line" = "$notes" ] || [ -n "${line//[$' \t']/}" ]; then
				break
			fi
			notes="${notes#*$'\n'}"
		done
	fi
fi

mkdir -p "$STAGING_DIR"
tmp="$(mktemp "${STAGING_DIR}/.agent.md.tmpl.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
{
	cat "$TEMPLATE"
	if [ -n "$notes" ]; then
		# $(...) strips a trailing LF, so an empty result means the template
		# already ends a line.
		[ -z "$(tail -c 1 "$TEMPLATE")" ] || printf '\n'
		# The backticks are Markdown code spans, not command substitution.
		# shellcheck disable=SC2016
		printf '\n## Additional tooling from the `%s` layer set\n\n%s\n' "$SET" "$notes"
	fi
} >"$tmp"
chmod 0644 "$tmp"

if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
	exit 0
fi
mv -f "$tmp" "$OUT"
