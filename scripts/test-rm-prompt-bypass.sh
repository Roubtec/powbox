#!/usr/bin/env bash
# Unit tests for the launch-time rm-prompt waiver, in two groups:
#
#   1. entrypoint-agent.sh exports CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS=1
#      into the environment the CMD is exec'd with on the Claude primary-agent
#      path only, and leaves a value already in the launch environment alone.
#   2. the settings.json that entrypoint-claude-hook.sh seeds into a fresh config
#      dir, and every seed JSON fragment it merges from, carry nothing that makes
#      that variable inert. A third set of cases proves the check itself has teeth.
#
# Claude Code reads the variable only from its launch environment, so the export
# cannot be seeded into the shared claude-config volume; and it is silently inert
# when settings carry any PermissionRequest hook, an ask/deny rule on Bash, Edit or
# Read, a PreToolUse hook answering "ask", or either
# block*OutsideWorkingDirectories setting. Whether the running CLI actually lifts
# the prompts (its startup line, a background subagent's rm) needs a logged-in
# session in a rebuilt image and is not covered here.
#
# Group 1 runs a copy of the entrypoint whose /usr/local/bin/ references point at a
# stub dir holding only a fake entrypoint-core.sh that records the environment it
# was exec'd with; no setup hook is present there, so nothing is seeded.
#
# Usage: scripts/test-rm-prompt-bypass.sh
#   ENTRYPOINT_AGENT=<path>  test that entrypoint instead of ../docker/shared/entrypoint-agent.sh
#   CLAUDE_HOOK=<path>       test that hook instead of ../docker/shared/entrypoint-claude-hook.sh
#   CLAUDE_SEED_DIR=<dir>    seed from that dir instead of one assembled from
#                            ../docker/claude/agent-container/ and the core template
# commands/smoke-test.sh Stage 0k points all three at the BAKED copies in the image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
ENTRYPOINT="${ENTRYPOINT_AGENT:-$REPO_DIR/docker/shared/entrypoint-agent.sh}"
HOOK="${CLAUDE_HOOK:-$REPO_DIR/docker/shared/entrypoint-claude-hook.sh}"
VAR=CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS

for f in "$ENTRYPOINT" "$HOOK"; do
	if [ ! -f "$f" ]; then
		echo "FATAL: not found: $f" >&2
		exit 1
	fi
done
command -v jq >/dev/null 2>&1 || {
	echo "FATAL: jq is required" >&2
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

WORK_ROOT="$(mktemp -d)"
WORK_ROOT="$(realpath "$WORK_ROOT")"
trap 'rm -rf "$WORK_ROOT"' EXIT

# The stub dir is spliced into the entrypoint's shell text, including one
# unquoted `exec` word, so the path must need no quoting at all.
case "$WORK_ROOT" in
*[!A-Za-z0-9/._-]*)
	echo "FATAL: the temporary directory '$WORK_ROOT' contains characters this suite cannot splice into shell text unquoted; set TMPDIR to a plain path." >&2
	exit 1
	;;
esac

# --- Group 1: the export ------------------------------------------------------
echo "Group 1: $VAR export (entrypoint: $ENTRYPOINT)"

STUB="$WORK_ROOT/stub-bin"
mkdir -p "$STUB" "$WORK_ROOT/claude-config" "$WORK_ROOT/codex-config"
cat >"$STUB/entrypoint-core.sh" <<'EOF'
#!/usr/bin/env bash
{
	if [ "${CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS+set}" = set ]; then
		printf 'var=set:%s\n' "$CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS"
	else
		printf 'var=unset\n'
	fi
	printf 'primary=%s\n' "${PRIMARY_AGENT:-}"
	printf 'argv=%s\n' "$*"
} >"$RM_BYPASS_TEST_OUT"
EOF
chmod +x "$STUB/entrypoint-core.sh"

SUT="$WORK_ROOT/entrypoint-agent.sh"
relocated=0
: >"$SUT"
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
	*/usr/local/bin/*)
		line="${line//\/usr\/local\/bin\//"$STUB/"}"
		relocated=$((relocated + 1))
		;;
	esac
	printf '%s\n' "$line" >>"$SUT"
done <"$ENTRYPOINT"
# Three references: the two setup hooks and the core it execs.
if [ "$relocated" -ne 3 ] || grep -q '/usr/local/bin/' "$SUT"; then
	echo "FATAL: expected to relocate exactly three /usr/local/bin/ references in $ENTRYPOINT, relocated $relocated; refusing to run an entrypoint that could reach the real hooks." >&2
	exit 1
fi

# run_entrypoint <label> <expected var line> <env assignment>...
run_entrypoint() {
	local label="$1" want="$2" out
	shift 2
	out="$WORK_ROOT/out.$pass.$fail"
	rm -f "$out"
	if ! env -u "$VAR" -u PRIMARY_AGENT \
		CLAUDE_CONFIG_DIR="$WORK_ROOT/claude-config" \
		CODEX_CONFIG_DIR="$WORK_ROOT/codex-config" \
		RM_BYPASS_TEST_OUT="$out" \
		"$@" bash "$SUT" claude --dangerously-skip-permissions </dev/null >/dev/null 2>&1; then
		ko "$label: the entrypoint exited non-zero"
		return
	fi
	if [ ! -f "$out" ]; then
		ko "$label: the stub core was never exec'd"
		return
	fi
	if ! grep -qx 'argv=claude --dangerously-skip-permissions' "$out"; then
		ko "$label: the CMD did not reach the core unchanged ($(grep '^argv=' "$out"))"
		return
	fi
	if grep -qxF "var=$want" "$out"; then
		ok "$label: var=$want"
	else
		ko "$label: expected var=$want, got $(grep '^var=' "$out")"
	fi
}

run_entrypoint "PRIMARY_AGENT unset (defaults to claude)" "set:1"
run_entrypoint "PRIMARY_AGENT=claude" "set:1" PRIMARY_AGENT=claude
run_entrypoint "PRIMARY_AGENT unknown (falls back to claude)" "set:1" PRIMARY_AGENT=bogus
run_entrypoint "PRIMARY_AGENT=codex" "unset" PRIMARY_AGENT=codex
run_entrypoint "claude, launch env already sets a value" "set:custom" PRIMARY_AGENT=claude "$VAR=custom"
run_entrypoint "claude, launch env sets it empty" "set:" PRIMARY_AGENT=claude "$VAR="
run_entrypoint "codex, launch env value passes through untouched" "set:1" PRIMARY_AGENT=codex "$VAR=1"

# --- Group 2: the seeded settings ---------------------------------------------
# Prints one line per setting that would make the variable inert. PreToolUse is
# flagged outright: a hook that answers "ask" makes it inert, and what a hook
# answers cannot be read from settings, so a seeded one needs a deliberate look.
# shellcheck disable=SC2016  # $k is a jq variable
INERT_FILTER='
def inert_rule: type == "string" and (split("(")[0] | . == "Bash" or . == "Edit" or . == "Read");
((.hooks? // {}) | objects | keys[] | select(. == "PermissionRequest" or . == "PreToolUse") | "hooks." + .),
((.permissions? // {}) | objects | to_entries[] | select(.key == "ask" or .key == "deny") | .key as $k
	| (.value | arrays | .[]) | select(inert_rule) | "permissions." + $k + ": " + .),
(paths | select(.[-1] == "blockReadsOutsideWorkingDirectories" or .[-1] == "blockWritesOutsideWorkingDirectories")
	| map(tostring) | join("."))
'

# check_clean <label> <file>: the file is valid JSON with no inert-making setting.
check_clean() {
	local label="$1" file="$2" found
	if ! found="$(jq -r "$INERT_FILTER" "$file" 2>&1)"; then
		ko "$label: not valid JSON ($found)"
	elif [ -n "$found" ]; then
		ko "$label: makes $VAR inert: $(printf '%s' "$found" | tr '\n' ';')"
	else
		ok "$label"
	fi
}

echo "Group 2: seeded settings (hook: $HOOK)"

if [ -n "${CLAUDE_SEED_DIR:-}" ]; then
	SEED="$CLAUDE_SEED_DIR"
else
	SEED="$WORK_ROOT/seed"
	mkdir -p "$SEED"
	cp -R "$REPO_DIR/docker/claude/agent-container/." "$SEED/"
	cp "$REPO_DIR/docker/shared/container-agent.md.tmpl" "$SEED/agent.md.tmpl"
	echo 1 >"$SEED/build-epoch"
fi
if [ ! -f "$SEED/agent.md.tmpl" ]; then
	echo "FATAL: $SEED has no agent.md.tmpl, so the hook would seed no settings at all" >&2
	exit 1
fi

shopt -s nullglob
fragments=("$SEED"/*.json)
shopt -u nullglob
if [ "${#fragments[@]}" -eq 0 ]; then
	ko "seed dir $SEED holds no JSON fragments to check"
fi
for fragment in "${fragments[@]}"; do
	check_clean "seed fragment ${fragment##*/}" "$fragment"
done

CFG="$WORK_ROOT/fresh-config"
mkdir -p "$CFG" "$WORK_ROOT/no-boot-bin"
if AGENT_CONFIG_DIR="$CFG" AGENT_SEED_DIR="$SEED" AGENT_INSTRUCTION_FILE=CLAUDE.md \
	PRIMARY_AGENT=claude POWBOX_PLUGIN_BOOTSTRAP=core POWBOX_CODEX_SYNC_BOOTSTRAP=core \
	POWBOX_BOOT_BIN="$WORK_ROOT/no-boot-bin" bash "$HOOK" </dev/null >/dev/null 2>&1; then
	if [ -f "$CFG/settings.json" ]; then
		check_clean "settings.json seeded into a fresh config dir" "$CFG/settings.json"
	else
		ko "the hook seeded no settings.json into a fresh config dir"
	fi
else
	ko "the hook exited non-zero seeding a fresh config dir"
fi

# --- Group 3: the check has teeth -------------------------------------------
echo "Group 3: the inert-setting check"

# expect_flagged <label> <json>
expect_flagged() {
	local file="$WORK_ROOT/probe.json" found
	printf '%s\n' "$2" >"$file"
	found="$(jq -r "$INERT_FILTER" "$file")"
	if [ -n "$found" ]; then
		ok "flags $1"
	else
		ko "does not flag $1"
	fi
}
# expect_clean <label> <json>
expect_clean() {
	local file="$WORK_ROOT/probe.json" found
	printf '%s\n' "$2" >"$file"
	found="$(jq -r "$INERT_FILTER" "$file")"
	if [ -z "$found" ]; then
		ok "accepts $1"
	else
		ko "wrongly flags $1: $found"
	fi
}

expect_flagged "a PermissionRequest hook" '{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"true"}]}]}}'
expect_flagged "a PreToolUse hook" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"true"}]}]}}'
expect_flagged "an ask rule on Bash" '{"permissions":{"ask":["Bash(rm:*)"]}}'
expect_flagged "a bare deny rule on Bash" '{"permissions":{"deny":["Bash"]}}'
expect_flagged "a deny rule on Edit" '{"permissions":{"deny":["Edit(/etc/**)"]}}'
expect_flagged "an ask rule on Read" '{"permissions":{"ask":["Read(~/.ssh/**)"]}}'
expect_flagged "blockReadsOutsideWorkingDirectories" '{"permissions":{"blockReadsOutsideWorkingDirectories":true}}'
expect_flagged "blockWritesOutsideWorkingDirectories at the top level" '{"blockWritesOutsideWorkingDirectories":false}'
expect_clean "an allow rule on Bash" '{"permissions":{"allow":["Bash(rm:*)","Read","Edit"]}}'
expect_clean "ask/deny rules on other tools" '{"permissions":{"ask":["WebFetch"],"deny":["mcp__github__merge_pull_request"]}}'
expect_clean "other hook events" '{"hooks":{"PostToolUse":[],"Stop":[]},"statusLine":{"type":"command","command":"true"}}'
expect_clean "an empty settings object" '{}'

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
