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
#      CMD-SHELL would stop testing it while still looking green.
#   2. The probe drives the check explicitly (`podman healthcheck run`) and REQUIRES
#      the state to reach "healthy" — a "merely running" pass, or dropping the
#      healthy assertion, is the failure mode the task calls out.
#   3. Cleanup tears down the exact Compose project AND removes only the temp
#      fixture dir, on success or failure (trap + `docker compose … down` + a
#      label-scoped rm + `rm -rf` of the mktemp dir).
#   4. The Bash and PowerShell probes stay in parity on the exec-form line and the
#      healthy assertion (the two scripts are hand-mirrored).
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
assert_grep "$SH" '"$health" = healthy' "sh: asserts the health state is exactly 'healthy' (not merely running)"
assert_grep "$SH" 'Healthcheck is empty' "sh: fails when compose drops the health check entirely"

echo "Test: the Bash probe cleans up the project and only the temp fixture dir"
assert_grep "$SH" 'compose_dir=$(mktemp -d)' "sh: fixture lives in a fresh mktemp -d dir"
assert_grep "$SH" 'chmod 700 "$compose_dir"' "sh: fixture dir gets restrictive (700) perms"
assert_grep "$SH" 'down -v >/dev/null 2>&1' "sh: cleanup tears down the exact compose project"
assert_grep "$SH" 'rm -rf "$compose_dir"' "sh: cleanup removes only the temp fixture dir"
assert_grep "$SH" 'trap cleanup EXIT' "sh: cleanup runs on EXIT (success or failure)"

echo "Test: the project name is invocation-unique"
assert_grep "$SH" 'compose_proj="smokehc$(od -An -N6 -tx1 /dev/urandom' "sh: project name is randomized per invocation"

echo "Test: the PowerShell probe mirrors the exec-form check and healthy assertion"
assert_grep "$PS1" 'test: ["CMD", "/bin/true"]' "ps1: embeds the same exec-form health check"
assert_grep "$PS1" 'podman healthcheck run' "ps1: drives the check with 'podman healthcheck run'"
assert_grep "$PS1" '[ "$health" = healthy ]' "ps1: asserts the health state reaches 'healthy'"
assert_grep "$PS1" 'rm -rf "$compose_dir"' "ps1: cleanup removes only the temp fixture dir"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
