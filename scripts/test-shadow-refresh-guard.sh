#!/usr/bin/env bash
# Unit tests for docker/shared/shadow-refresh.sh's launch-mode guards.
#
# Focus: the script must refuse to mount anything in the two modes where
# entrypoint-core.sh deliberately skips shadowing — self-hosted (--isolated)
# and the image-store WRITER role.  Both containers hold CAP_SYS_ADMIN, and
# shadow-mounts.sh validates only "under /workspace/ and not depth-1" (never
# emptiness), so an unguarded hand-run would successfully tmpfs-mask real
# content rather than fail safe.
#
# Runs directly against the repo copy — no image build, no sudo, no mounts.
# detect-shadows.sh and sudo are shimmed on PATH so a guard regression is
# caught as an attempted call instead of an actual mount.
#
# Usage: scripts/test-shadow-refresh-guard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$SCRIPT_DIR/../docker/shared/shadow-refresh.sh"

if [ ! -f "$REFRESH" ]; then
	echo "FATAL: shadow-refresh.sh not found at $REFRESH" >&2
	exit 1
fi

pass=0
fail=0

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

# Shim PATH: record any call the guard should have prevented.  `sudo` is the
# real hazard (it is what reaches shadow-mounts.sh); detect-shadows.sh is
# shimmed too so the test never depends on yq/jq or a real workspace layout.
SHIM_DIR="$WORK_ROOT/bin"
CALL_LOG="$WORK_ROOT/calls.log"
mkdir -p "$SHIM_DIR"

cat >"$SHIM_DIR/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >>"$CALL_LOG"
exit 0
EOF

# Emit one plausible target so an unguarded run reaches the sudo call rather
# than short-circuiting on "No directories to shadow."
cat >"$SHIM_DIR/detect-shadows.sh" <<EOF
#!/usr/bin/env bash
echo "detect-shadows \$*" >>"$CALL_LOG"
echo "/workspace/proj/pkg/node_modules"
EOF

chmod +x "$SHIM_DIR/sudo" "$SHIM_DIR/detect-shadows.sh"

# run_case <name> <expect: skip|proceed> [env assignments...]
# Runs shadow-refresh.sh with the shims first on PATH, against a fixed
# workspace-dir argument so the run never depends on real /workspace contents.
run_case() {
	local name="$1" expect="$2"
	shift 2
	local out rc=0
	: >"$CALL_LOG"

	out="$(env "$@" PATH="$SHIM_DIR:$PATH" bash "$REFRESH" /workspace/proj 2>&1)" || rc=$?

	local problems=""
	[ "$rc" -eq 0 ] || problems="$problems nonzero-exit($rc)"

	if [ "$expect" = "skip" ]; then
		grep -q 'sudo' "$CALL_LOG" && problems="$problems reached-sudo"
		grep -q 'detect-shadows' "$CALL_LOG" && problems="$problems reached-detect"
		case "$out" in
		*"skipped in this"*) ;;
		*) problems="$problems no-skip-message" ;;
		esac
	else
		grep -q 'sudo' "$CALL_LOG" || problems="$problems never-reached-sudo"
	fi

	if [ -n "$problems" ]; then
		echo "FAIL: $name —$problems"
		echo "  output: $out"
		fail=$((fail + 1))
	else
		echo "ok: $name"
		pass=$((pass + 1))
	fi
}

# --- the two guarded modes ---------------------------------------------------
run_case "self-hosted (--isolated) skips without mounting" skip POWBOX_SELF_HOSTED=1
run_case "image-store writer role skips without mounting" skip POWBOX_IMAGE_STORE_ROLE=writer

# --- the guards must not fire otherwise --------------------------------------
# Positive control: without these, "skip" could pass by the script being broken.
run_case "dir-mounted (both unset) still shadows" proceed POWBOX_UNRELATED=1
run_case "self-hosted=0 still shadows" proceed POWBOX_SELF_HOSTED=0
run_case "writer role spelled differently still shadows" proceed POWBOX_IMAGE_STORE_ROLE=reader

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
