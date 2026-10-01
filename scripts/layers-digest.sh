#!/usr/bin/env bash
# Compute the digest of a layer-set directory (docker/layers/<set>), after
# checking that the set obeys the layer Dockerfile contract.
#
# Usage: layers-digest.sh <set-directory>
#
# build-image.sh stamps the result as the powbox.layers.digest label on
# powbox-agent-layers:latest; check-updates.sh recomputes it from the working
# tree and compares it with the label the running agent image inherited. As
# with scripts/base-source-digest.sh, build-time and check-time must call this
# one script, and the .ps1 sibling must print a byte-identical digest for the
# same tree, or the update check reports permanent false staleness.
#
# Algorithm (must match layers-digest.ps1, and base-source-digest's format):
#   - every regular file under the set directory, recursively, dotfiles and
#     .gitkeep included; directories are not hashed, only their files
#   - paths relative to the set directory, forward slashes, byte-sorted
#   - for each path "<sha256-of-file-bytes>  <path>\n" (two spaces, LF)
#   - the digest is "sha256:" + sha256 of that concatenated buffer
#
# The digest is content-only on purpose. Docker's build context also carries
# file modes and symlink targets, which a content-only digest would miss, so the
# contract removes them as build inputs instead of hashing them:
#   - a symlink or any other non-regular entry under the set is a hard error
#     (a set that needs a link creates it in a RUN);
#   - every COPY and ADD in <set>/Dockerfile must carry --chmod=<mode>, so the
#     mode a copied file gets comes from the Dockerfile, which is hashed, never
#     from the checkout (a Windows checkout has no Unix modes, and Git tracks
#     only the executable bit).
# The Dockerfile check joins backslash continuations and skips comment and blank
# lines inside them, as Docker does. It does not parse heredoc bodies or an
# `# escape=` directive: a heredoc line that itself reads as a COPY or ADD
# instruction is checked too, which errs towards rejecting.
#
# Exit status: 0 with the digest on stdout; 1 when the set breaks the contract
# or cannot be read (every offending line or path is named on stderr); 2 on a
# usage error; 3 when no sha256 tool is available, which callers treat as an
# undeterminable digest rather than a broken set. Nothing is printed on stdout
# unless the status is 0.
set -euo pipefail
export LC_ALL=C

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
	echo "usage: layers-digest.sh <set-directory>" >&2
	exit 2
fi
SET_DIR="${1%/}"

if [ ! -d "$SET_DIR" ]; then
	echo "layers-digest: layer-set directory not found: $SET_DIR" >&2
	exit 1
fi
if [ ! -f "$SET_DIR/Dockerfile" ] || [ -L "$SET_DIR/Dockerfile" ]; then
	echo "layers-digest: $SET_DIR/Dockerfile is missing or not a regular file" >&2
	exit 1
fi

# Lowercase hex sha256 of stdin, no filename. The same fallbacks as
# base-source-digest.sh.
sha256_hex() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | cut -d' ' -f1
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 | sed 's/^.*[ =]//'
	else
		return 3
	fi
}

errors=0
report() {
	echo "layers-digest: $*" >&2
	errors=$((errors + 1))
}

ends_with_backslash() {
	[[ "$1" =~ \\[[:space:]]*$ ]]
}

strip_backslash() {
	local s="$1"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "${s%\\}"
}

is_blank_or_comment() {
	local s="${1#"${1%%[![:space:]]*}"}"
	case "$s" in "" | "#"*) return 0 ;; esac
	return 1
}

# Report a COPY or ADD (also behind ONBUILD) whose flags lack --chmod=<mode>.
# Flags are the leading --name=value words after the keyword; Docker accepts
# instruction flags only in that position and only in the = form.
check_instruction() {
	local lineno="$1" logical="$2"
	local -a words
	read -r -a words <<<"$logical" || true
	[ "${#words[@]}" -gt 0 ] || return 0
	local i=0 keyword
	keyword="$(printf '%s' "${words[0]}" | tr '[:lower:]' '[:upper:]')"
	if [ "$keyword" = ONBUILD ] && [ "${#words[@]}" -gt 1 ]; then
		keyword="$(printf '%s' "${words[1]}" | tr '[:lower:]' '[:upper:]')"
		i=1
	fi
	case "$keyword" in COPY | ADD) ;; *) return 0 ;; esac
	i=$((i + 1))
	while [ "$i" -lt "${#words[@]}" ]; do
		case "${words[$i]}" in
		--chmod=?*) return 0 ;;
		--*) ;;
		*) break ;;
		esac
		i=$((i + 1))
	done
	report "${SET_DIR}/Dockerfile:${lineno}: ${keyword} without --chmod=<mode>: ${logical}"
}

lines=()
while IFS= read -r line || [ -n "$line" ]; do
	lines+=("${line%$'\r'}")
done <"$SET_DIR/Dockerfile"

n="${#lines[@]}"
i=0
while [ "$i" -lt "$n" ]; do
	line="${lines[$i]}"
	start=$((i + 1))
	if is_blank_or_comment "$line"; then
		i=$((i + 1))
		continue
	fi
	logical="$line"
	cont=false
	if ends_with_backslash "$line"; then
		cont=true
		logical="$(strip_backslash "$line")"
	fi
	while $cont && [ $((i + 1)) -lt "$n" ]; do
		i=$((i + 1))
		next="${lines[$i]}"
		is_blank_or_comment "$next" && continue
		if ends_with_backslash "$next"; then
			logical="${logical} $(strip_backslash "$next")"
		else
			logical="${logical} ${next}"
			cont=false
		fi
	done
	check_instruction "$start" "$logical"
	i=$((i + 1))
done

entries="$(mktemp)"
trap 'rm -f "$entries"' EXIT
if ! (cd "$SET_DIR" && find . -mindepth 1 ! -type d -print0) >"$entries"; then
	echo "layers-digest: cannot list $SET_DIR" >&2
	exit 1
fi

files=()
while IFS= read -r -d '' rel; do
	rel="${rel#./}"
	path="${SET_DIR}/${rel}"
	if [ -L "$path" ]; then
		report "${path}: symlinks are not allowed in a layer set (create the link in a RUN instead)"
	elif [ ! -f "$path" ]; then
		report "${path}: not a regular file; only regular files are allowed in a layer set"
	else
		files+=("$rel")
	fi
done < <(sort -z "$entries")

[ "$errors" -eq 0 ] || exit 1

if ! printf '' | sha256_hex >/dev/null 2>&1; then
	echo "layers-digest: no sha256 tool (need sha256sum, shasum, or openssl)" >&2
	exit 3
fi

buffer=""
for rel in ${files[@]+"${files[@]}"}; do
	buffer="${buffer}$(sha256_hex <"${SET_DIR}/${rel}")  ${rel}"$'\n'
done

printf 'sha256:%s\n' "$(printf '%s' "$buffer" | sha256_hex)"
