#!/usr/bin/env bash
# Hermetic checks of what the agents' instruction file says, against the real
# sources: docker/shared/container-agent.md.tmpl, each committed layer set's
# agent-notes.md, and the on-demand reference files the instruction file points
# at (docs/agent-reference.md). The instruction file is loaded into every
# session, so most detail lives in the reference files; these checks hold the
# two halves together for the lean image and for every committed set:
#   - every reference file the staged instruction file names is staged, and
#     every staged reference file is named, so no pointer dangles and no file
#     sits where nothing sends an agent to read it;
#   - no reference file uses a template variable, since only the instruction
#     file is rendered;
#   - the image's AGENT_KNOWN_LIMITATIONS names a reference file the build
#     stages, since a report-writing tool finds the document through it;
#   - the hooks' variable list leaves no ${AGENT_...} placeholder in the
#     rendered instruction file;
#   - the hazards the instruction file exists to keep in view are still in it,
#     so a later trim that drops one fails here rather than in a session;
#   - the tool rows that moved to tooling.md still state the versions the
#     Dockerfiles pin.
#
# The staging scripts themselves are covered by test-stage-agent-template.sh
# and test-stage-agent-reference.sh, PowerShell twins included; this suite
# uses the Bash drivers only.
#
# The fixtures are Markdown: their backticks are code spans, never command
# substitutions.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CORE="${ROOT_DIR}/docker/shared/container-agent.md.tmpl"
REFERENCE_DIR=/usr/local/share/agent-reference

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
	if [ "$#" -gt 1 ]; then
		printf '       %s\n' "${@:2}"
	fi
}

assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected: [$3]" "actual:   [$2]"; fi
}

# assert_has <label> <file> <fixed string>
assert_has() {
	if grep -qF -- "$3" "$2"; then ok "$1"; else ko "$1" "not found in ${2#"$ROOT_DIR"/}: $3"; fi
}

# named_references <file>: the reference files <file> names, one per line. A
# reference file is named by its bare file name in a code span, or by its full
# path under the baked directory.
named_references() {
	{
		grep -oE '`[a-z0-9][a-z0-9-]*\.md`' "$1" | tr -d '`' || true
		grep -oE "${REFERENCE_DIR}/[a-z0-9][a-z0-9-]*\\.md" "$1" | sed "s|^${REFERENCE_DIR}/||" || true
	} | LC_ALL=C sort -u
}

root="$WORK_ROOT/root"
mkdir -p "$root/docker/shared" "$root/docker/layers"
cp "$CORE" "$root/docker/shared/"
cp -r "$ROOT_DIR/docker/shared/agent-reference" "$root/docker/shared/"

sets=("")
for dir in "$ROOT_DIR"/docker/layers/*/; do
	[ -f "${dir}Dockerfile" ] || continue
	set_name="$(basename "$dir")"
	# docker/layers/custom/ is the gitignored slot for a user's own set.
	[ "$set_name" != custom ] || continue
	cp -r "${dir%/}" "$root/docker/layers/"
	sets+=("$set_name")
done

for set_name in "${sets[@]}"; do
	label="${set_name:-lean}"
	echo "Test: the instruction file and its reference files, ${label}"
	"$SCRIPT_DIR/stage-agent-template.sh" "$set_name" "$root"
	"$SCRIPT_DIR/stage-agent-reference.sh" "$set_name" "$root"
	staged="$root/.powbox-staging/agent.md.tmpl"
	staged_ref="$root/.powbox-staging/agent-reference"

	named="$(named_references "$staged")"
	have="$(cd "$staged_ref" && LC_ALL=C ls -A)"
	assert_eq "[$label] every reference file the instruction file names is staged, and every staged one is named" "$named" "$have"

	leaked="$(grep -lF '${AGENT_' "$staged_ref"/* || true)"
	assert_eq "[$label] no reference file uses a template variable" "$leaked" ""

	rendered="$(AGENT_NAME=Claude AGENT_AUTONOMY_FLAG=--flag AGENT_CONFIG_DIR=/home/node/.claude AGENT_PEERS='- peer' \
		envsubst '${AGENT_NAME} ${AGENT_AUTONOMY_FLAG} ${AGENT_CONFIG_DIR} ${AGENT_PEERS}' <"$staged")"
	assert_eq "[$label] the hooks' variable list renders every placeholder" "$(grep -cF '${AGENT_' <<<"$rendered" || true)" 0
done

echo "Test: the image names its known-limitations document in AGENT_KNOWN_LIMITATIONS"
# A report-writing tool finds the document through the variable alone
# (docs/agent-reference.md), so the ENV must name a file the build bakes.
assert_eq "docker/agent/Dockerfile sets the variable once, to the baked document" \
	"$(grep -E '^ENV AGENT_KNOWN_LIMITATIONS=' "$ROOT_DIR/docker/agent/Dockerfile" || true)" \
	"ENV AGENT_KNOWN_LIMITATIONS=${REFERENCE_DIR}/known-limitations.md"

echo "Test: both hooks render the instruction file with the same variable list"
hook_vars() { grep -oE "envsubst '[^']*'" "$ROOT_DIR/docker/shared/$1"; }
assert_eq "the Claude and Codex hooks agree" "$(hook_vars entrypoint-claude-hook.sh)" "$(hook_vars entrypoint-codex-hook.sh)"
assert_eq "this suite renders with the hooks' list" "$(hook_vars entrypoint-claude-hook.sh)" \
	"envsubst '\${AGENT_NAME} \${AGENT_AUTONOMY_FLAG} \${AGENT_CONFIG_DIR} \${AGENT_PEERS}'"

echo "Test: the hazards every session must see are in the core template"
# One distinctive token per hazard, a command or an identifier where there is
# one, so that rewording a sentence does not fail the check but dropping the
# hazard does. A token found on more than one line would survive the loss of
# the sentence it stands for, so it must sit on exactly one.
while IFS='|' read -r what token; do
	[ -n "$what" ] || continue
	assert_eq "core: $what" "$(grep -cF -- "$token" "$CORE" || true)" 1
done <<'EOF'
host visibility is checked before promising a local file|POWBOX_WORKSPACE_HOST_PATH
a child Claude session keeps its rm prompts|"${DIR:?}"
a pointer may name a file this image lacks|can name a file your image does not have
yq is the jq wrapper|jq syntax
markdownlint-cli2 passes when it lints nothing|exits zero when its globs match no files
a pipeline hides a failure before the pipe|set -o pipefail
an unchecked cd before a state-changing command|unchecked `cd`
the peer list with its one-shot forms|${AGENT_PEERS}
a peer keeps its stdin closed|< /dev/null
reviews go through the helper|For a peer review, run `peer-review-run`
the verdict line a review prompt asks for|VERDICT: PASS
the scratchpad is shared by subagents|mktemp -d -p <scratchpad>
the remote is not rewritten|insteadOf
no raw force push|--force-with-lease
review threads come from the helper|gh-review-threads <PR#>
destructive checks go in a disposable clone|DC="$(dc-enter <slug>)"
a worktree shares .git|update-ref
dc-remove only works from the worktree that ran dc-enter|`dc-remove` finds a clone only from the worktree that ran `dc-enter`
wt-remove's refusal is not answered with a forced removal|git worktree remove --force
broad cleanups reach the shared main checkout|git clean -fdx
path-level discards reach it too: checkout|git checkout -- <path>
path-level discards reach it too: restore|git restore <path>
path-level discards reach it too: stash|git stash
node_modules is hardlinked from the shared store|hardlink
a node_modules symlink is not ignored|ignore pattern
shadows are refreshed before output can reach the host|shadow-refresh.sh
the empty-shadow trap has a repair|pnpm-shadow-doctor
private networks are blocked|100.64.0.0/10
the firewall is not worked around|.powbox-egress
EOF

echo "Test: a set's hazards are in its always-loaded notes"
FULL_NOTES="$ROOT_DIR/docker/layers/full/agent-notes.md"
assert_has "full: parallel Go test suites exhaust memory" "$FULL_NOTES" 'go test -p'
assert_has "full: the sign of it never names memory" "$FULL_NOTES" 'never an error that names memory'
assert_has "full: PSScriptAnalyzer needs -Recurse" "$FULL_NOTES" '-Recurse'
assert_has "full: parallel worktrees need their own database cluster" "$FULL_NOTES" 'pg-dev-up --worktree'
assert_has "full: docker is a Podman shim" "$FULL_NOTES" 'is a shim for rootless `podman`'
assert_has "full: the Go memory hazard is baked beside the Go row too" "$ROOT_DIR/docker/layers/full/agent-reference/tooling.md" 'never an error that names memory'
for set_name in full browser; do
	assert_has "$set_name: Playwright's browsers are not baked" "$ROOT_DIR/docker/layers/$set_name/agent-notes.md" 'browsers are not baked'
done

echo "Test: the tool rows state the versions the Dockerfiles pin"
# The rows moved out of the template into tooling.md, and a Dockerfile's bump
# comment can only ask for them to be kept in step.
while IFS='|' read -r tool rows dockerfile expr; do
	[ -n "$tool" ] || continue
	version="$(sed -n "$expr" "$ROOT_DIR/$dockerfile")"
	if [ -z "$version" ]; then
		ko "$tool: no pinned version found in $dockerfile"
	else
		assert_has "$tool $version" "$ROOT_DIR/$rows" "\`$tool\` $version "
	fi
done <<'EOF'
shellcheck|docker/shared/agent-reference/tooling.md|docker/agent/Dockerfile|s/^RUN SHELLCHECK_VERSION=\([0-9.]*\).*/\1/p
actionlint|docker/shared/agent-reference/tooling.md|docker/agent/Dockerfile|s/^RUN ACTIONLINT_VERSION=\([0-9.]*\).*/\1/p
markdownlint-cli2|docker/shared/agent-reference/tooling.md|docker/agent/Dockerfile|s/.*markdownlint-cli2@\([0-9.]*\).*/\1/p
gitleaks|docker/layers/full/agent-reference/tooling.md|docker/layers/full/Dockerfile|s/^RUN GITLEAKS_VERSION=\([0-9.]*\).*/\1/p
EOF

echo
echo "agent-instructions tests: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
