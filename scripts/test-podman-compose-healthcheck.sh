#!/usr/bin/env bash
# The assert_grep patterns in this file are LITERAL fixed strings for `grep -F` —
# the `$health` / `$compose_dir` etc. inside single quotes are the exact source
# text we search for in the probe scripts and must NOT expand here (file-wide, so
# it must sit above the first command).
# shellcheck disable=SC2016
#
# Hermetic guard for the Compose exec-form health-check probe embedded in
# scripts/smoke-test-podman.{sh,ps1} (task 025).
#
# The live half of that probe needs a built image + /dev/net/tun and so cannot run
# here (see AGENTS.md "Validating Changes"). This test instead locks the probe's
# load-bearing INVARIANTS, which CAN regress in a plain edit and would silently
# neuter the regression guard:
#
#   1. The embedded Compose fixture is well-formed YAML whose health check is an
#      EXEC-form CMD array (test[0] == "CMD"), NOT a CMD-SHELL string — the exec
#      form is the entire point (the Kalm2 distroless case), and a stray rewrite to
#      CMD-SHELL would stop testing it while still looking green. It also carries a
#      never-succeeding /bin/false negative-control service and a shell-less
#      "distroless" service (its own heredoc) that actively reproduces the break.
#   2. The probe INSPECTS what Compose actually wired (`.Config.Healthcheck.Test[0]`)
#      and classifies it, so an incorrect CMD->CMD-SHELL translation is DETECTED and
#      surfaced as a loud KNOWN-XFAIL rather than passing silently on a non-empty
#      check; it FAILS if the exec form is dropped or mangled beyond the known wrap.
#   3. The probe drives the check explicitly (`podman healthcheck run`, since no
#      systemd timer fires here) and REQUIRES "hc" to reach "healthy" while the
#      never-succeeding negative control MUST be driven to "unhealthy" (not merely
#      "not healthy") — requiring the terminal-failure state proves /bin/false was
#      actually wired and executed, so a never-wired check left at starting cannot
#      pass the negative control vacuously.
#   4. Cleanup tears down the exact Compose project AND removes only the temp
#      fixture dir, on success or failure (trap + `docker compose … down` + a
#      label-scoped rm + `rm -rf` of the mktemp dir). The umbrella smoke likewise
#      removes the Stage-3 skip marker even when the child smoke FAILS (Bash EXIT
#      trap / PowerShell finally), not with a trailing rm that `set -e` skips.
#   5. The Bash and PowerShell probes stay in parity on the exec-form line, the
#      translation detection, and the healthy/negative assertions (hand-mirrored).
#   6. The distroless (shell-less) XFAIL reproduction (task 025 fix-up): the probe
#      pre-pulls a genuinely shell-less image and appends a third service with the
#      SAME exec-form shape. The XFAIL is discriminated by the EXACT translated FORM +
#      a SPECIFIC failure REASON, NOT a never-healthy outcome (a never-exiting binary
#      is "never healthy" whether wrapped or preserved, so the outcome cannot tell
#      broken from fixed): the KNOWN-XFAIL (GREEN) branch requires the wired
#      `.Config.Healthcheck.Test` to be EXACTLY the shell-wrap of the original —
#      `["CMD-SHELL","/bin/sh -c /pause"]` — AND that the wrap's /bin/sh is genuinely
#      absent, proven with `podman exec` failing for a specific not-found reason (not
#      merely a message mentioning /bin/sh), since the health-check Log Output is empty
#      on podman 5.x. It SELF-CLEARS to a loud NOTE only when the translated form is
#      EXACTLY the preserved exec form `["CMD","/pause"]` (the true provider-fixed
#      signal). ANY OTHER translated array (mangled command, wrong binary, extra tokens)
#      matches neither and HARD-FAILS as inconclusive — it is never silently greened. On
#      a pull failure it SKIPs just that scenario (visible sentinel) — surfaced in the
#      umbrella banner via a marker the parent smoke wires. Bash/PowerShell parity is
#      locked for all of the above.
#
# Needs bash + a behaviorally compatible yq on PATH. The agent image's python-yq
# works, as does mikefarah yq v4.45.1; the interface is verified up front by a
# capability probe (see yq_capable), so an incompatible implementation fails fast
# with one clear FATAL instead of confusing per-assertion failures.
# Usage: scripts/test-podman-compose-healthcheck.sh [--check-yq]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SH="$SCRIPT_DIR/smoke-test-podman.sh"
PS1="$SCRIPT_DIR/smoke-test-podman.ps1"
UMBRELLA_SH="$ROOT_DIR/commands/smoke-test.sh"
UMBRELLA_PS1="$ROOT_DIR/commands/smoke-test.ps1"

# yq_capable — behavioral capability probe for the `yq -r <filter>` operations
# this test relies on. It exercises the exact feature set used below — raw (-r)
# scalar output, path + array-index filters, `| length`,
# and a non-zero exit on malformed YAML (the well-formedness assertion depends on
# it) — so any yq that answers correctly can run the test, while an incompatible
# implementation on PATH (e.g. mikefarah's Go yq v3, whose CLI is
# `yq r <file> <path>`) is rejected up front instead of producing confusing
# YAML/fixture failures further down. Silent: callers print their own message.
yq_capable() {
	command -v yq >/dev/null 2>&1 || return 1
	local out
	out="$(printf 'probe:\n  test: ["CMD", "ok"]\n' | yq -r '.probe.test[0]' 2>/dev/null)" || return 1
	[ "$out" = "CMD" ] || return 1
	out="$(printf 'probe:\n  test: ["CMD", "ok"]\n' | yq -r '.probe.test | length' 2>/dev/null)" || return 1
	[ "$out" = "2" ] || return 1
	if printf '{"unclosed\n' | yq -r '.' >/dev/null 2>&1; then return 1; fi
	return 0
}

# --check-yq: run ONLY the yq presence/capability probe and exit 0 (capable) or 1.
# This standalone mode lets callers test whether PATH provides the yq behavior
# needed by the full suite without running its fixture assertions.
if [ "${1:-}" = "--check-yq" ]; then
	yq_capable || exit 1
	exit 0
fi

for f in "$SH" "$PS1" "$UMBRELLA_SH" "$UMBRELLA_PS1"; do
	[ -f "$f" ] || {
		echo "FATAL: expected probe not found at $f" >&2
		exit 1
	}
done
command -v yq >/dev/null 2>&1 || {
	echo "FATAL: yq not found on PATH (needed to parse the embedded fixture)" >&2
	exit 1
}
yq_capable || {
	echo "FATAL: the 'yq' on PATH does not provide the 'yq -r <filter>' behavior this test needs — e.g. mikefarah's Go yq v3 ('yq r <file> <path>') is incompatible" >&2
	exit 1
}

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}
ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
}

# extract_yaml — echo the lines of the embedded `<<"SMOKE_COMPOSE_YAML" … YAML`
# heredoc body from the Bash probe (the delimiter is the shared contract both
# scripts embed). Full-file numbering is irrelevant; we only need the body.
extract_yaml() {
	awk '
		/<<"?SMOKE_COMPOSE_YAML"?/ { f = 1; next }
		f && $0 ~ /^[[:space:]]*SMOKE_COMPOSE_YAML[[:space:]]*$/ { f = 0 }
		f { print }
	' "$SH"
}

# extract_distroless_yaml — echo the body of the conditionally-appended
# `<<"SMOKE_COMPOSE_DISTROLESS" … SMOKE_COMPOSE_DISTROLESS` heredoc (the shell-less
# XFAIL service). It is a service-map fragment (indented under `services:`), so callers
# prepend a `services:` root before handing it to yq.
extract_distroless_yaml() {
	awk '
		/<<"?SMOKE_COMPOSE_DISTROLESS"?/ { f = 1; next }
		f && $0 ~ /^[[:space:]]*SMOKE_COMPOSE_DISTROLESS[[:space:]]*$/ { f = 0 }
		f { print }
	' "$SH"
}

echo "Test: the embedded Compose fixture parses and uses an exec-form health check"
YAML="$(extract_yaml)"
if [ -z "$YAML" ]; then
	ko "could not extract the SMOKE_COMPOSE_YAML heredoc body from $SH"
else
	# yq exits non-zero on malformed YAML — proves the fixture is well-formed.
	if test0="$(printf '%s\n' "$YAML" | yq -r '.services.hc.healthcheck.test[0]' 2>/dev/null)"; then
		ok "fixture is well-formed YAML and healthcheck.test parses"
	else
		ko "fixture did not parse as YAML with .services.hc.healthcheck.test"
		test0=""
	fi
	if [ "$test0" = "CMD" ]; then
		ok "health check is exec form (test[0] == CMD), not CMD-SHELL"
	else
		ko "health check test[0] is '$test0', expected exec-form 'CMD' (a CMD-SHELL rewrite would stop testing the exec path)"
	fi
	len="$(printf '%s\n' "$YAML" | yq -r '.services.hc.healthcheck.test | length' 2>/dev/null || echo 0)"
	if [ "${len:-0}" -ge 2 ] 2>/dev/null; then
		ok "exec array carries a command element (length $len)"
	else
		ko "exec array has no command element (length ${len:-unknown})"
	fi
	cmd="$(printf '%s\n' "$YAML" | yq -r '.services.hc.healthcheck.test[1]' 2>/dev/null || echo '')"
	if [ -n "$cmd" ] && [ "$cmd" != null ]; then
		ok "health-check binary is set (test[1] == '$cmd')"
	else
		ko "health-check binary (test[1]) is empty/null"
	fi
	img="$(printf '%s\n' "$YAML" | yq -r '.services.hc.image' 2>/dev/null || echo '')"
	case "$img" in
	*alpine*) ok "fixture reuses the alpine image already pulled by the smoke ($img)" ;;
	*) ko "fixture image is '$img', expected an alpine image reused from the earlier checks" ;;
	esac
	sp="$(printf '%s\n' "$YAML" | yq -r '.services.hc.healthcheck.start_period' 2>/dev/null || echo null)"
	if [ -n "$sp" ] && [ "$sp" != null ]; then
		ok "health check sets a start_period ($sp)"
	else
		ko "health check has no start_period"
	fi
	# The negative-control "bad" service is what gives the healthy assertion teeth: a
	# never-succeeding exec-form check that must never flip to healthy.
	bad0="$(printf '%s\n' "$YAML" | yq -r '.services.bad.healthcheck.test[0]' 2>/dev/null || echo '')"
	if [ "$bad0" = "CMD" ]; then
		ok "negative-control service 'bad' uses an exec-form (CMD) health check"
	else
		ko "negative-control service 'bad' health check test[0] is '$bad0', expected exec-form 'CMD'"
	fi
	bad1="$(printf '%s\n' "$YAML" | yq -r '.services.bad.healthcheck.test[1]' 2>/dev/null || echo '')"
	case "$bad1" in
	*/bin/false) ok "negative-control command never succeeds (test[1] == '$bad1')" ;;
	*) ko "negative-control command is '$bad1', expected a never-succeeding /bin/false" ;;
	esac
fi

# assert_grep <file> <fixed-string> <msg>
assert_grep() {
	if grep -qF -- "$2" "$1"; then
		ok "$3"
	else
		ko "$3 (missing '$2' in $(basename "$1"))"
	fi
}

echo "Test: the Bash probe drives the check explicitly and requires 'healthy'"
assert_grep "$SH" 'podman healthcheck run' "sh: drives the check with 'podman healthcheck run' (no systemd timer in-sandbox)"
assert_grep "$SH" 'never reached healthy' "sh: fails when the state does not reach healthy"
assert_grep "$SH" '[ "$hc_health" = healthy ] ||' "sh: asserts the hc health state is exactly 'healthy' (not merely running)"
assert_grep "$SH" 'dropped the exec-form health check entirely' "sh: fails when compose drops the health check entirely"

echo "Test: the Bash probe DETECTS the exec-form (mis)translation, not just non-emptiness"
assert_grep "$SH" '{{index .Config.Healthcheck.Test 0}}' "sh: inspects the wired health-check kind (Test[0]), so CMD vs CMD-SHELL is observable"
assert_grep "$SH" 'KNOWN-XFAIL' "sh: surfaces the podman-compose CMD->CMD-SHELL rewrite as a loud detected xfail (not silent prose)"
assert_grep "$SH" 'beyond the known CMD-SHELL wrap' "sh: FAILS if the exec form is mangled beyond the known wrap (intended binary lost)"
assert_grep "$SH" 'case "$hc_kind" in' "sh: classifies the translation (CMD-SHELL / CMD / dropped / unrecognized)"

echo "Test: the Bash probe proves a never-healthy service fails (negative control)"
assert_grep "$SH" 'test: ["CMD", "/bin/false"]' "sh: fixture includes a never-succeeding /bin/false negative-control service"
assert_grep "$SH" '[ "$bad_health" = unhealthy ] ||' "sh: REQUIRES the negative control to be driven to unhealthy (not merely 'not healthy')"
assert_grep "$SH" 'did not become unhealthy after driven failures' "sh: FAILS if the never-succeeding check does not reach unhealthy (proves it was wired + executed, non-vacuous)"
assert_grep "$SH" 'so Podman never fires the' "sh: documents in-code WHY the periodic-timer path is unavailable here (no systemd)"

echo "Test: the no-tun skip message names the Compose health-check scenario"
assert_grep "$SH" 'Compose exec-form health-check checks: /dev/net/tun' "sh: no-tun skip lists the Compose health-check scenario as skipped"

echo "Test: the Bash probe cleans up the project and only the temp fixture dir"
assert_grep "$SH" 'compose_dir=$(mktemp -d)' "sh: fixture lives in a fresh mktemp -d dir"
assert_grep "$SH" 'chmod 700 "$compose_dir"' "sh: fixture dir gets restrictive (700) perms"
assert_grep "$SH" 'down -v >/dev/null 2>&1' "sh: cleanup tears down the exact compose project"
assert_grep "$SH" 'rm -rf "$compose_dir"' "sh: cleanup removes only the temp fixture dir"
assert_grep "$SH" 'trap cleanup EXIT' "sh: cleanup runs on EXIT (success or failure)"

echo "Test: the project name is invocation-unique"
assert_grep "$SH" 'compose_proj="smokehc$(od -An -N6 -tx1 /dev/urandom' "sh: project name is randomized per invocation"

echo "Test: the PowerShell probe mirrors the exec-form check, translation detection, and negative control"
assert_grep "$PS1" 'test: ["CMD", "/bin/true"]' "ps1: embeds the same exec-form health check"
assert_grep "$PS1" 'test: ["CMD", "/bin/false"]' "ps1: embeds the same never-succeeding negative-control check"
assert_grep "$PS1" 'podman healthcheck run' "ps1: drives the check with 'podman healthcheck run'"
assert_grep "$PS1" '[ "$hc_health" = healthy ]' "ps1: asserts the hc health state reaches 'healthy'"
assert_grep "$PS1" '{{index .Config.Healthcheck.Test 0}}' "ps1: inspects the wired health-check kind (translation detection)"
assert_grep "$PS1" 'KNOWN-XFAIL' "ps1: surfaces the CMD->CMD-SHELL rewrite as a detected xfail"
assert_grep "$PS1" '[ "$bad_health" = unhealthy ] ||' "ps1: REQUIRES the negative control to be driven to unhealthy"
assert_grep "$PS1" 'rm -rf "$compose_dir"' "ps1: cleanup removes only the temp fixture dir"

echo "Test: the distroless (shell-less) XFAIL service is present and uses the exec form"
DL_YAML="$(printf 'services:\n%s\n' "$(extract_distroless_yaml)")"
if [ -z "$(extract_distroless_yaml)" ]; then
	ko "could not extract the SMOKE_COMPOSE_DISTROLESS heredoc body from $SH (the shell-less XFAIL service is missing)"
else
	dl0="$(printf '%s\n' "$DL_YAML" | yq -r '.services.distroless.healthcheck.test[0]' 2>/dev/null || echo '')"
	if [ "$dl0" = "CMD" ]; then
		ok "distroless service health check is exec form (test[0] == CMD)"
	else
		ko "distroless service health check test[0] is '$dl0', expected exec-form 'CMD'"
	fi
	dl1="$(printf '%s\n' "$DL_YAML" | yq -r '.services.distroless.healthcheck.test[1]' 2>/dev/null || echo '')"
	if [ -n "$dl1" ] && [ "$dl1" != null ]; then
		ok "distroless health-check binary is set (test[1] == '$dl1')"
	else
		ko "distroless health-check binary (test[1]) is empty/null"
	fi
	dlimg="$(printf '%s\n' "$DL_YAML" | yq -r '.services.distroless.image' 2>/dev/null || echo '')"
	case "$dlimg" in
	*pause*) ok "distroless service uses a shell-less stock image ($dlimg)" ;;
	*) ko "distroless service image is '$dlimg', expected a shell-less image (registry.k8s.io/pause)" ;;
	esac
	# The heredoc image literal must match the $distroless_image the probe pre-pulls,
	# or the pull check and the fixture would drift (pull one image, run another).
	if grep -qF "distroless_image=\"$dlimg\"" "$SH"; then
		ok "the pre-pull \$distroless_image matches the fixture image literal ($dlimg)"
	else
		ko "the pre-pull \$distroless_image does not match the fixture image literal '$dlimg' (they must stay in sync)"
	fi
fi

echo "Test: the Bash probe pre-pulls the shell-less image and SKIPs (never a false pass) on failure"
assert_grep "$SH" 'podman pull -q "$distroless_image"' "sh: pre-pulls the shell-less image before building the fixture"
assert_grep "$SH" 'SKIP [DISTROLESS-XFAIL]' "sh: emits a visible SKIP sentinel when the shell-less image cannot be pulled"
assert_grep "$SH" 'if [ "$distroless_ok" = true ]; then' "sh: the shell-less service is appended/asserted only when the image pulled (pull-failure skip)"

echo "Test: the Bash probe classifies the distroless break by EXACT translated FORM + specific failure REASON, not a never-healthy outcome"
assert_grep "$SH" 'KNOWN-XFAIL (distroless)' "sh: surfaces the distroless break as a loud KNOWN-XFAIL"
assert_grep "$SH" 'dl_expected_wrap="[\"CMD-SHELL\",\"/bin/sh -c /pause\"]"' "sh: XFAIL keys on the EXACT shell-wrap of the original /pause exec command (not generic CMD-SHELL)"
assert_grep "$SH" 'dl_expected_exec="[\"CMD\",\"/pause\"]"' "sh: NOTE self-clear keys on the EXACT preserved CMD exec form (not generic CMD)"
assert_grep "$SH" '[ "$dl_test" = "$dl_expected_wrap" ] && dl_wrapped=true' "sh: dl_wrapped requires an exact match to the expected shell-wrap (a mangled array does not match)"
assert_grep "$SH" '[ "$dl_test" = "$dl_expected_exec" ] && dl_preserved=true' "sh: dl_preserved requires an exact match to the expected preserved exec form"
assert_grep "$SH" 'podman exec "$dl_cid" /bin/sh -c ":"' "sh: isolates the CAUSE by reproducing the wrap's /bin/sh with podman exec (health Log Output is empty on podman 5.x)"
assert_grep "$SH" '*"no such file"* | *"No such file"* | *"not found"*) dl_shellmissing=true' "sh: cause match requires a SPECIFIC not-found reason, not any message merely mentioning /bin/sh"
assert_grep "$SH" '[ "$dl_wrapped" = true ] && [ "$dl_shellmissing" = true ]' "sh: XFAIL holds only when EXACT-shell-WRAPPED AND the wrap's /bin/sh is proven missing (not keyed on never-healthy)"
assert_grep "$SH" 'if [ "$dl_preserved" = true ]; then' "sh: SELF-CLEARS on the EXACT preserved CMD exec form (the true provider-fixed signal, not a health outcome)"
assert_grep "$SH" 'NOTE (distroless XFAIL now obsolete)' "sh: emits a loud NOTE when the exec form is preserved (provider fixed)"
assert_grep "$SH" 'took an UNEXPECTED form' "sh: any OTHER translated array (mangled/wrong-binary/extra-token) HARD-FAILS as inconclusive (not silently XFAIL/NOTE)"

echo "Test: the distroless SKIP is surfaced in the umbrella summary via a marker"
assert_grep "$SH" 'SKIP \[DISTROLESS-XFAIL\]' "sh: the outer probe greps the SKIP sentinel to write the parent marker"
assert_grep "$SH" 'POWBOX_SMOKE_SKIP_MARKER' "sh: writes the distroless skip reason to the parent-provided marker"
assert_grep "$UMBRELLA_SH" 'POWBOX_SMOKE_SKIP_MARKER="$podman_marker"' "umbrella sh: Stage 3 hands the podman probe a skip marker"
assert_grep "$UMBRELLA_SH" 'elif [ -s "$podman_marker" ]; then' "umbrella sh: Stage 3 records the distroless SKIP in the banner"

echo "Test: the umbrella removes the Stage-3 skip marker even when the child smoke FAILS"
assert_grep "$UMBRELLA_SH" "trap 'rm -f \"\$podman_marker\"' EXIT" "umbrella sh: an EXIT trap removes the marker even if the child fails under set -e"
assert_grep "$UMBRELLA_PS1" '$podmanSkip = Get-Content -LiteralPath $podmanMarker.FullName -Raw -ErrorAction SilentlyContinue' "umbrella ps1: reads the skip inside the finally"
assert_grep "$UMBRELLA_PS1" 'Remove-Item -LiteralPath $podmanMarker.FullName' "umbrella ps1: removes the marker file (now inside the finally so a child failure still cleans up)"

echo "Test: the PowerShell probe mirrors the distroless XFAIL, self-clear, skip, and marker"
assert_grep "$PS1" 'image: registry.k8s.io/pause' "ps1: embeds the same shell-less distroless service"
assert_grep "$PS1" 'test: ["CMD", "/pause"]' "ps1: distroless service uses the same exec-form check shape"
assert_grep "$PS1" 'podman pull -q "$distroless_image"' "ps1: pre-pulls the shell-less image"
assert_grep "$PS1" 'SKIP [DISTROLESS-XFAIL]' "ps1: emits the same visible SKIP sentinel on a pull failure"
assert_grep "$PS1" 'KNOWN-XFAIL (distroless)' "ps1: surfaces the distroless break as a KNOWN-XFAIL"
assert_grep "$PS1" 'NOTE (distroless XFAIL now obsolete)' "ps1: mirrors the self-clearing NOTE branch (preserved CMD exec form)"
assert_grep "$PS1" 'podman exec "$dl_cid" /bin/sh -c ":"' "ps1: mirrors the podman-exec /bin/sh cause-isolation probe"
assert_grep "$PS1" 'dl_expected_wrap="[\"CMD-SHELL\",\"/bin/sh -c /pause\"]"' "ps1: mirrors the EXACT expected shell-wrap literal"
assert_grep "$PS1" '[ "$dl_test" = "$dl_expected_exec" ] && dl_preserved=true' "ps1: mirrors the exact preserved-exec-form match"
assert_grep "$PS1" '*"no such file"* | *"No such file"* | *"not found"*) dl_shellmissing=true' "ps1: mirrors the SPECIFIC not-found cause match (not any /bin/sh mention)"
assert_grep "$PS1" '[ "$dl_wrapped" = true ] && [ "$dl_shellmissing" = true ]' "ps1: mirrors the exact-wrap + shell-missing XFAIL condition (not never-healthy)"
assert_grep "$PS1" 'if [ "$dl_preserved" = true ]; then' "ps1: mirrors the self-clear on the EXACT preserved CMD exec form"
assert_grep "$PS1" 'took an UNEXPECTED form' "ps1: mirrors the hard-fail on any other translated array (inconclusive)"
assert_grep "$PS1" 'Set-Content -LiteralPath $env:POWBOX_SMOKE_SKIP_MARKER' "ps1: the outer probe writes the parent marker when the SKIP sentinel is seen"
assert_grep "$UMBRELLA_PS1" '$env:POWBOX_SMOKE_SKIP_MARKER = $podmanMarker.FullName' "umbrella ps1: Stage 3 hands the podman probe a skip marker"
assert_grep "$UMBRELLA_PS1" 'elseif ($podmanSkip) {' "umbrella ps1: Stage 3 records the distroless SKIP in the banner"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
