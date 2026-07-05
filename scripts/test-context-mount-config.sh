#!/usr/bin/env bash
set -euo pipefail

# Unit tests for host-side ctx mount config parsing in launch-agent.{sh,ps1}.
# These use POWBOX_PRINT_CTX=1 or a fake docker shim, so they do not need Docker
# or a built image.

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

run_sh_no_print() {
	local ws="$1"
	shift
	bash "$LAUNCH_SH" codex "$ws" "$@" 2>&1
}

run_ps_no_print() {
	local ws="$1"
	shift
	pwsh -NoProfile -File "$LAUNCH_PS" codex "$ws" "$@" 2>&1
}

run_ps_ctx_values_from() {
	local cwd="$1" ws="$2" joined="" value
	shift 2
	for value in "$@"; do
		if [ -n "$joined" ]; then
			joined+=$'\n'
		fi
		joined+="$value"
	done
	(
		cd "$cwd"
		# shellcheck disable=SC2016 # Literal PowerShell command; variables expand in pwsh.
		POWBOX_PRINT_CTX=1 \
			POWBOX_TEST_LAUNCH_PS="$LAUNCH_PS" \
			POWBOX_TEST_WS="$ws" \
			POWBOX_TEST_CTX_VALUES="$joined" \
			pwsh -NoProfile -Command '$ctx = if ($env:POWBOX_TEST_CTX_VALUES -eq "") { @() } else { $env:POWBOX_TEST_CTX_VALUES -split "`n" }; & $env:POWBOX_TEST_LAUNCH_PS codex $env:POWBOX_TEST_WS -Ctx $ctx' 2>&1
	)
}

run_ps_ctx_values() {
	local ws="$1"
	shift
	run_ps_ctx_values_from "$PWD" "$ws" "$@"
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
	if printf '%s' "$text" | grep -qF -- "$needle"; then
		ok "$label"
	else
		ko "$label (missing '$needle')"
	fi
}

assert_not_contains() {
	local label="$1" text="$2" needle="$3"
	if printf '%s' "$text" | grep -qF -- "$needle"; then
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

echo "Test: key-looking short forms are scalars unless colon is followed by whitespace"
key_ws="$(new_ws key-looking-scalars)"
mkdir -p "$key_ws/path:foo" "$key_ws/name:bar" "$key_ws/mode:baz"
cat >"$key_ws/.powbox.local.yml" <<'YAML'
ctx:
  - path:foo
  - name:bar
  - mode:baz
YAML
out_sh="$(run_sh "$key_ws")"
out_ps="$(run_ps "$key_ws")"
assert_eq "key-looking scalar bash count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 3
assert_eq "key-looking scalar PowerShell count" "$(value_of "$out_ps" CTX_MOUNT_COUNT)" 3
assert_eq "key-looking scalar hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"
assert_contains "path-looking scalar name" "$out_sh" "CTX_MOUNT_0_NAME=path:foo"
assert_contains "name-looking scalar name" "$out_sh" "CTX_MOUNT_1_NAME=name:bar"
assert_contains "mode-looking scalar name" "$out_sh" "CTX_MOUNT_2_NAME=mode:baz"
assert_contains "path-looking scalar default mode" "$out_sh" "CTX_MOUNT_0_MODE=ro"
assert_contains "name-looking scalar default mode" "$out_sh" "CTX_MOUNT_1_MODE=ro"
assert_contains "mode-looking scalar default mode" "$out_sh" "CTX_MOUNT_2_MODE=ro"
assert_not_contains "key-looking scalars do not form missing-path objects in bash" "$out_sh" "missing required path"
assert_not_contains "key-looking scalars do not form missing-path objects in PowerShell" "$out_ps" "missing required path"

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

echo "Test: CLI --ctx accepts multiple values, modes, aliases, and config/hash parity"
ws="$(new_ws cli-multi)"
mkdir -p "$ws/config" "$ws/refA" "$ws/docs"
cat >"$ws/.powbox.local.yml" <<'YAML'
ctx:
  - config
YAML
out_sh="$(run_sh "$ws" --ctx "$ws/refA" --ctx "Docs=$ws/docs:rw")"
out_ps="$(run_ps_ctx_values "$ws" "$ws/refA" "Docs=$ws/docs:rw")"
assert_eq "CLI multi bash count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 2
assert_eq "CLI multi PowerShell count" "$(value_of "$out_ps" CTX_MOUNT_COUNT)" 2
assert_contains "CLI multi basename target" "$out_sh" "CTX_MOUNT_0_NAME=refA"
assert_contains "CLI multi basename mode" "$out_sh" "CTX_MOUNT_0_MODE=ro"
assert_contains "CLI multi alias target" "$out_sh" "CTX_MOUNT_1_NAME=Docs"
assert_contains "CLI multi alias mode" "$out_sh" "CTX_MOUNT_1_MODE=rw"
assert_not_contains "CLI multi ignores configured ctx" "$out_sh" "NAME=config"
assert_eq "CLI multi hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"
cli_multi_hash="$(value_of "$out_sh" CTX_HASH)"
cat >"$ws/.powbox.local.yml" <<YAML
ctx:
  - "$ws/refA"
  - path: "$ws/docs"
    name: Docs
    mode: rw
YAML
config_hash="$(value_of "$(run_sh "$ws")" CTX_HASH)"
assert_eq "CLI and equivalent config hash match" "$cli_multi_hash" "$config_hash"

echo "Test: CLI relative ctx resolves from caller cwd"
caller_ws="$(new_ws cli-caller-cwd)"
mkdir -p "$caller_ws/project" "$caller_ws/refs" "$caller_ws/project/refs"
out_sh="$(
	cd "$caller_ws"
	POWBOX_PRINT_CTX=1 bash "$LAUNCH_SH" codex "$caller_ws/project" --ctx refs 2>&1
)"
out_ps="$(
	cd "$caller_ws"
	POWBOX_PRINT_CTX=1 pwsh -NoProfile -File "$LAUNCH_PS" codex "$caller_ws/project" -Ctx refs 2>&1
)"
assert_contains "CLI relative bash caller path" "$out_sh" "CTX_MOUNT_0_PATH=$(realpath "$caller_ws/refs")"
assert_contains "CLI relative PowerShell caller path" "$out_ps" "CTX_MOUNT_0_PATH=$(realpath "$caller_ws/refs")"
assert_not_contains "CLI relative bash not workspace path" "$out_sh" "CTX_MOUNT_0_PATH=$(realpath "$caller_ws/project/refs")"
assert_not_contains "CLI relative PowerShell not workspace path" "$out_ps" "CTX_MOUNT_0_PATH=$(realpath "$caller_ws/project/refs")"

echo "Test: CLI literal leading tilde ctx resolves from HOME"
tilde_ws="$(new_ws cli-tilde)"
fake_home="$WORK_ROOT/fake-home"
# shellcheck disable=SC2088 # This regression requires a literal leading tilde.
literal_tilde_ctx='~/existing-dir'
mkdir -p "$tilde_ws/project" "$fake_home/existing-dir"
out_sh="$(HOME="$fake_home" run_sh "$tilde_ws/project" --ctx "$literal_tilde_ctx")"
out_ps="$(HOME="$fake_home" run_ps "$tilde_ws/project" -Ctx "$literal_tilde_ctx")"
assert_eq "CLI tilde bash count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 1
assert_eq "CLI tilde PowerShell count" "$(value_of "$out_ps" CTX_MOUNT_COUNT)" 1
assert_contains "CLI tilde bash path" "$out_sh" "CTX_MOUNT_0_PATH=$(realpath "$fake_home/existing-dir")"
assert_contains "CLI tilde PowerShell path" "$out_ps" "CTX_MOUNT_0_PATH=$(realpath "$fake_home/existing-dir")"
assert_eq "CLI tilde hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"

echo "Test: CLI equals split only when the prefix is a valid alias"
eq_ws="$(new_ws cli-equals)"
mkdir -p "$eq_ws/project" "$eq_ws/fixtures=a" "$eq_ws/a"
out_sh="$(
	cd "$eq_ws"
	POWBOX_PRINT_CTX=1 bash "$LAUNCH_SH" codex "$eq_ws/project" --ctx ./fixtures=a --ctx fixtures=a 2>&1
)"
out_ps="$(run_ps_ctx_values_from "$eq_ws" "$eq_ws/project" "./fixtures=a" "fixtures=a")"
assert_eq "CLI equals bash count" "$(value_of "$out_sh" CTX_MOUNT_COUNT)" 2
assert_eq "CLI equals PowerShell count" "$(value_of "$out_ps" CTX_MOUNT_COUNT)" 2
assert_contains "CLI path with equals remains path" "$out_sh" "CTX_MOUNT_0_NAME=fixtures=a"
assert_contains "CLI path with equals path" "$out_sh" "CTX_MOUNT_0_PATH=$(realpath "$eq_ws/fixtures=a")"
assert_contains "CLI bare equals uses alias" "$out_sh" "CTX_MOUNT_1_NAME=fixtures"
assert_contains "CLI bare equals alias path" "$out_sh" "CTX_MOUNT_1_PATH=$(realpath "$eq_ws/a")"
assert_eq "CLI equals hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"

echo "Test: invalid CLI ctx values fail hard"
ws="$(new_ws cli-invalid)"
mkdir -p "$ws/a" "$ws/b"
set +e
out_sh="$(run_sh "$ws" --ctx "same=$ws/a" --ctx "same=$ws/b")"
status_sh=$?
out_ps="$(run_ps_ctx_values "$ws" "same=$ws/a" "same=$ws/b")"
status_ps=$?
set -e
assert_eq "CLI duplicate bash status" "$status_sh" 1
assert_eq "CLI duplicate PowerShell status" "$status_ps" 1
assert_contains "CLI duplicate bash error" "$out_sh" "duplicate ctx target name 'same'"
assert_contains "CLI duplicate PowerShell error" "$out_ps" "duplicate ctx target name 'same'"
set +e
out_sh="$(run_sh "$ws" --ctx "$ws/missing")"
status_sh=$?
out_ps="$(run_ps "$ws" -Ctx "$ws/missing")"
status_ps=$?
set -e
assert_eq "CLI missing path bash status" "$status_sh" 1
assert_eq "CLI missing path PowerShell status" "$status_ps" 1
assert_contains "CLI missing path bash error" "$out_sh" "context path does not exist"
assert_contains "CLI missing path PowerShell error" "$out_ps" "context path does not exist"
set +e
out_sh="$(run_sh "$ws" --ctx)"
status_sh=$?
out_ps="$(run_ps "$ws" -Ctx "")"
status_ps=$?
set -e
assert_eq "CLI missing value bash status" "$status_sh" 1
assert_eq "CLI empty value PowerShell status" "$status_ps" 1
assert_contains "CLI missing value bash error" "$out_sh" "missing path for --ctx"
assert_contains "CLI empty value PowerShell error" "$out_ps" "-Ctx value has an empty path"

echo "Test: CLI ctx validation runs before Docker setup"
ws="$(new_ws cli-before-docker)"
fake_bin="$WORK_ROOT/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
echo "FAKE_DOCKER_CALLED $*" >&2
exit 42
SH
chmod +x "$fake_bin/docker"
set +e
out_sh="$(PATH="$fake_bin:$PATH" run_sh_no_print "$ws" --ctx "")"
status_sh=$?
out_ps="$(PATH="$fake_bin:$PATH" run_ps_no_print "$ws" -Ctx "")"
status_ps=$?
set -e
assert_eq "empty ctx before Docker bash status" "$status_sh" 1
assert_eq "empty ctx before Docker PowerShell status" "$status_ps" 1
assert_contains "empty ctx before Docker bash error" "$out_sh" "--ctx value has an empty path"
assert_contains "empty ctx before Docker PowerShell error" "$out_ps" "-Ctx value has an empty path"
assert_not_contains "empty ctx before Docker bash skips docker" "$out_sh" "FAKE_DOCKER_CALLED"
assert_not_contains "empty ctx before Docker PowerShell skips docker" "$out_ps" "FAKE_DOCKER_CALLED"

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
printf -v source_dollar_needle 'dollar\044\044name,pipe|dir'
printf -v target_dollar_needle 'target\044\044NAME,pipe|'
assert_eq "overlay hash parity" "$(value_of "$out_sh" CTX_HASH)" "$(value_of "$out_ps" CTX_HASH)"
assert_contains "source dollar escaped" "$(cat "$overlay_sh")" 'source: '
assert_contains "source doubles dollar" "$(cat "$overlay_sh")" "$source_dollar_needle"
assert_contains "target doubles dollar" "$(cat "$overlay_sh")" "$target_dollar_needle"
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
