#!/usr/bin/env bash
# Hermetic tests for scripts/stage-agent-reference.{sh,ps1}, which compose the
# on-demand agent reference directory baked into the agent image: the core
# files from docker/shared/agent-reference/, plus the selected layer set's
# agent-reference/ contributions (appended under a fixed heading to a core file
# of the same name, or added beside them). Each case runs against a throwaway
# repo root, compares the staged files with exact expectations, and requires
# the PowerShell twin to stage the same names, bytes and modes; without pwsh
# those halves report an honest skip.
#
# The fixtures are Markdown: their backticks are code spans, never command
# substitutions.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGE_SH="${SCRIPT_DIR}/stage-agent-reference.sh"
STAGE_PS="${SCRIPT_DIR}/stage-agent-reference.ps1"

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

# assert_same_file <label> <actual> <expected>: byte-for-byte equality.
assert_same_file() {
	if [ -f "$2" ] && cmp -s "$2" "$3"; then
		ok "$1"
	else
		ko "$1" "$(cmp "$2" "$3" 2>&1 || true)"
	fi
}

# new_root: a repo root with a two-file core directory and an empty set "demo".
new_root() {
	local root
	root="$(mktemp -d "$WORK_ROOT/root.XXXXXX")"
	mkdir -p "$root/docker/shared/agent-reference" "$root/docker/layers/demo"
	printf '# Known limitations\n\nCore entries.\n' >"$root/docker/shared/agent-reference/known-limitations.md"
	printf '# Other\n\nOther text.\n' >"$root/docker/shared/agent-reference/other.md"
	printf '%s\n' "$root"
}

out_dir() {
	printf '%s/.powbox-staging/agent-reference' "$1"
}

set_dir() {
	mkdir -p "$1/docker/layers/demo/agent-reference"
	printf '%s/docker/layers/demo/agent-reference' "$1"
}

# listing <dir>: one line per entry, "<mode> <name> <sha256>", plus the
# directory's own mode first.
listing() {
	local path
	stat -c '%a .' "$1"
	for path in "$1"/* "$1"/.*; do
		case "${path##*/}" in . | ..) continue ;; esac
		[ -e "$path" ] || [ -L "$path" ] || continue
		printf '%s %s %s\n' "$(stat -c '%a' "$path")" "${path##*/}" "$(sha256sum <"$path" | cut -d' ' -f1)"
	done
}

# stage_both <label> <root> <set>: stage with the .sh, then with the .ps1 into
# a copy of the same root (staging directory included), and require the same
# exit status and the same staged names, bytes and modes. Leaves the .sh result
# in <root> and its stderr in <root>.err; returns its status.
stage_both() {
	local label="$1" root="$2" set="$3" rc=0 ps_rc=0 twin
	twin="$(mktemp -d "$WORK_ROOT/twin.XXXXXX")"
	cp -a "$root/." "$twin/"
	bash "$STAGE_SH" "$set" "$root" 2>"$root.err" || rc=$?
	if ! $HAVE_PWSH; then
		skipped "$label: PowerShell parity (pwsh not installed)"
		return "$rc"
	fi
	pwsh -NoProfile -File "$STAGE_PS" "$set" "$twin" 2>"$twin.err" || ps_rc=$?
	assert_eq "$label: PowerShell exit status matches" "$ps_rc" "$rc"
	if [ -d "$(out_dir "$root")" ] || [ -d "$(out_dir "$twin")" ]; then
		assert_eq "$label: PowerShell stages the same files and modes" \
			"$(listing "$(out_dir "$twin")" 2>&1)" "$(listing "$(out_dir "$root")" 2>&1)"
	fi
	return "$rc"
}

core_listing() {
	local root="$1" core
	core="$root/docker/shared/agent-reference"
	printf '755 .\n'
	printf '644 known-limitations.md %s\n' "$(sha256sum <"$core/known-limitations.md" | cut -d' ' -f1)"
	printf '644 other.md %s\n' "$(sha256sum <"$core/other.md" | cut -d' ' -f1)"
}

echo "Test: no set, or no contribution, stages the core files unchanged"

root="$(new_root)"
stage_both "no set" "$root" ""
assert_eq "no set: exactly the core files, 0644 in a 0755 directory" "$(listing "$(out_dir "$root")")" "$(core_listing "$root")"
root="$(new_root)"
(cd / && bash "$STAGE_SH" "" "$root")
assert_eq "no set, run from another directory: the core files" "$(listing "$(out_dir "$root")")" "$(core_listing "$root")"

root="$(new_root)"
stage_both "set without agent-reference/" "$root" demo
assert_eq "set without agent-reference/: the core files" "$(listing "$(out_dir "$root")")" "$(core_listing "$root")"

root="$(new_root)"
printf '\xef\xbb\xbf \r\n\t\n\r\n  ' >"$(set_dir "$root")/known-limitations.md"
: >"$(set_dir "$root")/extra.md"
stage_both "whitespace-only contributions" "$root" demo
assert_eq "whitespace-only contributions (BOM, CRLF, tabs, empty): nothing added" "$(listing "$(out_dir "$root")")" "$(core_listing "$root")"

echo "Test: a contribution is appended under the heading, or added beside"

root="$(new_root)"
printf '\xef\xbb\xbf\r\n \r\n### `tool` entry\r\n\r\n- **What:** x\r\nlone\rcr\n\n\t \n' >"$(set_dir "$root")/known-limitations.md"
stage_both "appended contribution" "$root" demo
printf '# Known limitations\n\nCore entries.\n\n## Contributed by the `demo` layer set\n\n### `tool` entry\n\n- **What:** x\nlone\ncr\n' >"$WORK_ROOT/expected-append"
assert_same_file "appended contribution: normalized, under the heading" "$(out_dir "$root")/known-limitations.md" "$WORK_ROOT/expected-append"
assert_same_file "appended contribution: the other core file is untouched" "$(out_dir "$root")/other.md" "$root/docker/shared/agent-reference/other.md"

root="$(new_root)"
printf '# Known limitations' >"$root/docker/shared/agent-reference/known-limitations.md"
printf 'Set entry.\n' >"$(set_dir "$root")/known-limitations.md"
stage_both "core file without a final LF" "$root" demo
printf '# Known limitations\n\n## Contributed by the `demo` layer set\n\nSet entry.\n' >"$WORK_ROOT/expected-nolf"
assert_same_file "core file without a final LF: the line is ended first" "$(out_dir "$root")/known-limitations.md" "$WORK_ROOT/expected-nolf"

root="$(new_root)"
printf '\r\n# Set guide\r\n\r\nText.  \r\n\r\n' >"$(set_dir "$root")/set-guide.md"
stage_both "contribution with a name of its own" "$root" demo
printf '# Set guide\n\nText.\n' >"$WORK_ROOT/expected-own"
assert_same_file "contribution with a name of its own: staged normalized, no heading" "$(out_dir "$root")/set-guide.md" "$WORK_ROOT/expected-own"
assert_eq "contribution with a name of its own: 0644" "$(stat -c '%a' "$(out_dir "$root")/set-guide.md")" 644

echo "Test: restaging prunes, repairs modes and leaves unchanged files alone"

stage_both "back to no set" "$root" ""
assert_eq "back to no set: the set's file is gone, the core files remain" "$(listing "$(out_dir "$root")")" "$(core_listing "$root")"

root="$(new_root)"
bash "$STAGE_SH" "" "$root"
printf 'stale\n' >"$(out_dir "$root")/.stale.md"
inode="$(stat -c '%i' "$(out_dir "$root")/known-limitations.md")"
chmod 0600 "$(out_dir "$root")/other.md"
chmod 0700 "$(out_dir "$root")"
stage_both "restage over leftovers" "$root" ""
assert_eq "restage: stray file removed, modes repaired" "$(listing "$(out_dir "$root")")" "$(core_listing "$root")"
assert_eq "restage: an unchanged file is not rewritten" "$(stat -c '%i' "$(out_dir "$root")/known-limitations.md")" "$inode"

echo "Test: refusals leave the staged directory as it was"

# refuse <label> <root> <set> <stderr fragment>
refuse() {
	local before rc=0
	before="$(listing "$(out_dir "$2")" 2>/dev/null || true)"
	stage_both "$1" "$2" "$3" || rc=$?
	assert_eq "$1: fails" "$([ "$rc" -ne 0 ] && echo failed)" failed
	if grep -qF -- "$4" "$2.err"; then ok "$1: says why"; else ko "$1: says why" "stderr: $(cat "$2.err")"; fi
	assert_eq "$1: staged directory unchanged" "$(listing "$(out_dir "$2")" 2>/dev/null || true)" "$before"
}

root="$(new_root)"
bash "$STAGE_SH" "" "$root"
printf 'x\n' >"$root/docker/shared/agent-reference/notes.txt"
refuse "a core file not named name.md" "$root" "" "only files named like name.md"

root="$(new_root)"
bash "$STAGE_SH" "" "$root"
mkdir -p "$(set_dir "$root")/sub.md"
refuse "a subdirectory in the set's directory" "$root" demo "is not a regular file"

root="$(new_root)"
bash "$STAGE_SH" "" "$root"
ln -s ../../../shared/agent-reference/other.md "$(set_dir "$root")/link.md"
refuse "a symlink in the set's directory" "$root" demo "is not a regular file"

root="$(new_root)"
bash "$STAGE_SH" "" "$root"
printf 'a\0b\n' >"$(set_dir "$root")/known-limitations.md"
refuse "a NUL byte in a contribution" "$root" demo "contains a NUL byte"

root="$(new_root)"
bash "$STAGE_SH" "" "$root"
refuse "an invalid set name" "$root" "Bad Name" "invalid layer-set name"

root="$(new_root)"
bash "$STAGE_SH" "" "$root"
mkdir "$(out_dir "$root")/other.md.d"
refuse "a directory in the staging directory" "$root" "" "is a directory"

root="$(new_root)"
rm -r "$root/docker/shared/agent-reference"
refuse "no core directory" "$root" "" "not found"

echo "Test: the repository's own sources"

root="$(mktemp -d "$WORK_ROOT/real.XXXXXX")"
mkdir -p "$root/docker/shared" "$root/docker/layers"
cp -r "$ROOT_DIR/docker/shared/agent-reference" "$root/docker/shared/"
for set in full browser; do
	cp -r "$ROOT_DIR/docker/layers/$set" "$root/docker/layers/"
done
stage_both "real sources, lean" "$root" ""
assert_same_file "real sources, lean: the core known-limitations document" \
	"$(out_dir "$root")/known-limitations.md" "$ROOT_DIR/docker/shared/agent-reference/known-limitations.md"
stage_both "real sources, browser" "$root" browser
assert_same_file "real sources, browser: no known limitations of its own" \
	"$(out_dir "$root")/known-limitations.md" "$ROOT_DIR/docker/shared/agent-reference/known-limitations.md"
assert_eq "real sources, browser: its tools follow the heading once" \
	"$(grep -cxF -- '## Contributed by the `browser` layer set' "$(out_dir "$root")/tooling.md")" 1
stage_both "real sources, full" "$root" full
assert_eq "real sources, full: its entries follow the heading once" \
	"$(grep -cxF -- '## Contributed by the `full` layer set' "$(out_dir "$root")/known-limitations.md")" 1
assert_eq "real sources, full: its tools follow the heading once" \
	"$(grep -cxF -- '## Contributed by the `full` layer set' "$(out_dir "$root")/tooling.md")" 1

echo
echo "stage-agent-reference tests: ${pass} passed, ${fail} failed, ${skip} skipped"
[ "$fail" -eq 0 ]
