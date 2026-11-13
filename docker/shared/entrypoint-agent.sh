#!/usr/bin/env bash
set -euo pipefail

# Unified entrypoint for the multi-agent image. Both agent binaries are present;
# PRIMARY_AGENT selects which one this container runs. Every agent is seeded at
# startup so a non-primary agent can be invoked in-container (delegated reviews,
# etc.) with its config, skills, and instruction file already in place.
#
# The non-primary agents are seeded here directly. The primary agent's env is
# exported and handed to entrypoint-core.sh, which runs its setup hook (so the
# hook is not run twice) alongside firewall/git/shadow setup before execing the
# CMD. See docs/unified-agent-image.md.

# Every agent the image knows how to run. Adding a harness = extend agent_env
# (and the registry comment in the Dockerfile / docs) and add it here.
ALL_AGENTS="claude codex"

PRIMARY_AGENT="${PRIMARY_AGENT:-claude}"
case " $ALL_AGENTS " in
*" $PRIMARY_AGENT "*) ;;
*)
	echo "entrypoint-agent: unknown PRIMARY_AGENT '$PRIMARY_AGENT'; falling back to claude." >&2
	PRIMARY_AGENT="claude"
	;;
esac
export PRIMARY_AGENT

# Populate the AGENT_* variables for the named agent. AGENT_BINARY, AGENT_LABEL,
# and AGENT_ONESHOT feed the peer list rendered into each agent's instruction
# file; AGENT_ONESHOT is a Markdown fragment describing the peer's
# non-interactive one-shot invocation (the right form for delegated reviews and
# other fire-and-collect sub-tasks).
agent_env() {
	case "$1" in
	claude)
		AGENT_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/home/node/.claude}"
		AGENT_SETUP_HOOK="/usr/local/bin/entrypoint-claude-hook.sh"
		AGENT_SEED_DIR="/home/node/.agent-container/claude"
		AGENT_NAME="Claude"
		AGENT_BINARY="claude"
		AGENT_AUTONOMY_FLAG="--dangerously-skip-permissions"
		AGENT_INSTRUCTION_FILE="CLAUDE.md"
		AGENT_LABEL="Claude Code (Anthropic)"
		# shellcheck disable=SC2016
		AGENT_ONESHOT='One-shot: `claude -p "<prompt>"` prints the final answer on stdout (`--output-format json` for machine-readable output; `--model <alias>` / `--effort <level>` to pick strength). Print mode permits reads but denies Bash/Edit by default — right for review-type asks; add `--dangerously-skip-permissions` only when the sub-task must run commands or write.'
		;;
	codex)
		AGENT_CONFIG_DIR="${CODEX_CONFIG_DIR:-/home/node/.codex}"
		AGENT_SETUP_HOOK="/usr/local/bin/entrypoint-codex-hook.sh"
		AGENT_SEED_DIR="/home/node/.agent-container/codex"
		AGENT_NAME="Codex"
		AGENT_BINARY="codex"
		AGENT_AUTONOMY_FLAG="--dangerously-bypass-approvals-and-sandbox"
		AGENT_INSTRUCTION_FILE="AGENTS.md"
		AGENT_LABEL="Codex (OpenAI)"
		# shellcheck disable=SC2016
		AGENT_ONESHOT='One-shot: `codex exec --sandbox read-only -o <file> "<prompt>"` for read-only work like reviews (`codex review --base <branch>` is the purpose-built review form, run from the tree to review; note `--base` and a custom prompt are mutually exclusive); use `codex exec --dangerously-bypass-approvals-and-sandbox` only when the sub-task must write. `-m <model>` / `-c model_reasoning_effort=<level>` pick strength. Preflight with `codex login status` (non-zero exit = not logged in) — an unauthenticated `codex exec` burns ~30s of retries before failing.'
		;;
	muse)
		# Peer-only: Muse Code is never a PRIMARY_AGENT and has no setup hook, seed
		# directory or instruction file. Only the fields peer_list prints are set.
		AGENT_NAME="Muse"
		AGENT_BINARY="muse"
		AGENT_AUTONOMY_FLAG="--yolo"
		AGENT_LABEL="Muse Code (Meta) — optional reviewer; use it only when it is logged in"
		AGENT_ONESHOT='One-shot: `muse exec --prompt-file <file>` prints the final answer on stdout (`--json` for JSONL events; `--model <id>` / `--effort <level>` to pick strength). Approval and the sandbox stay on unless you pass flags to lift them, which suits a review; a review prompt should still say the checkout is shared with other agents, so the reviewer reads the diff rather than running builds or changing files. Preflight with `muse usage` (non-zero exit = not logged in, and it prints the remaining subscription allowance otherwise). Contributor mode follows the saved Muse setting; pass `--contributor-mode on|off` only when the user asked for a per-run override.'
		;;
	*)
		echo "entrypoint-agent: unknown agent '$1'" >&2
		return 1
		;;
	esac
}

# Peer-only agents: listed as a peer when their binary is baked into this image
# (an opt-in build input), never seeded and never a valid PRIMARY_AGENT.
PEER_ONLY_AGENTS="muse"

# Render the Markdown bullet list of peer agents (every agent except $1) that the
# instruction template substitutes via ${AGENT_PEERS}.
peer_list() {
	local self="$1" other
	for other in $ALL_AGENTS $PEER_ONLY_AGENTS; do
		[ "$other" = "$self" ] && continue
		case " $PEER_ONLY_AGENTS " in
		*" $other "*) command -v "$other" >/dev/null 2>&1 || continue ;;
		esac
		(
			agent_env "$other" || exit 0
			# Backticks here are literal Markdown for the instruction file, not a
			# command substitution; the %s placeholders carry the real values.
			# shellcheck disable=SC2016
			printf -- '- `%s %s` — %s\n  %s\n' "$AGENT_BINARY" "$AGENT_AUTONOMY_FLAG" "$AGENT_LABEL" "$AGENT_ONESHOT"
		)
	done
}

# Export everything a setup hook (and the instruction template) needs for $1.
export_agent_env() {
	agent_env "$1" || return 1
	AGENT_PEERS="$(peer_list "$1")"
	export AGENT_CONFIG_DIR AGENT_SETUP_HOOK AGENT_SEED_DIR \
		AGENT_NAME AGENT_BINARY AGENT_AUTONOMY_FLAG \
		AGENT_INSTRUCTION_FILE AGENT_LABEL AGENT_ONESHOT AGENT_PEERS
}

# Seed every non-primary agent now. Hooks are idempotent and epoch-gated, and
# each writes only into its own config dir, so this never clobbers the primary.
for agent in $ALL_AGENTS; do
	[ "$agent" = "$PRIMARY_AGENT" ] && continue
	export_agent_env "$agent" || continue
	mkdir -p "$AGENT_CONFIG_DIR"
	if [ -x "$AGENT_SETUP_HOOK" ]; then
		"$AGENT_SETUP_HOOK" || echo "entrypoint-agent: seeding $agent failed; continuing." >&2
	fi
done

# Configure the primary agent and hand off to the shared core entrypoint, which
# runs its setup hook plus firewall/git/shadow setup and finally execs the CMD.
export_agent_env "$PRIMARY_AGENT"

exec /usr/local/bin/entrypoint-core.sh "$@"
