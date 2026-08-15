#!/usr/bin/env bash
# Unit tests for docker/shared/entrypoint-claude-hook.sh, in three groups:
#
#   1. the build-skew shim (tests 1-5),
#   2. the statusline seed's digest-marker gating (tests 6-15, task 002e), and
#   3. that same seed's ERROR paths (tests 16-28), which must degrade rather
#      than abort: the hook runs under `set -euo pipefail` and entrypoint-core.sh
#      invokes it UNGUARDED, so a non-zero exit here ends container startup.
#
# Test numbers are assertion numbers: every numbered block makes exactly one
# ok/no/sk call, so passed+failed+skipped in the summary line equals the highest
# label.
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
# Group 3 breaks the volume in every way that has ever made this block misbehave:
# the four that used to abort the hook outright (an unreadable marker, a read-only
# statusline, no sha256sum on PATH, a directory where the file belongs), a marker
# carrying no `sha256=` key, a copy that fails after truncating its destination, a
# peer container truncating the marker mid-rewrite, a closed fd 2, a marker that
# cannot be written in place, a read-only statusline restarted on the SAME image
# (the note must be throttled per image, not repeated per start), and a directory
# where the MARKER belongs (a plain `mv` moves the temp inside it and reports
# success). Each case asserts the same three things: the hook exits
# 0, the on-disk statusline is left as it was (or, where a refresh was due, is whole
# and correctly marked), AND the instruction file and settings.json still refresh.
# That last one is the point: the independence the decision path promises must hold
# on the error path too, or a cosmetic asset still decides whether the rest of the
# volume converges. Test 28 closes the group by breaking the CODE rather than the
# volume — a fatal shell error injected into a copy of the hook, inside the step —
# so invariant B is pinned as a property of the call site's structure and not only
# as a list of shapes that happen to survive.
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
skip=0
ok() {
	pass=$((pass + 1))
	printf 'ok   - %s\n' "$1"
}
no() {
	fail=$((fail + 1))
	printf 'FAIL - %s\n' "$1"
}
# sk <reason> — a case that cannot be MEANINGFULLY run here. Loud on purpose: a
# permission-denial case is vacuous under root/CAP_DAC_OVERRIDE, and silently
# counting it as a pass would report coverage the run does not have.
sk() {
	skip=$((skip + 1))
	printf 'SKIP - %s\n' "$1"
}

# chmod 000/444 deny nothing to root. The pure-shell suite runs as uid 1000 in
# the container and on CI, so the denial cases below normally execute.
if [ "$(id -u)" -eq 0 ]; then
	RUNNING_AS_ROOT=yes
else
	RUNNING_AS_ROOT=no
fi

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

SL_PATH="/usr/bin:/bin"

# sl_invoke <cfg> <seed> <path> [stderr-mode] — drive the REAL hook against an
# explicit config/seed pair with BOTH convergence handshakes claimed by core, so the
# detached build-skew block never spawns and only the seeding path runs. stderr lands
# in <cfg>.stderr, unless <stderr-mode> is `closed`, which runs the hook with fd 2
# CLOSED so every `echo … >&2` in the block fails with EBADF. <path> is explicit so a
# group-3 case can hand the hook a PATH with one tool taken away or stubbed, and
# <hook> so test 28 can drive a deliberately sabotaged COPY of the hook instead of
# the repo file; the hook's own exit status is this function's status.
sl_invoke() {
	local cfg="$1" seed="$2" path="$3" stderr_mode="${4:-file}" hook="${5:-$HOOK}"
	local -a cmd=(
		env -i
		HOME="$WORK_ROOT"
		PATH="$path"
		AGENT_CONFIG_DIR="$cfg"
		AGENT_SEED_DIR="$seed"
		AGENT_INSTRUCTION_FILE="CLAUDE.md"
		AGENT_NAME="Claude"
		AGENT_AUTONOMY_FLAG="--yolo"
		AGENT_PEERS="none"
		PRIMARY_AGENT=claude
		POWBOX_PLUGIN_BOOTSTRAP=core
		POWBOX_CODEX_SYNC_BOOTSTRAP=core
		bash "$hook"
	)
	if [ "$stderr_mode" = closed ]; then
		"${cmd[@]}" 2>&-
	else
		"${cmd[@]}" 2>"$cfg.stderr"
	fi
}

# sl_run <cfg> <seed> — the happy-path form: a hook failure propagates and this
# suite (also `set -e`) stops, which is what a broken decision path deserves.
sl_run() {
	sl_invoke "$1" "$2" "$SL_PATH"
}

# sl_rc <cfg> <seed> [path] [stderr-mode] [hook] — PRINTS the hook's exit status
# instead of propagating it. Group 3 asserts that status, so it must survive to be
# compared: a non-zero one is precisely the entrypoint-killing bug those cases exist
# to catch, and letting it abort this suite would report the bug as a missing test
# rather than a failing one.
sl_rc() {
	local rc=0
	sl_invoke "$1" "$2" "${3:-$SL_PATH}" "${4:-file}" "${5:-$HOOK}" || rc=$?
	printf '%s\n' "$rc"
}

# sl_key <marker> <key> — read one key from a key=value marker (by key, never by
# line position: the .powbox-seeded parsing contract).
#
# The trailing `|| true` on both readers is not decoration: this suite also runs
# under `set -euo pipefail`, and these are called in bare command substitutions
# (`X="$(sl_key …)"`). Without it, a missing or unreadable marker takes the whole
# suite down mid-run — no summary line, no idea which cases never ran.
sl_key() {
	sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 || true
}

sl_sha() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true
}

# sl_flip_byte <file> <offset> <char> — overwrite exactly one byte in place,
# leaving the length and every other byte untouched. The acceptance criterion
# words the customization case as "verified by editing one byte", so it is
# tested with a real one-byte edit rather than a rewritten line.
sl_flip_byte() {
	printf '%s' "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none 2>/dev/null
}

# sl_tmpl <seed-dir> <version> — write the instruction template. Its ${AGENT_NAME}
# placeholder must reach envsubst literally, hence the single quotes.
# shellcheck disable=SC2016
sl_tmpl() {
	printf 'instruction %s for ${AGENT_NAME}\n' "$2" >"$1/agent.md.tmpl"
}

# sl_seed_full <dir> <epoch> <body> <tmpl-version> — sl_seed plus the two OTHER
# epoch-gated assets, so a case can watch them converge while the statusline
# decision goes the other way (or goes wrong).
sl_seed_full() {
	sl_seed "$1" "$2" "$3"
	sl_tmpl "$1" "$4"
	printf '{"statusLine":{"type":"command","command":"x"}}\n' >"$1/statusline-settings.json"
}

# sl_independent <cfg> <tmpl-version> — assert the two assets the statusline must
# never gate did land: the instruction file rendered at <tmpl-version> and the
# statusLine key merged into settings.json.
sl_independent() {
	[ "$(cat "$1/CLAUDE.md" 2>/dev/null)" = "instruction $2 for Claude" ] &&
		[ "$(jq -r '.statusLine.command' "$1/settings.json" 2>/dev/null)" = "x" ]
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

# --- Test 9: customized by ONE BYTE -> PRESERVED, with a note -------------------
# The acceptance criterion says "verified by editing one byte", so the edit is
# literally one byte: same length, same every-other-byte, different digest.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
sl_seed "$SL_SEED" 100 'v1 baseline statusline'
sl_run "$CFG" "$SL_SEED"
SEEDED_SHA="$(sl_key "$MK" sha256)"
SEEDED_SIZE="$(wc -c <"$DST")"
sl_flip_byte "$DST" 3 B # 'v1 baseline …' -> 'v1 Baseline …'
sl_seed "$SL_SEED" 200 'v2'
sl_run "$CFG" "$SL_SEED"
if [ "$(cat "$DST" 2>/dev/null)" = "v1 Baseline statusline" ] &&
	[ "$(wc -c <"$DST")" = "$SEEDED_SIZE" ] &&
	[ "$(sl_sha "$DST")" != "$SEEDED_SHA" ] &&
	[ "$(sl_key "$MK" epoch)" = "100" ] &&
	[ "$(sl_key "$MK" sha256)" = "$SEEDED_SHA" ] &&
	grep -q 'differs from the copy powbox seeded' "$CFG.stderr"; then
	ok "one-byte-edited statusline, newer epoch: preserved, marker untouched, one note"
else
	no "one-byte-edited statusline, newer epoch: preserved, marker untouched, one note (got: $(cat "$DST" 2>/dev/null))"
fi

# --- Test 10: restarting on the SAME image must not nag again -------------------
sl_run "$CFG" "$SL_SEED"
if [ ! -s "$CFG.stderr" ] && [ "$(sl_key "$MK" notified_epoch)" = "200" ]; then
	ok "customized statusline, same image again: silent (no nag per start)"
else
	no "customized statusline, same image again: silent (got: $(cat "$CFG.stderr" 2>/dev/null))"
fi

# --- Test 11: ...but a NEWER image is a new offer, so it says so once more ------
# The rewrite that records the new notified_epoch must PRESERVE the other keys:
# a marker reduced to notified_epoch= alone would unmark the file for good.
sl_seed "$SL_SEED" 300 'v3'
sl_run "$CFG" "$SL_SEED"
if [ "$(cat "$DST" 2>/dev/null)" = "v1 Baseline statusline" ] &&
	[ "$(sl_key "$MK" notified_epoch)" = "300" ] &&
	grep -q 'differs from the copy powbox seeded' "$CFG.stderr"; then
	ok "customized statusline, next image: preserved and noted once more"
else
	no "customized statusline, next image: preserved and noted once more"
fi

# --- Test 12: UNMARKED pre-existing file -> preserved (today's upgrade path) ----
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

# --- Test 13: deleting the file re-seeds it AND adopts the marker ---------------
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

# --- Test 14: a held-back statusline does not hold back the instruction file ----
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
SL_SEED_FULL="$WORK_ROOT/slseed-full"
sl_seed_full "$SL_SEED_FULL" 100 'v1' v1
sl_run "$CFG" "$SL_SEED_FULL"
printf 'my own statusline\n' >"$DST"
sl_seed_full "$SL_SEED_FULL" 200 'v2' v2
sl_run "$CFG" "$SL_SEED_FULL"
if [ "$(cat "$DST" 2>/dev/null)" = "my own statusline" ] &&
	[ "$(cat "$CFG/.instruction-epoch" 2>/dev/null)" = "200" ] &&
	sl_independent "$CFG" v2; then
	ok "customized statusline does not block the instruction file or settings.json"
else
	no "customized statusline does not block the instruction file or settings.json"
fi

# --- Test 15: ...and a skipped instruction render does not block the statusline -
# A volume stamped by a NEWER image than the one now running skips the instruction
# block entirely (VOLUME_EPOCH > IMAGE_EPOCH); the statusline still refreshes on
# its own marker's epoch.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
sl_seed_full "$SL_SEED_FULL" 100 'v1' v1
sl_run "$CFG" "$SL_SEED_FULL"
printf '999\n' >"$CFG/.instruction-epoch"
sl_seed_full "$SL_SEED_FULL" 200 'v2' v2
sl_run "$CFG" "$SL_SEED_FULL"
if [ "$(cat "$DST" 2>/dev/null)" = "v2" ] &&
	[ "$(sl_key "$MK" epoch)" = "200" ] &&
	[ "$(cat "$CFG/CLAUDE.md" 2>/dev/null)" = "instruction v1 for Claude" ] &&
	[ "$(cat "$CFG/.instruction-epoch" 2>/dev/null)" = "999" ]; then
	ok "skipped instruction render does not block the statusline refresh"
else
	no "skipped instruction render does not block the statusline refresh"
fi

# ================================================================================
# Statusline seeding, ERROR paths. Tests 16-20 each ABORTED the hook of their day
# (exit 2, 1, 127, 127 and 1 in order), as does test 24, and entrypoint-core.sh
# invokes this hook UNGUARDED under `set -euo pipefail`, so each was a dead
# container: no instruction file, no settings.json, no CMD, because a cosmetic asset
# could not be digested, written or even complained about. Tests 21-23 and 25 are the
# odd ones out — they exited 0 but LIED, silently and permanently — which is why
# every case here asserts the hook exited 0 AND that the other two seeded assets
# landed anyway AND what it left on disk and said on stderr. A status-only check
# would pass a hook that survives by skipping the rest of its work, and would miss
# the four lying cases entirely.
# ================================================================================

SL_SEED_ERR="$WORK_ROOT/slseed-err"

# sl_bin_mirror <dir> — mirror the real PATH into <dir> as symlinks, so a case can
# then drop one tool or shadow it with a stub while the hook's own PATH search
# behaves exactly as it does here. Returns nonzero (and the case skips) if the
# mirror did not come out usable.
sl_bin_mirror() {
	local dir="$1" t
	mkdir -p "$dir"
	ln -s /usr/bin/* "$dir/" 2>/dev/null || true
	ln -s /bin/* "$dir/" 2>/dev/null || true
	for t in bash cat cp sed head cut mktemp grep mv rm chmod envsubst jq sha256sum; do
		[ -x "$dir/$t" ] || return 1
	done
}

# sl_bin_without_sha256 <dir> — a mirror with exactly one tool dropped. An honest
# stand-in for an image built without coreutils' sha256sum: the hook's PATH search
# fails there just as it does here, which a stub exiting 127 would only imitate.
sl_bin_without_sha256() {
	local dir="$1"
	sl_bin_mirror "$dir" || return 1
	rm -f "$dir/sha256sum"
	[ ! -e "$dir/sha256sum" ]
}

# sl_bin_with_stub <dir> <tool> <body> — a mirror in which <tool> is shadowed by a
# bash stub. The stub reaches the genuine tool through $REAL, resolved here, so it
# can sabotage the ONE call a case is about and pass every other one through: the
# hook runs cp and grep for more than the statusline, and a blanket break would
# make the independence assertions pass (or fail) for the wrong reason.
sl_bin_with_stub() {
	local dir="$1" tool="$2" body="$3" real
	sl_bin_mirror "$dir" || return 1
	real="$(command -v "$tool")" || return 1
	rm -f "$dir/$tool"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'REAL=%q\n' "$real"
		printf '%s\n' "$body"
	} >"$dir/$tool" || return 1
	chmod +x "$dir/$tool"
}

SL_NOSHA_BIN="$WORK_ROOT/bin-nosha"
if sl_bin_without_sha256 "$SL_NOSHA_BIN"; then
	SL_NOSHA_OK=yes
else
	SL_NOSHA_OK=no
fi

# --- Test 16: UNREADABLE marker, newer epoch -> kept, silent, hook survives -----
# Pre-fix this was exit 2: sed could not open the marker, and with `pipefail` the
# unguarded reader carried that status out of a bare command substitution.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
sl_run "$CFG" "$SL_SEED_ERR"
sl_seed_full "$SL_SEED_ERR" 200 'v2' v2
if [ "$RUNNING_AS_ROOT" = yes ]; then
	sk "unreadable marker, newer epoch: keeps the file and survives (root ignores chmod 000)"
else
	chmod 000 "$MK"
	RC="$(sl_rc "$CFG" "$SL_SEED_ERR")"
	chmod 600 "$MK"
	if [ "$RC" = 0 ] &&
		[ "$(cat "$DST" 2>/dev/null)" = "v1" ] &&
		sl_independent "$CFG" v2; then
		ok "unreadable marker, newer epoch: keeps the file and survives, others still refresh"
	else
		no "unreadable marker, newer epoch: keeps the file and survives, others still refresh (rc=$RC, statusline=$(cat "$DST" 2>/dev/null))"
	fi
fi

# --- Test 17: READ-ONLY statusline, digest matches -> kept, noted, hook survives -
# The cruellest shape: the file is byte-identical, so the hook DECIDES to refresh
# and only then finds it cannot write. Pre-fix the unguarded `cp` exited 1.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
sl_run "$CFG" "$SL_SEED_ERR"
sl_seed_full "$SL_SEED_ERR" 200 'v2' v2
if [ "$RUNNING_AS_ROOT" = yes ]; then
	sk "read-only statusline, newer epoch: kept with a note (root ignores chmod 444)"
else
	chmod 444 "$DST"
	RC="$(sl_rc "$CFG" "$SL_SEED_ERR")"
	chmod 644 "$DST"
	if [ "$RC" = 0 ] &&
		[ "$(cat "$DST" 2>/dev/null)" = "v1" ] &&
		grep -q 'could not write' "$CFG.stderr" &&
		sl_independent "$CFG" v2; then
		ok "read-only statusline, newer epoch: kept with a note, others still refresh"
	else
		no "read-only statusline, newer epoch: kept with a note, others still refresh (rc=$RC, statusline=$(cat "$DST" 2>/dev/null))"
	fi
fi

# --- Test 18: NO sha256sum, absent statusline -> seeded but NOT marked ----------
# Pre-fix exit 127, and notably AFTER the copy landed: the file was replaced and
# the container then died on digesting it. The fix keeps the copy and writes no
# marker, because an identity it cannot prove must never license a later refresh.
if [ "$SL_NOSHA_OK" != yes ]; then
	sk "no sha256sum, absent statusline: seeded without a marker (no usable stub PATH here)"
else
	CFG="$(sl_new_cfg)"
	DST="$CFG/statusline-command.sh"
	MK="$CFG/.statusline-command.sh.powbox-seeded"
	sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
	RC="$(sl_rc "$CFG" "$SL_SEED_ERR" "$SL_NOSHA_BIN")"
	if [ "$RC" = 0 ] &&
		[ "$(cat "$DST" 2>/dev/null)" = "v1" ] &&
		[ ! -e "$MK" ] &&
		sl_independent "$CFG" v1; then
		ok "no sha256sum, absent statusline: seeded but left unmarked, others still refresh"
	else
		no "no sha256sum, absent statusline: seeded but left unmarked, others still refresh (rc=$RC, marker=$([ -e "$MK" ] && echo present || echo absent))"
	fi
fi

# --- Test 19: NO sha256sum, MARKED statusline, newer epoch -> kept, silent ------
# The other half of the same outage, and the only case that exercises an empty
# `_sl_have` (test 21 covers an empty `_sl_want`): the marker names a digest the
# hook cannot compute, so there is no proof either way and the file stays.
if [ "$SL_NOSHA_OK" != yes ]; then
	sk "no sha256sum, marked statusline: kept unprovable-so-untouched (no usable stub PATH here)"
else
	CFG="$(sl_new_cfg)"
	DST="$CFG/statusline-command.sh"
	MK="$CFG/.statusline-command.sh.powbox-seeded"
	sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
	sl_run "$CFG" "$SL_SEED_ERR"
	MK_BEFORE="$(cat "$MK")"
	sl_seed_full "$SL_SEED_ERR" 200 'v2' v2
	RC="$(sl_rc "$CFG" "$SL_SEED_ERR" "$SL_NOSHA_BIN")"
	if [ "$RC" = 0 ] &&
		[ "$(cat "$DST" 2>/dev/null)" = "v1" ] &&
		[ "$(cat "$MK")" = "$MK_BEFORE" ] &&
		[ ! -s "$CFG.stderr" ] &&
		sl_independent "$CFG" v2; then
		ok "no sha256sum, marked statusline: kept silently, marker intact, others still refresh"
	else
		no "no sha256sum, marked statusline: kept silently, marker intact, others still refresh (rc=$RC, stderr=$(cat "$CFG.stderr" 2>/dev/null))"
	fi
fi

# --- Test 20: a DIRECTORY where the statusline belongs -> untouched -------------
# Pre-fix, `[ ! -f ]` was true for a directory, so the hook copied the baked file
# INTO it and then exited 1 digesting the directory. The emptiness assertion is
# what catches that copy; the status alone would not.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
mkdir -p "$DST"
sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
RC="$(sl_rc "$CFG" "$SL_SEED_ERR")"
if [ "$RC" = 0 ] &&
	[ -d "$DST" ] &&
	[ -z "$(find "$DST" -mindepth 1 -print -quit 2>/dev/null)" ] &&
	[ ! -e "$MK" ] &&
	sl_independent "$CFG" v1; then
	ok "directory at the statusline path: left untouched and unmarked, others still refresh"
else
	no "directory at the statusline path: left untouched and unmarked, others still refresh (rc=$RC, entries=$(find "$DST" -mindepth 1 2>/dev/null | tr '\n' ' '))"
fi

# --- Test 21: marker with NO sha256= key -> kept SILENTLY -----------------------
# Not a crash, a lie: pre-fix an absent `sha256=` fell through to the "differs"
# branch, so powbox asserted a difference it had not established and invited the
# user to delete a file that may never have been touched — then stamped
# notified_epoch onto the marker to make sure it only said so once.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
printf 'v1\n' >"$DST"
printf 'epoch=100\ncommit=c0ffee1\nsource=Roubtec/powbox#x\n' >"$MK"
MK_BEFORE="$(cat "$MK")"
sl_seed_full "$SL_SEED_ERR" 200 'v2' v2
RC="$(sl_rc "$CFG" "$SL_SEED_ERR")"
if [ "$RC" = 0 ] &&
	[ "$(cat "$DST" 2>/dev/null)" = "v1" ] &&
	[ "$(cat "$MK")" = "$MK_BEFORE" ] &&
	[ ! -s "$CFG.stderr" ] &&
	sl_independent "$CFG" v2; then
	ok "marker without sha256=: kept silently, marker intact, others still refresh"
else
	no "marker without sha256=: kept silently, marker intact, others still refresh (rc=$RC, stderr=$(cat "$CFG.stderr" 2>/dev/null))"
fi

# --- Test 22: a copy that fails MID-WRITE leaves the destination intact ---------
# `cp SRC DST` opens DST with O_TRUNC, so a failure after that open (a full or
# failing volume) used to leave a truncated statusline behind — while the marker
# still named the OLD digest, so every later start read the wreckage as a user
# customization and never repaired it. Invariant A: the copy lands in a temp
# sibling and a failure renames nothing, which is what makes "left as found" true.
SL_CP_FAIL_STUB="$(
	cat <<'STUB'
# Reproduce what a copy failing AFTER it opened the destination does (ENOSPC,
# EIO): the destination is left truncated and cp exits nonzero. ONLY the
# statusline copy is sabotaged — settings.json is copied with the same cp, and
# breaking that too would make the independence assertion meaningless.
case "$1" in
*/statusline-command.sh)
	: >"$2" 2>/dev/null || true
	exit 1
	;;
esac
exec "$REAL" "$@"
STUB
)"
SL_CP_FAIL_BIN="$WORK_ROOT/bin-cp-fails"
if ! sl_bin_with_stub "$SL_CP_FAIL_BIN" cp "$SL_CP_FAIL_STUB"; then
	sk "copy fails mid-write: statusline intact (no usable stub PATH here)"
else
	CFG="$(sl_new_cfg)"
	DST="$CFG/statusline-command.sh"
	MK="$CFG/.statusline-command.sh.powbox-seeded"
	sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
	sl_run "$CFG" "$SL_SEED_ERR"
	MK_BEFORE="$(cat "$MK")"
	sl_seed_full "$SL_SEED_ERR" 200 'v2' v2
	RC="$(sl_rc "$CFG" "$SL_SEED_ERR" "$SL_CP_FAIL_BIN")"
	# The proof of the OLD file must survive verbatim; the only permitted change
	# is the `notified_epoch=` the note's own throttle stamps (see test 26).
	if [ "$RC" = 0 ] &&
		[ "$(cat "$DST" 2>/dev/null)" = "v1" ] &&
		[ "$(grep -v '^notified_epoch=' "$MK")" = "$MK_BEFORE" ] &&
		[ "$(sl_key "$MK" notified_epoch)" = "200" ] &&
		grep -q 'could not write' "$CFG.stderr" &&
		[ -z "$(find "$CFG" -name 'statusline-command.sh.*' -print -quit 2>/dev/null)" ] &&
		sl_independent "$CFG" v2; then
		ok "copy fails mid-write: statusline and marker intact, temp cleaned up, others still refresh"
	else
		no "copy fails mid-write: statusline and marker intact, temp cleaned up, others still refresh (rc=$RC, statusline=$(cat "$DST" 2>/dev/null))"
	fi
fi

# --- Test 23: a marker that changes UNDER the rewrite is not published over -----
# The claude-config volume is shared by every powbox container, so a peer can
# truncate the marker between this hook reading `sha256=` out of it and the grep
# that filters it. grep then reports "no lines" (status 1), and treating that as
# "nothing to keep" published a marker holding `notified_epoch=` alone — no
# `epoch=`, no `sha256=` — which unmarks the file for good: never refreshed and
# never noted again, in perfect silence. Reaching this branch PROVES the marker
# carried a `sha256=` line moments ago, so status 1 can only mean it changed.
SL_GREP_RACE_STUB="$(
	cat <<'STUB'
# Simulate that peer's truncating write landing in exactly that window: empty the
# marker, let the real grep read it (no output, status 1), then let the peer's
# write complete so the marker is whole again. Any non-marker grep passes through.
mk=""
for a in "$@"; do
	case "$a" in
	*.powbox-seeded) mk="$a" ;;
	esac
done
if [ -n "$mk" ] && [ -f "$mk" ]; then
	saved="$(cat "$mk")"
	: >"$mk"
	rc=0
	"$REAL" "$@" || rc=$?
	printf '%s\n' "$saved" >"$mk"
	exit "$rc"
fi
exec "$REAL" "$@"
STUB
)"
SL_GREP_RACE_BIN="$WORK_ROOT/bin-grep-race"
if ! sl_bin_with_stub "$SL_GREP_RACE_BIN" grep "$SL_GREP_RACE_STUB"; then
	sk "marker truncated under the rewrite: epoch=/sha256= survive (no usable stub PATH here)"
else
	CFG="$(sl_new_cfg)"
	DST="$CFG/statusline-command.sh"
	MK="$CFG/.statusline-command.sh.powbox-seeded"
	sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
	sl_run "$CFG" "$SL_SEED_ERR"
	MK_BEFORE="$(cat "$MK")"
	printf 'my own statusline\n' >"$DST"
	sl_seed_full "$SL_SEED_ERR" 200 'v2' v2
	RC="$(sl_rc "$CFG" "$SL_SEED_ERR" "$SL_GREP_RACE_BIN")"
	if [ "$RC" = 0 ] &&
		[ "$(cat "$MK")" = "$MK_BEFORE" ] &&
		[ "$(sl_key "$MK" epoch)" = "100" ] &&
		[ -n "$(sl_key "$MK" sha256)" ] &&
		[ -z "$(sl_key "$MK" notified_epoch)" ] &&
		[ "$(cat "$DST" 2>/dev/null)" = "my own statusline" ] &&
		[ -z "$(find "$CFG" -name '.statusline-command.sh.powbox-seeded.*' -print -quit 2>/dev/null)" ] &&
		sl_independent "$CFG" v2; then
		ok "marker truncated under the rewrite: abandoned, epoch=/sha256= survive, others still refresh"
	else
		no "marker truncated under the rewrite: abandoned, epoch=/sha256= survive, others still refresh (rc=$RC, marker=$(tr '\n' ' ' <"$MK" 2>/dev/null))"
	fi
fi

# --- Test 24: fd 2 CLOSED -> the block still cannot end startup -----------------
# Both notes in the block are bare `echo … >&2`, which return 1 with stderr closed
# and, as the last command of their branch under `set -e`, used to abort the hook.
# Not a realistic container runtime, but the block's contract is absolute — see
# invariant B — and the customized branch is the one that always reaches an echo.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
sl_run "$CFG" "$SL_SEED_ERR"
printf 'my own statusline\n' >"$DST"
sl_seed_full "$SL_SEED_ERR" 200 'v2' v2
RC="$(sl_rc "$CFG" "$SL_SEED_ERR" "$SL_PATH" closed)"
if [ "$RC" = 0 ] &&
	[ "$(cat "$DST" 2>/dev/null)" = "my own statusline" ] &&
	[ "$(sl_key "$MK" notified_epoch)" = "200" ] &&
	[ "$(sl_key "$MK" epoch)" = "100" ] &&
	[ -n "$(sl_key "$MK" sha256)" ] &&
	sl_independent "$CFG" v2; then
	ok "stderr closed, note undeliverable: hook still exits 0, others still refresh"
else
	no "stderr closed, note undeliverable: hook still exits 0, others still refresh (rc=$RC)"
fi

# --- Test 25: no stale proof outlives a refreshed file --------------------------
# The user deleted the statusline (the documented escape hatch) but the marker
# stayed, and that marker cannot be written in place. Re-seeding the file while
# leaving the old marker behind strands a `sha256=` naming bytes that are gone, so
# every later start reads powbox's OWN fresh copy as a user edit and nags about it
# forever. Invariant A fixes this by construction — a rename needs the DIRECTORY's
# permission, not the file's, so the marker is replaced anyway — and if even that
# fails the marker is removed, leaving the honest unmarked state instead of a lie.
if [ "$RUNNING_AS_ROOT" = yes ]; then
	sk "unwritable marker on re-seed: no stale proof survives (root ignores chmod 444)"
else
	CFG="$(sl_new_cfg)"
	DST="$CFG/statusline-command.sh"
	MK="$CFG/.statusline-command.sh.powbox-seeded"
	sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
	sl_run "$CFG" "$SL_SEED_ERR"
	rm -f "$DST"
	chmod 444 "$MK"
	sl_seed_full "$SL_SEED_ERR" 200 'v2' v2
	RC="$(sl_rc "$CFG" "$SL_SEED_ERR")"
	chmod 644 "$MK" 2>/dev/null || true
	# Second start on the SAME image: the proof must agree with the file, so this
	# one has nothing to say. A stale marker nags here.
	RC2="$(sl_rc "$CFG" "$SL_SEED_ERR")"
	if [ "$RC" = 0 ] && [ "$RC2" = 0 ] &&
		[ "$(cat "$DST" 2>/dev/null)" = "v2" ] &&
		{ [ ! -e "$MK" ] || [ "$(sl_key "$MK" sha256)" = "$(sl_sha "$DST")" ]; } &&
		[ ! -s "$CFG.stderr" ] &&
		sl_independent "$CFG" v2; then
		ok "unwritable marker on re-seed: proof matches the new file (or is gone), no false nag"
	else
		no "unwritable marker on re-seed: proof matches the new file (or is gone), no false nag (rc=$RC/$RC2, marker=$(tr '\n' ' ' <"$MK" 2>/dev/null))"
	fi
fi

# --- Test 26: the read-only note is throttled per IMAGE, not fired per start ----
# This branch stays true forever once the image is newer: nothing is published, so
# the marker's `epoch=` never advances and the refresh is re-decided (and re-denied)
# on every single start. An unthrottled note therefore printed on each one, which is
# exactly the per-start nagging the design forbids. `notified_epoch=` throttles it —
# writable in this shape because only the FILE is read-only, not the marker.
if [ "$RUNNING_AS_ROOT" = yes ]; then
	sk "read-only statusline, same image again: noted once, not once per start (root ignores chmod 444)"
else
	CFG="$(sl_new_cfg)"
	DST="$CFG/statusline-command.sh"
	MK="$CFG/.statusline-command.sh.powbox-seeded"
	sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
	sl_run "$CFG" "$SL_SEED_ERR"
	sl_seed_full "$SL_SEED_ERR" 200 'v2' v2
	chmod 444 "$DST"
	RC="$(sl_rc "$CFG" "$SL_SEED_ERR")"
	SL_NOTE_FIRST="$(cat "$CFG.stderr" 2>/dev/null || true)"
	RC2="$(sl_rc "$CFG" "$SL_SEED_ERR")"
	SL_NOTE_SECOND="$(cat "$CFG.stderr" 2>/dev/null || true)"
	chmod 644 "$DST"
	if [ "$RC" = 0 ] && [ "$RC2" = 0 ] &&
		[ "$(cat "$DST" 2>/dev/null)" = "v1" ] &&
		printf '%s' "$SL_NOTE_FIRST" | grep -q 'could not write' &&
		[ -z "$SL_NOTE_SECOND" ] &&
		[ "$(sl_key "$MK" notified_epoch)" = "200" ] &&
		[ "$(sl_key "$MK" epoch)" = "100" ] &&
		[ -n "$(sl_key "$MK" sha256)" ] &&
		sl_independent "$CFG" v2; then
		ok "read-only statusline, same image again: noted once, marker keeps epoch/sha256"
	else
		no "read-only statusline, same image again: noted once, marker keeps epoch/sha256 (rc=$RC/$RC2, second start said: $SL_NOTE_SECOND)"
	fi
fi

# --- Test 27: a DIRECTORY where the MARKER belongs -> failure, not a stray file -
# `mv tmp DIR` moves the temp INSIDE the directory and exits 0, so the writer
# reported "published" having published nowhere — and deposited a stray file in a
# directory the user owns. `mv -T` makes it the failure it is, and the caller then
# answers as it does for any unpublishable marker: leave no proof at all.
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
mkdir -p "$MK"
sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
RC="$(sl_rc "$CFG" "$SL_SEED_ERR")"
if [ "$RC" = 0 ] &&
	[ "$(cat "$DST" 2>/dev/null)" = "v1" ] &&
	[ -d "$MK" ] &&
	[ -z "$(find "$MK" -mindepth 1 -print -quit 2>/dev/null)" ] &&
	[ -z "$(find "$CFG" -maxdepth 1 -name '.statusline-command.sh.powbox-seeded.*' -print -quit 2>/dev/null)" ] &&
	sl_independent "$CFG" v1; then
	ok "directory at the marker path: nothing deposited inside it, no temp left behind"
else
	no "directory at the marker path: nothing deposited inside it, no temp left behind (rc=$RC, entries=$(find "$CFG" -name '.statusline-command.sh.powbox-seeded*' 2>/dev/null | tr '\n' ' '))"
fi

# --- Test 28: a FATAL shell error inside the step cannot end startup ------------
# Invariant B's structural half. Every case above breaks the volume; this one breaks
# the CODE, injecting a `set -u` read of an unset variable as the step's first
# statement in a COPY of the hook (the repo file is never touched). That is a fatal
# shell error, not an exit status, so both halves of the old `statusline_seed_step
# || true` are blind to it: `set -e` suspension only covers failing commands, and
# `|| true` only discards a status that was returned. It kills the shell it runs in
# outright, straight through an AND-OR list — so this case exits 1 with nothing
# rendered on the direct form, and exits 0 on `(statusline_seed_step) || true`,
# where the parentheses make that shell a child.
SL_HOOK_FATAL="$WORK_ROOT/hook-with-fatal.sh"
SL_FATAL_OK=yes
# The awk exits non-zero unless the anchor matched EXACTLY once, so a renamed or
# reshaped step turns into a loud failure below rather than a case that silently
# runs an unsabotaged hook and passes for the wrong reason.
awk '
	{ print }
	/^statusline_seed_step\(\) \{$/ {
		print "\t: \"${POWBOX_TEST_NEVER_SET}\""
		injected++
	}
	END { exit(injected == 1 ? 0 : 1) }
' "$HOOK" >"$SL_HOOK_FATAL" || SL_FATAL_OK=no
CFG="$(sl_new_cfg)"
DST="$CFG/statusline-command.sh"
MK="$CFG/.statusline-command.sh.powbox-seeded"
sl_seed_full "$SL_SEED_ERR" 100 'v1' v1
if [ "$SL_FATAL_OK" != yes ]; then
	no "fatal error inside the step: contained by the subshell (could not inject it: the statusline_seed_step anchor moved)"
else
	RC="$(sl_rc "$CFG" "$SL_SEED_ERR" "$SL_PATH" file "$SL_HOOK_FATAL")"
	# The stderr check keeps the case honest: without it an injection that never
	# executed would pass on rc=0 alone.
	if [ "$RC" = 0 ] &&
		grep -q 'POWBOX_TEST_NEVER_SET' "$CFG.stderr" 2>/dev/null &&
		[ ! -e "$DST" ] && [ ! -e "$MK" ] &&
		sl_independent "$CFG" v1; then
		ok "fatal error inside the step: contained by the subshell, hook exits 0, others still refresh"
	else
		no "fatal error inside the step: contained by the subshell, hook exits 0, others still refresh (rc=$RC, stderr=$(tr '\n' ' ' <"$CFG.stderr" 2>/dev/null))"
	fi
fi

echo
echo "claude-hook build-skew + statusline-seed tests: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
