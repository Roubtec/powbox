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
partial_output="$($HELPER "$PARTIAL_DIR")"
assert_has "missing snapshot degrades to partial" "$partial_output" "Status: partial"
assert_has "partial journal plus transcript still produce useful counts" "$partial_output" "Agents: 3 total (1 completed, 1 failed, 1 pending)"
assert_has "complete non-newline-terminated transcript line is retained" "$partial_output" "pending label from prompt [p1]"
assert_has "transcript failure survives a matching journal result" "$partial_output" "failed    failed result transcript [p3]"
assert_has "partial run has no invented final return" "$partial_output" "(not available)"
assert_has "missing snapshot is a warning" "$partial_output" "workflow snapshot is missing"

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
