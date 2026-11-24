#!/usr/bin/env bash
# Unit test for scripts/smoke-test-ownership-negative-control.sh, the Stage 6
# mountpoint-ownership negative control (task 053c).
#
# Hermetic: no image, no Docker daemon, no root. The control's real run needs a
# rootful engine and runs in Tier 1; this suite pins the parts whose failure
# would turn that run into a silent pass:
#   * the mutation removes exactly the mountpoint chown from the REAL
#     docker/shared/shadow-mounts.sh, keeps the ancestor chown, mode and syntax,
#     and refuses (leaving the file untouched) when its line is absent,
#     duplicated or reindented, or when the ancestor chown is gone;
#   * the classifier, fed the REAL output of BOTH unchanged Stage 6 drivers
#     (the .ps1 half when pwsh is installed). A fake `docker` stands in for the
#     engine and plays Container A; a fake `stat` reports the three created
#     mountpoints as root-owned, which is what the mutation leaves on a rootful
#     host (as another owner when the suite itself runs as root). It must accept only that run, and reject a run that passed (chown
#     intact), a run whose assertions are blind (stat returns one sentinel for
#     every path), and a Container A abort; a self-skip and a rootless note are
#     inconclusive, never a pass;
#   * the teeth probe's decision, and that every driver and Container A string
#     the classifier anchors on still occurs in its source file;
#   * that `run` refuses without jq and the image-config check never passes on
#     an unreadable config, and that the .ps1 wrapper's exit status follows
#     `pwsh -File` (a driver's own `exit N` is forwarded).
# shellcheck disable=SC2016 # single-quoted shell text here is literal by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARNESS="$ROOT_DIR/scripts/smoke-test-ownership-negative-control.sh"
SHADOW_MOUNTS="$ROOT_DIR/docker/shared/shadow-mounts.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/powbox-negctl-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

failures=0
checks=0

ok() {
	checks=$((checks + 1))
	printf '  ok    %s\n' "$1"
}

bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  FAIL  %s\n' "$1" >&2
	if [ "$#" -gt 1 ]; then
		shift
		printf '        %s\n' "$@" >&2
	fi
}

# The harness's anchors, read from the harness itself.
# shellcheck source=/dev/null # sourced for its anchors only; linted on its own
. "$HARNESS"
set +e

echo "== mutation =="

cp -- "$SHADOW_MOUNTS" "$TMP/sm.sh"
chmod 755 "$TMP/sm.sh"
if out="$(bash "$HARNESS" mutate "$TMP/sm.sh" 2>&1)"; then
	ok "the mutation applies to the real shadow-mounts.sh"
else
	bad "the mutation does not apply to the real shadow-mounts.sh" "$out"
fi
grep -vxF -- "$MOUNTPOINT_CHOWN" "$SHADOW_MOUNTS" >"$TMP/expected.sh"
if cmp -s "$TMP/expected.sh" "$TMP/sm.sh" && [ "$(diff "$SHADOW_MOUNTS" "$TMP/sm.sh" | grep -c '^[<>]')" = 1 ]; then
	ok "the result is the source minus exactly one line, the mountpoint chown"
else
	bad "the result is not the source minus exactly the mountpoint chown" "$(diff "$SHADOW_MOUNTS" "$TMP/sm.sh")"
fi
if [ "$(grep -cxF -- "$ANCESTOR_CHOWN" "$TMP/sm.sh")" = 1 ]; then
	ok "the ancestor chown survives, so Container A's intermediate check still passes"
else
	bad "the ancestor chown did not survive the mutation"
fi
if [ "$(stat -c %a "$TMP/sm.sh")" = 755 ] && bash -n "$TMP/sm.sh"; then
	ok "the mutated file keeps its mode and parses"
else
	bad "the mutated file lost its mode or no longer parses"
fi

# refuse_case <name> <fixture>: the mutation must fail and leave the file as it was.
refuse_case() {
	local name="$1" file="$2" before
	before="$(cat "$file")"
	if bash "$HARNESS" mutate "$file" >"$TMP/refuse.out" 2>&1; then
		bad "the mutation applied to a file $name" "$(cat "$TMP/refuse.out")"
	elif ! grep -q '^NEGATIVE CONTROL FAILED: ' "$TMP/refuse.out"; then
		bad "the mutation refused a file $name without the harness's failure line" "$(cat "$TMP/refuse.out")"
	elif [ "$(cat "$file")" != "$before" ]; then
		bad "the mutation refused a file $name but changed it"
	else
		ok "the mutation refuses a file $name and leaves it untouched"
	fi
}

cp -- "$TMP/sm.sh" "$TMP/already.sh"
refuse_case "already mutated (no mountpoint chown)" "$TMP/already.sh"
{
	cat "$SHADOW_MOUNTS"
	printf '%s\n' "$MOUNTPOINT_CHOWN"
} >"$TMP/twice.sh"
refuse_case "holding the mountpoint chown twice" "$TMP/twice.sh"
sed 's/^\tif \[ "\$created" = 1 \]; then adopt_owner; fi$/    if [ "$created" = 1 ]; then adopt_owner; fi/' "$SHADOW_MOUNTS" >"$TMP/reindented.sh"
refuse_case "whose mountpoint chown is reindented" "$TMP/reindented.sh"
grep -vxF -- "$ANCESTOR_CHOWN" "$SHADOW_MOUNTS" >"$TMP/noancestor.sh"
refuse_case "without the ancestor chown" "$TMP/noancestor.sh"

echo "== anchors occur in their sources =="

DRIVER_SH="$ROOT_DIR/scripts/smoke-test-worktree-metadata.sh"
DRIVER_PS1="$ROOT_DIR/scripts/smoke-test-worktree-metadata.ps1"
CONTAINER_A="$ROOT_DIR/scripts/smoke-test-worktree-metadata-container-a.bash"
for pair in \
	"$CONTAINER_A|$CONTAINER_A_ANCESTOR_OK" \
	"$CONTAINER_A|$CONTAINER_A_DONE_OK" \
	"$CONTAINER_A|$CONTAINER_A_REGRESSED" \
	"$DRIVER_SH|$CONTAINER_A_ABORT" "$DRIVER_PS1|$CONTAINER_A_ABORT" \
	"$DRIVER_SH|$DRIVER_BANNER_PREFIX" "$DRIVER_PS1|$DRIVER_BANNER_PREFIX" \
	"$DRIVER_SH|$HOST_OWNERSHIP_OK" "$DRIVER_PS1|$HOST_OWNERSHIP_OK" \
	"$DRIVER_SH|$VACUITY_ROOTLESS" "$DRIVER_PS1|$VACUITY_ROOTLESS" \
	"$DRIVER_SH|$VACUITY_ROOT" "$DRIVER_PS1|$VACUITY_ROOT"; do
	file="${pair%%|*}"
	text="${pair#*|}"
	if grep -qF -- "$text" "$file"; then
		ok "'$text' occurs in ${file#"$ROOT_DIR"/}"
	else
		bad "'$text' no longer occurs in ${file#"$ROOT_DIR"/}; update the harness's anchor"
	fi
done

echo "== classifier against the real drivers =="

REAL_STAT="$(command -v stat)"
REAL_ID="$(command -v id)"
# The owner the fakes report for what the container's root created: root on a
# real rootful host. Run as root, the real stat reads the fixture's ancestors as
# 0:0 too, so report another owner then, or nothing could tell them apart.
FOREIGN=0:0
[ "$("$REAL_ID" -u)" != 0 ] || FOREIGN=1:1
FAKE="$TMP/bin"
mkdir -p "$FAKE"

# A stand-in engine. Container A is recognised by its shared script's header,
# creates the three mountpoints in the bind-mounted fixture, and prints the
# lines the real script prints on success; FAKE_A=regressed / skip play its
# ownership abort and its capability skip instead.
cat >"$FAKE/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
image | volume) exit 0 ;;
info)
	printf '%s\n' "${FAKE_DOCKER_INFO:-[name=apparmor name=seccomp,profile=builtin name=cgroupns]}"
	exit 0
	;;
run)
	shift
	fixture="" script=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-v)
			[ -n "$fixture" ] || fixture="${2%%:*}"
			shift 2
			;;
		-c)
			script="$2"
			break
			;;
		*) shift ;;
		esac
	done
	case "$script" in
	*"Container A of the durable worktree-metadata smoke stage"*)
		echo "  ok: mount capability confirmed and the persistent .worktrees volume is present (preflight)"
		case "${FAKE_A:-ok}" in
		skip)
			echo "  skip: runtime cannot perform mount --bind (no CAP_SYS_ADMIN / EPERM) - the durable-bind lifecycle cannot be exercised here"
			exit 42
			;;
		regressed)
			echo "FAIL: the created intermediate directory /workspace/x/.claude is owned by 0:0 but its pre-existing parent /workspace/x is owned by 4242:4242 - the shadow-mounts.sh mountpoint chown REGRESSED" >&2
			exit 1
			;;
		esac
		mkdir -p "$fixture/proj/bin" "$fixture/.claude/worktrees" "$fixture/.git/worktrees"
		echo "  ok: multi-component shadow created; the intermediate .claude inherited the tree owner (4242:4242)"
		echo "  ok: single-component artifact shadow created at proj/bin (ownership asserted on the host after this container exits)"
		exit 0
		;;
	*)
		echo "  ok: recycled worktree intact"
		exit 0
		;;
	esac
	;;
esac
echo "fake docker: unexpected call: $*" >&2
exit 99
EOF

# FAKE_STAT=unchowned: the three mountpoints read as root-owned, as the mutation
# leaves them on a rootful host. FAKE_STAT=sentinel: every path reads the same
# owner, the blind-assertion regression. Anything else: the real stat.
cat >"$FAKE/stat" <<EOF
#!/usr/bin/env bash
path="\${!#}"
case "\${FAKE_STAT:-real}" in
unchowned)
	case "\$path" in
	*/proj/bin | */.claude/worktrees | */.git/worktrees)
		echo $FOREIGN
		exit 0
		;;
	esac
	;;
sentinel)
	echo 7:7
	exit 0
	;;
esac
exec "$REAL_STAT" "\$@"
EOF

# The drivers print a vacuity note when the invoker is root; pin a non-root uid
# so the suite means the same thing whoever runs it.
cat >"$FAKE/id" <<EOF
#!/usr/bin/env bash
[ "\$*" = -u ] && { echo 4242; exit 0; }
exec "$REAL_ID" "\$@"
EOF
chmod +x "$FAKE/docker" "$FAKE/stat" "$FAKE/id"

IMAGE=negctl-fake:mutated

# verdict <driver> <scenario> <expected rc> <expected text> [env...]
verdict() {
	local driver="$1" scenario="$2" want_rc="$3" want_text="$4" rc=0 vrc=0
	shift 4
	local log="$TMP/$driver-$scenario.log" marker="$TMP/$driver-$scenario.marker"
	env PATH="$FAKE:$PATH" "$@" bash "$HARNESS" drive "$driver" "$IMAGE" "$log" "$marker" >/dev/null 2>&1 || rc=$?
	bash "$HARNESS" classify "$driver" "$rc" "$log" "$marker" "$IMAGE" >"$TMP/$driver-$scenario.verdict" 2>&1 || vrc=$?
	if [ "$vrc" = "$want_rc" ] && grep -qF -- "$want_text" "$TMP/$driver-$scenario.verdict"; then
		ok "$driver, $scenario: classified $vrc ($want_text)"
	else
		bad "$driver, $scenario: expected $want_rc with '$want_text', got $vrc (driver exit $rc)" "$(cat "$TMP/$driver-$scenario.verdict")" "--- driver log:" "$(cat "$log")"
	fi
}

drivers=(sh)
if command -v pwsh >/dev/null 2>&1; then
	drivers+=(ps1)
else
	printf '  skip  pwsh unavailable - the PowerShell driver half is not checked here\n'
fi

for d in "${drivers[@]}"; do
	verdict "$d" mutated 0 "assertion failed (single created component, tmpfs path)" FAKE_STAT=unchowned
	verdict "$d" chown-intact 1 "PASSED against $IMAGE" FAKE_STAT=real
	verdict "$d" blind-assertions 1 "PASSED against $IMAGE" FAKE_STAT=sentinel
	verdict "$d" container-a-abort 1 "aborted in Container A" FAKE_STAT=unchowned FAKE_A=regressed
	verdict "$d" self-skip 2 "self-skipped" FAKE_STAT=unchowned FAKE_A=skip
	verdict "$d" rootless 2 "vacuous on this host" FAKE_STAT=unchowned "FAKE_DOCKER_INFO=[name=seccomp,profile=builtin name=rootless]"
done

# Each driver is held to its own dash: the .sh driver's line with the .ps1's
# hyphen is not an anchor hit.
if [ -f "$TMP/sh-mutated.log" ]; then
	sed 's/ — the created mountpoint/ - the created mountpoint/' "$TMP/sh-mutated.log" >"$TMP/sh-hyphen.log"
	if bash "$HARNESS" classify sh 1 "$TMP/sh-hyphen.log" "$TMP/sh-mutated.marker" "$IMAGE" >"$TMP/sh-hyphen.verdict" 2>&1; then
		bad "the .sh anchor accepted the .ps1's hyphen" "$(cat "$TMP/sh-hyphen.verdict")"
	else
		ok "the .sh anchor requires the .sh driver's em dash"
	fi
fi

echo "== teeth probe =="

# teeth <scenario> <expected rc> [env...]: check_teeth against the fake engine,
# whose `run` for the probe is played by creating the directory directly.
cat >"$TMP/teeth-docker" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
	case "$a" in *:/negctl-teeth) mkdir "${a%%:*}/created" && exit 0 ;; esac
done
exit 99
EOF
chmod +x "$TMP/teeth-docker"
mkdir -p "$TMP/teethbin"
cp "$TMP/teeth-docker" "$TMP/teethbin/docker"
cat >"$TMP/teethbin/stat" <<EOF
#!/usr/bin/env bash
case "\${FAKE_TEETH:-same}:\${!#}" in
root:*/created) echo $FOREIGN; exit 0 ;;
esac
exec "$REAL_STAT" "\$@"
EOF
chmod +x "$TMP/teethbin/stat"

teeth() {
	local scenario="$1" want="$2" rc=0
	shift 2
	env PATH="$TMP/teethbin:$PATH" "$@" bash -c '. "$1"; check_teeth img' _ "$HARNESS" >"$TMP/teeth-$scenario.out" 2>&1 || rc=$?
	if [ "$rc" = "$want" ]; then
		ok "teeth probe, $scenario: exit $rc"
	else
		bad "teeth probe, $scenario: expected exit $want, got $rc" "$(cat "$TMP/teeth-$scenario.out")"
	fi
}
teeth "root-created dir lands root-owned" 0 FAKE_TEETH=root
teeth "root-created dir lands with its parent's owner" 2 FAKE_TEETH=same

echo "== jq and the image-config check =="

# run checks for jq before it touches the engine; PATH holds only what the
# harness's own preamble needs.
mkdir -p "$TMP/nojqbin"
ln -s "$(command -v dirname)" "$TMP/nojqbin/dirname"
rc=0
env PATH="$TMP/nojqbin" "$(command -v bash)" "$HARNESS" run img sh >"$TMP/nojq.out" 2>&1 || rc=$?
if [ "$rc" = 1 ] && grep -qF 'NEGATIVE CONTROL FAILED: jq is not installed' "$TMP/nojq.out"; then
	ok "run refuses without jq"
else
	bad "run did not refuse without jq (exit $rc)" "$(cat "$TMP/nojq.out")"
fi

# verify_derived against a fake engine whose two images differ only by the
# mutation, with a jq that is missing (127) or prints nothing: the config check
# must fail, not compare two empty strings equal.
mkdir -p "$TMP/cfgbin"
cat >"$TMP/cfgbin/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
image) echo '{"User":"node"}' ;;
run)
	echo '755 0:0'
	case "\$*" in
	*" base -c "*) cat "$SHADOW_MOUNTS" ;;
	*) cat "$TMP/sm.sh" ;;
	esac
	;;
esac
EOF
chmod +x "$TMP/cfgbin/docker"
cfg_case() {
	local name="$1" jq_body="$2" want="$3" rc=0
	printf '#!/usr/bin/env bash\n%s\n' "$jq_body" >"$TMP/cfgbin/jq"
	chmod +x "$TMP/cfgbin/jq"
	mkdir -p "$TMP/cfg-$name"
	env PATH="$TMP/cfgbin:$PATH" bash -c '. "$1"; verify_derived base tag "$2"' _ "$HARNESS" "$TMP/cfg-$name" >"$TMP/cfg-$name.out" 2>&1 || rc=$?
	if [ "$rc" = "$want" ]; then
		ok "verify_derived, $name: exit $rc"
	else
		bad "verify_derived, $name: expected exit $want, got $rc" "$(cat "$TMP/cfg-$name.out")"
	fi
}
cfg_case "jq works" 'exec cat' 0
cfg_case "jq missing" 'exit 127' 1
cfg_case "jq prints nothing" 'exit 0' 1

echo "== .ps1 wrapper exit status =="

if command -v pwsh >/dev/null 2>&1; then
	bash -c '. "$1"; write_ps1_wrapper "$2"' _ "$HARNESS" "$TMP/wrapper.ps1"
	# wrap_case <name> <driver body> <expected rc> [expected output line]
	wrap_case() {
		local name="$1" body="$2" want="$3" line="${4:-}" rc=0
		printf 'param([string]$Image)\n%s\n' "$body" >"$TMP/drv-$name.ps1"
		pwsh -NoProfile -File "$TMP/wrapper.ps1" -Driver "$TMP/drv-$name.ps1" -Image img >"$TMP/wrap-$name.out" 2>&1 || rc=$?
		if [ "$rc" = "$want" ] && { [ -z "$line" ] || grep -qxF -- "$line" "$TMP/wrap-$name.out"; }; then
			ok "wrapper, $name: exit $rc"
		else
			bad "wrapper, $name: expected exit $want, got $rc" "$(cat "$TMP/wrap-$name.out")"
		fi
	}
	wrap_case "driver exits 3" 'exit 3' 3
	wrap_case "driver ends normally after a failing native command" '& false' 0
	wrap_case "driver ends normally" 'Write-Host done' 0
	wrap_case "driver throws" 'throw "FAIL: one line"' 1 "FAIL: one line"
else
	printf '  skip  pwsh unavailable - the .ps1 wrapper is not checked here\n'
fi

echo
if [ "$failures" -eq 0 ]; then
	echo "ownership negative-control tests: all $checks checks passed"
	exit 0
fi
echo "ownership negative-control tests: $failures of $checks checks FAILED" >&2
exit 1
