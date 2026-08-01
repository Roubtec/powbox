#!/usr/bin/env bash
# Unit tests for docker/shared/detect-shadows.sh.
#
# Focus: the .powbox.yml literal-vs-glob split.  A literal path (no glob
# metacharacters) is emitted even when absent, so committed worktree
# scaffolding is created + tmpfs-shadowed at startup; a glob pattern stays
# existence-gated.  Also covers the under-/workspace-root security validation
# (including symlink escape) and confirms the pnpm/npm workspace logic is
# unchanged.
#
# Runs directly against the repo copy of detect-shadows.sh — no image build
# needed.  Requires bash, yq, and jq on PATH (all present in the agent image).
#
# Usage: scripts/test-detect-shadows.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DETECT="$SCRIPT_DIR/../docker/shared/detect-shadows.sh"
DOCTOR="$SCRIPT_DIR/../docker/shared/pnpm-shadow-doctor"

if [ ! -f "$DETECT" ]; then
	echo "FATAL: detect-shadows.sh not found at $DETECT" >&2
	exit 1
fi
if [ ! -f "$DOCTOR" ]; then
	echo "FATAL: pnpm-shadow-doctor not found at $DOCTOR" >&2
	exit 1
fi

pass=0
fail=0

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

# new_ws <name> — create a fresh workspace dir and echo its canonical path.
# Canonicalizing here means detect-shadows resolves the same path back, so
# emitted paths compare equal to "$ws/<rel>" with no symlink surprises.
new_ws() {
	local ws="$WORK_ROOT/$1"
	mkdir -p "$ws"
	realpath "$ws"
}

# write_powbox <ws> <entry...> — write a .powbox.yml shadow list.  Each entry
# is double-quoted so YAML special leaders ('!', '*', '[') are taken literally;
# detect-shadows does its own glob expansion on the resulting string value.
write_powbox() {
	local ws="$1"
	shift
	{
		echo "shadow:"
		local entry
		for entry in "$@"; do
			printf '  - "%s"\n' "$entry"
		done
	} >"$ws/.powbox.yml"
}

# write_powbox_local <ws> <entry...> — write a .powbox.local.yml shadow list.
write_powbox_local() {
	local ws="$1"
	shift
	{
		echo "shadow:"
		local entry
		for entry in "$@"; do
			printf '  - "%s"\n' "$entry"
		done
	} >"$ws/.powbox.local.yml"
}

write_powbox_local_empty() {
	local ws="$1"
	printf 'shadow: []\n' >"$ws/.powbox.local.yml"
}

# run_out <ws> — stdout of detect-shadows (stderr silenced).
run_out() {
	bash "$DETECT" "$1" 2>/dev/null
}

# run_err <ws> — stderr of detect-shadows (stdout silenced).
run_err() {
	{ bash "$DETECT" "$1" >/dev/null; } 2>&1
}

run_doctor_err() {
	{ PATH="$(dirname "$DETECT"):$PATH" bash "$DOCTOR" --quiet "$1" >/dev/null || true; } 2>&1
}

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
}

# The assertions below capture the run first and match against a HERE-STRING
# rather than piping the run straight into `grep -q`.  With `set -o pipefail`, a
# `grep -q` that matches exits immediately, the producer's next write gets
# SIGPIPE, and the pipeline's status becomes 141 — so a genuine match would be
# reported as a failure whenever the sought line is not the producer's last
# write.  That is a race (it depends on whether the producer finished first), and
# it fires for real: detect-shadows emits two symlink diagnostics, and its stdout
# comes from a `printf | sort -u` whose `sort` is what takes the SIGPIPE.

# assert_emits <ws> <abs-path> <msg>
assert_emits() {
	local out
	out="$(run_out "$1")"
	if grep -qxF "$2" <<<"$out"; then
		ok "$3"
	else
		ko "$3 (expected '$2' in output)"
	fi
}

# assert_absent <ws> <abs-path> <msg>
assert_absent() {
	local out
	out="$(run_out "$1")"
	if grep -qxF "$2" <<<"$out"; then
		ko "$3 (did not expect '$2' in output)"
	else
		ok "$3"
	fi
}

# assert_no_output <ws> <msg>
assert_no_output() {
	local out
	out="$(run_out "$1")"
	if [ -z "$out" ]; then
		ok "$2"
	else
		ko "$2 (expected no output, got: $(printf '%s' "$out" | tr '\n' ' '))"
	fi
}

# assert_output_exact <ws> <expected-output> <msg>
assert_output_exact() {
	local out
	out="$(run_out "$1")"
	if [ "$out" = "$2" ]; then
		ok "$3"
	else
		ko "$3 (expected exactly: $(printf '%s' "$2" | tr '\n' ' '); got: $(printf '%s' "$out" | tr '\n' ' '))"
	fi
}

# assert_stderr <ws> <substring> <msg>
assert_stderr() {
	local err
	err="$(run_err "$1")"
	if grep -qF "$2" <<<"$err"; then
		ok "$3"
	else
		ko "$3 (expected stderr to contain '$2')"
	fi
}

assert_stderr_absent() {
	local err
	err="$(run_err "$1")"
	if grep -qF "$2" <<<"$err"; then
		ko "$3 (did not expect stderr to contain '$2')"
	else
		ok "$3"
	fi
}

echo "Test: literal non-existent paths are emitted (created at startup)"
ws="$(new_ws literal-absent)"
# Mirror real usage: this script runs inside a git repo, so .git exists; it is
# the declared .git/worktrees *subdir* that is absent on a fresh checkout.
mkdir "$ws/.git"
write_powbox "$ws" .worktrees .git/worktrees .claude/worktrees
assert_emits "$ws" "$ws/.worktrees" "literal .worktrees emitted though absent"
assert_emits "$ws" "$ws/.git/worktrees" "literal .git/worktrees emitted though absent"
assert_emits "$ws" "$ws/.claude/worktrees" "literal .claude/worktrees emitted though absent"

echo "Test: .git/* literal skipped when .git is absent (non-git folder)"
ws="$(new_ws git-absent)"
write_powbox "$ws" .git/worktrees
assert_absent "$ws" "$ws/.git/worktrees" ".git/worktrees not emitted when .git absent"
assert_stderr "$ws" ".git is not a directory" "diagnostic explains the .git-absent skip"

echo "Test: .git/* literal skipped when .git is a file (linked worktree)"
ws="$(new_ws git-file)"
printf 'gitdir: /elsewhere/.git/worktrees/wt\n' >"$ws/.git"
write_powbox "$ws" .git/worktrees
assert_absent "$ws" "$ws/.git/worktrees" ".git/worktrees not emitted when .git is a file"
assert_stderr "$ws" ".git is not a directory" "diagnostic explains the linked-worktree skip"

echo "Test: non-matching glob produces no output (existence-gated)"
ws="$(new_ws glob-nomatch)"
write_powbox "$ws" 'packages/*/node_modules'
assert_no_output "$ws" "unmatched glob emits nothing"

echo "Test: matching glob emitted, package without node_modules skipped"
ws="$(new_ws glob-match)"
mkdir -p "$ws/packages/a/node_modules" "$ws/packages/b/node_modules" "$ws/packages/c"
write_powbox "$ws" 'packages/*/node_modules'
assert_emits "$ws" "$ws/packages/a/node_modules" "matching glob emits packages/a/node_modules"
assert_emits "$ws" "$ws/packages/b/node_modules" "matching glob emits packages/b/node_modules"
assert_absent "$ws" "$ws/packages/c/node_modules" "glob skips package lacking node_modules"

echo "Test: ? and [..] classify as glob, not literal (absent → nothing)"
ws="$(new_ws glob-meta)"
write_powbox "$ws" 'foo?' 'bar[12]'
assert_absent "$ws" "$ws/foo?" "'foo?' treated as glob, not emitted as literal"
assert_absent "$ws" "$ws/bar[12]" "'bar[12]' treated as glob, not emitted as literal"
assert_no_output "$ws" "no glob matches → no output"

echo "Test: escaping literal (../) rejected to stderr, not emitted"
ws="$(new_ws escape)"
write_powbox "$ws" '../evil'
assert_no_output "$ws" "escaping literal emits nothing"
assert_stderr "$ws" "resolves outside workspace root" "escaping literal rejected to stderr"

echo "Test: symlink escape rejected (realpath -m canonicalizes the prefix)"
ws="$(new_ws symlink-escape)"
ln -s /tmp "$ws/escape"
write_powbox "$ws" 'escape/evil'
assert_no_output "$ws" "symlink escape emits nothing"
assert_stderr "$ws" "resolves outside workspace root" "symlink escape rejected to stderr"

echo "Test: negation entries are skipped"
ws="$(new_ws negation)"
write_powbox "$ws" '!secret'
assert_no_output "$ws" "negation '!secret' skipped"

echo "Test: the workspace root itself is rejected with an accurate message"
ws="$(new_ws root-self)"
write_powbox "$ws" '.'
assert_no_output "$ws" "'.' (resolves to workspace root) not shadowed"
assert_stderr "$ws" "workspace root itself" "'.' rejected with a workspace-root diagnostic, not 'outside'"

echo "Test: local shadow list replaces committed custom shadows"
ws="$(new_ws local-override)"
write_powbox "$ws" committed-cache
write_powbox_local "$ws" local-cache
assert_output_exact "$ws" "$ws/local-cache" "local shadow list emits exactly the local entry"
assert_absent "$ws" "$ws/committed-cache" "committed shadow ignored under local override"
assert_stderr "$ws" "shadow list overridden by .powbox.local.yml" "local override diagnostic emitted"

echo "Test: local file without shadow key falls back to committed shadows"
ws="$(new_ws local-no-shadow-key)"
write_powbox "$ws" committed-cache
cat >"$ws/.powbox.local.yml" <<'YAML'
ctx: []
YAML
assert_output_exact "$ws" "$ws/committed-cache" "ctx-only local file does not replace committed shadow list"
assert_stderr_absent "$ws" "shadow list overridden by .powbox.local.yml" "ctx-only local file emits no override diagnostic"

echo "Test: local shadow empty list disables committed custom shadows but not workspace auto-detection"
ws="$(new_ws local-empty-shadow)"
mkdir -p "$ws/pkgs/a"
cat >"$ws/pnpm-workspace.yaml" <<'YAML'
packages:
  - "pkgs/*"
YAML
write_powbox "$ws" committed-cache
write_powbox_local_empty "$ws"
assert_output_exact "$ws" "$ws/pkgs/a/node_modules" "shadow: [] disables committed custom shadows while keeping pnpm workspace shadows"
assert_absent "$ws" "$ws/committed-cache" "committed shadow suppressed by local shadow: []"
assert_stderr "$ws" "shadow list overridden by .powbox.local.yml" "local empty-list override diagnostic emitted"

echo "Test: no local file preserves committed shadow behavior"
ws="$(new_ws no-local)"
write_powbox "$ws" committed-cache
assert_output_exact "$ws" "$ws/committed-cache" "committed shadow emitted when no local file exists"

echo "Test: escaping local literal is rejected and does not fall back to committed shadows"
ws="$(new_ws local-escape)"
write_powbox "$ws" committed-cache
write_powbox_local "$ws" '../evil'
assert_no_output "$ws" "escaping local literal emits nothing"
assert_absent "$ws" "$ws/committed-cache" "committed shadow ignored even when overriding local entry is rejected"
assert_stderr "$ws" "resolves outside workspace root" "escaping local literal rejected to stderr"

echo "Test: pnpm-shadow-doctor forwards only the local override diagnostic"
ws="$(new_ws doctor-stderr-filter)"
cat >"$ws/package.json" <<'JSON'
{}
JSON
write_powbox_local "$ws" '../evil'
doctor_err="$(run_doctor_err "$ws")"
if grep -qxF "detect-shadows: shadow list overridden by .powbox.local.yml" <<<"$doctor_err"; then
	ok "doctor forwards the local override diagnostic"
else
	ko "doctor did not forward the local override diagnostic"
fi
if grep -qF "resolves outside workspace root" <<<"$doctor_err"; then
	ko "doctor leaked ordinary validation noise"
else
	ok "doctor suppresses ordinary validation noise"
fi

echo "Test: pnpm workspace globs remain existence-gated on the package dir"
ws="$(new_ws pnpm-ws)"
mkdir -p "$ws/pkgs/x/node_modules" "$ws/pkgs/y"
cat >"$ws/pnpm-workspace.yaml" <<'YAML'
packages:
  - "pkgs/*"
YAML
assert_emits "$ws" "$ws/pkgs/x/node_modules" "pnpm pkg x → node_modules emitted"
assert_emits "$ws" "$ws/pkgs/y/node_modules" "pnpm pkg y → node_modules emitted (dir need not pre-exist)"
assert_absent "$ws" "$ws/pkgs/z/node_modules" "pnpm skips package dir that does not exist"

echo "Test: package.json workspaces array remains existence-gated"
ws="$(new_ws npm-ws)"
mkdir -p "$ws/apps/web"
cat >"$ws/package.json" <<'JSON'
{ "workspaces": ["apps/*"] }
JSON
assert_emits "$ws" "$ws/apps/web/node_modules" "npm workspace apps/web → node_modules emitted"

echo "Test: a path emitted via both workspace and .powbox.yml is deduplicated"
ws="$(new_ws dedup)"
mkdir -p "$ws/pkgs/x/node_modules"
cat >"$ws/pnpm-workspace.yaml" <<'YAML'
packages:
  - "pkgs/*"
YAML
write_powbox "$ws" 'pkgs/x/node_modules'
count="$(run_out "$ws" | grep -cxF "$ws/pkgs/x/node_modules" || true)"
if [ "$count" -eq 1 ]; then
	ok "duplicate path collapsed to a single line"
else
	ko "dedup failed (count=$count)"
fi

echo "Test: a bare workspace with no declarations emits nothing"
ws="$(new_ws empty)"
assert_no_output "$ws" "no .powbox.yml and no workspaces → no output"

# --- .NET project detection (*.csproj / *.fsproj / *.vbproj -> bin + obj) ---
#
# The key property: bin/obj are emitted as LITERALS, so they appear even though
# they do not exist yet.  Build output is absent on a fresh clone, which is
# exactly when the shadow has to be established.

echo "Test: a .csproj emits its sibling bin and obj though neither exists"
ws="$(new_ws dotnet-basic)"
mkdir -p "$ws/agents/svc"
touch "$ws/agents/svc/Svc.csproj"
assert_emits "$ws" "$ws/agents/svc/bin" "csproj → bin emitted though absent"
assert_emits "$ws" "$ws/agents/svc/obj" "csproj → obj emitted though absent"

echo "Test: .fsproj and .vbproj are detected too"
ws="$(new_ws dotnet-langs)"
mkdir -p "$ws/f" "$ws/v"
touch "$ws/f/App.fsproj" "$ws/v/App.vbproj"
assert_emits "$ws" "$ws/f/obj" "fsproj → obj emitted"
assert_emits "$ws" "$ws/v/obj" "vbproj → obj emitted"

echo "Test: a project at the workspace root emits root bin/obj, not the root itself"
ws="$(new_ws dotnet-root)"
touch "$ws/Root.csproj"
assert_emits "$ws" "$ws/bin" "root csproj → bin emitted"
assert_emits "$ws" "$ws/obj" "root csproj → obj emitted"
assert_absent "$ws" "$ws" "workspace root itself never emitted"

echo "Test: two project files in one directory collapse to a single bin/obj pair"
ws="$(new_ws dotnet-dedup)"
mkdir -p "$ws/multi"
touch "$ws/multi/A.csproj" "$ws/multi/B.fsproj"
count="$(run_out "$ws" | grep -cxF "$ws/multi/obj" || true)"
if [ "$count" -eq 1 ]; then
	ok "duplicate project dir collapsed to one obj line"
else
	ko "dotnet dedup failed (count=$count)"
fi

echo "Test: projects under node_modules / .git / .worktrees are pruned"
ws="$(new_ws dotnet-pruned)"
mkdir -p "$ws/node_modules/pkg" "$ws/.git/tmpl" "$ws/.worktrees/task/proj"
touch "$ws/node_modules/pkg/Vendored.csproj" \
	"$ws/.git/tmpl/Hook.csproj" \
	"$ws/.worktrees/task/proj/Wt.csproj"
assert_absent "$ws" "$ws/node_modules/pkg/obj" "csproj under node_modules pruned"
assert_absent "$ws" "$ws/.git/tmpl/obj" "csproj under .git pruned"
assert_absent "$ws" "$ws/.worktrees/task/proj/obj" "csproj under .worktrees pruned"
assert_no_output "$ws" "pruned-only tree emits nothing"

echo "Test: a project file copied under bin/ or obj/ does not seed a nested scan"
ws="$(new_ws dotnet-nested-artifacts)"
mkdir -p "$ws/app/bin/Release/net8.0" "$ws/app/obj/Debug"
touch "$ws/app/App.csproj" \
	"$ws/app/bin/Release/net8.0/Copied.csproj" \
	"$ws/app/obj/Debug/Stale.csproj"
assert_emits "$ws" "$ws/app/bin" "the project's own bin still emitted"
assert_absent "$ws" "$ws/app/bin/Release/net8.0/bin" "csproj under bin/ pruned"
assert_absent "$ws" "$ws/app/obj/Debug/obj" "csproj under obj/ pruned"

echo "Test: project directories containing spaces are handled"
ws="$(new_ws dotnet-spaces)"
mkdir -p "$ws/my project"
touch "$ws/my project/My App.csproj"
assert_emits "$ws" "$ws/my project/obj" "space-containing project dir → obj emitted"

echo "Test: a symlinked bin/obj is skipped, never resolved to its target"
ws="$(new_ws dotnet-symlink)"
mkdir -p "$ws/app" "$ws/src"
touch "$ws/app/App.csproj"
ln -s ../src "$ws/app/bin"
ln -s /etc "$ws/app/obj"
assert_absent "$ws" "$ws/src" "symlinked bin never resolves to its in-workspace target"
assert_absent "$ws" "$ws/app/bin" "symlinked bin not emitted as itself either"
assert_absent "$ws" "/etc" "symlinked obj never resolves outside the workspace"
assert_no_output "$ws" "a project whose bin and obj are both symlinks emits nothing"
assert_stderr "$ws" "symlink; refusing to shadow its target" "symlink skip is announced on stderr"

echo "Test: a symlinked bin does not suppress the same project's real obj"
ws="$(new_ws dotnet-symlink-partial)"
mkdir -p "$ws/app" "$ws/src"
touch "$ws/app/App.csproj"
ln -s ../src "$ws/app/bin"
assert_absent "$ws" "$ws/app/bin" "symlinked bin still skipped"
assert_emits "$ws" "$ws/app/obj" "the sibling obj is unaffected by the symlinked bin"

# --- .NET: an existing bin/obj holding tracked content is never masked ---
#
# A project redirecting its output (ArtifactsPath/OutputPath) can keep tracked
# scripts or fixtures in a sibling bin/obj.  Shadowing one would make them read
# as deleted for the session and send edits to a tmpfs that dies with the
# container, so tracked content vetoes the shadow.  `git add -f` mirrors the
# real situation (the file IS in the index) regardless of any ignore rules.

# git_ws <name> — a workspace that is also a fresh git repo.
git_ws() {
	local ws
	ws="$(new_ws "$1")"
	git -c init.defaultBranch=main init -q "$ws"
	printf '%s' "$ws"
}

echo "Test: a bin/obj containing Git-tracked files is not shadowed"
ws="$(git_ws dotnet-tracked)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/publish.sh"
git -C "$ws" add -f app/bin/publish.sh
assert_absent "$ws" "$ws/app/bin" "bin holding a tracked file is not shadowed"
assert_emits "$ws" "$ws/app/obj" "the untracked sibling obj is still shadowed"
assert_stderr "$ws" "contains Git-tracked files" "tracked-content skip is announced on stderr"

echo "Test: tracked content nested deeper in bin/ still vetoes the shadow"
ws="$(git_ws dotnet-tracked-nested)"
mkdir -p "$ws/app/obj/fixtures"
touch "$ws/app/App.csproj" "$ws/app/obj/fixtures/golden.json"
git -C "$ws" add -f app/obj/fixtures/golden.json
assert_absent "$ws" "$ws/app/obj" "obj holding tracked content at depth is not shadowed"
assert_emits "$ws" "$ws/app/bin" "the untracked sibling bin is still shadowed"

echo "Test: real build output (untracked) in bin/obj is still shadowed"
ws="$(git_ws dotnet-untracked)"
mkdir -p "$ws/app/bin/Debug" "$ws/app/obj"
touch "$ws/app/App.csproj" "$ws/app/bin/Debug/App.dll" "$ws/app/obj/project.assets.json"
git -C "$ws" add -f app/App.csproj
assert_emits "$ws" "$ws/app/bin" "untracked build output does not veto the bin shadow"
assert_emits "$ws" "$ws/app/obj" "untracked build output does not veto the obj shadow"

echo "Test: a non-git workspace keeps the default shadow (probe fails open)"
ws="$(new_ws dotnet-nongit)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/leftover.dll"
assert_emits "$ws" "$ws/app/bin" "existing bin outside a git repo is still shadowed"

# --- newline-containing paths are never emitted ---
#
# The output protocol is newline-delimited (mapfile -t in entrypoint-core.sh,
# read -r in shadow-refresh.sh), so an emitted path containing a newline would
# arrive at the privileged shadow-mounts.sh as two arguments — the first being a
# truncated ANCESTOR of the target.  With a leading newline that ancestor is the
# workspace root itself, which would tmpfs-mask the whole checkout.
nl="$(printf '\nx')" # a directory name whose first character is a newline

echo "Test: a project under a newline-named directory emits nothing for it"
ws="$(new_ws dotnet-newline)"
mkdir -p "$ws/$nl"
touch "$ws/$nl/App.csproj"
assert_absent "$ws" "$ws/" "the truncated workspace-root fragment is never emitted"
assert_absent "$ws" "$ws" "the workspace root is never emitted"
assert_no_output "$ws" "a newline-named project dir emits nothing at all"
assert_stderr "$ws" "path contains a newline" "newline rejection is announced on stderr"

echo "Test: a newline-named sibling does not suppress a normal project"
ws="$(new_ws dotnet-newline-sibling)"
mkdir -p "$ws/$nl" "$ws/ok"
touch "$ws/$nl/App.csproj" "$ws/ok/Ok.csproj"
assert_absent "$ws" "$ws/" "truncated fragment still absent alongside a valid project"
assert_emits "$ws" "$ws/ok/bin" "the well-named project is still shadowed"
assert_emits "$ws" "$ws/ok/obj" "the well-named project's obj is still shadowed"

# The guard sits at the single emit point rather than in the .NET branch, so it
# also covers the other producer that can pick a newline up from the filesystem:
# a .powbox.yml glob whose expansion matches a newline-named directory.  (The
# literal branch cannot carry one — yq output is itself read line by line.)
echo "Test: a .powbox.yml glob matching a newline-named directory is rejected too"
ws="$(new_ws newline-glob)"
mkdir -p "$ws/$nl/cache" "$ws/ok/cache"
write_powbox "$ws" '*/cache'
assert_absent "$ws" "$ws/" "newline glob match does not emit a truncated ancestor"
assert_emits "$ws" "$ws/ok/cache" "the well-named glob match is still shadowed"
assert_stderr "$ws" "path contains a newline" "newline glob rejection announced on stderr"

echo "Test: a repo with no .NET projects emits nothing from the .NET scan"
ws="$(new_ws dotnet-none)"
mkdir -p "$ws/src"
touch "$ws/src/main.go" "$ws/src/notes.csproj.md"
assert_no_output "$ws" "no project file → no .NET output"

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
	exit 1
fi
