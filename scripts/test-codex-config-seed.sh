#!/usr/bin/env bash
# Unit tests for the Codex config-seeding helpers in
# docker/shared/entrypoint-codex-hook.sh.
#
# Focus: the multi_agent_v2 concurrency default (Task 023). Covers the new
# ensure_table_scalar_setting no-clobber writer and the config_v2_seed_blocked
# guard, plus the composed "guarded seed" the hook performs:
#   - a cold / statusline-only config gains [features] multi_agent_v2 = true;
#   - a config that already sets multi_agent_v2 (true OR false) is left untouched
#     (no-clobber);
#   - a config that already carries an [agents] block (table, subtable, or inline
#     agents = { ... }) is left untouched and NOT given the mutually-exclusive
#     multi_agent_v2 key Codex would reject at load;
#   - re-running the seed is a byte-for-byte no-op with a stable mtime.
#
# The helpers are sourced straight from the hook: everything above the hook's
# "sourced?" guard is pure function definitions, so sourcing yields the helpers
# without running the seeding body. No image build needed.
#
# Usage: scripts/test-codex-config-seed.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../docker/shared/entrypoint-codex-hook.sh"

if [ ! -f "$HOOK" ]; then
	echo "FATAL: entrypoint-codex-hook.sh not found at $HOOK" >&2
	exit 1
fi

# shellcheck source=docker/shared/entrypoint-codex-hook.sh
. "$HOOK"

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

# new_config <name> <<<contents — write a scratch config.toml and echo its path.
new_config() {
	local f="$WORK_ROOT/$1.toml"
	cat >"$f"
	printf '%s' "$f"
}

# seed_v2 <file> — the exact guarded seed the hook performs.
seed_v2() {
	local f="$1"
	if ! config_v2_seed_blocked "$f"; then
		ensure_table_scalar_setting "$f" "features" "multi_agent_v2" "true"
	fi
}

# A realistic already-seeded statusline/title config, the state config.toml is in
# by the time the v2 seed runs in the hook.
STATUSLINE_CONFIG='[tui]
status_line = [
  "model-with-reasoning",
  "current-dir",
]

terminal_title = [
  "current-dir",
  "git-branch",
]'

# assert_blocked <file> <msg> — config_v2_seed_blocked returns success (skip).
assert_blocked() {
	if config_v2_seed_blocked "$1"; then
		ok "$2"
	else
		ko "$2 (expected guard to BLOCK the seed)"
	fi
}

# assert_not_blocked <file> <msg> — config_v2_seed_blocked returns failure (seed).
assert_not_blocked() {
	if config_v2_seed_blocked "$1"; then
		ko "$2 (expected guard to ALLOW the seed)"
	else
		ok "$2"
	fi
}

# assert_grep <file> <ERE> <msg>
assert_grep() {
	if grep -qE "$2" "$1"; then
		ok "$3"
	else
		ko "$3 (expected /$2/ in $1)"
	fi
}

# assert_no_grep <file> <ERE> <msg>
assert_no_grep() {
	if grep -qE "$2" "$1"; then
		ko "$3 (did not expect /$2/ in $1)"
	else
		ok "$3"
	fi
}

# assert_count <file> <ERE> <n> <msg>
assert_count() {
	local n
	n="$(grep -cE "$2" "$1" || true)"
	if [ "$n" = "$3" ]; then
		ok "$4"
	else
		ko "$4 (expected $3 line(s) matching /$2/, got $n)"
	fi
}

echo "Test: guard ALLOWS the seed on a cold (non-existent) config"
assert_not_blocked "$WORK_ROOT/cold.toml" "missing file is not blocked (fresh volume seeds)"

echo "Test: guard ALLOWS the seed on a statusline-only config"
ws="$(printf '%s\n' "$STATUSLINE_CONFIG" | new_config statusline-only)"
assert_not_blocked "$ws" "statusline/title config has no v2 or [agents] -> seed"

echo "Test: guard BLOCKS when multi_agent_v2 is already set (no-clobber)"
ws="$(printf '[features]\nmulti_agent_v2 = true\n' | new_config v2-true)"
assert_blocked "$ws" "existing multi_agent_v2 = true blocks (no-clobber)"
ws="$(printf '[features]\nmulti_agent_v2 = false\n' | new_config v2-false)"
assert_blocked "$ws" "existing multi_agent_v2 = false blocks (respects opt-out)"
ws="$(printf 'features = { multi_agent_v2 = true }\n' | new_config v2-inline)"
assert_blocked "$ws" "inline features = { multi_agent_v2 = true } blocks"

echo "Test: guard BLOCKS a quoted multi_agent_v2 key (no-clobber on opt-out)"
ws="$(printf '[features]\n"multi_agent_v2" = false\n' | new_config v2-quoted)"
assert_blocked "$ws" 'quoted "multi_agent_v2" = false blocks (no-clobber)'

echo "Test: guard BLOCKS when an [agents] block exists (mutual exclusion)"
ws="$(printf '[agents]\nmax_threads = 9\nmax_depth = 1\n' | new_config agents-table)"
assert_blocked "$ws" "[agents] table blocks the seed"
ws="$(printf '[agents.limits]\nmax_threads = 9\n' | new_config agents-subtable)"
assert_blocked "$ws" "[agents.limits] subtable blocks the seed"
ws="$(printf 'agents = { max_threads = 9 }\n' | new_config agents-inline)"
assert_blocked "$ws" "inline agents = { ... } blocks the seed"

echo "Test: guard BLOCKS valid-TOML [agents] spellings that once evaded it"
ws="$(printf '[ agents ]\nmax_threads = 9\n' | new_config agents-ws-header)"
assert_blocked "$ws" "[ agents ] (whitespace in header) blocks the seed"
ws="$(printf '["agents"]\nmax_threads = 9\n' | new_config agents-quoted-header)"
assert_blocked "$ws" '["agents"] (quoted header) blocks the seed'
ws="$(printf 'agents.max_threads = 9\n' | new_config agents-dotted)"
assert_blocked "$ws" "top-level dotted agents.max_threads = 9 blocks the seed"
ws="$(printf '"agents" = { max_threads = 9 }\n' | new_config agents-quoted-inline)"
assert_blocked "$ws" 'inline "agents" = { ... } (quoted) blocks the seed'

echo "Test: guard BLOCKS an inline features table with no multi_agent_v2 key"
ws="$(printf 'features = { other = true }\n' | new_config features-inline-other)"
# Appending a [features] table here would define `features` twice (Codex
# rejects). Fail safe: skip the seed rather than author the duplicate table.
assert_blocked "$ws" "inline features = { other = true } blocks (no safe extend)"

echo "Test: [features]/[agents] not confused with lookalike tables"
ws="$(printf '[features_other]\nmulti_agent_v2 = 0\n' | new_config not-agents)"
# multi_agent_v2 appears verbatim, so the no-clobber grep legitimately blocks;
# this asserts the guard keys off the literal name, not a false table match.
# Intentionally conservative (peer #4): an unrelated table carrying the literal
# key still blocks. This only ever SKIPS the seed, never corrupts a config.
assert_blocked "$ws" "verbatim multi_agent_v2 anywhere blocks (no-clobber)"
ws="$(printf '[agentsx]\nfoo = 1\n' | new_config agentsx)"
assert_not_blocked "$ws" "[agentsx] does NOT match the [agents] guard"
ws="$(printf 'agentsx = 1\n' | new_config agentsx-key)"
assert_not_blocked "$ws" "agentsx = 1 does NOT match the [agents] guard"
ws="$(printf '[features_x]\nfoo = 1\n' | new_config features-x)"
assert_not_blocked "$ws" "[features_x] does NOT match the inline-features guard"

echo "Test: seed writes [features] multi_agent_v2 = true onto a statusline config"
ws="$(printf '%s\n' "$STATUSLINE_CONFIG" | new_config seed-fresh)"
seed_v2 "$ws"
assert_grep "$ws" '^\[features\]$' "[features] table header written"
assert_grep "$ws" '^multi_agent_v2 = true$' "multi_agent_v2 = true written"
assert_grep "$ws" '^\[tui\]$' "existing [tui] table preserved"
assert_grep "$ws" '^terminal_title = \[' "existing terminal_title preserved"
# suppress_unstable_features_warning is intentionally NOT seeded (warning stays on).
assert_no_grep "$ws" 'suppress_unstable_features_warning' "unstable-feature warning left ON"

echo "Test: re-running the seed is a byte-for-byte no-op with a stable mtime"
cp "$ws" "$ws.snap"
before="$(stat -c '%Y.%N' "$ws" 2>/dev/null || stat -f '%m' "$ws")"
seed_v2 "$ws"
after="$(stat -c '%Y.%N' "$ws" 2>/dev/null || stat -f '%m' "$ws")"
if cmp -s "$ws" "$ws.snap"; then
	ok "second seed leaves bytes unchanged"
else
	ko "second seed rewrote the file"
fi
if [ "$before" = "$after" ]; then
	ok "second seed leaves mtime unchanged (no rewrite)"
else
	ko "second seed changed mtime (file was rewritten)"
fi

echo "Test: an existing [agents] config is left completely untouched"
ws="$(printf '[agents]\nmax_threads = 9\nmax_depth = 1\n' | new_config agents-untouched)"
cp "$ws" "$ws.snap"
seed_v2 "$ws"
if cmp -s "$ws" "$ws.snap"; then
	ok "[agents] config unchanged (no exclusion conflict authored)"
else
	ko "[agents] config was modified"
fi
assert_no_grep "$ws" 'multi_agent_v2' "no multi_agent_v2 added next to [agents]"

echo "Test: ensure_table_scalar_setting inserts under an existing [features] table"
ws="$(printf '[features]\nsome_other_flag = true\n' | new_config features-existing)"
ensure_table_scalar_setting "$ws" "features" "multi_agent_v2" "true"
assert_count "$ws" '^\[features\]$' 1 "no duplicate [features] table created"
assert_grep "$ws" '^some_other_flag = true$' "sibling key under [features] preserved"
assert_grep "$ws" '^multi_agent_v2 = true$' "multi_agent_v2 added under existing [features]"

echo "Test: ensure_table_scalar_setting is no-clobber on the key within the table"
ws="$(printf '[features]\nmulti_agent_v2 = false\n' | new_config scalar-noclobber)"
ensure_table_scalar_setting "$ws" "features" "multi_agent_v2" "true"
assert_grep "$ws" '^multi_agent_v2 = false$' "existing scalar value not overwritten"
assert_no_grep "$ws" '^multi_agent_v2 = true$' "no second multi_agent_v2 appended"

echo "Test: ensure_table_scalar_setting inserts under a DECORATED [features] header"
# A trailing comment and surrounding whitespace on the header must still be
# recognised, otherwise a second [features] table is appended (TOML rejects it).
ws="$(printf '  [features]   # tuning\nsome_other_flag = true\n' | new_config features-decorated)"
ensure_table_scalar_setting "$ws" "features" "multi_agent_v2" "true"
assert_count "$ws" '^[[:space:]]*\[features\]' 1 "no duplicate [features] table (decorated header)"
assert_grep "$ws" '^multi_agent_v2 = true$' "multi_agent_v2 inserted under decorated [features]"
assert_grep "$ws" '^some_other_flag = true$' "sibling key under decorated [features] preserved"

echo "Test: ensure_table_scalar_setting is no-clobber under a DECORATED header"
ws="$(printf '[features]  # tuning\nmulti_agent_v2 = false\n' | new_config scalar-decorated-noclobber)"
cp "$ws" "$ws.snap"
before="$(stat -c '%Y.%N' "$ws" 2>/dev/null || stat -f '%m' "$ws")"
ensure_table_scalar_setting "$ws" "features" "multi_agent_v2" "true"
after="$(stat -c '%Y.%N' "$ws" 2>/dev/null || stat -f '%m' "$ws")"
if cmp -s "$ws" "$ws.snap"; then
	ok "existing key under decorated header left byte-for-byte unchanged"
else
	ko "decorated-header no-clobber rewrote the file"
fi
if [ "$before" = "$after" ]; then
	ok "decorated-header no-clobber leaves mtime stable"
else
	ko "decorated-header no-clobber changed mtime"
fi

echo "Test: ensure_table_array_setting is a mtime-stable no-op when the key exists"
# Regression for peer #5: the status_line seeder runs every start; once the key
# is present it must NOT rewrite config.toml (stable mtime across starts).
ws="$(printf '%s\n' "$STATUSLINE_CONFIG" | new_config array-noop)"
cp "$ws" "$ws.snap"
before="$(stat -c '%Y.%N' "$ws" 2>/dev/null || stat -f '%m' "$ws")"
ensure_table_array_setting "$ws" "tui" "status_line" '  "current-dir",'
after="$(stat -c '%Y.%N' "$ws" 2>/dev/null || stat -f '%m' "$ws")"
if cmp -s "$ws" "$ws.snap"; then
	ok "existing status_line left byte-for-byte unchanged"
else
	ko "ensure_table_array_setting rewrote config with status_line already present"
fi
if [ "$before" = "$after" ]; then
	ok "ensure_table_array_setting leaves mtime stable (no rewrite)"
else
	ko "ensure_table_array_setting changed mtime (file was rewritten)"
fi

echo "Test: ensure_table_array_setting still inserts under an existing bare [tui]"
ws="$(printf '[tui]\nsome_flag = true\n' | new_config array-insert)"
ensure_table_array_setting "$ws" "tui" "status_line" '  "current-dir",'
assert_count "$ws" '^\[tui\]$' 1 "no duplicate [tui] table created"
assert_grep "$ws" '^status_line = \[' "status_line inserted under existing [tui]"
assert_grep "$ws" '^some_flag = true$' "sibling key under [tui] preserved"

echo "Test: ensure_table_scalar_setting skips an inline table it cannot extend"
ws="$(printf 'features = { other = true }\n' | new_config scalar-inline-skip)"
cp "$ws" "$ws.snap"
ensure_table_scalar_setting "$ws" "features" "multi_agent_v2" "true"
if cmp -s "$ws" "$ws.snap"; then
	ok "inline features table left untouched (no duplicate [features] authored)"
else
	ko "ensure_table_scalar_setting modified an inline features table"
fi
assert_no_grep "$ws" '^\[features\]' "no [features] header appended next to inline table"

echo
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
