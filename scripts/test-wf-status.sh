#!/usr/bin/env bash

# Fixture test for docker/shared/wf-status. The completed fixture mirrors the
# installed harness split: started/result records in journal.jsonl, tiny agent
# sidecars/transcripts in the run directory, and labels/phases/final return in
# the sibling workflows/<runId>.json snapshot. The partial fixtures deliberately
# omit and truncate each surface.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${WF_STATUS:-${ROOT_DIR}/docker/shared/wf-status}"
if [[ ! -x "$HELPER" ]]; then
	echo "test-wf-status: helper is not executable: $HELPER" >&2
	exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wf-status-test-047.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
CONFIG="$WORK/config"
SESSION="$CONFIG/projects/-workspace-fixture/session-047"
RUN_ID="wf_fixture-047"
RUN_DIR="$SESSION/subagents/workflows/$RUN_ID"
mkdir -p "$RUN_DIR" "$SESSION/workflows"

cat >"$RUN_DIR/journal.jsonl" <<'EOF'
{"type":"started","key":"v2:one","agentId":"a1"}
{"type":"result","key":"v2:one","agentId":"a1","result":{"ok":true}}
{"type":"started","key":"v2:two","agentId":"a2"}
{"type":"result","key":"v2:two","agentId":"a2","result":{"ok":false}}
{"type":"started","key":"v2:three","agentId":"a3"}
EOF
printf '{"type":"result"' >>"$RUN_DIR/journal.jsonl"
cat >"$RUN_DIR/agent-a1.meta.json" <<'EOF'
{"agentType":"workflow-subagent","spawnDepth":1}
EOF
cat >"$RUN_DIR/agent-a2.meta.json" <<'EOF'
{"agentType":"workflow-subagent","spawnDepth":1}
EOF
cat >"$RUN_DIR/agent-a3.meta.json" <<'EOF'
{"agentType":"workflow-subagent","spawnDepth":1}
EOF
cat >"$RUN_DIR/agent-a1.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"first fixture prompt\nmore"}}
{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}
EOF
cat >"$RUN_DIR/agent-a2.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"second fixture prompt"}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API error"}]}}
EOF
cat >"$RUN_DIR/agent-a3.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"third fixture prompt"}}
{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[]}}
EOF
cat >"$SESSION/workflows/$RUN_ID.json" <<'EOF'
{
  "runId": "wf_fixture-047",
  "workflowName": "fixture-workflow",
  "status": "failed",
  "phases": [{"title":"Bootstrap"},{"title":"Work"}],
  "workflowProgress": [
    {"type":"workflow_phase","index":1,"title":"Bootstrap"},
    {"type":"workflow_agent","index":1,"label":"bootstrap","phaseIndex":1,"phaseTitle":"Bootstrap","agentId":"a1","state":"done"},
    {"type":"workflow_phase","index":2,"title":"Work"},
    {"type":"workflow_agent","index":2,"label":"worker-failed","phaseIndex":2,"phaseTitle":"Work","agentId":"a2","state":"error","error":"fixture failure"},
    {"type":"workflow_agent","index":3,"label":"worker-pending","phaseIndex":2,"phaseTitle":"Work","agentId":"a3","state":"start"}
  ],
  "result": {"delivered":1,"note":"fixture return"},
  "error": "workflow stopped after fixture failure"
}
EOF

checks=0
fails=0

ok() {
	checks=$((checks + 1))
	printf '  ok %s\n' "$1"
}

bad() {
	checks=$((checks + 1))
	fails=$((fails + 1))
	printf '  FAIL %s\n%s\n' "$1" "${2:-}" >&2
}

assert_has() {
	local label="$1" output="$2" expected="$3"
	if grep -Fq -- "$expected" <<<"$output"; then
		ok "$label"
	else
		bad "$label" "expected '$expected' in:\n$output"
	fi
}

write_boundary_aligned_transcript() {
	local filename="$1" prompt="$2" status_record="$3"
	local padding_prefix='{"type":"progress","padding":"'
	local padding_suffix='"}'
	local prefix_size padding_width final_size
	printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$prompt" >"$filename"
	prefix_size="$(wc -c <"$filename")"
	padding_width=$((65536 - ${#status_record} - 1 - ${#padding_prefix} - ${#padding_suffix} - 1))
	{
		printf '%s\n%s' "$status_record" "$padding_prefix"
		printf '%*s' "$padding_width" ''
		printf '%s\n' "$padding_suffix"
	} >>"$filename"
	final_size="$(wc -c <"$filename")"
	if [[ "$final_size" -ne $((prefix_size + 65536)) ]]; then
		echo "test-wf-status: failed to align tail fixture $filename" >&2
		exit 1
	fi
}

output="$($HELPER "$RUN_DIR")"
assert_has "transcript directory resolves its run ID" "$output" "Workflow: $RUN_ID"
assert_has "snapshot status is shown" "$output" "Status: failed"
assert_has "phases seen are rendered" "$output" "1. Bootstrap"
assert_has "completed/failed/pending calls are counted" "$output" "Agents: 3 total (1 completed, 1 failed, 1 pending)"
assert_has "snapshot failure survives a matching journal result" "$output" "failed    worker-failed [a2]"
assert_has "snapshot labels are correlated by agent ID" "$output" "worker-failed [a2] · Work · fixture failure"
assert_has "agent error is rendered" "$output" "fixture failure"
assert_has "final return is rendered" "$output" '{"delivered":1,"note":"fixture return"}'
assert_has "truncated final journal record is non-fatal" "$output" "truncated final record and was ignored"

run_id_output="$(CLAUDE_CONFIG_DIR="$CONFIG" "$HELPER" "$RUN_ID")"
assert_has "run ID lookup finds the same session artifact" "$run_id_output" "Directory: $RUN_DIR"

PARTIAL_ID="wf_partial-047"
PARTIAL_DIR="$SESSION/subagents/workflows/$PARTIAL_ID"
mkdir -p "$PARTIAL_DIR"
cat >"$PARTIAL_DIR/journal.jsonl" <<'EOF'
{"type":"started","key":"v2:pending","agentId":"p1"}
{"type":"started","key":"v2:failed","agentId":"p3"}
{"type":"result","key":"v2:failed","agentId":"p3","result":{"ok":false}}
EOF
printf '{"type":"started","key":"v2:cut"' >>"$PARTIAL_DIR/journal.jsonl"
cat >"$PARTIAL_DIR/agent-p1.meta.json" <<'EOF'
{"agentType":"workflow-subagent","spawnDepth":1}
EOF
printf '%s' '{"type":"user","message":{"role":"user","content":"pending label from prompt"}}' >"$PARTIAL_DIR/agent-p1.jsonl"
cat >"$PARTIAL_DIR/agent-p2.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"completed orphan transcript"}}
{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}
EOF
cat >"$PARTIAL_DIR/agent-p3.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"failed result transcript"}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API error"}]}}
EOF
cat >"$PARTIAL_DIR/agent-p3.meta.json" <<'EOF'
{"agentType":"workflow-subagent","state":"running"}
EOF
partial_output="$($HELPER "$PARTIAL_DIR")"
assert_has "missing snapshot degrades to partial" "$partial_output" "Status: partial"
assert_has "partial journal plus transcript still produce useful counts" "$partial_output" "Agents: 3 total (1 completed, 1 failed, 1 pending)"
assert_has "complete non-newline-terminated transcript line is retained" "$partial_output" "pending label from prompt [p1]"
assert_has "transcript failure survives a matching journal result" "$partial_output" "failed    failed result transcript [p3]"
assert_has "partial run has no invented final return" "$partial_output" "(not available)"
assert_has "missing snapshot is a warning" "$partial_output" "workflow snapshot is missing"

MERGE_ID="wf_merge-047"
MERGE_DIR="$SESSION/subagents/workflows/$MERGE_ID"
mkdir -p "$MERGE_DIR"
cat >"$MERGE_DIR/journal.jsonl" <<'EOF'
{"type":"started","key":"v2:failed","agentId":"m1"}
{"type":"result","key":"v2:failed","agentId":"m1","result":{"ok":false}}
EOF
cat >"$MERGE_DIR/agent-m1.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"snapshot pending transcript failure"}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API error"}]}}
EOF
cat >"$MERGE_DIR/agent-m1.meta.json" <<'EOF'
{"agentType":"workflow-subagent","state":"start"}
EOF
cat >"$MERGE_DIR/agent-m2.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"snapshot pending transcript completion"}}
{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}
EOF
cat >"$SESSION/workflows/$MERGE_ID.json" <<'EOF'
{
  "runId": "wf_merge-047",
  "status": "running",
  "workflowProgress": [
    {"type":"workflow_agent","index":1,"label":"snapshot-pending","agentId":"m1","state":"start"},
    {"type":"workflow_agent","index":2,"label":"snapshot-stale-completed","agentId":"m2","state":"start"}
  ]
}
EOF
merge_output="$($HELPER "$MERGE_DIR")"
assert_has "transcript failure overrides a pending snapshot with a matching result" "$merge_output" "failed    snapshot-pending [m1]"
assert_has "transcript completion overrides a stale pending snapshot without a result" "$merge_output" "completed snapshot-stale-completed [m2]"

PHASES_ID="wf_phases-047"
PHASES_DIR="$SESSION/subagents/workflows/$PHASES_ID"
mkdir -p "$PHASES_DIR"
cat >"$SESSION/workflows/$PHASES_ID.json" <<'EOF'
{
  "runId": "wf_phases-047",
  "status": "running",
  "phases": [{"title":"Snapshot phase one"},{"title":"Snapshot phase two"}],
  "workflowProgress": []
}
EOF
phases_output="$($HELPER "$PHASES_DIR")"
assert_has "top-level snapshot phase definitions are used when progress events are absent" "$phases_output" "1. Snapshot phase one"
assert_has "all top-level snapshot phase definitions are retained" "$phases_output" "2. Snapshot phase two"

AGENT_PHASE_ID="wf_agent-phase-047"
AGENT_PHASE_DIR="$SESSION/subagents/workflows/$AGENT_PHASE_ID"
mkdir -p "$AGENT_PHASE_DIR"
cat >"$SESSION/workflows/$AGENT_PHASE_ID.json" <<'EOF'
{
  "runId": "wf_agent-phase-047",
  "status": "running",
  "workflowProgress": [
    {"type":"workflow_agent","index":1,"label":"legacy-agent","phaseIndex":3,"phaseTitle":"Agent row phase","agentId":"ap1","state":"start"}
  ]
}
EOF
agent_phase_output="$($HELPER "$AGENT_PHASE_DIR")"
assert_has "agent phase titles are used when phase definitions and events are absent" "$agent_phase_output" "3. Agent row phase"

JOURNAL_COLLISION_ID="wf_journal-collision-047"
JOURNAL_COLLISION_DIR="$SESSION/subagents/workflows/$JOURNAL_COLLISION_ID"
mkdir -p "$JOURNAL_COLLISION_DIR"
cat >"$JOURNAL_COLLISION_DIR/journal.jsonl" <<'EOF'
{"type":"started","agentId":"j1"}
{"type":"result","key":"unkeyed:1","agentId":"j2","result":{"ok":true}}
EOF
journal_collision_output="$($HELPER "$JOURNAL_COLLISION_DIR")"
assert_has "a keyless journal record cannot replace an explicit lookalike key" "$journal_collision_output" "pending   ? [j1]"
assert_has "an explicit journal key resembling the old fallback is retained" "$journal_collision_output" "completed ? [j2]"
assert_has "keyless and explicitly keyed journal agents are both counted" "$journal_collision_output" "Agents: 2 total (1 completed, 0 failed, 1 pending)"

UNINDEXED_ID="wf_unindexed-047"
UNINDEXED_DIR="$SESSION/subagents/workflows/$UNINDEXED_ID"
mkdir -p "$UNINDEXED_DIR"
cat >"$SESSION/workflows/$UNINDEXED_ID.json" <<'EOF'
{
  "runId": "wf_unindexed-047",
  "status": "running",
  "workflowProgress": [
    {"type":"workflow_phase","index":2,"title":"Indexed phase"},
    {"type":"workflow_phase","title":"Unindexed phase"},
    {"type":"workflow_agent","index":2,"label":"indexed agent","agentId":"u1","state":"done"},
    {"type":"workflow_agent","label":"unindexed agent","agentId":"u2","state":"start"}
  ]
}
EOF
unindexed_output="$($HELPER "$UNINDEXED_DIR")"
assert_has "an unindexed phase cannot replace an indexed phase" "$unindexed_output" "2. Indexed phase"
assert_has "an unindexed phase is retained with an unknown index" "$unindexed_output" "?. Unindexed phase"
assert_has "an unindexed agent cannot replace an indexed agent" "$unindexed_output" "completed indexed agent [u1]"
assert_has "an unindexed agent is retained" "$unindexed_output" "pending   unindexed agent [u2]"
assert_has "indexed and unindexed agents are both counted" "$unindexed_output" "Agents: 2 total (1 completed, 0 failed, 1 pending)"

DUPLICATE_ID="wf_duplicate-047"
DUPLICATE_A="$CONFIG/projects/-workspace-fixture/session-duplicate-a"
DUPLICATE_B="$CONFIG/projects/-workspace-fixture/session-duplicate-b"
DUPLICATE_A_RUN="$DUPLICATE_A/subagents/workflows/$DUPLICATE_ID"
DUPLICATE_B_RUN="$DUPLICATE_B/subagents/workflows/$DUPLICATE_ID"
mkdir -p "$DUPLICATE_A_RUN" "$DUPLICATE_A/workflows" "$DUPLICATE_B_RUN" "$DUPLICATE_B/workflows"
printf '%s\n' '{"type":"started","key":"v2:a","agentId":"a"}' >"$DUPLICATE_A_RUN/journal.jsonl"
printf '%s\n' '{"runId":"wf_duplicate-047","status":"older-snapshot-newer-journal"}' >"$DUPLICATE_A/workflows/$DUPLICATE_ID.json"
printf '%s\n' '{"type":"started","key":"v2:b","agentId":"b"}' >"$DUPLICATE_B_RUN/journal.jsonl"
printf '%s\n' '{"runId":"wf_duplicate-047","status":"newer-snapshot-older-journal"}' >"$DUPLICATE_B/workflows/$DUPLICATE_ID.json"
touch -d '@1000000000' "$DUPLICATE_A/workflows/$DUPLICATE_ID.json"
touch -d '@1200000000' "$DUPLICATE_A_RUN"
touch -d '@1400000000' "$DUPLICATE_A_RUN/journal.jsonl"
touch -d '@1100000000' "$DUPLICATE_B_RUN/journal.jsonl"
touch -d '@1200000000' "$DUPLICATE_B_RUN"
touch -d '@1300000000' "$DUPLICATE_B/workflows/$DUPLICATE_ID.json"
duplicate_output="$(CLAUDE_CONFIG_DIR="$CONFIG" "$HELPER" "$DUPLICATE_ID")"
assert_has "duplicate run lookup uses the newest artifact across each candidate" "$duplicate_output" "Directory: $DUPLICATE_A_RUN"
assert_has "duplicate run lookup reports its selection" "$duplicate_output" "using the newest artifact"

BOUNDARY_ID="wf_boundary-047"
BOUNDARY_DIR="$SESSION/subagents/workflows/$BOUNDARY_ID"
mkdir -p "$BOUNDARY_DIR"
write_boundary_aligned_transcript \
	"$BOUNDARY_DIR/agent-b1.jsonl" \
	"boundary failure prompt" \
	'{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[]}}'
write_boundary_aligned_transcript \
	"$BOUNDARY_DIR/agent-b2.jsonl" \
	"boundary completion prompt" \
	'{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}'
boundary_output="$($HELPER "$BOUNDARY_DIR")"
assert_has "newline-aligned tail retains its first failure record" "$boundary_output" "failed    boundary failure prompt [b1]"
assert_has "newline-aligned tail retains its first completion record" "$boundary_output" "completed boundary completion prompt [b2]"
assert_has "boundary-aligned transcript states are counted" "$boundary_output" "Agents: 2 total (1 completed, 1 failed, 0 pending)"

TERMINAL_ORDER_ID="wf_terminal-order-047"
TERMINAL_ORDER_DIR="$SESSION/subagents/workflows/$TERMINAL_ORDER_ID"
mkdir -p "$TERMINAL_ORDER_DIR"
cat >"$TERMINAL_ORDER_DIR/agent-t1.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"recovered agent"}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[]}}
{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}
EOF
cat >"$TERMINAL_ORDER_DIR/agent-t2.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"late failure agent"}}
{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[]}}
EOF
terminal_order_output="$($HELPER "$TERMINAL_ORDER_DIR")"
assert_has "a completion after an API error marks a recovered transcript completed" "$terminal_order_output" "completed recovered agent [t1]"
assert_has "an API error after completion remains the final failed state" "$terminal_order_output" "failed    late failure agent [t2]"
assert_has "the last terminal transcript signals determine the counts" "$terminal_order_output" "Agents: 2 total (1 completed, 1 failed, 0 pending)"

LONG_TERMINAL_ID="wf_long-terminal-047"
LONG_TERMINAL_DIR="$SESSION/subagents/workflows/$LONG_TERMINAL_ID"
mkdir -p "$LONG_TERMINAL_DIR"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"long terminal record"}}' >"$LONG_TERMINAL_DIR/agent-l1.jsonl"
{
	printf '%s' '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"'
	printf '%70000s' ''
	printf '%s' '"}]}}'
} >>"$LONG_TERMINAL_DIR/agent-l1.jsonl"
long_terminal_output="$($HELPER "$LONG_TERMINAL_DIR")"
assert_has "a terminal transcript record larger than the edge chunk is read completely" "$long_terminal_output" "completed long terminal record [l1]"

EMPTY_ID="wf_empty-047"
EMPTY_DIR="$SESSION/subagents/workflows/$EMPTY_ID"
mkdir -p "$EMPTY_DIR"
empty_output="$($HELPER "$EMPTY_DIR")"
assert_has "missing journal and snapshot do not throw" "$empty_output" "Status: unknown"
assert_has "missing journal is identified" "$empty_output" "journal.jsonl is missing"
assert_has "empty partial run reports no calls" "$empty_output" "Agents: 0 total (0 completed, 0 failed, 0 pending)"

BROKEN_ID="wf_broken-047"
BROKEN_DIR="$SESSION/subagents/workflows/$BROKEN_ID"
mkdir -p "$BROKEN_DIR"
printf '{"runId":"wf_broken-047"' >"$SESSION/workflows/$BROKEN_ID.json"
broken_output="$($HELPER "$BROKEN_DIR")"
assert_has "truncated snapshot is ignored" "$broken_output" "workflow snapshot is truncated or invalid JSON"
assert_has "truncated snapshot does not create a final return" "$broken_output" "(not available)"

if "$HELPER" --help | grep -Fq "best-effort summary"; then
	ok "help labels derivation as best effort"
else
	bad "help labels derivation as best effort"
fi

if [[ "$fails" -ne 0 ]]; then
	echo "wf-status unit test: $fails/$checks checks FAILED." >&2
	exit 1
fi
echo "wf-status unit test passed ($checks checks)."
