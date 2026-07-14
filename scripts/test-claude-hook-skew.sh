#!/usr/bin/env bash
# Unit tests for the build-skew shim in docker/shared/entrypoint-claude-hook.sh —
# specifically the two INDEPENDENT handshake markers (task 021 fix-up) that decide
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

echo
echo "claude-hook build-skew tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
