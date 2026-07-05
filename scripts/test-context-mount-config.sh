#!/usr/bin/env bash
set -euo pipefail

# Unit tests for host-side ctx mount config parsing in launch-agent.{sh,ps1}.
# These use POWBOX_PRINT_CTX=1, so they do not need Docker or a built image.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LAUNCH_SH="${ROOT_DIR}/scripts/launch-agent.sh"
LAUNCH_PS="${ROOT_DIR}/scripts/launch-agent.ps1"

pass=0
fail=0
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
}

new_ws() {
	local name="$1" ws
	ws="${WORK_ROOT}/${name}"
	mkdir -p "$ws"
	realpath "$ws"
}

run_sh() {
	local ws="$1"
	shift
	POWBOX_PRINT_CTX=1 bash "$LAUNCH_SH" codex "$ws" "$@" 2>&1
}

run_ps() {
	local ws="$1"
	shift
	POWBOX_PRINT_CTX=1 pwsh -NoProfile -File "$LAUNCH_PS" codex "$ws" "$@" 2>&1
}

run_sh_overlay() {
	local ws="$1" overlay="$2"
	shift 2
	POWBOX_PRINT_CTX=1 POWBOX_CTX_OVERLAY_OUT="$overlay" bash "$LAUNCH_SH" codex "$ws" "$@" 2>&1
}

run_ps_overlay() {
	local ws="$1" overlay="$2"
	shift 2
	POWBOX_PRINT_CTX=1 POWBOX_CTX_OVERLAY_OUT="$overlay" pwsh -NoProfile -File "$LAUNCH_PS" codex "$ws" "$@" 2>&1
}

value_of() {
	local text="$1" key="$2"
	printf '%s\n' "$text" | awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }'
}

assert_eq() {
	local label="$1" got="$2" want="$3"
	if [ "$got" = "$want" ]; then
		ok "$label"
	else
		ko "$label (got '$got', expected '$want')"
	fi
}

assert_contains() {
	local label="$1" text="$2" needle="$3"
	if printf '%s' "$text" | grep -qF "$needle"; then
		ok "$label"
	else
		ko "$label (missing '$needle')"
	fi
}

assert_not_contains() {
	local label="$1" text="$2" needle="$3"
	if printf '%s' "$text" | grep -qF "$needle"; then
		ko "$label (unexpected '$needle')"
	else
		ok "$label"
	fi
}

echo "Test: committed ctx block supports short/long forms and hash parity"
ws="$(new_ws base-ctx)"
mkdir -p "$ws/ref A" "$ws/refB"
cat >"$ws/.powbox.yml" <<'YAML'
ctx:
  - "ref A:rw"
  - path: refB
    name: aliasB
YAML
out_sh="$(run_sh "$ws")"
out_ps="$(run_ps "$ws")"
assert_eq "bash mount count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 2
assert_eq "PowerShell mount count" "$(value_of "$out_ps" CTX_MOUNT_COUNT)" 2
assert_eq "hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"
assert_contains "short form rw mode" "$out_sh" "CTX_MOUNT_0_MODE=rw"
assert_contains "long form alias" "$out_sh" "CTX_MOUNT_1_NAME=aliasB"

hash_before="$(value_of "$out_sh" CTX_HASH)"
cat >"$ws/.powbox.yml" <<'YAML'
# Cosmetic reorder should not affect the canonical hash.
ctx:
  - path: refB
    name: aliasB
  - "ref A:rw" # same mount as before
YAML
hash_after="$(value_of "$(run_sh "$ws")" CTX_HASH)"
assert_eq "cosmetic reorder keeps hash" "$hash_after" "$hash_before"
base_ws="$ws"

echo "Test: colon-bearing short forms and long-form suffix literals"
colon_ws="$(new_ws colon-paths)"
mkdir -p "$colon_ws/foo:bar" "$colon_ws/baz:qux" "$colon_ws/ref:rw"
cat >"$colon_ws/.powbox.local.yml" <<'YAML'
ctx:
  - foo:bar
  - baz:qux:rw
  - C:\Code\OtherRepo:rw
  - path: ref:rw
YAML
out_sh="$(run_sh "$colon_ws")"
out_ps="$(run_ps "$colon_ws")"
assert_eq "colon path bash count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 3
assert_eq "colon path PowerShell count" "$(value_of "$out_ps" CTX_MOUNT_COUNT)" 3
assert_eq "colon path hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"
assert_contains "short scalar colon name" "$out_sh" "CTX_MOUNT_0_NAME=foo:bar"
assert_contains "short scalar colon default mode" "$out_sh" "CTX_MOUNT_0_MODE=ro"
assert_contains "short scalar colon rw suffix name" "$out_sh" "CTX_MOUNT_1_NAME=baz:qux"
assert_contains "short scalar colon rw suffix mode" "$out_sh" "CTX_MOUNT_1_MODE=rw"
assert_contains "long-form path keeps rw suffix in name" "$out_sh" "CTX_MOUNT_2_NAME=ref:rw"
assert_contains "long-form path keeps rw suffix in path" "$out_sh" "CTX_MOUNT_2_PATH=$(realpath "$colon_ws/ref:rw")"
assert_contains "long-form path defaults to ro" "$out_sh" "CTX_MOUNT_2_MODE=ro"
assert_not_contains "Windows-drive-looking scalar is not an object in bash" "$out_sh" "unsupported ctx object key 'C'"
assert_not_contains "Windows-drive-looking scalar is not an object in PowerShell" "$out_ps" "unsupported ctx object key 'C'"

echo "Test: local ctx clobbers committed ctx and ctx: [] is explicit empty"
ws="$base_ws"
mkdir -p "$ws/refC"
cat >"$ws/.powbox.local.yml" <<'YAML'
ctx:
  - refC
YAML
out_sh="$(run_sh "$ws")"
assert_eq "local clobber count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 1
assert_contains "local clobber target" "$out_sh" "CTX_MOUNT_0_NAME=refC"
cat >"$ws/.powbox.local.yml" <<'YAML'
ctx: []
YAML
out_sh="$(run_sh "$ws")"
out_ps="$(run_ps "$ws")"
assert_eq "explicit empty count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 0
assert_eq "explicit empty hash" "$(value_of "$out_sh" CTX_HASH)" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
assert_eq "explicit empty hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"

echo "Test: CLI --ctx overrides configured ctx"
ws="$(new_ws cli-override)"
mkdir -p "$ws/config" "$ws/cli"
cat >"$ws/.powbox.local.yml" <<'YAML'
ctx:
  - config
YAML
out_sh="$(run_sh "$ws" --ctx "$ws/cli")"
out_ps="$(run_ps "$ws" -Ctx "$ws/cli")"
assert_eq "CLI count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 1
assert_contains "CLI basename target" "$out_sh" "CTX_MOUNT_0_NAME=cli"
assert_contains "CLI mode is ro" "$out_sh" "CTX_MOUNT_0_MODE=ro"
assert_eq "CLI hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"

echo "Test: missing configured paths and duplicate target names warn and skip"
ws="$(new_ws missing-duplicate)"
mkdir -p "$ws/dupe1" "$ws/dupe2"
cat >"$ws/.powbox.local.yml" <<'YAML'
ctx:
  - missing
  - path: dupe1
    name: same
  - path: dupe2
    name: same
YAML
out_sh="$(run_sh "$ws")"
assert_eq "missing+duplicate count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 1
assert_contains "missing path warning" "$out_sh" "context path does not exist"
assert_contains "duplicate warning" "$out_sh" "duplicate ctx target name 'same'"
hash_without_missing="$(value_of "$out_sh" CTX_HASH)"
mkdir -p "$ws/missing"
out_sh="$(run_sh "$ws")"
assert_eq "missing path appears once created" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 2
if [ "$(value_of "$out_sh" CTX_HASH)" != "$hash_without_missing" ]; then
	ok "created path changes hash"
else
	ko "created path changes hash (hash did not change)"
fi

echo "Test: overlay quotes YAML scalars and doubles Compose dollars"
ws="$(new_ws overlay-dollar)"
mkdir -p "$ws/dollar\$name,pipe|dir"
cat >"$ws/.powbox.local.yml" <<'YAML'
ctx:
  - path: dollar$name,pipe|dir
    name: "target$NAME,pipe|"
    mode: rw
YAML
overlay_sh="$WORK_ROOT/ctx-sh.yml"
overlay_ps="$WORK_ROOT/ctx-ps.yml"
out_sh="$(run_sh_overlay "$ws" "$overlay_sh")"
out_ps="$(run_ps_overlay "$ws" "$overlay_ps")"
assert_eq "overlay hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"
assert_contains "source dollar escaped" "$(cat "$overlay_sh")" 'source: '
assert_contains "source doubles dollar" "$(cat "$overlay_sh")" "dollar\$\$name,pipe|dir"
assert_contains "target doubles dollar" "$(cat "$overlay_sh")" "target\$\$NAME,pipe|"
if cmp -s "$overlay_sh" "$overlay_ps"; then
	ok "bash and PowerShell overlays match"
else
	ko "bash and PowerShell overlays match"
fi

echo "Test: YAML newline escapes survive hash and overlay emission"
ws="$(new_ws newline)"
mkdir -p "$ws/line
break"
cat >"$ws/.powbox.local.yml" <<'YAML'
ctx:
  - path: "line\nbreak"
    name: "line\nname"
YAML
overlay_sh="$WORK_ROOT/ctx-newline-sh.yml"
overlay_ps="$WORK_ROOT/ctx-newline-ps.yml"
out_sh="$(run_sh_overlay "$ws" "$overlay_sh")"
out_ps="$(run_ps_overlay "$ws" "$overlay_ps")"
assert_eq "newline hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"
assert_contains "newline source emitted as YAML escape" "$(cat "$overlay_sh")" 'line\nbreak'
assert_contains "newline target emitted as YAML escape" "$(cat "$overlay_sh")" 'line\nname'
if cmp -s "$overlay_sh" "$overlay_ps"; then
	ok "newline overlays match"
else
	ko "newline overlays match"
fi

echo "Test: .powbox.local.yml gitignore guard"
ws="$(new_ws gitignore-guard)"
git -C "$ws" init -q
cat >"$ws/.powbox.local.yml" <<'YAML'
ctx: []
YAML
out_sh="$(run_sh "$ws")"
assert_contains "unignored local config warns" "$out_sh" ".powbox.local.yml exists but is not ignored"
printf '.powbox.local.yml\n' >"$ws/.gitignore"
out_sh="$(run_sh "$ws")"
out_ps="$(run_ps "$ws")"
assert_not_contains "ignored local config quiet in bash" "$out_sh" ".powbox.local.yml exists but is not ignored"
assert_not_contains "ignored local config quiet in PowerShell" "$out_ps" ".powbox.local.yml exists but is not ignored"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
