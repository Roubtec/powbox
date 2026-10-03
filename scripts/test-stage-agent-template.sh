#!/usr/bin/env bash
# Hermetic tests for scripts/stage-agent-template.{sh,ps1}, which compose the
# agent instruction template baked into the agent image: the core template,
# then the selected layer set's agent-notes.md under a fixed heading. Each case
# runs against a throwaway repo root, compares the staged bytes with an exact
# expectation, and requires the PowerShell twin to write the same bytes; without
# pwsh those halves report an honest skip. The render case runs the staged file
# through envsubst with the variable list the entrypoint hooks really use.
#
# The fixtures are Markdown: their backticks are code spans, never command
# substitutions, and their $ signs are meant literally.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGE_SH="${SCRIPT_DIR}/stage-agent-template.sh"
STAGE_PS="${SCRIPT_DIR}/stage-agent-template.ps1"
CORE="${ROOT_DIR}/docker/shared/container-agent.md.tmpl"

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

# new_root [<template file>]: a repo root holding the core template (the real
# one unless another is given) and an empty layer set "demo".
new_root() {
	local root
	root="$(mktemp -d "$WORK_ROOT/root.XXXXXX")"
	mkdir -p "$root/docker/shared" "$root/docker/layers/demo"
	cp "${1:-$CORE}" "$root/docker/shared/container-agent.md.tmpl"
	printf '%s\n' "$root"
}

staged() {
	printf '%s/.powbox-staging/agent.md.tmpl' "$1"
}

# stage_both <label> <root> <set>: stage with the .sh, then with the .ps1 into a
# copy of the same root, and require identical bytes and exit status. Leaves
# the .sh result in <root> and its stderr in <root>.err; returns its status.
stage_both() {
	local label="$1" root="$2" set="$3" rc=0 ps_rc=0 twin
	bash "$STAGE_SH" "$set" "$root" 2>"$root.err" || rc=$?
	if ! $HAVE_PWSH; then
		skipped "$label: PowerShell parity (pwsh not installed)"
		return "$rc"
	fi
	twin="$(mktemp -d "$WORK_ROOT/twin.XXXXXX")"
	cp -r "$root/docker" "$twin/"
	pwsh -NoProfile -File "$STAGE_PS" "$set" "$twin" 2>"$twin.err" || ps_rc=$?
	assert_eq "$label: PowerShell exit status matches" "$ps_rc" "$rc"
	if [ "$rc" -eq 0 ]; then
		assert_same_file "$label: PowerShell writes the same bytes" "$(staged "$twin")" "$(staged "$root")"
	else
		assert_eq "$label: PowerShell writes nothing either" "$([ -e "$(staged "$twin")" ] && echo written)" ""
	fi
	return "$rc"
}

# expected <root> <set> <notes body>: the core template, a blank line, the
# heading and the body plus one LF.
expected() {
	local out="$WORK_ROOT/expected.$RANDOM$RANDOM"
	{
		cat "$1/docker/shared/container-agent.md.tmpl"
		printf '\n## Additional tooling from the `%s` layer set\n\n%s\n' "$2" "$3"
	} >"$out"
	printf '%s\n' "$out"
}

echo "Test: no set, or no notes, stages the core template unchanged"

root="$(new_root)"
bash "$STAGE_SH" "" "$root"
assert_same_file "no set (empty argument): byte-identical to the core template" "$(staged "$root")" "$CORE"
root="$(new_root)"
(cd / && bash "$STAGE_SH" "" "$root")
assert_same_file "no set, run from another directory: byte-identical" "$(staged "$root")" "$CORE"
root="$(new_root)"
stage_both "no set" "$root" ""
assert_same_file "no set: byte-identical to the core template" "$(staged "$root")" "$CORE"

root="$(new_root)"
stage_both "set without agent-notes.md" "$root" demo
assert_same_file "set without agent-notes.md: no heading added" "$(staged "$root")" "$CORE"

root="$(new_root)"
: >"$root/docker/layers/demo/agent-notes.md"
stage_both "empty agent-notes.md" "$root" demo
assert_same_file "empty agent-notes.md: no heading added" "$(staged "$root")" "$CORE"

root="$(new_root)"
printf '\xef\xbb\xbf \r\n\t\n\r\n  ' >"$root/docker/layers/demo/agent-notes.md"
stage_both "whitespace-only agent-notes.md" "$root" demo
assert_same_file "whitespace-only agent-notes.md (BOM, CRLF, tabs): no heading added" "$(staged "$root")" "$CORE"

echo "Test: notes are appended under the heading"

root="$(new_root)"
printf -- '- `typst` compiles Markdown-like markup to PDF.\n- `foo`\n' >"$root/docker/layers/demo/agent-notes.md"
stage_both "LF notes" "$root" demo
assert_same_file "LF notes: core template, blank line, heading, blank line, notes" "$(staged "$root")" \
	"$(expected "$root" demo $'- `typst` compiles Markdown-like markup to PDF.\n- `foo`')"
assert_eq "LF notes: the heading appears once" "$(grep -c '^## Additional tooling from the `demo` layer set$' "$(staged "$root")")" "1"

root="$(new_root)"
printf '\xef\xbb\xbf\r\n  \r\n| Tool | Use |\r\n|---|---|\r\n| `x` | old\rmac |\r\n\r\n\r\n \t\r\n' >"$root/docker/layers/demo/agent-notes.md"
stage_both "CRLF notes" "$root" demo
assert_same_file "CRLF notes: BOM, leading blank lines and trailing whitespace dropped, LF only" "$(staged "$root")" \
	"$(expected "$root" demo $'| Tool | Use |\n|---|---|\n| `x` | old\nmac |')"
assert_eq "CRLF notes: no CR anywhere in the staged file" "$(tr -cd '\r' <"$(staged "$root")" | wc -c)" "0"
assert_eq "CRLF notes: ends with exactly one LF" "$(tail -c 2 "$(staged "$root")" | od -An -c | tr -d ' ')" '|\n'

root="$(new_root)"
printf 'Indented first line kept:\n\n    code block\n' >"$root/docker/layers/demo/agent-notes.md"
stage_both "interior blank lines" "$root" demo
assert_same_file "interior blank lines and indentation are kept" "$(staged "$root")" \
	"$(expected "$root" demo $'Indented first line kept:\n\n    code block')"

root="$(new_root)"
printf 'no trailing newline' >"$root/docker/layers/demo/agent-notes.md"
stage_both "notes without a final LF" "$root" demo
assert_same_file "notes without a final LF: one LF added" "$(staged "$root")" "$(expected "$root" demo 'no trailing newline')"

nolf="$WORK_ROOT/template-without-final-lf"
printf '# Core\n\nlast line' >"$nolf"
root="$(new_root "$nolf")"
printf 'note\n' >"$root/docker/layers/demo/agent-notes.md"
stage_both "core template without a final LF" "$root" demo
assert_eq "core template without a final LF: the line is ended before the blank line" \
	"$(cat "$(staged "$root")")" $'# Core\n\nlast line\n\n## Additional tooling from the `demo` layer set\n\nnote'

root="$(new_root)"
printf 'caf\xc3\xa9 \xff\xfe raw bytes\n' >"$root/docker/layers/demo/agent-notes.md"
stage_both "non-ASCII and invalid UTF-8 bytes" "$root" demo
assert_same_file "non-ASCII and invalid UTF-8 bytes pass through unchanged" "$(staged "$root")" \
	"$(expected "$root" demo $'caf\xc3\xa9 \xff\xfe raw bytes')"

echo "Test: \$ in notes is staged verbatim; the hooks substitute only their four names"

root="$(new_root)"
printf '%s\n' 'Cache in $HOME/.cache, never `${PATH}` or $1.' 'Config: ${AGENT_CONFIG_DIR}; peers: $AGENT_PEERS; name: ${AGENT_NAME}.' \
	>"$root/docker/layers/demo/agent-notes.md"
stage_both "notes with \$" "$root" demo
assert_same_file "notes with \$: staged verbatim" "$(staged "$root")" \
	"$(expected "$root" demo 'Cache in $HOME/.cache, never `${PATH}` or $1.'$'\n''Config: ${AGENT_CONFIG_DIR}; peers: $AGENT_PEERS; name: ${AGENT_NAME}.')"
for hook in entrypoint-claude-hook.sh entrypoint-codex-hook.sh; do
	assert_eq "$hook still renders with exactly the four documented names" \
		"$(sed -n "s/^[[:space:]]*envsubst '\([^']*\)'.*/\1/p" "$ROOT_DIR/docker/shared/$hook")" \
		'${AGENT_NAME} ${AGENT_AUTONOMY_FLAG} ${AGENT_CONFIG_DIR} ${AGENT_PEERS}'
done
if command -v envsubst >/dev/null 2>&1; then
	vars="$(sed -n "s/^[[:space:]]*envsubst '\([^']*\)'.*/\1/p" "$ROOT_DIR/docker/shared/entrypoint-codex-hook.sh")"
	rendered="$(AGENT_NAME=Codex AGENT_AUTONOMY_FLAG=--yolo AGENT_CONFIG_DIR=/home/node/.codex AGENT_PEERS=claude \
		HOME=/should-not-appear PATH="$PATH" envsubst "$vars" <"$(staged "$root")" | tail -n 2)"
	assert_eq "rendered notes: the four names substituted, every other \$ left alone" "$rendered" \
		'Cache in $HOME/.cache, never `${PATH}` or $1.'$'\n''Config: /home/node/.codex; peers: claude; name: Codex.'
else
	skipped "render through envsubst (envsubst not installed)"
fi

echo "Test: deterministic, and rewritten only when the content changes"

root="$(new_root)"
printf 'stable\r\n' >"$root/docker/layers/demo/agent-notes.md"
bash "$STAGE_SH" demo "$root"
first="$(sha256sum <"$(staged "$root")")"
touch -d '2001-01-01 00:00:00' "$(staged "$root")"
before="$(stat -c %Y "$(staged "$root")")"
bash "$STAGE_SH" demo "$root"
assert_eq "second run: identical bytes" "$(sha256sum <"$(staged "$root")")" "$first"
assert_eq "second run: the unchanged file is not rewritten" "$(stat -c %Y "$(staged "$root")")" "$before"
if $HAVE_PWSH; then
	pwsh -NoProfile -File "$STAGE_PS" demo "$root"
	assert_eq "PowerShell run over the .sh result: identical bytes" "$(sha256sum <"$(staged "$root")")" "$first"
	assert_eq "PowerShell run over the .sh result: not rewritten" "$(stat -c %Y "$(staged "$root")")" "$before"
else
	skipped "PowerShell no-rewrite (pwsh not installed)"
fi
assert_eq "staged file is mode 0644" "$(stat -c %a "$(staged "$root")")" "644"
for driver in sh ps1; do
	if [ "$driver" = ps1 ] && ! $HAVE_PWSH; then
		skipped "PowerShell under umask 077 (pwsh not installed)"
		continue
	fi
	umask_root="$(new_root)"
	if [ "$driver" = sh ]; then
		(umask 077 && bash "$STAGE_SH" "" "$umask_root")
	else
		(umask 077 && pwsh -NoProfile -File "$STAGE_PS" "" "$umask_root")
	fi
	assert_eq "$driver under umask 077: staged file is still mode 0644" "$(stat -c %a "$(staged "$umask_root")")" "644"
	chmod 0600 "$(staged "$umask_root")"
	touch -d '2001-01-01 00:00:00' "$(staged "$umask_root")"
	before="$(stat -c %Y "$(staged "$umask_root")")"
	if [ "$driver" = sh ]; then
		bash "$STAGE_SH" "" "$umask_root"
	else
		pwsh -NoProfile -File "$STAGE_PS" "" "$umask_root"
	fi
	assert_eq "$driver over an unchanged 0600 file: mode restored to 0644" "$(stat -c %a "$(staged "$umask_root")")" "644"
	assert_eq "$driver over an unchanged 0600 file: not rewritten" "$(stat -c %Y "$(staged "$umask_root")")" "$before"
done
# A chmod that fails on the staged file stands in for one another user owns.
shim="$(mktemp -d "$WORK_ROOT/shim.XXXXXX")"
real_chmod="$(command -v chmod)"
printf '#!/bin/sh\ncase "$2" in */agent.md.tmpl) exit 1 ;; esac\nexec %s "$@"\n' "$real_chmod" >"$shim/chmod"
"$real_chmod" 0755 "$shim/chmod"
owned_root="$(new_root)"
bash "$STAGE_SH" "" "$owned_root"
chmod 0600 "$(staged "$owned_root")"
PATH="$shim:$PATH" bash "$STAGE_SH" "" "$owned_root"
assert_eq "sh over an unchanged file whose mode cannot be set: replaced at 0644" "$(stat -c %a "$(staged "$owned_root")")" "644"
assert_same_file "sh over an unchanged file whose mode cannot be set: same bytes" "$(staged "$owned_root")" "$CORE"
for driver in sh ps1; do
	if [ "$driver" = ps1 ] && ! $HAVE_PWSH; then
		skipped "PowerShell over an unreadable file (pwsh not installed)"
		continue
	fi
	locked_root="$(new_root)"
	bash "$STAGE_SH" "" "$locked_root"
	chmod 0000 "$(staged "$locked_root")"
	if [ "$driver" = sh ]; then
		bash "$STAGE_SH" "" "$locked_root"
	else
		pwsh -NoProfile -File "$STAGE_PS" "" "$locked_root"
	fi
	assert_eq "$driver over an unreadable file: replaced at 0644" "$(stat -c %a "$(staged "$locked_root")")" "644"
	assert_same_file "$driver over an unreadable file: same bytes" "$(staged "$locked_root")" "$CORE"
done
assert_eq "no temp file left in the staging directory" "$(find "$root/.powbox-staging" -mindepth 1 | wc -l)" "1"
printf 'changed\n' >"$root/docker/layers/demo/agent-notes.md"
bash "$STAGE_SH" demo "$root"
assert_same_file "edited notes: the staged file follows" "$(staged "$root")" "$(expected "$root" demo changed)"
rm "$root/docker/layers/demo/agent-notes.md"
bash "$STAGE_SH" demo "$root"
assert_same_file "notes removed: back to the core template" "$(staged "$root")" "$CORE"
printf 'back\n' >"$root/docker/layers/demo/agent-notes.md"
bash "$STAGE_SH" demo "$root"
bash "$STAGE_SH" "" "$root"
assert_same_file "set deselected: back to the core template" "$(staged "$root")" "$CORE"

echo "Test: refusals"

root="$(new_root)"
rc=0
stage_both "invalid set name" "$root" '../demo' || rc=$?
assert_eq "invalid set name: fails" "$rc" "1"
assert_eq "invalid set name: names the value" "$(cat "$root.err")" "stage-agent-template: invalid layer-set name '../demo'"
assert_eq "invalid set name: nothing staged" "$([ -e "$(staged "$root")" ] && echo written)" ""

root="$(new_root)"
printf 'a\0b\n' >"$root/docker/layers/demo/agent-notes.md"
rc=0
stage_both "NUL in notes" "$root" demo || rc=$?
assert_eq "NUL in notes: fails" "$rc" "1"
assert_eq "NUL in notes: nothing staged" "$([ -e "$(staged "$root")" ] && echo written)" ""

root="$(new_root)"
mkdir "$root/docker/layers/demo/agent-notes.md"
rc=0
stage_both "agent-notes.md is a directory" "$root" demo || rc=$?
assert_eq "agent-notes.md is a directory: fails" "$rc" "1"

root="$(new_root)"
mkdir -p "$(staged "$root")"
for driver in sh ps1; do
	if [ "$driver" = ps1 ] && ! $HAVE_PWSH; then
		skipped "PowerShell over a directory at the output (pwsh not installed)"
		continue
	fi
	rc=0
	if [ "$driver" = sh ]; then
		bash "$STAGE_SH" "" "$root" 2>"$root.err" || rc=$?
	else
		pwsh -NoProfile -File "$STAGE_PS" "" "$root" 2>"$root.err" || rc=$?
	fi
	assert_eq "$driver over a directory at the output: fails" "$rc" "1"
	assert_eq "$driver over a directory at the output: says so" "$(cat "$root.err")" "stage-agent-template: $(staged "$root") is a directory"
	assert_eq "$driver over a directory at the output: nothing moved into it or left behind" "$(find "$root/.powbox-staging" -mindepth 1 | wc -l)" "1"
done

root="$(new_root)"
rm "$root/docker/shared/container-agent.md.tmpl"
rc=0
stage_both "core template missing" "$root" "" || rc=$?
assert_eq "core template missing: fails" "$rc" "1"

echo
echo "stage-agent-template tests: ${pass} passed, ${fail} failed, ${skip} skipped"
[ "$fail" -eq 0 ]
