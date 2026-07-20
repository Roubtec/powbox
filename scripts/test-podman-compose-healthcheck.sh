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
#      never-succeeding /bin/false negative-control service.
#   2. The probe INSPECTS what Compose actually wired (`.Config.Healthcheck.Test[0]`)
#      and classifies it, so an incorrect CMD->CMD-SHELL translation is DETECTED and
#      surfaced as a loud KNOWN-XFAIL rather than passing silently on a non-empty
#      check; it FAILS if the exec form is dropped or mangled beyond the known wrap.
#   3. The probe drives the check explicitly (`podman healthcheck run`, since no
#      systemd timer fires here) and REQUIRES "hc" to reach "healthy" while the
#      never-succeeding negative control MUST NOT — proving the healthy assertion is
#      non-vacuous and genuinely fails a service stuck at starting/unhealthy.
#   4. Cleanup tears down the exact Compose project AND removes only the temp
#      fixture dir, on success or failure (trap + `docker compose … down` + a
#      label-scoped rm + `rm -rf` of the mktemp dir).
#   5. The Bash and PowerShell probes stay in parity on the exec-form line, the
#      translation detection, and the healthy/negative assertions (hand-mirrored).
#
# Needs bash + yq (python-yq, jq-backed) on PATH — both ship in the agent image.
# Usage: scripts/test-podman-compose-healthcheck.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SH="$SCRIPT_DIR/smoke-test-podman.sh"
PS1="$SCRIPT_DIR/smoke-test-podman.ps1"

for f in "$SH" "$PS1"; do
	[ -f "$f" ] || {
		echo "FATAL: expected probe not found at $f" >&2
		exit 1
	}
done
command -v yq >/dev/null 2>&1 || {
	echo "FATAL: yq not found on PATH (needed to parse the embedded fixture)" >&2
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
assert_grep "$SH" 'negative control broke' "sh: FAILS if the never-succeeding check ever reports healthy (assertion is non-vacuous)"
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
assert_grep "$PS1" 'negative control broke' "ps1: FAILS if the never-succeeding check reports healthy"
assert_grep "$PS1" 'rm -rf "$compose_dir"' "ps1: cleanup removes only the temp fixture dir"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
