#!/usr/bin/env bash
# Hermetic tests for the launcher's image-store writer gate: whether
# scripts/launch-agent.{sh,ps1} start the shared image-store writer depends on
# the agent image's powbox.podman label, which the layer set that installs
# Podman declares (docker/layers/full/Dockerfile).
#
# Driving the whole launcher as far as the writer block would mean answering
# every Docker call before it, so the suite tests the gate where it is a small
# function: powbox_image_store_writer_wanted in launch-agent.sh and
# Test-PowboxImageStoreWriterWanted in launch-agent.ps1, each extracted from
# the launcher and run against a fake `docker` on PATH that answers
# `image inspect`. Both are checked for the same cases (label present, absent,
# empty, `<no value>`, an image that cannot be inspected) and must agree. A
# static check pins each call site: the writer's `compose run` is reached only
# through the gate and carries the container label powbox.image-store-role=writer.
# Without pwsh the PowerShell half reports an honest skip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LAUNCH_SH="${ROOT_DIR}/scripts/launch-agent.sh"
LAUNCH_PS="${ROOT_DIR}/scripts/launch-agent.ps1"

pass=0
fail=0
skip=0
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

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

HAVE_PWSH=false
if command -v pwsh >/dev/null 2>&1; then
	HAVE_PWSH=true
fi

# ---------------------------------------------------------------------------
# The fake docker. `image inspect <image> --format <template>` answers from
# FAKE_LABEL_MODE: `value` prints FAKE_LABEL_VALUE, `empty` prints an empty
# line (a label set to ""), `novalue` prints `<no value>` (the label is
# absent), and `fail` exits 1 (an image that cannot be inspected). The
# template must name the powbox.podman label as a Go raw string and hold no
# double quote: Windows PowerShell 5.1 strips double quotes embedded in a
# native argument, which would leave real docker an invalid template. Every
# call is logged, so a test can see that nothing else was asked.
# ---------------------------------------------------------------------------
FAKE_DIR="$WORK_ROOT/fake"
mkdir -p "$FAKE_DIR"
cat >"$FAKE_DIR/docker" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
[ "$1" = image ] && [ "$2" = inspect ] || exit 97
fmt="" prev=""
for a in "$@"; do
	[ "$prev" = --format ] && fmt="$a"
	prev="$a"
done
case "$fmt" in
*'"'*)
	echo "template parsing error: $fmt" >&2
	exit 98
	;;
*'Labels `powbox.podman`'*) : ;;
*)
	echo "unexpected template: $fmt" >&2
	exit 99
	;;
esac
case "$FAKE_LABEL_MODE" in
value) printf '%s\n' "$FAKE_LABEL_VALUE" ;;
empty) echo ;;
novalue) echo '<no value>' ;;
fail)
	echo "Error: No such image: $3" >&2
	exit 1
	;;
esac
SHIM
chmod +x "$FAKE_DIR/docker"

# ---------------------------------------------------------------------------
# Extract the two functions from the launchers. Each starts at its definition
# and ends at the first closing brace in column 0.
# ---------------------------------------------------------------------------
GATE_SH="$WORK_ROOT/gate.sh"
sed -n '/^powbox_image_store_writer_wanted() {$/,/^}$/p' "$LAUNCH_SH" >"$GATE_SH"
GATE_PS="$WORK_ROOT/gate.ps1"
tr -d '\r' <"$LAUNCH_PS" | sed -n '/^function Test-PowboxImageStoreWriterWanted {$/,/^}$/p' >"$GATE_PS"

echo "Test: the gate functions can be extracted from the launchers"
if [ -s "$GATE_SH" ] && [ "$(tail -n 1 "$GATE_SH")" = "}" ]; then
	ok "launch-agent.sh defines powbox_image_store_writer_wanted"
else
	ko "launch-agent.sh: powbox_image_store_writer_wanted not found as a column-0 function"
fi
if [ -s "$GATE_PS" ] && [ "$(tail -n 1 "$GATE_PS")" = "}" ]; then
	ok "launch-agent.ps1 defines Test-PowboxImageStoreWriterWanted"
else
	ko "launch-agent.ps1: Test-PowboxImageStoreWriterWanted not found as a column-0 function"
fi

# gate_sh <mode> [<value>]: prints seed or skip.
gate_sh() {
	FAKE_DOCKER_LOG="$WORK_ROOT/docker.log" FAKE_LABEL_MODE="$1" FAKE_LABEL_VALUE="${2:-}" PATH="$FAKE_DIR:$PATH" \
		bash -c '. "$1"; if powbox_image_store_writer_wanted powbox-agent:latest; then echo seed; else echo skip; fi' gate "$GATE_SH"
}

# gate_ps <mode> [<value>]: prints seed or skip, then the exit code the
# function leaves behind.
gate_ps() {
	# shellcheck disable=SC2016 # PowerShell variables, expanded by pwsh
	FAKE_DOCKER_LOG="$WORK_ROOT/docker.log" FAKE_LABEL_MODE="$1" FAKE_LABEL_VALUE="${2:-}" PATH="$FAKE_DIR:$PATH" GATE_PS="$GATE_PS" \
		pwsh -NoProfile -NonInteractive -Command '. $env:GATE_PS; if (Test-PowboxImageStoreWriterWanted -Image "powbox-agent:latest") { "seed" } else { "skip" }; "exit=$LASTEXITCODE"'
}

echo "Test: the writer is started only for an image that carries powbox.podman"
# mode|value|expected|description
CASES=(
	"value|1|seed|label powbox.podman=1"
	"value|yes|seed|label with another non-empty value"
	"novalue||skip|label absent (<no value>)"
	"empty||skip|label present but empty"
	"fail||skip|image that cannot be inspected"
)
for c in "${CASES[@]}"; do
	IFS='|' read -r mode value want what <<<"$c"
	: >"$WORK_ROOT/docker.log"
	got="$(gate_sh "$mode" "$value" 2>&1)" || true
	if [ "$got" = "$want" ]; then
		ok "[sh] $what: $want"
	else
		ko "[sh] $what" "expected: $want" "actual:   $got"
	fi
	calls="$(wc -l <"$WORK_ROOT/docker.log" | tr -d ' ')"
	if [ "$calls" = 1 ] && grep -q '^image inspect powbox-agent:latest --format ' "$WORK_ROOT/docker.log"; then
		ok "[sh] $what: one image inspect of powbox-agent:latest, nothing else"
	else
		ko "[sh] $what: unexpected docker calls" "$(cat "$WORK_ROOT/docker.log")"
	fi
	if ! $HAVE_PWSH; then
		continue
	fi
	cp "$WORK_ROOT/docker.log" "$WORK_ROOT/docker.sh.log"
	: >"$WORK_ROOT/docker.log"
	got="$(gate_ps "$mode" "$value" 2>&1 | tr -d '\r')" || true
	if [ "$got" = "$want"$'\n'"exit=0" ]; then
		ok "[ps1] $what: $want, leaving \$LASTEXITCODE at 0"
	else
		ko "[ps1] $what" "expected: $want / exit=0" "actual:   $(printf '%s' "$got" | tr '\n' ' ')"
	fi
	if cmp -s "$WORK_ROOT/docker.log" "$WORK_ROOT/docker.sh.log"; then
		ok "[ps1] $what: the same docker arguments as the .sh"
	else
		ko "[ps1] $what: docker arguments differ from the .sh" "sh:  $(cat "$WORK_ROOT/docker.sh.log")" "ps1: $(cat "$WORK_ROOT/docker.log")"
	fi
done
if ! $HAVE_PWSH; then
	skipped "pwsh unavailable - Test-PowboxImageStoreWriterWanted not run"
fi

# ---------------------------------------------------------------------------
# The call sites. The writer block is the only `compose run` that sets
# POWBOX_IMAGE_STORE_ROLE=writer; it must sit behind the gate and carry the
# container label the host validation filters `docker events` on.
# ---------------------------------------------------------------------------
echo "Test: each launcher's writer run is gated and labelled"
# block_of <file>: the lines from the fuse device check that opens the writer
# block (the last one before the writer) to the writer's
# `seed-image-store.sh seed` line.
block_of() {
	tr -d '\r' <"$1" | awk '
		done { next }
		/fuse,\*/ { on = 1; buf = "" }
		on { buf = buf $0 "\n" }
		on && /seed-image-store\.sh seed/ { printf "%s", buf; done = 1 }
	'
}
for launcher in "$LAUNCH_SH" "$LAUNCH_PS"; do
	name="${launcher##*/}"
	blk="$(block_of "$launcher")" || true
	if [ -z "$blk" ]; then
		ko "$name: writer block not found"
		continue
	fi
	case "$name" in
	*.sh) gate_call="powbox_image_store_writer_wanted powbox-agent:latest" ;;
	*) gate_call="Test-PowboxImageStoreWriterWanted -Image 'powbox-agent:latest'" ;;
	esac
	gate_line="$(printf '%s' "$blk" | grep -nF -- "$gate_call" | head -n 1 | cut -d: -f1)" || true
	run_line="$(printf '%s' "$blk" | grep -n -- 'compose .*run --rm -d' | head -n 1 | cut -d: -f1)" || true
	if [ -n "$gate_line" ] && [ -n "$run_line" ] && [ "$gate_line" -le "$run_line" ]; then
		ok "$name: the writer run is reached only through the gate"
	else
		ko "$name: the writer run is not behind the gate" "$blk"
	fi
	if printf '%s' "$blk" | grep -qE -- '--label powbox\.image-store-role=writer( |$)'; then
		ok "$name: the writer run carries --label powbox.image-store-role=writer"
	else
		ko "$name: the writer run lacks --label powbox.image-store-role=writer" "$blk"
	fi
	if [ "$(tr -d '\r' <"$launcher" | grep -c 'POWBOX_IMAGE_STORE_ROLE=writer')" = 1 ]; then
		ok "$name: exactly one run starts a writer"
	else
		ko "$name: expected exactly one POWBOX_IMAGE_STORE_ROLE=writer run"
	fi
done

echo "Test: the layer set that installs Podman declares the label"
full_dockerfile="${ROOT_DIR}/docker/layers/full/Dockerfile"
if grep -qx 'LABEL powbox.podman="1"' "$full_dockerfile" && grep -q '^    podman \\$' "$full_dockerfile"; then
	ok "docker/layers/full/Dockerfile installs podman and declares LABEL powbox.podman=\"1\""
else
	ko "docker/layers/full/Dockerfile: the podman install and the powbox.podman label must both be there"
fi
for f in "${ROOT_DIR}/docker/base/Dockerfile" "${ROOT_DIR}/docker/layers/browser/Dockerfile"; do
	if grep -qE '^[[:space:]]*LABEL[[:space:]].*powbox\.podman' "$f"; then
		ko "${f#"$ROOT_DIR"/} declares powbox.podman, but installs no Podman"
	else
		ok "${f#"$ROOT_DIR"/} does not declare powbox.podman"
	fi
done

echo
echo "image-store writer gate tests: ${pass} passed, ${fail} failed, ${skip} skipped"
[ "$fail" -eq 0 ]
