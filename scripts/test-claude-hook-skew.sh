#!/usr/bin/env bash
# Unit tests for docker/shared/entrypoint-claude-hook.sh, in two groups:
#
#   1. the build-skew shim (tests 1-5), and
#   2. the statusline seed's digest-marker gating (tests 6+, task 002e).
#
# Group 1 covers the two INDEPENDENT handshake markers (task 021 fix-up) that decide
# which detached convergence duties the hook must cover for primary Claude:
#   POWBOX_PLUGIN_BOOTSTRAP=core     -> core owns the dev-skills plugin bootstrap
#   POWBOX_CODEX_SYNC_BOOTSTRAP=core -> core owns the Codex shared-skill sync
# The hook launches whichever duty's marker is ABSENT. Reusing a single marker was
# the bug: the current-main base core sets the PLUGIN marker but never chained the
# Codex sync, so a shared marker made an agent-only rebuild skip the sync entirely.
#
# We drive the REAL hook with POWBOX_BOOT_BIN pointed at stub bootstrap scripts (so
# no root-writable /usr/local/bin is needed) and assert which stubs the detached
# sequence invoked: each stub appends its tag to a shared sentinel file.
#
# Group 2 drives the same hook against a fake AGENT_SEED_DIR/AGENT_CONFIG_DIR pair
# and asserts the three transitions the seed must distinguish: untouched -> refreshed,
# customized -> preserved, and unmarked-pre-existing -> preserved (the upgrade path
# for every claude-config volume that predates the marker).
#
# Runs against the repo copy of the hook — no image build needed. Requires bash;
# setsid is optional (the hook falls back to a plain background detach without it).
#
# Usage: scripts/test-claude-hook-skew.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../docker/shared/entrypoint-claude-hook.sh"

if [ ! -f "$HOOK" ]; then
	echo "FATAL: hook not found at $HOOK" >&2
	exit 1
fi

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf 'ok   - %s\n' "$1"
}
no() {
	fail=$((fail + 1))
	printf 'FAIL - %s\n' "$1"
}

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

# make_bootbin <dir> <with-sync> — a stub boot-script dir whose seed-claude-plugins.sh
# / sync-codex-skills.sh append their tag to $TEST_SENTINEL, plus a stub `claude` so
# `command -v claude` succeeds. Omit the sync stub (with-sync=no) to exercise the
# sync-script-presence gate.
make_bootbin() {
	local dir="$1" with_sync="$2"
	mkdir -p "$dir"
	cat >"$dir/seed-claude-plugins.sh" <<'EOF'
#!/usr/bin/env bash
printf 'plugin\n' >>"$TEST_SENTINEL"
EOF
	if [ "$with_sync" = yes ]; then
		cat >"$dir/sync-codex-skills.sh" <<'EOF'
#!/usr/bin/env bash
printf 'sync\n' >>"$TEST_SENTINEL"
EOF
	fi
	cat >"$dir/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "$dir"/*
}

BOOT_BIN="$WORK_ROOT/bootbin"
make_bootbin "$BOOT_BIN" yes
BOOT_BIN_NOSYNC="$WORK_ROOT/bootbin-nosync"
make_bootbin "$BOOT_BIN_NOSYNC" no

# run_hook <sentinel> <boot-bin> [env assignments...] — invoke the real hook with a
# fresh temp config/seed dir (no agent.md.tmpl, so the epoch-gated seeding is skipped
# and only the build-skew block runs). PATH is prefixed with the stub bin so
# `command -v claude` resolves to the stub. Extra args are VAR=VAL env overrides.
run_hook() {
	local sentinel="$1" bootbin="$2"
	shift 2
	local cfg seed
	cfg="$(mktemp -d "$WORK_ROOT/cfg.XXXXXX")"
	seed="$(mktemp -d "$WORK_ROOT/seed.XXXXXX")"
	env -i \
		HOME="$WORK_ROOT" \
		PATH="$bootbin:/usr/bin:/bin" \
		AGENT_CONFIG_DIR="$cfg" \
		AGENT_SEED_DIR="$seed" \
		AGENT_INSTRUCTION_FILE="CLAUDE.md" \
		POWBOX_BOOT_BIN="$bootbin" \
		TEST_SENTINEL="$sentinel" \
		"$@" \
		bash "$HOOK"
}

# wait_for_content <sentinel> <expected> — poll up to ~5s until the sentinel holds
# exactly <expected> (the detached sequence appends sequentially, so the final state
# is deterministic). Returns nonzero on timeout.
wait_for_content() {
	local sentinel="$1" expected="$2" actual
	for _ in $(seq 1 50); do
		actual="$(cat "$sentinel" 2>/dev/null || true)"
		[ "$actual" = "$expected" ] && return 0
		sleep 0.1
	done
	return 1
}

# assert_stays_empty <sentinel> — the block was expected NOT to spawn anything; give
# any (erroneous) detached spawn ample time to appear, then assert nothing did.
assert_stays_empty() {
	local sentinel="$1"
	sleep 1.2
	[ ! -s "$sentinel" ]
}

# ================================================================================
# Test 1: NEW core (both markers=core) — hook covers NEITHER duty (no double-run).
# ================================================================================
S="$WORK_ROOT/s1"
: >"$S"
run_hook "$S" "$BOOT_BIN" PRIMARY_AGENT=claude POWBOX_PLUGIN_BOOTSTRAP=core POWBOX_CODEX_SYNC_BOOTSTRAP=core
if assert_stays_empty "$S"; then
	ok "both markers=core: hook runs neither duty (new core, no double-run)"
else
	no "both markers=core: hook runs neither duty (new core, no double-run)"
fi

# ================================================================================
# Test 2: CURRENT-main base skew (plugin marker=core, sync marker ABSENT) — the key
#         fix: the hook must still run the Codex sync, and ONLY the sync.
# ================================================================================
S="$WORK_ROOT/s2"
: >"$S"
run_hook "$S" "$BOOT_BIN" PRIMARY_AGENT=claude POWBOX_PLUGIN_BOOTSTRAP=core
if wait_for_content "$S" "sync"; then
	ok "plugin=core, sync marker absent: hook runs ONLY the Codex sync"
else
	no "plugin=core, sync marker absent: hook runs ONLY the Codex sync (got: $(cat "$S" 2>/dev/null))"
fi

# ================================================================================
# Test 3: ancient base (NEITHER marker set) — hook runs BOTH, plugin first so the
#         sync then reads the just-refreshed clone.
# ================================================================================
S="$WORK_ROOT/s3"
: >"$S"
run_hook "$S" "$BOOT_BIN" PRIMARY_AGENT=claude
if wait_for_content "$S" "$(printf 'plugin\nsync')"; then
	ok "neither marker: hook runs plugin then Codex sync, in order"
else
	no "neither marker: hook runs plugin then Codex sync, in order (got: $(cat "$S" 2>/dev/null))"
fi

# ================================================================================
# Test 4: Codex-PRIMARY (neither marker) — the documented residual gap: the hook is
#         gated on PRIMARY_AGENT=claude, so it runs nothing on a Codex-primary launch.
# ================================================================================
S="$WORK_ROOT/s4"
: >"$S"
run_hook "$S" "$BOOT_BIN" PRIMARY_AGENT=codex
if assert_stays_empty "$S"; then
	ok "PRIMARY_AGENT=codex: hook runs nothing (documented residual gap)"
else
	no "PRIMARY_AGENT=codex: hook runs nothing (documented residual gap)"
fi

# ================================================================================
# Test 5: sync-script-presence gate — neither marker set, but sync-codex-skills.sh
#         is NOT baked (older agent layer): the plugin still runs, the sync does not.
# ================================================================================
S="$WORK_ROOT/s5"
: >"$S"
run_hook "$S" "$BOOT_BIN_NOSYNC" PRIMARY_AGENT=claude
if wait_for_content "$S" "plugin"; then
	ok "sync script absent: hook runs the plugin only, never the missing sync"
else
	no "sync script absent: hook runs the plugin only, never the missing sync (got: $(cat "$S" 2>/dev/null))"
fi

# ================================================================================
# Statusline seeding (task 002e). The baked statusline is opinionated and users
# edit it, so a newer image may overwrite only a copy still byte-identical to what
# powbox seeded — proven by the sha256 in the .statusline-command.sh.powbox-seeded
# sidecar, since a running container has no copy of the previous image's file.
# ================================================================================

# sl_seed <dir> <epoch> <body> — a fake AGENT_SEED_DIR holding just the baked
# statusline plus build metadata. No agent.md.tmpl, so the instruction/settings
# block stays out of the way; the independence tests add one deliberately.
sl_seed() {
	local dir="$1" epoch="$2" body="$3"
	mkdir -p "$dir"
	printf '%s\n' "$body" >"$dir/statusline-command.sh"
	printf '%s\n' "$epoch" >"$dir/build-epoch"
	printf 'c0ffee1\n' >"$dir/build-commit"
}

# sl_new_cfg — print the path of a fresh empty config dir. mktemp, not a counter:
# this runs inside `$(…)`, so a counter would increment in the subshell only and
# every case would silently share one dir.
sl_new_cfg() {
	mktemp -d "$WORK_ROOT/slcfg.XXXXXX"
}

# sl_run <cfg> <seed> — drive the REAL hook against an explicit config/seed pair
# with BOTH convergence handshakes claimed by core, so the detached build-skew
# block never spawns and only the seeding path runs. stderr lands in <cfg>.stderr.
sl_run() {
	local cfg="$1" seed="$2"
	env -i \
		HOME="$WORK_ROOT" \
		PATH="/usr/bin:/bin" \
		AGENT_CONFIG_DIR="$cfg" \
		AGENT_SEED_DIR="$seed" \
		AGENT_INSTRUCTION_FILE="CLAUDE.md" \
		AGENT_NAME="Claude" \
		AGENT_AUTONOMY_FLAG="--yolo" \
		AGENT_PEERS="none" \
		PRIMARY_AGENT=claude \
		POWBOX_PLUGIN_BOOTSTRAP=core \
		POWBOX_CODEX_SYNC_BOOTSTRAP=core \
		bash "$HOOK" 2>"$cfg.stderr"
}

# sl_key <marker> <key> — read one key from a key=value marker (by key, never by
# line position: the .powbox-seeded parsing contract).
sl_key() {
	sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}

sl_sha() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# sl_tmpl <seed-dir> <version> — write the instruction template. Its ${AGENT_NAME}
# placeholder must reach envsubst literally, hence the single quotes.
# shellcheck disable=SC2016
sl_tmpl() {
	printf 'instruction %s for ${AGENT_NAME}\n' "$2" >"$1/agent.md.tmpl"
}

SL_SEED="$WORK_ROOT/slseed"

# --- Test 6: absent statusline -> seeded AND marked ----------------------------
CFG="$(sl_new_cfg)"
sl_seed "$SL_SEED" 100 'v1'
sl_run "$CFG" "$SL_SEED"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
if [ "$(cat "$DST" 2>/dev/null)" = "v1" ] &&
	[ "$(sl_key "$MK" epoch)" = "100" ] &&
	[ "$(sl_key "$MK" commit)" = "c0ffee1" ] &&
	[ "$(sl_key "$MK" sha256)" = "$(sl_sha "$DST")" ] &&
	[ "$(sl_key "$MK" source)" = "Roubtec/powbox#docker/claude/agent-container/statusline-command.sh" ]; then
	ok "statusline absent: seeded and marked with epoch/commit/sha256/source"
else
	no "statusline absent: seeded and marked with epoch/commit/sha256/source"
fi

# --- Test 7: untouched + newer image epoch -> REFRESHED, marker rewritten -------
sl_seed "$SL_SEED" 200 'v2'
sl_run "$CFG" "$SL_SEED"
if [ "$(cat "$DST" 2>/dev/null)" = "v2" ] &&
	[ "$(sl_key "$MK" epoch)" = "200" ] &&
	[ "$(sl_key "$MK" sha256)" = "$(sl_sha "$DST")" ]; then
	ok "untouched statusline, newer epoch: refreshed and re-marked"
else
	no "untouched statusline, newer epoch: refreshed and re-marked (got: $(cat "$DST" 2>/dev/null))"
fi

# --- Test 8: marker present, image epoch NOT newer -> left alone ----------------
# Same epoch and then an OLDER image; neither may re-copy.
SL_SEED_SAME="$WORK_ROOT/slseed-same"
sl_seed "$SL_SEED_SAME" 200 'v3-same-epoch'
sl_run "$CFG" "$SL_SEED_SAME"
SL_SEED_OLD="$WORK_ROOT/slseed-old"
sl_seed "$SL_SEED_OLD" 150 'v3-older-epoch'
sl_run "$CFG" "$SL_SEED_OLD"
if [ "$(cat "$DST" 2>/dev/null)" = "v2" ] && [ "$(sl_key "$MK" epoch)" = "200" ]; then
	ok "marked statusline, epoch not newer: left alone (same and older image)"
else
	no "marked statusline, epoch not newer: left alone (got: $(cat "$DST" 2>/dev/null))"
fi

# --- Test 9: customized -> PRESERVED, with a note exactly once per image --------
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
sl_seed "$SL_SEED" 100 'v1'
sl_run "$CFG" "$SL_SEED"
SEEDED_SHA="$(sl_key "$MK" sha256)"
printf 'v1 with my own tweak\n' >"$DST" # one byte is enough; this is a whole line
sl_seed "$SL_SEED" 200 'v2'
sl_run "$CFG" "$SL_SEED"
if [ "$(cat "$DST" 2>/dev/null)" = "v1 with my own tweak" ] &&
	[ "$(sl_key "$MK" epoch)" = "100" ] &&
	[ "$(sl_key "$MK" sha256)" = "$SEEDED_SHA" ] &&
	grep -q 'differs from the copy powbox seeded' "$CFG.stderr"; then
	ok "customized statusline, newer epoch: preserved, marker untouched, one note"
else
	no "customized statusline, newer epoch: preserved, marker untouched, one note (got: $(cat "$DST" 2>/dev/null))"
fi

# Restarting on the SAME image must not nag again...
sl_run "$CFG" "$SL_SEED"
if [ ! -s "$CFG.stderr" ] && [ "$(sl_key "$MK" notified_epoch)" = "200" ]; then
	ok "customized statusline, same image again: silent (no nag per start)"
else
	no "customized statusline, same image again: silent (got: $(cat "$CFG.stderr" 2>/dev/null))"
fi

# ...but a NEWER image is a new offer, so it says so once more.
sl_seed "$SL_SEED" 300 'v3'
sl_run "$CFG" "$SL_SEED"
if [ "$(cat "$DST" 2>/dev/null)" = "v1 with my own tweak" ] &&
	[ "$(sl_key "$MK" notified_epoch)" = "300" ] &&
	grep -q 'differs from the copy powbox seeded' "$CFG.stderr"; then
	ok "customized statusline, next image: preserved and noted once more"
else
	no "customized statusline, next image: preserved and noted once more"
fi

# --- Test 10: UNMARKED pre-existing file -> preserved (today's upgrade path) ----
# Every claude-config volume in existence right now is in this state: powbox
# cannot prove the file is unmodified, so it must never be overwritten.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
printf 'seeded by an older powbox, possibly edited\n' >"$DST"
sl_seed "$SL_SEED" 400 'v4'
sl_run "$CFG" "$SL_SEED"
if [ "$(cat "$DST" 2>/dev/null)" = "seeded by an older powbox, possibly edited" ] &&
	[ ! -e "$MK" ] && [ ! -s "$CFG.stderr" ]; then
	ok "unmarked pre-existing statusline: preserved, still unmarked, silent"
else
	no "unmarked pre-existing statusline: preserved, still unmarked, silent (got: $(cat "$DST" 2>/dev/null))"
fi

# --- Test 11: deleting the file re-seeds it AND adopts the marker ---------------
# The documented escape hatch, now self-healing: the next rebuild refreshes it.
rm -f "$DST"
sl_run "$CFG" "$SL_SEED"
if [ "$(cat "$DST" 2>/dev/null)" = "v4" ] &&
	[ "$(sl_key "$MK" epoch)" = "400" ] &&
	[ "$(sl_key "$MK" sha256)" = "$(sl_sha "$DST")" ]; then
	ok "deleted statusline: re-seeded and now marked (adopts the mechanism)"
else
	no "deleted statusline: re-seeded and now marked (got: $(cat "$DST" 2>/dev/null))"
fi

# --- Test 12: a held-back statusline does not hold back the instruction file ----
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
SL_SEED_FULL="$WORK_ROOT/slseed-full"
sl_seed "$SL_SEED_FULL" 100 'v1'
sl_tmpl "$SL_SEED_FULL" v1
printf '{"statusLine":{"type":"command","command":"x"}}\n' >"$SL_SEED_FULL/statusline-settings.json"
sl_run "$CFG" "$SL_SEED_FULL"
printf 'my own statusline\n' >"$DST"
sl_seed "$SL_SEED_FULL" 200 'v2'
sl_tmpl "$SL_SEED_FULL" v2
sl_run "$CFG" "$SL_SEED_FULL"
if [ "$(cat "$DST" 2>/dev/null)" = "my own statusline" ] &&
	[ "$(cat "$CFG/CLAUDE.md" 2>/dev/null)" = "instruction v2 for Claude" ] &&
	[ "$(cat "$CFG/.instruction-epoch" 2>/dev/null)" = "200" ] &&
	[ "$(jq -r '.statusLine.command' "$CFG/settings.json" 2>/dev/null)" = "x" ]; then
	ok "customized statusline does not block the instruction file or settings.json"
else
	no "customized statusline does not block the instruction file or settings.json"
fi

# --- Test 13: ...and a skipped instruction render does not block the statusline -
# A volume stamped by a NEWER image than the one now running skips the instruction
# block entirely (VOLUME_EPOCH > IMAGE_EPOCH); the statusline still refreshes on
# its own marker's epoch.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
sl_seed "$SL_SEED_FULL" 100 'v1'
sl_tmpl "$SL_SEED_FULL" v1
sl_run "$CFG" "$SL_SEED_FULL"
printf '999\n' >"$CFG/.instruction-epoch"
sl_seed "$SL_SEED_FULL" 200 'v2'
sl_tmpl "$SL_SEED_FULL" v2
sl_run "$CFG" "$SL_SEED_FULL"
if [ "$(cat "$DST" 2>/dev/null)" = "v2" ] &&
	[ "$(sl_key "$MK" epoch)" = "200" ] &&
	[ "$(cat "$CFG/CLAUDE.md" 2>/dev/null)" = "instruction v1 for Claude" ] &&
	[ "$(cat "$CFG/.instruction-epoch" 2>/dev/null)" = "999" ]; then
	ok "skipped instruction render does not block the statusline refresh"
else
	no "skipped instruction render does not block the statusline refresh"
fi

echo
echo "claude-hook build-skew + statusline-seed tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
