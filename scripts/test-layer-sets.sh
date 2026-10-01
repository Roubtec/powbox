#!/usr/bin/env bash
# Hermetic tests for the layer-set mechanism: the selector
# (scripts/layers-select.{sh,ps1}), the set digest and its contract checks
# (scripts/layers-digest.{sh,ps1}), the build drivers' image decisions
# (scripts/build-image-lib.{sh,ps1}: layer-set currency, parent signature,
# Codex-commit resolution), the update check's layers row
# (commands/check-updates.{sh,ps1}), agent-update's routing of a stale set and
# agent-image-info (shell/powbox.{sh,ps1}), and both build drivers' dispatch
# (scripts/build-image.{sh,ps1}). Docker, npm and the build are fakes on PATH, so no
# daemon or image is needed. Every PowerShell twin is run against the same
# fixture and must agree with the bash one; without pwsh those halves report an
# honest skip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0
skip=0
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

HAVE_PWSH=false
if command -v pwsh >/dev/null 2>&1; then
	HAVE_PWSH=true
fi

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		printf '       %s\n' "${@:2}"
	fi
}

skipped() {
	skip=$((skip + 1))
	printf '  skip %s\n' "$1"
}

assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected: [$3]" "actual:   [$2]"; fi
}

assert_contains() {
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) ko "$1" "missing: [$3]" "in:      [$2]" ;;
	esac
}

assert_not_contains() {
	case "$2" in
	*"$3"*) ko "$1" "unexpected: [$3]" "in:         [$2]" ;;
	*) ok "$1" ;;
	esac
}

sha256_of_stdin() {
	sha256sum | cut -d' ' -f1
}

# ---------------------------------------------------------------------------
# Fakes: docker (image inspect / run / buildx imagetools), npm
# ---------------------------------------------------------------------------

FAKE_BIN="$WORK_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/docker" <<'SH'
#!/usr/bin/env bash
# Fake docker over a state directory: images/<name with : and / as _>/ holds
# id, signature-source, labels/<label>, and versions (for `docker run`).
state="${FAKE_DOCKER_STATE:?}"
printf '%s\n' "$*" >>"$state/calls.log"
img_dir() { printf '%s/images/%s' "$state" "$(printf '%s' "$1" | tr ':/' '__')"; }
# `buildx bake` simulation: log the targets and the variables the build driver
# exported, then write the images a real bake would leave, with labels set and
# inherited the way the bake file and Dockerfiles set them. A base bake writes a
# new ID over an unchanged layer chain unless the test staged a different one
# in base-signature-source; the skeleton layer set adds no layer either, unless
# the test staged layers-signature-source (a set built on some other image).
fake_bake() {
	local no_cache=false t n parent dir pdir
	shift 2 # --file <bake file>
	[ "$1" = --no-cache ] && { no_cache=true; shift; }
	for t; do
		{
			printf 'bake %s no-cache=%s' "$t" "$no_cache"
			for v in BASE_IMAGE CODEX_VERSION CLAUDE_CODE_VERSION POWBOX_COMMIT POWBOX_COMMIT_CODEX POWBOX_COMMIT_BASE \
				POWBOX_PARENT_SIGNATURE POWBOX_LAYERS_DIR POWBOX_LAYERS_SET POWBOX_LAYERS_DIGEST POWBOX_LAYERS_BASE_ID; do
				[ -n "${!v+x}" ] && printf ' %s=%s' "$v" "${!v}"
			done
			printf '\n'
		} >>"$state/bake.log"
		n=$(($(cat "$state/counter" 2>/dev/null || echo 0) + 1))
		echo "$n" >"$state/counter"
		case "$t" in
		base)
			dir="$(img_dir powbox-agent-base:latest)"
			rm -rf "$dir"
			mkdir -p "$dir/labels"
			echo "sha256:base-$n" >"$dir/id"
			if [ -f "$state/base-signature-source" ]; then
				cp "$state/base-signature-source" "$dir/signature-source"
			else
				echo '["sha256:b1"] ["PATH=/usr/bin"] null "/home/node" "node"' >"$dir/signature-source"
			fi
			echo "$POWBOX_COMMIT" >"$dir/labels/powbox.commit.base"
			;;
		layers | agent)
			if [ "$t" = layers ]; then
				parent=powbox-agent-base:latest
				dir="$(img_dir powbox-agent-layers:latest)"
			else
				parent="$BASE_IMAGE"
				dir="$(img_dir powbox-agent:latest)"
			fi
			pdir="$(img_dir "$parent")"
			[ -d "$pdir" ] || { echo "fake bake: parent $parent missing" >&2; exit 1; }
			rm -rf "$dir"
			mkdir -p "$dir"
			cp -r "$pdir/labels" "$dir/labels"
			cp "$pdir/signature-source" "$dir/signature-source"
			if [ "$t" = layers ] && [ -f "$state/layers-signature-source" ]; then
				cp "$state/layers-signature-source" "$dir/signature-source"
			fi
			# A set whose ONBUILD escaped the Dockerfile scan records it here.
			if [ "$t" = layers ] && [ -f "$state/layers-onbuild" ]; then
				cp "$state/layers-onbuild" "$dir/onbuild"
			fi
			echo "sha256:$t-$n" >"$dir/id"
			if [ "$t" = layers ]; then
				echo "$POWBOX_LAYERS_SET" >"$dir/labels/powbox.layers.set"
				echo "$POWBOX_LAYERS_DIGEST" >"$dir/labels/powbox.layers.digest"
				echo "$POWBOX_LAYERS_BASE_ID" >"$dir/labels/powbox.layers.base.id"
				echo "$POWBOX_COMMIT" >"$dir/labels/powbox.commit.layers"
			else
				echo "$POWBOX_COMMIT" >"$dir/labels/powbox.commit.claude"
				echo "$POWBOX_COMMIT_CODEX" >"$dir/labels/powbox.commit.codex"
				echo "$POWBOX_PARENT_SIGNATURE" >"$dir/labels/powbox.parent.signature"
				echo "$CODEX_VERSION" >"$dir/labels/powbox.codex.version"
				echo "$CLAUDE_CODE_VERSION" >"$dir/labels/powbox.claude.version"
				# What the top metadata layer writes to /home/node/.powbox/base.commit.
				echo "$POWBOX_COMMIT_BASE" >"$dir/base.commit"
			fi
			;;
		esac
	done
}
case "$1 $2" in
"--version ")
	echo "Docker version 27.3.1, build fake"
	;;
"pull "*)
	exit 0
	;;
"buildx bake")
	shift 2
	fake_bake "$@"
	;;
"image inspect")
	dir="$(img_dir "$3")"
	[ -d "$dir" ] || { echo "Error: No such image: $3" >&2; exit 1; }
	shift 3
	[ "$#" -eq 0 ] && { echo '[{}]'; exit 0; }
	[ "$1" = --format ] || { echo "fake docker: unsupported inspect args: $*" >&2; exit 64; }
	fmt="$2"
	case "$fmt" in
	'{{.Id}}') cat "$dir/id"; exit 0 ;;
	'{{json .RootFS.Layers}}') cut -d' ' -f1 "$dir/signature-source"; exit 0 ;;
	'{{json .RootFS.Layers}}'*) cat "$dir/signature-source"; exit 0 ;;
	'{{json .Config.OnBuild}}') cat "$dir/onbuild" 2>/dev/null || echo null; exit 0 ;;
	esac
	out="$fmt"
	re='\{\{ ?index \.Config\.Labels "([^"]*)" ?\}\}'
	while [[ "$out" =~ $re ]]; do
		val=""
		[ -f "$dir/labels/${BASH_REMATCH[1]}" ] && val="$(cat "$dir/labels/${BASH_REMATCH[1]}")"
		out="${out/"${BASH_REMATCH[0]}"/$val}"
	done
	printf '%s\n' "$out"
	;;
"run --rm")
	# The image is the argument before "-c".
	img=""
	prev=""
	for a in "$@"; do
		[ "$a" = -c ] && img="$prev"
		prev="$a"
	done
	dir="$(img_dir "$img")"
	[ -f "$dir/versions" ] && cat "$dir/versions"
	;;
"buildx imagetools")
	[ -f "$state/registry-digest" ] || exit 1
	cat "$state/registry-digest"
	;;
*)
	echo "fake docker: unsupported: $*" >&2
	exit 64
	;;
esac
SH
cat >"$FAKE_BIN/npm" <<'SH'
#!/usr/bin/env bash
# Fake `npm view <pkg> version`.
state="${FAKE_DOCKER_STATE:?}"
[ "$1" = view ] || exit 1
f="$state/npm/$(printf '%s' "$2" | tr '@/' '__')"
[ -f "$f" ] || exit 1
cat "$f"
SH
chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/npm"

# new_state: a fresh fake-docker state directory, echoed.
new_state() {
	local st
	st="$(mktemp -d "$WORK_ROOT/state.XXXXXX")"
	mkdir -p "$st/images" "$st/npm"
	: >"$st/calls.log"
	printf '%s\n' "$st"
}

# mkimage <state> <image> [label=value...]: create (or replace) a fake image.
mkimage() {
	local st="$1" img="$2" dir kv
	shift 2
	dir="$st/images/$(printf '%s' "$img" | tr ':/' '__')"
	rm -rf "$dir"
	mkdir -p "$dir/labels"
	printf 'sha256:%s\n' "$(printf '%s' "$img" | sha256_of_stdin)" >"$dir/id"
	printf '%s\n' '["sha256:l1","sha256:l2"] ["PATH=/usr/bin"] null "/home/node" "node"' >"$dir/signature-source"
	for kv in "$@"; do
		printf '%s\n' "${kv#*=}" >"$dir/labels/${kv%%=*}"
	done
}

# set_image_field <state> <image> <file> <value>
set_image_field() {
	printf '%s\n' "$4" >"$1/images/$(printf '%s' "$2" | tr ':/' '__')/$3"
}

with_fakes() {
	local st="$1"
	shift
	FAKE_DOCKER_STATE="$st" PATH="$FAKE_BIN:$PATH" "$@"
}

# ---------------------------------------------------------------------------
# 1. Selector
# ---------------------------------------------------------------------------

echo "Test: layers-select parses .powbox-layers and agrees across bash and PowerShell"

SEL_SH="$ROOT_DIR/scripts/layers-select.sh"
SEL_PS="$ROOT_DIR/scripts/layers-select.ps1"

# sel_case <label> <mode:absent|file|dir> <content> <expected-stdout> <expected-rc> [stderr-fragment...]
sel_case() {
	local label="$1" mode="$2" content="$3" want_out="$4" want_rc="$5"
	shift 5
	local root out err rc frag ps_out ps_err ps_rc
	root="$(mktemp -d "$WORK_ROOT/sel.XXXXXX")"
	mkdir -p "$root/docker/layers/full" "$root/docker/layers/custom" "$root/docker/layers/my.set_1-a" "$root/docker/layers/emptyset"
	: >"$root/docker/layers/full/Dockerfile"
	: >"$root/docker/layers/custom/Dockerfile"
	: >"$root/docker/layers/my.set_1-a/Dockerfile"
	case "$mode" in
	file) printf '%s' "$content" >"$root/.powbox-layers" ;;
	dir) mkdir "$root/.powbox-layers" ;;
	esac
	rc=0
	out="$(bash "$SEL_SH" "$root" 2>"$root/err")" || rc=$?
	err="$(cat "$root/err")"
	assert_eq "select [$label] bash stdout" "$out" "$want_out"
	assert_eq "select [$label] bash exit" "$rc" "$want_rc"
	for frag in "$@"; do
		assert_contains "select [$label] bash error names '$frag'" "$err" "$frag"
	done
	if ! $HAVE_PWSH; then
		skipped "select [$label] PowerShell parity (pwsh not installed)"
		return
	fi
	ps_rc=0
	ps_out="$(pwsh -NoProfile -File "$SEL_PS" "$root" 2>"$root/err.ps")" || ps_rc=$?
	ps_err="$(cat "$root/err.ps")"
	assert_eq "select [$label] PowerShell stdout matches bash" "$ps_out" "$out"
	assert_eq "select [$label] PowerShell exit matches bash" "$ps_rc" "$rc"
	assert_eq "select [$label] PowerShell error matches bash" "$ps_err" "$err"
}

sel_case "absent" absent "" "" 0
sel_case "empty" file "" "" 0
sel_case "blank and comments only" file $'\n   \n# full\n\t# custom\n' "" 0
sel_case "plain name" file $'full\n' "full" 0
sel_case "no trailing newline" file 'full' "full" 0
sel_case "surrounding whitespace" file $'  full \t\n' "full" 0
sel_case "comment before name" file $'# pick one\n\nfull\n' "full" 0
sel_case "CRLF" file $'full\r\n' "full" 0
sel_case "UTF-8 BOM" file $'\xef\xbb\xbffull\n' "full" 0
sel_case "BOM, CRLF, comment" file $'\xef\xbb\xbf# choose\r\n\r\ncustom\r\n' "custom" 0
sel_case "first name wins" file $'full\ncustom\n' "full" 0
sel_case "dots, underscore, dash" file $'my.set_1-a\n' "my.set_1-a" 0
sel_case "space in name" file $'Bad Name\n' "" 1 "'Bad Name'" ".powbox-layers"
sel_case "uppercase" file $'FULL\n' "" 1 "'FULL'"
sel_case "leading dash" file $'-full\n' "" 1 "'-full'"
sel_case "path traversal" file $'../full\n' "" 1 "'../full'"
sel_case "leading dot" file $'.hidden\n' "" 1 "'.hidden'"
sel_case "non-breaking space is not trimmed" file $'full\xc2\xa0\n' "" 1 "invalid layer-set name"
sel_case "lone CR mid-line" file $'fu\rll\n' "" 1 "invalid layer-set name"
sel_case "missing set directory" file $'nosuchset\n' "" 1 "docker/layers/nosuchset/Dockerfile"
sel_case "set without Dockerfile" file $'emptyset\n' "" 1 "docker/layers/emptyset/Dockerfile"
sel_case "selector is a directory" dir "" "" 1 ".powbox-layers is not a regular file"

# ---------------------------------------------------------------------------
# 2. Digest and the layer Dockerfile contract
# ---------------------------------------------------------------------------

echo "Test: layers-digest is deterministic, content-only, and enforces the contract"

DIG_SH="$ROOT_DIR/scripts/layers-digest.sh"
DIG_PS="$ROOT_DIR/scripts/layers-digest.ps1"

# shellcheck disable=SC2016 # a literal Dockerfile
GOOD_DOCKERFILE='ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}
USER root
COPY --chmod=644 notes.md /opt/notes.md
USER node
'

# make_set <dir> [reverse]: a small valid set; "reverse" creates the same files
# in the opposite order.
make_set() {
	local d="$1"
	mkdir -p "$d"
	if [ "${2:-}" = reverse ]; then
		mkdir -p "$d/sub/deeper"
		printf 'deep\n' >"$d/sub/deeper/z.txt"
		printf 'alpha\n' >"$d/sub/a.txt"
		: >"$d/.gitkeep"
		printf 'notes\n' >"$d/notes.md"
		printf '%s' "$GOOD_DOCKERFILE" >"$d/Dockerfile"
	else
		printf '%s' "$GOOD_DOCKERFILE" >"$d/Dockerfile"
		printf 'notes\n' >"$d/notes.md"
		: >"$d/.gitkeep"
		mkdir -p "$d/sub/deeper"
		printf 'alpha\n' >"$d/sub/a.txt"
		printf 'deep\n' >"$d/sub/deeper/z.txt"
	fi
}

# Independent reference for the documented algorithm.
reference_digest() {
	(
		cd "$1"
		find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r p; do
			printf '%s  %s\n' "$(sha256_of_stdin <"$p")" "$p"
		done
	) | sha256_of_stdin | sed 's/^/sha256:/'
}

digest() {
	bash "$DIG_SH" "$1" 2>/dev/null
}

set_a="$WORK_ROOT/set-a"
make_set "$set_a"
d_a="$(digest "$set_a")"
assert_eq "digest follows the documented algorithm" "$d_a" "$(reference_digest "$set_a")"
assert_eq "digest is repeatable" "$(digest "$set_a")" "$d_a"
assert_eq "trailing slash on the directory is ignored" "$(digest "$set_a/")" "$d_a"

set_b="$WORK_ROOT/set-b"
make_set "$set_b" reverse
assert_eq "digest does not depend on creation order" "$(digest "$set_b")" "$d_a"

chmod +x "$set_b/notes.md"
assert_eq "digest is content-only (a mode change does not move it)" "$(digest "$set_b")" "$d_a"

# The digest hashes files only, so an empty directory, which COPY would still
# copy, is rejected rather than silently left out (see "an empty directory").
mkdir -p "$set_b/empty-dir"
assert_eq "an empty directory yields no digest" "$(digest "$set_b")" ""
rmdir "$set_b/empty-dir"

mkdir -p "$set_b/keep-only"
: >"$set_b/keep-only/.gitkeep"
d_keep="$(digest "$set_b")"
if [ -n "$d_keep" ] && [ "$d_keep" != "$d_a" ]; then ok "a .gitkeep-only subdirectory is hashed"; else ko "a .gitkeep-only subdirectory is hashed"; fi
rm -r "$set_b/keep-only"

rm "$set_b/.gitkeep"
d_nokeep="$(digest "$set_b")"
if [ -n "$d_nokeep" ] && [ "$d_nokeep" != "$d_a" ]; then ok "the top-level .gitkeep is hashed like any file"; else ko "the top-level .gitkeep is hashed like any file"; fi
: >"$set_b/.gitkeep"

printf 'alpha!\n' >"$set_b/sub/a.txt"
d_edit="$(digest "$set_b")"
if [ -n "$d_edit" ] && [ "$d_edit" != "$d_a" ]; then ok "editing a file not COPYed changes the digest"; else ko "editing a file not COPYed changes the digest"; fi
printf 'alpha\n' >"$set_b/sub/a.txt"

mv "$set_b/sub/a.txt" "$set_b/sub/b.txt"
d_ren="$(digest "$set_b")"
if [ -n "$d_ren" ] && [ "$d_ren" != "$d_a" ]; then ok "renaming a file changes the digest"; else ko "renaming a file changes the digest"; fi
mv "$set_b/sub/b.txt" "$set_b/sub/a.txt"
assert_eq "restoring the tree restores the digest" "$(digest "$set_b")" "$d_a"

set_mode="$WORK_ROOT/set-mode"
make_set "$set_mode"
sed -i 's/--chmod=644/--chmod=755/' "$set_mode/Dockerfile"
d_mode="$(digest "$set_mode")"
if [ -n "$d_mode" ] && [ "$d_mode" != "$d_a" ]; then ok "changing a --chmod= mode changes the digest"; else ko "changing a --chmod= mode changes the digest"; fi

# reject_case <label> <setdir> <stderr-fragment...>: the set must be rejected
# with exit 1, naming each fragment, and print no digest.
reject_case() {
	local label="$1" dir="$2" out err rc frag
	shift 2
	rc=0
	out="$(bash "$DIG_SH" "$dir" 2>"$WORK_ROOT/dig.err")" || rc=$?
	err="$(cat "$WORK_ROOT/dig.err")"
	assert_eq "digest rejects [$label] (exit 1)" "$rc" "1"
	assert_eq "digest rejects [$label] with no digest" "$out" ""
	for frag in "$@"; do
		assert_contains "digest rejects [$label] naming '$frag'" "$err" "$frag"
	done
}

# dockerfile_case <label> <dockerfile-body> <ok|reject> [stderr-fragment...]
dockerfile_case() {
	local label="$1" body="$2" want="$3" d
	shift 3
	d="$(mktemp -d "$WORK_ROOT/df.XXXXXX")"
	make_set "$d"
	printf '%s' "$body" >"$d/Dockerfile"
	if [ "$want" = ok ]; then
		local out
		out="$(digest "$d")"
		case "$out" in
		sha256:*) ok "digest accepts [$label]" ;;
		*) ko "digest accepts [$label]" "got: [$out]" ;;
		esac
	else
		reject_case "$label" "$d" "$@"
	fi
}

dockerfile_case "COPY without --chmod" $'FROM ${BASE_IMAGE}\nUSER root\nCOPY notes.md /opt/notes.md\nUSER node\n' reject "Dockerfile:3:" "COPY notes.md /opt/notes.md"
dockerfile_case "ADD without --chmod" $'FROM ${BASE_IMAGE}\nADD notes.md /opt/\n' reject "Dockerfile:2:" "ADD without --chmod="
dockerfile_case "lowercase copy" $'FROM ${BASE_IMAGE}\ncopy notes.md /opt/\n' reject "Dockerfile:2:"
dockerfile_case "COPY with --chown only" $'FROM ${BASE_IMAGE}\nCOPY --chown=node:node notes.md /opt/\n' reject "Dockerfile:2:"
dockerfile_case "ONBUILD COPY without --chmod" $'FROM ${BASE_IMAGE}\nONBUILD COPY notes.md /opt/\n' reject "Dockerfile:2: ONBUILD is not allowed"
dockerfile_case "ONBUILD COPY with --chmod" $'FROM ${BASE_IMAGE}\nONBUILD COPY --chmod=644 notes.md /opt/\n' reject "Dockerfile:2: ONBUILD is not allowed"
dockerfile_case "ONBUILD RUN with a bind mount" $'FROM ${BASE_IMAGE}\nonbuild RUN --mount=type=bind,target=/ctx cat /ctx/x\n' reject "Dockerfile:2: ONBUILD is not allowed"
dockerfile_case "ONBUILD in a builder stage" $'FROM golang AS build\nONBUILD ADD --chmod=644 a /a\nFROM ${BASE_IMAGE}\n' reject "Dockerfile:2: ONBUILD is not allowed"
dockerfile_case "continued ONBUILD, named by its first line" $'FROM ${BASE_IMAGE}\nONBUILD \\\n  RUN true\n' reject "Dockerfile:2: ONBUILD is not allowed"
dockerfile_case "empty --chmod=" $'FROM ${BASE_IMAGE}\nCOPY --chmod= notes.md /opt/\n' reject "Dockerfile:2:"
dockerfile_case "--chmod= after the sources does not count" $'FROM ${BASE_IMAGE}\nCOPY notes.md --chmod=644 /opt/\n' reject "Dockerfile:2:"
dockerfile_case "continued COPY lacking --chmod, named by its first line" $'FROM ${BASE_IMAGE}\nRUN true\nCOPY \\\n    notes.md \\\n    /opt/\n' reject "Dockerfile:3: COPY without --chmod=<mode>"
dockerfile_case "two violations, both named" $'FROM ${BASE_IMAGE}\nCOPY a /a\nADD b /b\n' reject "Dockerfile:2:" "Dockerfile:3:"
dockerfile_case "COPY with --chmod" $'FROM ${BASE_IMAGE}\nCOPY --chmod=644 notes.md /opt/\n' ok
dockerfile_case "ADD with --chmod among other flags" $'FROM ${BASE_IMAGE}\nADD --chown=node:node --chmod=0755 notes.md /opt/\n' ok
dockerfile_case "--chmod= on a continuation line" $'FROM ${BASE_IMAGE}\nCOPY \\\n  # comment inside the instruction\n\n  --chmod=644 notes.md /opt/\n' ok
dockerfile_case "CRLF Dockerfile" $'FROM ${BASE_IMAGE}\r\nCOPY --chmod=644 \\\r\n  notes.md /opt/\r\n' ok
dockerfile_case "COPY in a comment or a RUN" $'FROM ${BASE_IMAGE}\n# COPY notes.md /opt/\nRUN echo COPY notes.md /opt/\n' ok
dockerfile_case "no COPY at all" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nUSER root\nUSER node' ok
# The final stage must descend from ${BASE_IMAGE}: the bake stamps the base's ID
# on the layer image, which the update check trusts as proof of the chain.
dockerfile_case "final stage on another image" $'FROM busybox\nUSER node\n' reject "Dockerfile:1: the final stage must build FROM \${BASE_IMAGE}" "FROM busybox"
dockerfile_case "no FROM at all" $'ARG BASE_IMAGE=b\n' reject "Dockerfile: no FROM"
dockerfile_case "builder stage last" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nFROM golang AS build\n' reject "Dockerfile:3: the final stage"
dockerfile_case "final stage named after a non-base stage" $'FROM golang AS b\nFROM b\n' reject "Dockerfile:2: the final stage"
dockerfile_case "FROM rule and --chmod rule both named" $'FROM busybox\nCOPY a /a\n' reject "Dockerfile:2: COPY without" "Dockerfile:1: the final stage"
dockerfile_case "unbraced \$BASE_IMAGE, lowercase from" $'ARG BASE_IMAGE=b\nfrom $BASE_IMAGE\n' ok
dockerfile_case "--platform flag and a stage built on the base" $'ARG BASE_IMAGE=b\nFROM --platform=linux/amd64 ${BASE_IMAGE} AS Base\nFROM base\n' ok
dockerfile_case "builder stage first, base stage last" $'ARG BASE_IMAGE=b\nFROM golang AS build\nRUN true\nFROM ${BASE_IMAGE}\nCOPY --from=build --chmod=755 /x /x\n' ok
# Lines are read as Docker reads them: heredoc bodies are not instructions,
# continuations join with nothing added, and only the backslash escape is known.
dockerfile_case "heredoc body cannot stand in for the final FROM" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nFROM busybox\nRUN cat <<\'EOF\' >/tmp/x\nFROM ${BASE_IMAGE}\nEOF\n' reject "Dockerfile:3: the final stage"
dockerfile_case "COPY heredoc body cannot stand in for the final FROM" $'FROM busybox\nCOPY --chmod=644 <<EOF /x\nFROM $BASE_IMAGE\nEOF\n' reject "Dockerfile:1: the final stage"
dockerfile_case "heredoc body lines are not instructions" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN <<EOF\nfrom busybox\ncopy a b\nEOF\n' ok
dockerfile_case "<<- heredoc ends at a tab-indented terminator" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN <<-"EOT" bash\n\tFROM busybox\n\tEOT\nUSER node\n' ok
dockerfile_case "two heredocs on one instruction" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nCOPY --chmod=644 <<A <<B /dst/\nFROM x\nA\nCOPY y\nB\n' ok
dockerfile_case "unterminated heredoc" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN cat <<EOF\nhello\n' reject "Dockerfile:3: heredoc EOF is never terminated"
dockerfile_case "<< inside quotes opens no heredoc" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN echo "a <<EOF b"\nFROM busybox\n' reject "Dockerfile:4: the final stage"
dockerfile_case "here-string is not a heredoc" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN cat <<<hello\n' ok
dockerfile_case "continuation joins mid-word" $'ARG BASE_IMAGE=b\nFROM ${BASE_\\\nIMAGE}\n' ok
dockerfile_case "backtick escape directive" $'# escape=`\nARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\n' reject "Dockerfile:1: only the default \\ escape is supported"
dockerfile_case "backslash escape directive" $'# Escape = \\ \nARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\n' ok
dockerfile_case "escape after an instruction is a comment" $'ARG BASE_IMAGE=b\n# escape=`\nFROM ${BASE_IMAGE}\n' ok
dockerfile_case "UTF-8 BOM before a directive" $'\xef\xbb\xbf# escape=`\nFROM ${BASE_IMAGE}\n' reject "Dockerfile:1: only the default"
dockerfile_case "escaped trailing backslash does not continue" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN echo C:\\\\\nFROM busybox\n' reject "Dockerfile:4: the final stage"
dockerfile_case "indented escape directive" $'  # escape=`\nARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\n' reject "Dockerfile:1: only the default"
dockerfile_case "an unknown directive ends the directives" $'# custom=value\n# escape=`\nARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\n' ok
dockerfile_case "ONBUILD heredoc body is not an instruction" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nFROM busybox\nONBUILD RUN cat <<EOF >/x\nFROM ${BASE_IMAGE}\nEOF\n' reject "Dockerfile:3: the final stage" "Dockerfile:4: ONBUILD is not allowed"
dockerfile_case "escaped quote opens no quote" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nFROM busybox\nRUN echo \\" <<EOF\nFROM ${BASE_IMAGE}\nEOF\n' reject "Dockerfile:3: the final stage"
dockerfile_case "backslash-quoted heredoc name" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN cat <<\\EOF\nfrom x\nEOF\n' ok
dockerfile_case "<< EOF with a space" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN python3 - << EOF\nfrom os import path\nEOF\n' ok
dockerfile_case "<<- then a space opens no heredoc, as in BuildKit" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN cat <<- EOF >/x\n\tFROM busybox\n\tEOF\n' reject "Dockerfile:4: the final stage"
dockerfile_case "quoted heredoc name holding a space" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN <<\'END SCRIPT\'\necho hi\nEND SCRIPT\nUSER node\n' ok
dockerfile_case "double-quoted name with a space skips a FROM body line" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN cat <<"A B" >/f\nFROM busybox\nA B\n' ok
dockerfile_case "escaped quote inside a double-quoted name" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN cat <<"E\\"F"\nFROM y\nE"F\n' ok
dockerfile_case "vertical tab separates FROM from its image" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nFROM\vbusybox\n' reject "Dockerfile:3: the final stage"
dockerfile_case "form feed separates COPY from its sources" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nCOPY\fa /b\n' reject "Dockerfile:3: COPY without"
dockerfile_case "quoted FROM image is compared unquoted" $'ARG BASE_IMAGE=b\nFROM "${BASE_IMAGE}"\nUSER node\n' ok
dockerfile_case "backtick in a double-quoted name stays literal" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN cat <<"E\\`F"\nFROM y\nE\\`F\n' ok
dockerfile_case "<< in shell arithmetic is a heredoc to Docker too" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN echo $((1 << 3))\n' reject "heredoc 3)) is never terminated"
dockerfile_case "<< EOF body cannot stand in for the final FROM" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nFROM busybox\nRUN cat << EOF >/x\nFROM ${BASE_IMAGE}\nEOF\n' reject "Dockerfile:3: the final stage"
dockerfile_case "ONBUILD indented with U+00A0" $'FROM ${BASE_IMAGE}\n\xc2\xa0ONBUILD COPY --chmod=644 a /a\n' reject "Dockerfile:2: ONBUILD is not allowed"
dockerfile_case "ONBUILD indented with U+3000 and a tab" $'FROM ${BASE_IMAGE}\n\t\xe3\x80\x80ONBUILD RUN true\n' reject "Dockerfile:2: ONBUILD is not allowed"
dockerfile_case "ONBUILD spelled with U+0130" $'FROM ${BASE_IMAGE}\nONBU\xc4\xb0LD RUN true\n' reject "Dockerfile:2: ONBUILD is not allowed"
dockerfile_case "vertical tab after a backslash does not continue" $'FROM ${BASE_IMAGE}\nRUN echo \\\v\nONBUILD COPY --chmod=644 a /a\n' reject "Dockerfile:3: ONBUILD is not allowed"
dockerfile_case "form feed after a backslash does not continue" $'FROM ${BASE_IMAGE}\nRUN echo \\\f\nONBUILD RUN true\n' reject "Dockerfile:3: ONBUILD is not allowed"
dockerfile_case "every trailing CR is stripped before a continuation" $'FROM busybox\nRUN echo \\\r\r\nFROM ${BASE_IMAGE}\n' reject "Dockerfile:1: the final stage"
dockerfile_case "a U+00A0-indented comment is a comment" $'FROM ${BASE_IMAGE}\n\xc2\xa0# note \\\nONBUILD RUN true\n' reject "Dockerfile:3: ONBUILD is not allowed"
dockerfile_case "a U+00A0-only line inside a continuation is skipped" $'FROM busybox\nRUN echo \\\n\xc2\xa0\nFROM ${BASE_IMAGE}\n' reject "Dockerfile:1: the final stage"
dockerfile_case "escape directive indented with U+00A0" $'\xc2\xa0# escape=`\nFROM ${BASE_IMAGE}\n' reject "Dockerfile:1: only the default"
dockerfile_case "escape directive with U+2003 after the #" $'#\xe2\x80\x83escape=`\nFROM ${BASE_IMAGE}\n' reject "Dockerfile:1: only the default"
dockerfile_case "U+00A0 brought in by a continuation" $'FROM ${BASE_IMAGE}\n\\\n\xc2\xa0ONBUILD RUN true\n' reject "Dockerfile:2: ONBUILD is not allowed"
dockerfile_case "<< then a vertical tab opens no heredoc" $'FROM ${BASE_IMAGE}\nRUN true <<\v\'RUN true\'\nONBUILD COPY --chmod=644 a /a\nRUN true\n' reject "Dockerfile:3: ONBUILD is not allowed"
dockerfile_case "<< then a form feed opens no heredoc" $'FROM ${BASE_IMAGE}\nRUN true <<\fX\nCOPY a /a\nX\n' reject "Dockerfile:3: COPY without"
dockerfile_case "<< then U+00A0 opens no heredoc" $'FROM ${BASE_IMAGE}\nRUN true <<\xc2\xa0X\nONBUILD RUN true\nX\n' reject "Dockerfile:3: ONBUILD is not allowed"
dockerfile_case "<< then a tab and a CR still opens one" $'ARG BASE_IMAGE=b\nFROM ${BASE_IMAGE}\nRUN cat <<\t\rEOF\nFROM busybox\nEOF\n' ok
dockerfile_case "U+00A0 separates a heredoc word" $'FROM ${BASE_IMAGE}\nRUN true\xc2\xa0<<"EOF\\\\"\ntrue\nEOF\\\nONBUILD COPY --chmod=644 . /x\n' reject "Dockerfile:5: ONBUILD is not allowed"
dockerfile_case "U+00A0 ends a heredoc name" $'FROM ${BASE_IMAGE}\nRUN true <<\'LABEL a=b\'\xc2\xa0c=d\ntrue\nLABEL a=b\nONBUILD COPY --chmod=644 . /x\nLABEL a=b\xc2\xa0c=d\n' reject "Dockerfile:5: ONBUILD is not allowed"

set_link="$WORK_ROOT/set-link"
make_set "$set_link"
ln -s notes.md "$set_link/sub/link.md"
reject_case "a file symlink" "$set_link" "$set_link/sub/link.md" "symlinks are not allowed"

set_dirlink="$WORK_ROOT/set-dirlink"
make_set "$set_dirlink"
ln -s sub "$set_dirlink/sub-link"
reject_case "a directory symlink" "$set_dirlink" "$set_dirlink/sub-link"

set_fifo="$WORK_ROOT/set-fifo"
make_set "$set_fifo"
mkfifo "$set_fifo/pipe"
reject_case "a FIFO" "$set_fifo" "$set_fifo/pipe" "not a regular file"

set_emptydir="$WORK_ROOT/set-emptydir"
make_set "$set_emptydir"
mkdir -p "$set_emptydir/cache/inner"
reject_case "an empty directory" "$set_emptydir" "$set_emptydir/cache/inner: empty directories are not allowed"

set_nul="$WORK_ROOT/set-nul"
make_set "$set_nul"
printf 'FROM ${BASE_IMAGE}\nARG a=b\\\000\nONBUILD RUN true\n' >"$set_nul/Dockerfile"
reject_case "a NUL byte" "$set_nul" "$set_nul/Dockerfile: contains a NUL byte"

set_nodf="$WORK_ROOT/set-nodf"
make_set "$set_nodf"
rm "$set_nodf/Dockerfile"
reject_case "a set without a Dockerfile" "$set_nodf" "$set_nodf/Dockerfile"
reject_case "a missing directory" "$WORK_ROOT/no-such-set" "$WORK_ROOT/no-such-set"

rc=0
bash "$DIG_SH" >/dev/null 2>&1 || rc=$?
assert_eq "digest without an argument is a usage error (exit 2)" "$rc" "2"

# A PATH without sha256sum, shasum or openssl: the set is still checked, but
# the digest is undeterminable (exit 3), which callers treat apart from a
# broken set.
NOSHA_BIN="$WORK_ROOT/nosha-bin"
mkdir -p "$NOSHA_BIN"
for tool in bash env dirname sed head grep sort find mktemp rm tr cut cat; do
	ln -s "$(command -v "$tool")" "$NOSHA_BIN/$tool"
done
ln -s "$FAKE_BIN/docker" "$NOSHA_BIN/docker"
ln -s "$FAKE_BIN/npm" "$NOSHA_BIN/npm"
rc=0
out="$(PATH="$NOSHA_BIN" bash "$DIG_SH" "$set_a" 2>"$WORK_ROOT/nosha.err")" || rc=$?
assert_eq "no sha256 tool: exit 3" "$rc" "3"
assert_eq "no sha256 tool: no digest printed" "$out" ""
assert_contains "no sha256 tool: says so" "$(cat "$WORK_ROOT/nosha.err")" "no sha256 tool"
rc=0
PATH="$NOSHA_BIN" bash "$DIG_SH" "$set_link" >/dev/null 2>&1 || rc=$?
assert_eq "no sha256 tool: a broken set is still exit 1" "$rc" "1"

echo "Test: layers-digest.ps1 matches layers-digest.sh"
if $HAVE_PWSH; then
	# dig_parity <label> <setdir>: identical stdout, exit status and stderr.
	dig_parity() {
		local sh_out sh_err sh_rc=0 ps_out ps_err ps_rc=0
		sh_out="$(bash "$DIG_SH" "$2" 2>"$WORK_ROOT/p.sh.err")" || sh_rc=$?
		sh_err="$(cat "$WORK_ROOT/p.sh.err")"
		ps_out="$(pwsh -NoProfile -File "$DIG_PS" "$2" 2>"$WORK_ROOT/p.ps.err")" || ps_rc=$?
		ps_err="$(cat "$WORK_ROOT/p.ps.err")"
		assert_eq "digest parity [$1] stdout" "$ps_out" "$sh_out"
		assert_eq "digest parity [$1] exit" "$ps_rc" "$sh_rc"
		assert_eq "digest parity [$1] stderr" "$ps_err" "$sh_err"
	}
	dig_parity "valid set" "$set_a"
	dig_parity "same set, other creation order" "$set_b"
	dig_parity "other --chmod mode" "$set_mode"
	set_names="$WORK_ROOT/set-names"
	make_set "$set_names"
	printf 'x\n' >"$set_names/B.txt"
	printf 'x\n' >"$set_names/a b.txt"
	printf 'x\n' >"$set_names/_under"
	printf 'x\n' >"$set_names/.dot"
	mkdir -p "$set_names/sub-dir" "$set_names/sub.dir"
	printf 'x\n' >"$set_names/sub-dir/f"
	printf 'x\n' >"$set_names/sub.dir/f"
	dig_parity "names that sort differently by locale" "$set_names"
	# U+FF21 (EF BC A1) sorts before U+1F600 (F0 9F 98 80) by UTF-8 bytes, but
	# after it by UTF-16 code units (FF21 vs the D83D surrogate).
	set_utf8="$WORK_ROOT/set-utf8"
	make_set "$set_utf8"
	printf 'x\n' >"$set_utf8/"$'\xef\xbc\xa1'".txt"
	printf 'y\n' >"$set_utf8/"$'\xf0\x9f\x98\x80'".txt"
	dig_parity "names whose UTF-8 and UTF-16 orders differ" "$set_utf8"
	dig_parity "a file symlink" "$set_link"
	dig_parity "a directory symlink" "$set_dirlink"
	dig_parity "a FIFO" "$set_fifo"
	dig_parity "an empty directory" "$set_emptydir"
	dig_parity "a NUL byte" "$set_nul"
	dig_parity "no Dockerfile" "$set_nodf"
	for body in $'FROM ${BASE_IMAGE}\nCOPY a /a\nADD b /b\n' \
		$'FROM ${BASE_IMAGE}\nCOPY \\\n    notes.md \\\n    /opt/\n' \
		$'FROM ${BASE_IMAGE}\nCOPY \\\n  # comment inside the instruction\n\n  --chmod=644 notes.md /opt/\n' \
		$'FROM ${BASE_IMAGE}\r\nCOPY --chmod=644 \\\r\n  notes.md /opt/\r\n' \
		$'FROM ${BASE_IMAGE}\nONBUILD copy --chown=a notes.md /opt/\n' \
		$'FROM ${BASE_IMAGE}\nONBUILD COPY --chmod=644 a /a\n' \
		$'FROM ${BASE_IMAGE}\nOnBuild RUN --mount=type=bind,target=/ctx true\n' \
		$'FROM ${BASE_IMAGE}\nONBUILD\n' \
		$'FROM ${BASE_IMAGE}\n\xc2\xa0ONBUILD COPY --chmod=644 a /a\n' \
		$'FROM ${BASE_IMAGE}\n\t\xe3\x80\x80\xe2\x80\xafONBUILD RUN true\n' \
		$'FROM ${BASE_IMAGE}\nONBU\xc4\xb0LD RUN true\n' \
		$'FROM ${BASE_IMAGE}\nCOPY \xe2\x84\xaa /k\n' \
		$'FROM ${BASE_IMAGE}\nRUN echo \\\v\nONBUILD RUN true\n' \
		$'FROM ${BASE_IMAGE}\nRUN echo \\\f\nCOPY a /a\n' \
		$'FROM busybox\nRUN echo \\ \t\r\r\nFROM ${BASE_IMAGE}\n' \
		$'FROM ${BASE_IMAGE}\n\xc2\xa0# note \\\nONBUILD RUN true\n' \
		$'FROM busybox\nRUN echo \\\n\xc2\xa0\nFROM ${BASE_IMAGE}\n' \
		$'\xc2\xa0# escape=`\nFROM ${BASE_IMAGE}\n' \
		$'#\xe2\x80\x83escape=`\nFROM ${BASE_IMAGE}\n' \
		$'\xc2\x85FROM busybox\n' \
		$'FROM ${BASE_IMAGE}\n\\\n\xc2\xa0ONBUILD RUN true\n' \
		$'FROM ${BASE_IMAGE}\nRUN true <<\v\'RUN true\'\nONBUILD COPY --chmod=644 a /a\nRUN true\n' \
		$'FROM ${BASE_IMAGE}\nRUN true <<\fX\nCOPY a /a\nX\n' \
		$'FROM ${BASE_IMAGE}\nRUN true <<\xc2\xa0X\nONBUILD RUN true\nX\n' \
		$'FROM ${BASE_IMAGE}\nRUN cat <<\t\rEOF\nFROM busybox\nEOF\n' \
		$'FROM ${BASE_IMAGE}\nRUN true\xc2\xa0<<"EOF\\\\"\ntrue\nEOF\\\nONBUILD COPY --chmod=644 . /x\n' \
		$'FROM ${BASE_IMAGE}\nRUN true <<\'LABEL a=b\'\xc2\xa0c=d\ntrue\nLABEL a=b\nONBUILD COPY --chmod=644 . /x\nLABEL a=b\xc2\xa0c=d\n' \
		$'FROM ${BASE_IMAGE}\nRUN cat <<<<EOF\nFROM busybox\n' \
		$'FROM ${BASE_IMAGE}\nRUN cat \\<<EOF\nFROM busybox\n' \
		$'FROM ${BASE_IMAGE}\nCOPY --chmod= notes.md /opt/\n' \
		$'FROM ${BASE_IMAGE}\nCOPY notes.md' \
		$'FROM ${BASE_IMAGE}\n\tCOPY\tnotes.md\t/opt/   \n' \
		$'FROM busybox\nCOPY a /a\n' \
		$'ARG BASE_IMAGE=b\n' \
		$'FROM\n' \
		$'FROM golang AS b\nFROM B\n' \
		$'FROM --platform=x ${BASE_IMAGE} as Base\nFROM BASE\n' \
		$'FROM golang AS build\nFROM $BASE_IMAGE\n' \
		$'FROM ${BASE_IMAGE}\nFROM busybox\nRUN cat <<\'EOF\' >/x\nFROM ${BASE_IMAGE}\nEOF\n' \
		$'FROM ${BASE_IMAGE}\nRUN <<-"EOT" bash\n\tFROM busybox\n\tEOT\n' \
		$'FROM ${BASE_IMAGE}\nCOPY --chmod=644 <<A <<B /dst/\nFROM x\nA\nCOPY y\nB\n' \
		$'FROM ${BASE_IMAGE}\nRUN cat <<EOF\nhello\n' \
		$'FROM ${BASE_IMAGE}\nRUN echo "a <<EOF b"\nFROM busybox\n' \
		$'FROM ${BASE_\\\nIMAGE}\n' \
		$'# escape=`\nFROM ${BASE_IMAGE}\n' \
		$'\xef\xbb\xbf# escape=`\nFROM ${BASE_IMAGE}\n' \
		$'FROM ${BASE_IMAGE} AS \xc3\x89\nFROM \xc3\xa9\n' \
		$'FROM ${BASE_IMAGE}\nonbu\xc4\xb1ld COPY a b\n' \
		$'FROM ${BASE_IMAGE}\nRUN echo C:\\\\\nFROM busybox\n' \
		$'  # escape=`\nFROM ${BASE_IMAGE}\n' \
		$'# custom=value\n# escape=`\nFROM ${BASE_IMAGE}\n' \
		$'FROM busybox\nONBUILD RUN cat <<EOF >/x\nFROM ${BASE_IMAGE}\nEOF\n' \
		$'FROM busybox\nRUN echo \\" <<EOF\nFROM ${BASE_IMAGE}\nEOF\n' \
		$'FROM ${BASE_IMAGE}\nRUN cat <<\\EOF\nfrom x\nEOF\n' \
		$'FROM ${BASE_IMAGE}\nRUN cat <<- EOF >/x\n\thello\n\tEOF\n' \
		$'FROM busybox\nRUN cat << EOF >/x\nFROM ${BASE_IMAGE}\nEOF\n' \
		$'FROM ${BASE_IMAGE}\nRUN <<\'END SCRIPT\'\nFROM y\nEND SCRIPT\n' \
		$'FROM ${BASE_IMAGE}\nRUN cat <<"E\\"F"\nFROM y\nE"F\n' \
		$'FROM ${BASE_IMAGE}\nRUN\vcat\v<<EOF\nFROM y\nEOF\n' \
		$'FROM ${BASE_IMAGE}\nFROM\vbusybox\nCOPY\fa /b\n' \
		$'FROM ${BASE_IMAGE}\nRUN echo $((1 << 3))\n' \
		$'FROM "${BASE_IMAGE}" AS "b"\nFROM b\n' \
		$'FROM ${BASE_IMAGE}\nRUN cat <<"E\\`F"\nFROM y\nE\\`F\n'; do
		d="$(mktemp -d "$WORK_ROOT/dfp.XXXXXX")"
		make_set "$d"
		printf '%s' "$body" >"$d/Dockerfile"
		dig_parity "Dockerfile $(printf '%s' "$body" | tr '\n\r\t' '|~>')" "$d"
	done
	# The build driver calls the .ps1 with a path relative to its own location
	# after Push-Location, which moves PowerShell's location but not the process
	# directory .NET resolves relative paths against.
	rel_out="$(cd / && pwsh -NoProfile -Command "Push-Location '$WORK_ROOT'; & '$DIG_PS' set-a")"
	assert_eq "digest parity: relative path after Push-Location" "$rel_out" "$d_a"
else
	skipped "layers-digest.ps1 parity (pwsh not installed)"
fi

# ---------------------------------------------------------------------------
# 3. Build-driver decisions (scripts/build-image-lib.{sh,ps1})
# ---------------------------------------------------------------------------

echo "Test: layer-set currency, parent signature and Codex-commit resolution"

LIB_SH="$ROOT_DIR/scripts/build-image-lib.sh"
LIB_PS="$ROOT_DIR/scripts/build-image-lib.ps1"
BASE=powbox-agent-base:latest
LAYERS=powbox-agent-layers:latest
AGENT=powbox-agent:latest

lib_sh() {
	local st="$1"
	shift
	# shellcheck disable=SC2016 # expanded by the inner bash
	with_fakes "$st" bash -c '. "$0"; "$@"' "$LIB_SH" "$@"
}

lib_ps() {
	local st="$1" cmd="$2"
	with_fakes "$st" pwsh -NoProfile -Command ". '$LIB_PS'; $cmd"
}

DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111

# currency_case <label> <set> <digest> <expected-fragment or "">; the caller
# prepares $CUR_STATE.
currency_case() {
	local label="$1" set="$2" digest="$3" want="$4" out ps
	out="$(lib_sh "$CUR_STATE" layers_stale_reason "$set" "$digest")"
	if [ -z "$want" ]; then
		assert_eq "currency [$label]: current" "$out" ""
	else
		assert_contains "currency [$label]: stale" "$out" "$want"
	fi
	if $HAVE_PWSH; then
		ps="$(lib_ps "$CUR_STATE" "Get-LayersStaleReason -Set '$set' -Digest '$digest'")"
		assert_eq "currency [$label]: PowerShell agrees" "$ps" "$out"
	fi
}

current_layers() {
	CUR_STATE="$(new_state)"
	mkimage "$CUR_STATE" "$BASE" powbox.commit.base=c0
	mkimage "$CUR_STATE" "$LAYERS" powbox.layers.set=full "powbox.layers.digest=$DIGEST" \
		"powbox.layers.base.id=$(cat "$CUR_STATE/images/powbox-agent-base_latest/id")" powbox.commit.layers=c0
}

current_layers
currency_case "all equal" full "$DIGEST" ""
currency_case "set differs" custom "$DIGEST" "built from layer set 'full', not 'custom'"
currency_case "digest differs" full "sha256:2222" "changed since"
currency_case "digest undeterminable" full "" "could not be computed"
set_image_field "$CUR_STATE" "$BASE" id "sha256:rebuilt-base"
currency_case "parent differs (base rebuilt)" full "$DIGEST" "built on a different powbox-agent-base:latest"
current_layers
rm -r "$CUR_STATE/images/powbox-agent-base_latest"
currency_case "base absent" full "$DIGEST" "built on a different"
current_layers
rm -r "$CUR_STATE/images/powbox-agent-layers_latest"
currency_case "layers image absent" full "$DIGEST" "does not exist"
current_layers
set_image_field "$CUR_STATE" "$LAYERS" signature-source '["sha256:l1","sha256:l2","sha256:l3"] ["PATH=/usr/bin"] null "/home/node" "node"'
currency_case "layers adds a layer on the base" full "$DIGEST" ""
set_image_field "$CUR_STATE" "$LAYERS" signature-source '["sha256:l1","sha256:l20"] ["PATH=/usr/bin"] null "/home/node" "node"'
currency_case "layer digest sharing a prefix with the base's" full "$DIGEST" "is not built on powbox-agent-base:latest"
set_image_field "$CUR_STATE" "$LAYERS" signature-source '["sha256:busybox"] ["PATH=/usr/bin"] null "/home/node" "node"'
currency_case "labelled with the base but built on another image" full "$DIGEST" "is not built on powbox-agent-base:latest"
current_layers
printf '%s\n' '[]' >"$CUR_STATE/images/powbox-agent-layers_latest/onbuild"
currency_case "an empty ONBUILD list" full "$DIGEST" ""
printf '%s\n' '["COPY --chmod=644 . /x"]' >"$CUR_STATE/images/powbox-agent-layers_latest/onbuild"
currency_case "ONBUILD triggers recorded" full "$DIGEST" 'records ONBUILD triggers, which would run in the agent build outside the set'"'"'s digest: ["COPY --chmod=644 . /x"]'
if ! $HAVE_PWSH; then
	skipped "currency PowerShell parity (pwsh not installed)"
fi

SIG_STATE="$(new_state)"
mkimage "$SIG_STATE" "$LAYERS"
sig_src='["sha256:aaa","sha256:bbb"] ["PATH=/usr/local/bin:/usr/bin","CODEX_HOME=/x y"] ["/bin/bash","-c"] "/home/node" "node"'
set_image_field "$SIG_STATE" "$LAYERS" signature-source "$sig_src"
sig="$(lib_sh "$SIG_STATE" parent_signature "$LAYERS")"
assert_eq "parent signature is sha256 of the inspect line plus LF" "$sig" "sha256:$(printf '%s\n' "$sig_src" | sha256_of_stdin)"
assert_contains "parent signature reads the layer chain, Env, Shell, WorkingDir and User" "$(cat "$SIG_STATE/calls.log")" \
	'{{json .RootFS.Layers}} {{json .Config.Env}} {{json .Config.Shell}} {{json .Config.WorkingDir}} {{json .Config.User}}'
assert_not_contains "parent signature leaves labels out" "$(grep RootFS "$SIG_STATE/calls.log")" "Labels"
assert_eq "parent signature of an absent image is empty" "$(lib_sh "$SIG_STATE" parent_signature nope:latest)" ""
if $HAVE_PWSH; then
	assert_eq "parent signature: PowerShell computes the same bytes" "$(lib_ps "$SIG_STATE" "Get-ParentSignature '$LAYERS'")" "$sig"
	assert_eq "parent signature: PowerShell, absent image" "$(lib_ps "$SIG_STATE" "Get-ParentSignature 'nope:latest'")" ""
	# A non-ASCII Env value under a non-UTF-8 console encoding, as Windows has by
	# default: PowerShell must still hash the bytes docker printed.
	sig_src=$'["sha256:aaa"] ["GREETING=caf\xc3\xa9 \xf0\x9f\x98\x80"] null "/home/node" "node"'
	set_image_field "$SIG_STATE" "$LAYERS" signature-source "$sig_src"
	sig="$(lib_sh "$SIG_STATE" parent_signature "$LAYERS")"
	assert_eq "parent signature: non-ASCII Env, bash" "$sig" "sha256:$(printf '%s\n' "$sig_src" | sha256_of_stdin)"
	assert_eq "parent signature: non-ASCII Env, PowerShell under a Latin-1 console" \
		"$(lib_ps "$SIG_STATE" "[Console]::OutputEncoding = [System.Text.Encoding]::Latin1; Get-ParentSignature '$LAYERS'")" "$sig"
else
	skipped "parent signature PowerShell parity (pwsh not installed)"
fi

# codex_case <label> <head> <version> <signature> <no-cache> <expected>
codex_case() {
	local label="$1" out ps nc=false
	out="$(lib_sh "$CODEX_STATE" resolve_codex_commit "$2" "$3" "$4" "$5")"
	assert_eq "codex commit [$label]" "$out" "$6"
	if $HAVE_PWSH; then
		[ "$5" = true ] && nc=true
		ps="$(lib_ps "$CODEX_STATE" "Resolve-CodexCommit -HeadCommit '$2' -CodexVersion '$3' -Signature '$4' -NoCache:\$$nc")"
		assert_eq "codex commit [$label]: PowerShell agrees" "$ps" "$out"
	fi
}

CODEX_STATE="$(new_state)"
codex_case "no previous agent" HEAD1 0.9.0 sha256:sig false HEAD1
mkimage "$CODEX_STATE" "$AGENT" powbox.parent.signature=sha256:sig powbox.codex.version=0.9.0 powbox.commit.codex=OLD
codex_case "same parent and version: carried forward" HEAD1 0.9.0 sha256:sig false OLD
codex_case "--no-cache rebuilds it" HEAD1 0.9.0 sha256:sig true HEAD1
codex_case "parent signature changed" HEAD1 0.9.0 sha256:other false HEAD1
codex_case "parent signature unknown" HEAD1 0.9.0 "" false HEAD1
codex_case "Codex version changed" HEAD1 0.9.1 sha256:sig false HEAD1
mkimage "$CODEX_STATE" "$AGENT" powbox.parent.signature=sha256:sig powbox.codex.version=0.9.0
codex_case "reused layer with no recorded commit" HEAD1 0.9.0 sha256:sig false unknown
if ! $HAVE_PWSH; then
	skipped "codex commit PowerShell parity (pwsh not installed)"
fi

# The agent target used to stamp HEAD for any `all` or --pull run; those now
# fall through to the parent comparison, which runs after the parent exists.
for driver in "$ROOT_DIR/scripts/build-image.sh" "$ROOT_DIR/scripts/build-image.ps1"; do
	# shellcheck disable=SC2016 # a literal pattern
	if grep -nE 'PULL" = true \] && return|\$Pull\) \{ return|base \| all\) return' "$driver" >/dev/null; then
		ko "$(basename "$driver"): no early HEAD return for all/--pull"
	else
		ok "$(basename "$driver"): no early HEAD return for all/--pull"
	fi
done

# ---------------------------------------------------------------------------
# 4. The update check's layers row
# ---------------------------------------------------------------------------

echo "Test: check-updates reports the layers row in both languages"

# A fixture repo holding the scripts check-updates runs, so its selector and
# sets are under the test's control.
CU_ROOT="$WORK_ROOT/cu-root"
mkdir -p "$CU_ROOT/commands" "$CU_ROOT/scripts" "$CU_ROOT/docker/base" "$CU_ROOT/docker/layers/custom"
cp "$ROOT_DIR/commands/check-updates.sh" "$ROOT_DIR/commands/check-updates.ps1" "$CU_ROOT/commands/"
for f in layers-select layers-digest base-source-digest; do
	cp "$ROOT_DIR/scripts/$f.sh" "$ROOT_DIR/scripts/$f.ps1" "$CU_ROOT/scripts/"
done
cp "$ROOT_DIR/scripts/base-source-files.txt" "$CU_ROOT/scripts/"
cp "$ROOT_DIR/docker/base/Dockerfile" "$CU_ROOT/docker/base/"
cp -r "$ROOT_DIR/docker/layers/full" "$CU_ROOT/docker/layers/"
cp "$ROOT_DIR/docker/layers/full/Dockerfile" "$CU_ROOT/docker/layers/custom/"
FULL_DIGEST="$(bash "$DIG_SH" "$CU_ROOT/docker/layers/full")"
UPSTREAM=sha256:9999999999999999999999999999999999999999999999999999999999999999

# cu_state [layers-set layers-digest]: base and agent images current on every
# other row, the agent carrying the given layer-set labels.
cu_state() {
	local st
	st="$(new_state)"
	printf '%s\n' "$UPSTREAM" >"$st/registry-digest"
	printf '2.0.0\n' >"$st/npm/_anthropic-ai_claude-code"
	printf '0.50.0\n' >"$st/npm/_openai_codex"
	mkimage "$st" "$BASE" powbox.base.source=node:24-trixie-slim "powbox.base.source.digest=$UPSTREAM"
	if [ "$#" -gt 0 ]; then
		mkimage "$st" "$AGENT" "powbox.layers.set=$1" "powbox.layers.digest=$2"
	else
		mkimage "$st" "$AGENT"
	fi
	printf 'CLAUDE:2.0.0 (Claude Code)\nCODEX:codex-cli 0.50.0\n' >"$st/images/powbox-agent_latest/versions"
	printf '%s\n' "$st"
}

cu_select() {
	if [ "$#" -eq 0 ]; then
		rm -f "$CU_ROOT/.powbox-layers"
	else
		printf '%s\n' "$1" >"$CU_ROOT/.powbox-layers"
	fi
}

# cu_case <label> <state> <expected layers row> <report fragment>
cu_case() {
	local label="$1" st="$2" want_row="$3" want_line="$4" table row report ps_table
	table="$(with_fakes "$st" bash "$CU_ROOT/commands/check-updates.sh" --porcelain 2>&1)"
	row="$(printf '%s\n' "$table" | grep '^layers' || true)"
	assert_eq "check-updates [$label]: porcelain layers row" "$row" "$want_row"
	assert_eq "check-updates [$label]: other rows unchanged" "$(printf '%s\n' "$table" | cut -f1,2 | grep -v '^layers' | tr '\n\t' ' :')" "base:ok claude:ok codex:ok "
	report="$(with_fakes "$st" bash "$CU_ROOT/commands/check-updates.sh" 2>&1)"
	assert_contains "check-updates [$label]: report Layers row" "$(printf '%s\n' "$report" | grep '^  Layers' || true)" "$want_line"
	case "$want_row" in
	*$'\tstale\t'*) assert_contains "check-updates [$label]: report marks it" "$report" "update available" ;;
	*) assert_not_contains "check-updates [$label]: report has no marker" "$report" "update available" ;;
	esac
	if $HAVE_PWSH; then
		ps_table="$(with_fakes "$st" pwsh -NoProfile -File "$CU_ROOT/commands/check-updates.ps1" -Porcelain 2>&1)"
		assert_eq "check-updates [$label]: PowerShell porcelain matches bash" "$ps_table" "$table"
		assert_contains "check-updates [$label]: PowerShell report Layers row" \
			"$(with_fakes "$st" pwsh -NoProfile -File "$CU_ROOT/commands/check-updates.ps1" 2>&1 | grep '^  Layers' || true)" "$want_line"
	fi
}

short="${FULL_DIGEST#sha256:}"
short="${short:0:12}"

cu_select
cu_case "no set selected, lean agent" "$(cu_state)" $'layers\tok\t-\t-' "(none — lean image)  (up to date)"
cu_select full
cu_case "set selected, lean agent" "$(cu_state)" $'layers\tstale\t-\tfull@'"$FULL_DIGEST" "(none — lean image) -> full@$short  ** update available **"
cu_case "set selected and built" "$(cu_state full "$FULL_DIGEST")" $'layers\tok\tfull@'"$FULL_DIGEST"$'\tfull@'"$FULL_DIGEST" "full@$short  (up to date)"
cu_case "set edited since the build" "$(cu_state full "$DIGEST")" $'layers\tstale\tfull@'"$DIGEST"$'\tfull@'"$FULL_DIGEST" "full@111111111111 -> full@$short"
cu_select custom
cu_case "another set selected" "$(cu_state full "$FULL_DIGEST")" $'layers\tstale\tfull@'"$FULL_DIGEST"$'\tcustom@'"$FULL_DIGEST" "full@$short -> custom@$short"
cu_select
cu_case "selector removed after a set build" "$(cu_state full "$FULL_DIGEST")" $'layers\tstale\tfull@'"$FULL_DIGEST"$'\t-' "full@$short -> (none — lean image)"

# Without any sha256 tool only the set-name half of the comparison runs.
cu_nosha() {
	with_fakes "$1" env PATH="$NOSHA_BIN" bash "$CU_ROOT/commands/check-updates.sh" "${@:2}" 2>&1
}
cu_select full
nosha_lean="$(cu_state)"
assert_eq "no sha256 tool: set selected over a lean agent is stale" \
	"$(cu_nosha "$nosha_lean" --porcelain | grep $'^layers\t')" $'layers\tstale\t-\tfull@-'
nosha_other="$(cu_state other "$DIGEST")"
assert_eq "no sha256 tool: a differently named set is stale" \
	"$(cu_nosha "$nosha_other" --porcelain | grep $'^layers\t')" $'layers\tstale\tother@'"$DIGEST"$'\tfull@-'
nosha_same="$(cu_state full "$DIGEST")"
assert_eq "no sha256 tool: the same set name is ok" \
	"$(cu_nosha "$nosha_same" --porcelain | grep $'^layers\t')" $'layers\tok\tfull@'"$DIGEST"$'\tfull@-'
assert_contains "no sha256 tool: the report says the digest was not computed" \
	"$(cu_nosha "$nosha_same" | grep '^  Layers')" "full  (up to date; digest not computable)"
cu_select
nosha_removed="$(cu_state full "$DIGEST")"
assert_eq "no sha256 tool: a baked set with none selected is stale" \
	"$(cu_nosha "$nosha_removed" --porcelain | grep $'^layers\t')" $'layers\tstale\tfull@'"$DIGEST"$'\t-'

# An invalid selector fails the check instead of reporting a quiet row.
# cu_fail <label> <selector> <fragment>
cu_fail() {
	local st rc out
	cu_select "$2"
	st="$(cu_state)"
	for mode in --porcelain ""; do
		rc=0
		out="$(with_fakes "$st" bash "$CU_ROOT/commands/check-updates.sh" ${mode:+"$mode"} 2>&1)" || rc=$?
		assert_eq "check-updates [$1${mode:+ $mode}]: fails" "$([ "$rc" -ne 0 ] && echo failed)" failed
		assert_contains "check-updates [$1${mode:+ $mode}]: names the value" "$out" "$3"
		if $HAVE_PWSH; then
			rc=0
			out="$(with_fakes "$st" pwsh -NoProfile -File "$CU_ROOT/commands/check-updates.ps1" ${mode:+-Porcelain} 2>&1)" || rc=$?
			assert_eq "check-updates [$1${mode:+ $mode}]: PowerShell fails" "$([ "$rc" -ne 0 ] && echo failed)" failed
			assert_contains "check-updates [$1${mode:+ $mode}]: PowerShell names the value" "$out" "$3"
		fi
	done
}
cu_fail "invalid name" "Bad Name" "Bad Name"
cu_fail "missing set" "nosuchset" "docker/layers/nosuchset/Dockerfile"
printf 'FROM x\nCOPY a /a\n' >"$CU_ROOT/docker/layers/custom/Dockerfile"
cu_fail "set breaking the contract" "custom" "Dockerfile:2:"
cu_select
if ! $HAVE_PWSH; then
	skipped "check-updates PowerShell parity (pwsh not installed)"
fi

# ---------------------------------------------------------------------------
# 5. agent-update routes a stale layer set to a cached agent build
# ---------------------------------------------------------------------------

echo "Test: agent-update rebuilds a stale layer set through the agent target"

AU_ROOT="$WORK_ROOT/au-root"
mkdir -p "$AU_ROOT/commands"
cat >"$AU_ROOT/commands/check-updates.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --porcelain ]; then cat "$AU_TABLE"; exit 0; fi
grep -q $'\tstale\t' "$AU_TABLE" && echo "  Something  ** update available **"
exit 0
SH
cat >"$AU_ROOT/build.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AU_LOG"
SH
chmod +x "$AU_ROOT/commands/check-updates.sh" "$AU_ROOT/build.sh"
# shellcheck disable=SC2016 # literal PowerShell
printf '%s\r\n' 'param([switch]$Porcelain)' \
	'if ($Porcelain) { Get-Content $env:AU_TABLE; $global:LASTEXITCODE = 0; return }' \
	'if (Select-String -Path $env:AU_TABLE -Pattern "`tstale`t" -Quiet) { Write-Host "  Something  ** update available **" }' \
	'$global:LASTEXITCODE = 0' >"$AU_ROOT/commands/check-updates.ps1"
# shellcheck disable=SC2016 # literal PowerShell
printf '%s\r\n' 'param([string]$Target, [string]$ClaudeVersion, [string]$CodexVersion, [switch]$NoCache, [switch]$Pull)' \
	'$line = @($Target); if ($ClaudeVersion) { $line += "--claude-version", $ClaudeVersion }; if ($CodexVersion) { $line += "--codex-version", $CodexVersion }; if ($Pull) { $line += "--pull" }; if ($NoCache) { $line += "--no-cache" }' \
	'Add-Content -Path $env:AU_LOG -Value ($line -join " ")' \
	'$global:LASTEXITCODE = 0' >"$AU_ROOT/build.ps1"

au_table() {
	printf 'base\tok\tsha256:x\tsha256:x\nlayers\t%s\t-\tfull@sha256:d\nclaude\t%s\t2.0.0\t%s\ncodex\tok\t0.50.0\t0.50.0\n' "$1" "$2" "$3"
}

# au_case <label> <layers-status> <claude-status> <claude-latest> <args> <expected build line or "">
au_case() {
	local label="$1" args="$5" want="$6" st log
	st="$(new_state)"
	au_table "$2" "$3" "$4" >"$st/table"
	log="$st/build.log"
	: >"$log"
	# shellcheck disable=SC2016 # expanded by the inner bash
	printf 'y\nn\n' | with_fakes "$st" env POWBOX_ROOT="$AU_ROOT" AU_TABLE="$st/table" AU_LOG="$log" \
		bash -c '. "$0"; agent-update $1' "$ROOT_DIR/shell/powbox.sh" "$args" >/dev/null 2>&1 || true
	assert_eq "agent-update [$label]: build" "$(cat "$log")" "$want"
	if $HAVE_PWSH; then
		: >"$log"
		local ps_args=""
		[ "$args" = --refresh ] && ps_args="-Refresh"
		printf 'y\nn\n' | with_fakes "$st" env POWBOX_ROOT="$AU_ROOT" AU_TABLE="$st/table" AU_LOG="$log" \
			pwsh -NoProfile -Command ". '$ROOT_DIR/shell/powbox.ps1'; agent-update $ps_args" >/dev/null 2>&1 || true
		assert_eq "agent-update [$label]: PowerShell build" "$(cat "$log")" "$want"
	fi
}

au_case "stale layer set only" stale ok 2.0.0 "" "agent --claude-version 2.0.0 --codex-version 0.50.0"
au_case "stale layer set and a Claude release" stale stale 2.1.0 "" "agent --claude-version 2.1.0 --codex-version 0.50.0"
au_case "nothing stale" ok ok 2.0.0 "" ""
au_case "--refresh with nothing stale" ok ok 2.0.0 --refresh "all --claude-version 2.0.0 --codex-version 0.50.0"
au_case "--refresh with a stale layer set" stale ok 2.0.0 --refresh "all --claude-version 2.0.0 --codex-version 0.50.0"
if ! $HAVE_PWSH; then
	skipped "agent-update PowerShell routing (pwsh not installed)"
fi

echo "Test: agent-image-info shows the layer set and the commit that built it"

info_case() {
	local label="$1" st="$2" want="$3" out
	# shellcheck disable=SC2016 # expanded by the inner bash
	out="$(with_fakes "$st" bash -c '. "$0"; agent-image-info' "$ROOT_DIR/shell/powbox.sh" 2>&1)"
	assert_contains "agent-image-info [$label]" "$(printf '%s\n' "$out" | grep 'layers:')" "$want"
	assert_contains "agent-image-info [$label]: codex row intact" "$out" "codex:        c1  (codex 0.50.0)"
	if $HAVE_PWSH; then
		out="$(with_fakes "$st" pwsh -NoProfile -Command ". '$ROOT_DIR/shell/powbox.ps1'; agent-image-info" 2>&1)"
		assert_contains "agent-image-info [$label]: PowerShell" "$(printf '%s\n' "$out" | grep 'layers:')" "$want"
		assert_contains "agent-image-info [$label]: PowerShell codex row intact" "$out" "codex:        c1  (codex 0.50.0)"
	fi
}
INFO_STATE="$(new_state)"
mkimage "$INFO_STATE" "$AGENT" powbox.commit.base=c0 powbox.commit.codex=c1 powbox.commit.claude=c2 powbox.codex.version=0.50.0 powbox.claude.version=2.0.0
info_case "lean" "$INFO_STATE" "layers:       none (lean image)"
mkimage "$INFO_STATE" "$AGENT" powbox.commit.base=c0 powbox.commit.codex=c1 powbox.commit.claude=c2 powbox.codex.version=0.50.0 powbox.claude.version=2.0.0 \
	powbox.layers.set=full "powbox.layers.digest=$DIGEST" powbox.commit.layers=c9
info_case "on a set" "$INFO_STATE" "layers:       c9  (set full, digest $DIGEST)"

# ---------------------------------------------------------------------------
# 6. Build-driver dispatch, end to end against the simulating fake docker
# ---------------------------------------------------------------------------

echo "Test: build-image.{sh,ps1} chain base, layer set and agent"

# A local stand-in for Roubtec/agent-skills, reached through a URL rewrite so
# the drivers' fetch stays offline.
SKILLS_SRC="$WORK_ROOT/agent-skills-src"
mkdir -p "$SKILLS_SRC/codex/dev-skills/skills/demo" "$SKILLS_SRC/plugins/dev-skills/bin"
: >"$SKILLS_SRC/codex/dev-skills/skills/demo/SKILL.md"
for helper in gh-review-threads dc-enter dc-remove; do
	printf '#!/bin/sh\n' >"$SKILLS_SRC/plugins/dev-skills/bin/$helper"
	chmod +x "$SKILLS_SRC/plugins/dev-skills/bin/$helper"
done
git -C "$SKILLS_SRC" init -q -b main
git -C "$SKILLS_SRC" add -A
git -C "$SKILLS_SRC" -c user.name=t -c user.email=t@t commit -q -m skills

# git with fixed identity and dates, so both fixture repos get the same SHAs.
fixed_git() {
	GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
		git -c user.name=t -c user.email=t@t "$@"
}

# make_build_root <dir>: a git repo holding just what the drivers read.
make_build_root() {
	local br="$1" f
	mkdir -p "$br/scripts" "$br/docker/base" "$br/docker/layers/custom"
	for f in build-image build-image-lib layers-select layers-digest base-source-digest; do
		cp "$ROOT_DIR/scripts/$f.sh" "$ROOT_DIR/scripts/$f.ps1" "$br/scripts/"
	done
	cp "$ROOT_DIR/scripts/base-source-files.txt" "$br/scripts/"
	cp "$ROOT_DIR/docker/base/Dockerfile" "$br/docker/base/"
	cp -r "$ROOT_DIR/docker/layers/full" "$br/docker/layers/"
	: >"$br/docker/layers/custom/.gitkeep"
	printf '%s\n' .agent-skills-src/ .powbox-layers 'docker/layers/custom/*' '!docker/layers/custom/.gitkeep' >"$br/.gitignore"
	git -C "$br" init -q -b main
	git -C "$br" add -A
	fixed_git -C "$br" commit -q -m c0
}

# build <lang> <state> <target> [flags...]; flags use the bash spelling.
build() {
	local lang="$1" st="$2" target="$3" br
	shift 3
	br="$BR_SH"
	[ "$lang" = ps ] && br="$BR_PS"
	local -a gitcfg=(GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=url.file://$SKILLS_SRC.insteadOf"
		"GIT_CONFIG_VALUE_0=https://github.com/Roubtec/agent-skills.git")
	if [ "$lang" = sh ]; then
		with_fakes "$st" env "${gitcfg[@]}" bash "$br/scripts/build-image.sh" "$target" "$@"
	else
		local -a ps=(-Target "$target")
		while [ "$#" -gt 0 ]; do
			case "$1" in
			--claude-version)
				ps+=(-ClaudeVersion "$2")
				shift
				;;
			--codex-version)
				ps+=(-CodexVersion "$2")
				shift
				;;
			--no-cache) ps+=(-NoCache) ;;
			--pull) ps+=(-Pull) ;;
			esac
			shift
		done
		with_fakes "$st" env "${gitcfg[@]}" pwsh -NoProfile -File "$br/scripts/build-image.ps1" "${ps[@]}"
	fi
}

label() {
	local f
	f="$1/images/$(printf '%s' "$2" | tr ':/' '__')/labels/$3"
	[ -f "$f" ] && cat "$f"
	return 0
}

# bakes <state>: the bake log lines since the last call, as "target[ no-cache]".
bakes() {
	local seen=0 total
	[ -f "$1/bake.seen" ] && seen="$(cat "$1/bake.seen")"
	total="$(wc -l <"$1/bake.log" 2>/dev/null || echo 0)"
	echo "$total" >"$1/bake.seen"
	tail -n "+$((seen + 1))" "$1/bake.log" 2>/dev/null | awk '{ t = $2; if ($3 == "no-cache=true") t = t " no-cache"; printf "%s%s", sep, t; sep = "," }'
}

PIN=(--claude-version 2.0.0 --codex-version 0.50.0)

# run_sequence <lang>: the host session's build scenarios, with assertions; the
# full bake log is compared across languages afterwards.
run_sequence() {
	local lang="$1" st br out rc c0 c1 c2 c3 head base_id
	st="$(new_state)"
	printf 'sha256:%064d\n' 0 >"$st/registry-digest"
	br="$BR_SH"
	[ "$lang" = ps ] && br="$BR_PS"
	SEQ_STATE="$st"
	c0="$(git -C "$br" rev-parse --short HEAD)"

	build "$lang" "$st" all "${PIN[@]}" >/dev/null
	assert_eq "[$lang] lean all: base and agent, no layer set" "$(bakes "$st")" "base,agent"
	assert_contains "[$lang] lean all: agent on the base" "$(tail -1 "$st/bake.log")" "BASE_IMAGE=powbox-agent-base:latest"
	assert_eq "[$lang] lean all: base.commit file matches the label" "$(cat "$st/images/powbox-agent_latest/base.commit")" "$(label "$st" "$AGENT" powbox.commit.base)"
	assert_eq "[$lang] lean all: no layer-set label on the agent" "$(label "$st" "$AGENT" powbox.layers.set)" ""

	printf 'full\n' >"$br/.powbox-layers"
	fixed_git -C "$br" commit -q --allow-empty -m c1
	c1="$(git -C "$br" rev-parse --short HEAD)"
	build "$lang" "$st" all "${PIN[@]}" >/dev/null
	assert_eq "[$lang] set all: three images" "$(bakes "$st")" "base,layers,agent"
	assert_contains "[$lang] set all: agent on the layer-set image" "$(tail -1 "$st/bake.log")" "BASE_IMAGE=powbox-agent-layers:latest"
	assert_eq "[$lang] set all: agent carries the set" "$(label "$st" "$AGENT" powbox.layers.set)" "full"
	assert_eq "[$lang] set all: agent carries the set's digest" "$(label "$st" "$AGENT" powbox.layers.digest)" "$(bash "$DIG_SH" "$br/docker/layers/full")"
	assert_eq "[$lang] set all: layers image records the base it was built on" "$(label "$st" "$LAYERS" powbox.layers.base.id)" "$(cat "$st/images/powbox-agent-base_latest/id")"
	assert_eq "[$lang] set all: Codex layer reused over a label-only parent change keeps its commit" "$(label "$st" "$AGENT" powbox.commit.codex)" "$c0"
	assert_eq "[$lang] set all: base.commit file matches the inherited label" "$(cat "$st/images/powbox-agent_latest/base.commit")" "$c1"

	fixed_git -C "$br" commit -q --allow-empty -m c2
	c2="$(git -C "$br" rev-parse --short HEAD)"
	build "$lang" "$st" agent "${PIN[@]}" >/dev/null
	assert_eq "[$lang] agent with everything current: no layer-set bake" "$(bakes "$st")" "agent"
	assert_eq "[$lang] agent with everything current: layers commit kept" "$(label "$st" "$AGENT" powbox.commit.layers)" "$c1"
	assert_eq "[$lang] agent with everything current: claude commit moved" "$(label "$st" "$AGENT" powbox.commit.claude)" "$c2"

	printf '# edited\n' >>"$br/docker/layers/full/Dockerfile"
	fixed_git -C "$br" commit -q -am c3
	c3="$(git -C "$br" rev-parse --short HEAD)"
	base_id="$(cat "$st/images/powbox-agent-base_latest/id")"
	build "$lang" "$st" agent "${PIN[@]}" >/dev/null
	assert_eq "[$lang] edited set: layers and agent baked, base untouched" "$(bakes "$st")" "layers,agent"
	assert_eq "[$lang] edited set: base ID unchanged" "$(cat "$st/images/powbox-agent-base_latest/id")" "$base_id"
	assert_eq "[$lang] edited set: new digest on the agent" "$(label "$st" "$AGENT" powbox.layers.digest)" "$(bash "$DIG_SH" "$br/docker/layers/full")"
	assert_eq "[$lang] edited set: layers commit moved" "$(label "$st" "$AGENT" powbox.commit.layers)" "$c3"

	build "$lang" "$st" base >/dev/null
	assert_eq "[$lang] base alone: base only" "$(bakes "$st")" "base"
	build "$lang" "$st" agent "${PIN[@]}" >/dev/null
	assert_eq "[$lang] agent after a base rebuild: layer-set image rebaked" "$(bakes "$st")" "layers,agent"
	assert_eq "[$lang] agent after a base rebuild: layers image on the new base" "$(label "$st" "$LAYERS" powbox.layers.base.id)" "$(cat "$st/images/powbox-agent-base_latest/id")"

	build "$lang" "$st" agent --pull "${PIN[@]}" >/dev/null
	assert_eq "[$lang] agent --pull: base refreshed and cascaded" "$(bakes "$st")" "base,layers,agent"

	printf '%s\n' '["sha256:b1","sha256:b2"] ["PATH=/usr/bin"] null "/home/node" "node"' >"$st/base-signature-source"
	build "$lang" "$st" base >/dev/null
	build "$lang" "$st" agent "${PIN[@]}" >/dev/null
	bakes "$st" >/dev/null
	head="$(git -C "$br" rev-parse --short HEAD)"
	assert_eq "[$lang] base gained a layer: Codex commit re-stamped" "$(label "$st" "$AGENT" powbox.commit.codex)" "$head"

	build "$lang" "$st" agent --no-cache "${PIN[@]}" >/dev/null
	assert_eq "[$lang] agent --no-cache: layer-set step stays cached" "$(bakes "$st")" "agent no-cache"
	build "$lang" "$st" all --no-cache "${PIN[@]}" >/dev/null
	assert_eq "[$lang] all --no-cache: covers all three" "$(bakes "$st")" "base no-cache,layers no-cache,agent no-cache"
	build "$lang" "$st" layers >/dev/null
	assert_eq "[$lang] layers: always baked" "$(bakes "$st")" "layers"

	printf 'Bad Name\n' >"$br/.powbox-layers"
	rc=0
	out="$(build "$lang" "$st" agent "${PIN[@]}" 2>&1)" || rc=$?
	assert_eq "[$lang] invalid selector: build fails" "$([ "$rc" -ne 0 ] && echo failed)" failed
	assert_contains "[$lang] invalid selector: names the value" "$out" "'Bad Name'"
	assert_eq "[$lang] invalid selector: nothing baked" "$(bakes "$st")" ""

	printf 'custom\n' >"$br/.powbox-layers"
	cp "$br/docker/layers/full/Dockerfile" "$br/docker/layers/custom/"
	printf 'COPY probe /probe\n' >>"$br/docker/layers/custom/Dockerfile"
	rc=0
	out="$(build "$lang" "$st" agent "${PIN[@]}" 2>&1)" || rc=$?
	assert_eq "[$lang] set breaking the contract: build fails" "$([ "$rc" -ne 0 ] && echo failed)" failed
	assert_contains "[$lang] set breaking the contract: names the line" "$out" "docker/layers/custom/Dockerfile:"
	assert_eq "[$lang] set breaking the contract: nothing baked" "$(bakes "$st")" ""
	cp "$br/docker/layers/full/Dockerfile" "$br/docker/layers/custom/"
	assert_eq "[$lang] a copied custom set leaves the tree clean" "$(git -C "$br" status --porcelain)" ""
	build "$lang" "$st" agent "${PIN[@]}" >/dev/null
	assert_eq "[$lang] custom set: layers and agent baked" "$(bakes "$st")" "layers,agent"
	assert_eq "[$lang] custom set: agent carries it" "$(label "$st" "$AGENT" powbox.layers.set)" "custom"

	# A set whose final stage escapes the Dockerfile scan but starts from another
	# image: the bake still labels it with the base, so its layers decide.
	printf '%s\n' '["sha256:busybox"] ["PATH=/usr/bin"] null "/" "root"' >"$st/layers-signature-source"
	rc=0
	out="$(build "$lang" "$st" layers 2>&1)" || rc=$?
	assert_eq "[$lang] set not built on the base: build fails" "$([ "$rc" -ne 0 ] && echo failed)" failed
	assert_contains "[$lang] set not built on the base: says why" "$out" "is not built on powbox-agent-base:latest"
	assert_eq "[$lang] set not built on the base: only the layer-set bake ran" "$(bakes "$st")" "layers"
	rc=0
	out="$(build "$lang" "$st" agent "${PIN[@]}" 2>&1)" || rc=$?
	assert_eq "[$lang] set not built on the base: not current next time, no agent on it" "$(bakes "$st")" "layers"
	rm "$st/layers-signature-source"
	build "$lang" "$st" agent "${PIN[@]}" >/dev/null
	assert_eq "[$lang] set fixed: layers and agent baked" "$(bakes "$st")" "layers,agent"

	# An ONBUILD the Dockerfile scan missed: the image records the trigger, so
	# the build stops before the agent would run it from the repo-root context.
	printf '%s\n' '["COPY --chmod=644 . /x"]' >"$st/layers-onbuild"
	rc=0
	out="$(build "$lang" "$st" layers 2>&1)" || rc=$?
	assert_eq "[$lang] set recording ONBUILD: build fails" "$([ "$rc" -ne 0 ] && echo failed)" failed
	assert_contains "[$lang] set recording ONBUILD: says why" "$out" "records ONBUILD triggers"
	assert_contains "[$lang] set recording ONBUILD: names the remedy" "$out" "Remove every ONBUILD from"
	assert_eq "[$lang] set recording ONBUILD: only the layer-set bake ran" "$(bakes "$st")" "layers"
	rc=0
	out="$(build "$lang" "$st" agent "${PIN[@]}" 2>&1)" || rc=$?
	assert_eq "[$lang] set recording ONBUILD: not current next time, no agent on it" "$(bakes "$st")" "layers"
	rm "$st/layers-onbuild"
	build "$lang" "$st" agent "${PIN[@]}" >/dev/null
	assert_eq "[$lang] ONBUILD removed: layers and agent baked" "$(bakes "$st")" "layers,agent"

	rm "$br/.powbox-layers"
	rc=0
	out="$(build "$lang" "$st" layers 2>&1)" || rc=$?
	assert_eq "[$lang] layers with no set: fails" "$([ "$rc" -ne 0 ] && echo failed)" failed
	assert_contains "[$lang] layers with no set: says so" "$out" "No layer set is selected"
	assert_eq "[$lang] layers with no set: nothing baked" "$(bakes "$st")" ""
	build "$lang" "$st" agent "${PIN[@]}" >/dev/null
	assert_eq "[$lang] back to lean: agent only" "$(bakes "$st")" "agent"
	assert_contains "[$lang] back to lean: agent on the base" "$(tail -1 "$st/bake.log")" "BASE_IMAGE=powbox-agent-base:latest"
	assert_eq "[$lang] back to lean: no layer-set label" "$(label "$st" "$AGENT" powbox.layers.set)" ""
}

BR_SH="$WORK_ROOT/build-root-sh"
make_build_root "$BR_SH"
run_sequence sh
SH_LOG="$SEQ_STATE/bake.log"
if $HAVE_PWSH; then
	BR_PS="$WORK_ROOT/build-root-ps"
	make_build_root "$BR_PS"
	run_sequence ps
	assert_eq "build drivers: identical bake targets and variables across bash and PowerShell" \
		"$(cat "$SEQ_STATE/bake.log")" "$(cat "$SH_LOG")"
else
	skipped "build-image.ps1 dispatch (pwsh not installed)"
fi

echo
echo "layer-set tests: ${pass} passed, ${fail} failed, ${skip} skipped"
[ "$fail" -eq 0 ]
