#!/usr/bin/env bash
# Compose the on-demand agent reference directory the agent image bakes at
# /usr/local/share/agent-reference/ for both agents: the core files from
# docker/shared/agent-reference/ plus the selected layer set's contributions
# from docker/layers/<set>/agent-reference/, written to the gitignored
# .powbox-staging/agent-reference/ that docker/agent/Dockerfile COPYs. The home
# and its rules are documented in docs/agent-reference.md.
#
# Usage: stage-agent-reference.sh [<set> [<repo-root>]]
#   <set>        the layer set from scripts/layers-select.sh; empty or absent
#                means none
#   <repo-root>  default: this script's repo
#
# Both source directories hold only regular files named like `name.md`; any
# other entry is refused, so the bake never depends on a symlink target, a
# subdirectory or a file mode the checkout carries. The core directory must
# exist. Output, one file per name:
#   - a core file is staged byte for byte;
#   - a set file whose name a core file also has is appended to it: a blank
#     line, the heading "## Contributed by the `<set>` layer set", a blank line
#     and the set file, normalized as stage-agent-template.sh normalizes notes
#     (a leading UTF-8 BOM dropped, CRLF and lone CR made LF, leading
#     whitespace-only lines and all trailing whitespace dropped, one final LF);
#   - a set file with a name of its own is staged normalized the same way;
#   - a set file holding only whitespace contributes nothing.
# Any other file in the staging directory is removed, so switching sets never
# leaves a stale contribution behind.
#
# As for the instruction template, the output must be a pure function of those
# inputs, every file mode 0644 and the directory 0755, because BuildKit keys
# the COPY on content and mode. A file is rewritten only when it cannot be
# confirmed unchanged and set to 0644 in place. scripts/stage-agent-reference.ps1
# must produce the same bytes and modes for the same inputs.
set -euo pipefail
export LC_ALL=C

SET="${1:-}"
ROOT_DIR="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
CORE_DIR="${ROOT_DIR}/docker/shared/agent-reference"
OUT_DIR="${ROOT_DIR}/.powbox-staging/agent-reference"
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*\.md$'

fail() {
	echo "stage-agent-reference: $*" >&2
	exit 1
}

# entries <dir>: every entry in <dir>, dotfiles included, one per line, in
# byte order (globs sort by the C collation set above).
entries() {
	local -a found
	shopt -s nullglob dotglob
	found=("$1"/*)
	shopt -u nullglob dotglob
	[ "${#found[@]}" -eq 0 ] || printf '%s\n' "${found[@]}"
}

# list_sources <dir>: the names in <dir>, one per line; fails on any entry
# that is not a regular `name.md` file.
list_sources() {
	local path name
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		name="${path##*/}"
		[[ "$name" =~ $NAME_RE ]] || fail "$path: only files named like name.md belong here"
		[ -f "$path" ] && [ ! -L "$path" ] || fail "$path is not a regular file"
		printf '%s\n' "$name"
	done <<<"$(entries "$1")"
}

# normalized <file>: the file's text as a set contribution, without the final
# LF (empty when it holds only whitespace).
normalized() {
	local text line
	# A shell variable cannot hold NUL, so the PowerShell twin would keep bytes
	# this one drops; refuse in both rather than diverge.
	if [ "$(tr -d '\000' <"$1" | wc -c)" -ne "$(wc -c <"$1")" ]; then
		fail "$1 contains a NUL byte"
	fi
	text="$(cat "$1")"
	text="${text#$'\xef\xbb\xbf'}"
	text="${text//$'\r\n'/$'\n'}"
	text="${text//$'\r'/$'\n'}"
	text="${text%"${text##*[!$' \t\n']}"}"
	while :; do
		line="${text%%$'\n'*}"
		if [ "$line" = "$text" ] || [ -n "${line//[$' \t']/}" ]; then
			break
		fi
		text="${text#*$'\n'}"
	done
	printf '%s' "$text"
}

[ -d "$CORE_DIR" ] || fail "$CORE_DIR not found"
core_names="$(list_sources "$CORE_DIR")"

set_dir=""
set_names=""
if [ -n "$SET" ]; then
	# The name lands in a path and in a Markdown heading; layers-select enforces
	# the same pattern, so this only guards a direct caller.
	[[ "$SET" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "invalid layer-set name '${SET}'"
	set_dir="${ROOT_DIR}/docker/layers/${SET}/agent-reference"
	if [ -e "$set_dir" ] || [ -L "$set_dir" ]; then
		[ -d "$set_dir" ] && [ ! -L "$set_dir" ] || fail "$set_dir is not a directory"
		set_names="$(list_sources "$set_dir")"
	fi
fi

mkdir -p "${OUT_DIR%/*}"
work="$(mktemp -d "${OUT_DIR%/*}/.agent-reference.XXXXXX")"
trap 'rm -f "$work"/* && rmdir "$work"' EXIT

# Compose every output file in the work directory first, so a failure leaves
# the staged directory as it was.
while IFS= read -r name; do
	[ -n "$name" ] || continue
	cp "$CORE_DIR/$name" "$work/$name"
done <<<"$core_names"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	text="$(normalized "$set_dir/$name")"
	[ -n "$text" ] || continue
	if [ -e "$work/$name" ]; then
		# $(...) strips a trailing LF, so an empty result means the core file
		# already ends a line.
		sep=""
		[ -z "$(tail -c 1 "$work/$name")" ] || sep=$'\n'
		# The backticks are Markdown code spans, not command substitution.
		# shellcheck disable=SC2016
		printf '%s\n## Contributed by the `%s` layer set\n\n%s\n' "$sep" "$SET" "$text" >>"$work/$name"
	else
		printf '%s\n' "$text" >"$work/$name"
	fi
done <<<"$set_names"

# mv would move a file into a directory rather than replace it, and pruning
# never removes a directory; refuse before changing anything.
staged="$(entries "$OUT_DIR")"
while IFS= read -r path; do
	[ -n "$path" ] || continue
	[ ! -d "$path" ] || [ -L "$path" ] || fail "$path is a directory"
done <<<"$staged"
mkdir -p "$OUT_DIR"
chmod 0755 "$OUT_DIR"
while IFS= read -r path; do
	[ -n "$path" ] || continue
	[ -e "$work/${path##*/}" ] || rm -f -- "$path"
done <<<"$staged"
for path in "$work"/*; do
	[ -e "$path" ] || continue
	name="${path##*/}"
	chmod 0644 "$path"
	# chmod fails on a file another user owns (a sudo build's leftover);
	# replacing the file is then the way to the mode.
	if [ -f "$OUT_DIR/$name" ] && cmp -s "$path" "$OUT_DIR/$name" && chmod 0644 "$OUT_DIR/$name" 2>/dev/null; then
		continue
	fi
	mv -f "$path" "$OUT_DIR/$name"
done
