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
# file modes, symlink targets and empty directories, which a content-only digest
# would miss, so the contract removes them as build inputs instead of hashing
# them:
#   - a symlink, an empty directory or any other non-regular entry under the
#     set is a hard error (a set that needs one creates it in a RUN);
#   - every COPY and ADD in <set>/Dockerfile must carry --chmod=<mode>, so the
#     mode a copied file gets comes from the Dockerfile, which is hashed, never
#     from the checkout (a Windows checkout has no Unix modes, and Git tracks
#     only the executable bit).
# ONBUILD is rejected outright: its trigger runs while the agent image is built
# on the layer image, from the agent build's context (the repository root), so
# an ONBUILD COPY, ADD or RUN --mount could read inputs the digest never sees.
# This scan rejects it early; the build drivers also refuse a layer image that
# records any trigger (layers_onbuild_triggers in build-image-lib.sh).
# The Dockerfile's final stage must also build FROM ${BASE_IMAGE}, directly or
# through earlier stages. This only catches the plain mistake before anything
# is built: the bake labels the layer image with the base it passes in whatever
# the set built on, so the build drivers prove the chain from the built image's
# filesystem layers (layers_base_mismatch in build-image-lib.sh).
# The Dockerfile check follows the rules of BuildKit's Dockerfile parser where
# they decide what is an instruction: it refuses a NUL byte, drops a UTF-8 BOM
# and trailing CRs, trims leading Unicode whitespace (U+00A0 and the like)
# where BuildKit does, joins a line ending in an unescaped backslash, followed
# only by spaces or tabs, to the next without adding anything, skips comment
# and blank lines inside continuations, folds keywords as Go's strings.ToLower
# does, and skips heredoc bodies (<<EOF, <<-EOF, << 'EOF' after RUN, COPY or
# ADD, also behind ONBUILD, its words split as BuildKit's shell lexer splits
# them), so a body line that reads as FROM or COPY is neither taken for a stage
# nor checked; an unterminated heredoc is an error, as it is to Docker. It is a
# scan, not a parser: it reads no variables and no JSON-form arguments, though
# it compares FROM's image by its unquoted value, as Docker does. Only the
# default backslash escape is supported: an `# escape=` parser directive
# setting any other character is rejected, since it changes how Docker joins
# lines.
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

# As Docker's continuation rule: a backslash ending the line continues it, unless
# another backslash precedes it. Only spaces and tabs may follow it.
CONTINUATION_RE='(^|[^\\])\\[ '$'\t'']*$'
ends_with_backslash() {
	[[ "$1" =~ $CONTINUATION_RE ]]
}

strip_backslash() {
	local s="$1" blank=$' \t'
	s="${s%"${s##*[!"$blank"]}"}"
	printf '%s' "${s%\\}"
}

# The non-ASCII code points Go's unicode.IsSpace accepts (the Unicode
# White_Space property), as their UTF-8 bytes. BuildKit trims them, with the
# ASCII ones, from the start of an instruction, a comment or an empty
# continuation line, so a line indented with U+00A0 is still an instruction.
# Spelled with \x, as in smoke-test-image.sh, so the bytes do not depend on
# the locale.
UNICODE_SPACES=(
	$'\xc2\x85'     # U+0085 NEXT LINE
	$'\xc2\xa0'     # U+00A0 NO-BREAK SPACE
	$'\xe1\x9a\x80' # U+1680 OGHAM SPACE MARK
	$'\xe2\x80\x80' # U+2000 EN QUAD
	$'\xe2\x80\x81' # U+2001 EM QUAD
	$'\xe2\x80\x82' # U+2002 EN SPACE
	$'\xe2\x80\x83' # U+2003 EM SPACE
	$'\xe2\x80\x84' # U+2004 THREE-PER-EM SPACE
	$'\xe2\x80\x85' # U+2005 FOUR-PER-EM SPACE
	$'\xe2\x80\x86' # U+2006 SIX-PER-EM SPACE
	$'\xe2\x80\x87' # U+2007 FIGURE SPACE
	$'\xe2\x80\x88' # U+2008 PUNCTUATION SPACE
	$'\xe2\x80\x89' # U+2009 THIN SPACE
	$'\xe2\x80\x8a' # U+200A HAIR SPACE
	$'\xe2\x80\xa8' # U+2028 LINE SEPARATOR
	$'\xe2\x80\xa9' # U+2029 PARAGRAPH SEPARATOR
	$'\xe2\x80\xaf' # U+202F NARROW NO-BREAK SPACE
	$'\xe2\x81\x9f' # U+205F MEDIUM MATHEMATICAL SPACE
	$'\xe3\x80\x80' # U+3000 IDEOGRAPHIC SPACE
)

# Set TRIMMED to $1 without the leading whitespace BuildKit trims: the ASCII
# whitespace bytes and UNICODE_SPACES, in any order.
ltrim_space() {
	local s="$1" u again=true
	while $again; do
		again=false
		s="${s#"${s%%[![:space:]]*}"}"
		for u in "${UNICODE_SPACES[@]}"; do
			if [[ "$s" == "$u"* ]]; then
				s="${s#"$u"}"
				again=true
			fi
		done
	done
	TRIMMED="$s"
}

DOCKER_EXTRA_SPACE=$'\v\f\r'

# BuildKit matches a keyword after Go's strings.ToLower, which also folds U+0130
# (dotted capital I) to i and U+212A (Kelvin sign) to k: the only non-ASCII
# letters it maps into ASCII. Fold them too, so ONBU\u0130LD is still ONBUILD.
upper() {
	local s="${1//$'\xc4\xb0'/I}"
	printf '%s' "${s//$'\xe2\x84\xaa'/K}" | tr '[:lower:]' '[:upper:]'
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_blank_or_comment() {
	ltrim_space "$1"
	case "$TRIMMED" in "" | "#"*) return 0 ;; esac
	return 1
}

# Whether the latest stage descends from ${BASE_IMAGE}, and the names of the
# stages so far that do (space-separated, lowercased as Docker matches them).
from_count=0
from_line=0
from_logical=""
from_on_base=false
base_stages=" "

# Record a FROM: its flags are skipped, then the image, then an optional AS name.
note_from() {
	local -a words=("${@:3}")
	local i=1 image name=""
	while [ "$i" -lt "${#words[@]}" ]; do
		case "${words[$i]}" in --*) i=$((i + 1)) ;; *) break ;; esac
	done
	image="$(unquote_word "${words[$i]:-}")"
	if [ $((i + 2)) -lt "${#words[@]}" ] && [ "$(lower "${words[$((i + 1))]}")" = as ]; then
		name="$(lower "${words[$((i + 2))]}")"
	fi
	from_count=$((from_count + 1))
	from_line="$1"
	from_logical="$2"
	from_on_base=false
	# shellcheck disable=SC2016 # the literal reference, not an expansion
	case "$image" in
	'${BASE_IMAGE}' | '$BASE_IMAGE') from_on_base=true ;;
	*)
		case "$base_stages" in
		*" $(lower "$image") "*) from_on_base=true ;;
		esac
		;;
	esac
	if $from_on_base && [ -n "$name" ]; then
		base_stages="${base_stages}${name} "
	fi
}

# Report an ONBUILD and a COPY or ADD whose flags lack --chmod=<mode>, and
# pass a FROM to note_from.
# Flags are the leading --name=value words after the keyword; Docker accepts
# instruction flags only in that position and only in the = form.
check_instruction() {
	local lineno="$1" logical="$2"
	local -a words
	# Docker splits an instruction on space, tab, VT, FF and CR; `read` splits
	# only on the first two, so map the others to spaces for it.
	read -r -a words <<<"${logical//[$DOCKER_EXTRA_SPACE]/ }" || true
	[ "${#words[@]}" -gt 0 ] || return 0
	local i keyword
	keyword="$(upper "${words[0]}")"
	if [ "$keyword" = FROM ]; then
		note_from "$lineno" "$logical" "${words[@]}"
		return 0
	fi
	if [ "$keyword" = ONBUILD ]; then
		report "${SET_DIR}/Dockerfile:${lineno}: ONBUILD is not allowed (its trigger runs in the agent build, outside the set's digest): ${logical}"
		return 0
	fi
	case "$keyword" in COPY | ADD) ;; *) return 0 ;; esac
	i=1
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

# Split $1 into the words BuildKit's shell lexer sees when it looks for
# heredocs: unquoted whitespace (Go's unicode.IsSpace, so UNICODE_SPACES too)
# separates words, while quotes and backslash escapes stay in the word along
# with any whitespace they cover. An unquoted << keeps the spaces, tabs and CRs
# right after it in its word, as the lexer's processPossibleHeredoc does, so
# `<< EOF` is one word and `<<` then a vertical tab is a bare <<. The words are
# left in SHELL_WORDS.
shell_words() {
	local s="$1" k c u word="" quote="" have=false
	SHELL_WORDS=()
	for ((k = 0; k < ${#s}; k++)); do
		c="${s:k:1}"
		if [ -z "$quote" ]; then
			case "$c" in
			$'\xc2' | $'\xe1' | $'\xe2' | $'\xe3')
				for u in "${UNICODE_SPACES[@]}"; do
					if [ "${s:k:${#u}}" = "$u" ]; then
						c=" "
						k=$((k + ${#u} - 1))
						break
					fi
				done
				;;
			esac
		fi
		if [ -n "$quote" ]; then
			word+="$c"
			if [ "$c" = "$quote" ]; then
				quote=""
			elif [ "$c" = "\\" ] && [ "$quote" = '"' ] && [ $((k + 1)) -lt "${#s}" ]; then
				k=$((k + 1))
				word+="${s:k:1}"
			fi
			continue
		fi
		case "$c" in
		' ' | $'\t' | $'\n' | $'\v' | $'\f' | $'\r')
			if $have; then SHELL_WORDS+=("$word"); fi
			word=""
			have=false
			;;
		\\)
			word+="$c"
			have=true
			if [ $((k + 1)) -lt "${#s}" ]; then
				k=$((k + 1))
				word+="${s:k:1}"
			fi
			;;
		\" | \')
			quote="$c"
			word+="$c"
			have=true
			;;
		'<')
			word+="$c"
			have=true
			if [ "${s:k+1:1}" = "<" ]; then
				k=$((k + 1))
				word+="<"
				while [ $((k + 1)) -lt "${#s}" ]; do
					case "${s:k+1:1}" in ' ' | $'\t' | $'\r') ;; *) break ;; esac
					k=$((k + 1))
					word+="${s:k:1}"
				done
			fi
			;;
		*)
			word+="$c"
			have=true
			;;
		esac
	done
	if $have; then SHELL_WORDS+=("$word"); fi
}

# The value of a shell word: quotes removed and backslash escapes resolved (in
# double quotes a backslash escapes only " $ and \, as in BuildKit's lexer).
unquote_word() {
	local s="$1" k c out="" quote=""
	for ((k = 0; k < ${#s}; k++)); do
		c="${s:k:1}"
		if [ "$quote" = "'" ]; then
			if [ "$c" = "'" ]; then quote=""; else out+="$c"; fi
		elif [ "$quote" = '"' ]; then
			if [ "$c" = '"' ]; then
				quote=""
			elif [ "$c" = "\\" ] && [ $((k + 1)) -lt "${#s}" ]; then
				case "${s:k+1:1}" in
				'"' | \\ | '$')
					k=$((k + 1))
					out+="${s:k:1}"
					;;
				*) out+="$c" ;;
				esac
			else
				out+="$c"
			fi
		elif [ "$c" = "'" ] || [ "$c" = '"' ]; then
			quote="$c"
		elif [ "$c" = "\\" ]; then
			if [ $((k + 1)) -lt "${#s}" ]; then
				k=$((k + 1))
				out+="${s:k:1}"
			fi
		else
			out+="$c"
		fi
	done
	printf '%s' "$out"
}

HEREDOC_RE='^[0-9]*<<(-?)[ '$'\t\r'']*([^<]*)$'

# Skip the bodies of the heredocs a RUN, COPY or ADD (also behind ONBUILD)
# opens, advancing i past each terminator in turn. As in BuildKit, a heredoc
# opener is a word reading <<NAME, << NAME (see shell_words) or <<-NAME,
# optionally after a file descriptor; the name is the word's value, so a quoted
# one may hold spaces.
skip_heredocs() {
	local lineno="$1" logical="$2"
	[[ "$logical" == *'<<'* ]] || return 0
	shell_words "$logical"
	local -a words=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
	[ "${#words[@]}" -gt 1 ] || return 0
	if [ "$(upper "${words[0]}")" = ONBUILD ]; then
		words=("${words[@]:1}")
		[ "${#words[@]}" -gt 1 ] || return 0
	fi
	case "$(upper "${words[0]}")" in RUN | COPY | ADD) ;; *) return 0 ;; esac
	local idx=1 chomp rest name body found
	while [ "$idx" -lt "${#words[@]}" ]; do
		if [[ "${words[$idx]}" =~ $HEREDOC_RE ]]; then
			chomp="${BASH_REMATCH[1]}"
			rest="${BASH_REMATCH[2]}"
			name=""
			[[ "$rest" == *"<"* ]] || name="$(unquote_word "$rest")"
			if [ -n "$name" ]; then
				found=false
				while [ $((i + 1)) -lt "$n" ]; do
					i=$((i + 1))
					body="${lines[$i]}"
					if [ -n "$chomp" ]; then
						while [ "${body:0:1}" = $'\t' ]; do body="${body:1}"; done
					fi
					if [ "$body" = "$name" ]; then
						found=true
						break
					fi
				done
				$found || report "${SET_DIR}/Dockerfile:${lineno}: heredoc ${name} is never terminated: ${logical}"
			fi
		fi
		idx=$((idx + 1))
	done
}

# `read` drops NUL bytes, which would join what Docker reads as separate lines
# (and the .ps1 keeps), so a Dockerfile holding one is refused outright.
if [ "$(tr -d '\000' <"$SET_DIR/Dockerfile" | wc -c)" -ne "$(wc -c <"$SET_DIR/Dockerfile")" ]; then
	report "${SET_DIR}/Dockerfile: contains a NUL byte"
	exit 1
fi

lines=()
while IFS= read -r line || [ -n "$line" ]; do
	# BuildKit strips every trailing CR, not only a CRLF's one.
	while [[ "$line" == *$'\r' ]]; do line="${line%$'\r'}"; done
	lines+=("$line")
done <"$SET_DIR/Dockerfile"
n="${#lines[@]}"
[ "$n" -eq 0 ] || lines[0]="${lines[0]#$'\xef\xbb\xbf'}"

# Parser directives are the leading `# name=value` lines naming a directive
# Docker knows; any other line ends them.
for ((i = 0; i < n; i++)); do
	ltrim_space "${lines[$i]}"
	[[ "$TRIMMED" == "#"* ]] || break
	ltrim_space "${TRIMMED:1}"
	[[ "$TRIMMED" =~ ^([A-Za-z][A-Za-z0-9]*)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || break
	case "$(lower "${BASH_REMATCH[1]}")" in syntax | escape | check) ;; *) break ;; esac
	if [ "$(lower "${BASH_REMATCH[1]}")" = escape ] && [ "${BASH_REMATCH[2]}" != "\\" ]; then
		report "${SET_DIR}/Dockerfile:$((i + 1)): only the default \\ escape is supported: ${lines[$i]}"
	fi
done

i=0
while [ "$i" -lt "$n" ]; do
	line="${lines[$i]}"
	start=$((i + 1))
	if is_blank_or_comment "$line"; then
		i=$((i + 1))
		continue
	fi
	# BuildKit trims an instruction's first line, not its continuations.
	ltrim_space "$line"
	logical="$TRIMMED"
	cont=false
	if ends_with_backslash "$logical"; then
		cont=true
		logical="$(strip_backslash "$logical")"
	fi
	while $cont && [ $((i + 1)) -lt "$n" ]; do
		i=$((i + 1))
		next="${lines[$i]}"
		is_blank_or_comment "$next" && continue
		if ends_with_backslash "$next"; then
			logical="${logical}$(strip_backslash "$next")"
		else
			logical="${logical}${next}"
			cont=false
		fi
	done
	# BuildKit's splitCommand trims the joined line too, so leading whitespace
	# a continuation brought in does not hide the keyword.
	ltrim_space "$logical"
	logical="$TRIMMED"
	check_instruction "$start" "$logical"
	skip_heredocs "$start" "$logical"
	i=$((i + 1))
done

if [ "$from_count" -eq 0 ]; then
	report "${SET_DIR}/Dockerfile: no FROM; the final stage must build FROM \${BASE_IMAGE}"
elif ! $from_on_base; then
	report "${SET_DIR}/Dockerfile:${from_line}: the final stage must build FROM \${BASE_IMAGE} (directly or through an earlier stage): ${from_logical}"
fi

entries="$(mktemp)"
trap 'rm -f "$entries"' EXIT
if ! (cd "$SET_DIR" && find . -mindepth 1 \( ! -type d -o -type d -empty \) -print0) >"$entries"; then
	echo "layers-digest: cannot list $SET_DIR" >&2
	exit 1
fi

files=()
while IFS= read -r -d '' rel; do
	rel="${rel#./}"
	path="${SET_DIR}/${rel}"
	if [ -L "$path" ]; then
		report "${path}: symlinks are not allowed in a layer set (create the link in a RUN instead)"
	elif [ -d "$path" ]; then
		report "${path}: empty directories are not allowed in a layer set (the digest covers files only; create the directory in a RUN instead)"
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
