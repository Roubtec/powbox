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

# git_ws <name> — a workspace that is also a fresh git repo.  Use it wherever a
# test needs a $ws/.git: a bare `mkdir "$ws/.git"` is repository EVIDENCE without
# being a readable repository, which puts the tracked-content probe on its
# fail-closed path and quietly couples the test to logic it is not about.
git_ws() {
	local ws
	ws="$(new_ws "$1")"
	git -c init.defaultBranch=main init -q "$ws"
	printf '%s' "$ws"
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

echo "Test: a workspace pattern escaping the workspace root is rejected"
ws="$(new_ws pnpm-escape)"
mkdir -p "$ws/pkgs/x" "$WORK_ROOT/other/src"
cat >"$ws/pnpm-workspace.yaml" <<'YAML'
packages:
  - "pkgs/*"
  - "../other/src"
YAML
assert_emits "$ws" "$ws/pkgs/x/node_modules" "the in-workspace package is still emitted"
assert_absent "$ws" "$WORK_ROOT/other/src/node_modules" "a manifest cannot point the shadow outside the workspace"
assert_stderr "$ws" "resolves outside workspace root" "escaping workspace pattern rejected to stderr"

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

echo "Test: projects under node_modules / .git / .worktrees / .claude are pruned"
# git_ws, not new_ws: the `.git/tmpl` fixture below needs a $ws/.git, and a bare
# `mkdir` one is repository EVIDENCE without being a readable repository, so the
# tracked-content probe would fail closed and this pruning test would be quietly
# exercising index-readability logic it is not about.  A real (freshly init'ed)
# repository keeps the probe on its ordinary path; the assertion at the end of
# the block pins that.
ws="$(git_ws dotnet-pruned)"
mkdir -p "$ws/node_modules/pkg" "$ws/.git/tmpl" "$ws/.worktrees/task/proj" \
	"$ws/.claude/worktrees/task/proj"
touch "$ws/node_modules/pkg/Vendored.csproj" \
	"$ws/.git/tmpl/Hook.csproj" \
	"$ws/.worktrees/task/proj/Wt.csproj" \
	"$ws/.claude/worktrees/task/proj/Wt.csproj"
assert_absent "$ws" "$ws/node_modules/pkg/obj" "csproj under node_modules pruned"
assert_absent "$ws" "$ws/.git/tmpl/obj" "csproj under .git pruned"
assert_absent "$ws" "$ws/.worktrees/task/proj/obj" "csproj under .worktrees pruned"
assert_absent "$ws" "$ws/.claude/worktrees/task/proj/obj" "csproj under .claude/worktrees pruned"
assert_no_output "$ws" "pruned-only tree emits nothing"
# All five above are negative, so a scan that found nothing at all would score
# five passes.  A project OUTSIDE every pruned directory pins that the walk is
# alive and that the prunes are what silenced the others.
mkdir -p "$ws/src"
touch "$ws/src/Real.csproj"
assert_emits "$ws" "$ws/src/obj" "a project outside the pruned dirs is still found"
assert_stderr_absent "$ws" "could not read the Git index" \
	"pruning is decided without the fail-closed path being involved"

echo "Test: a project file copied under bin/ or obj/ does not seed a nested scan"
ws="$(new_ws dotnet-nested-artifacts)"
mkdir -p "$ws/app/bin/Release/net8.0" "$ws/app/obj/Debug"
touch "$ws/app/App.csproj" \
	"$ws/app/bin/Release/net8.0/Copied.csproj" \
	"$ws/app/obj/Debug/Stale.csproj"
assert_emits "$ws" "$ws/app/bin" "the project's own bin still emitted"
assert_absent "$ws" "$ws/app/bin/Release/net8.0/bin" "csproj under bin/ pruned"
assert_absent "$ws" "$ws/app/obj/Debug/obj" "csproj under obj/ pruned"

echo "Test: project extensions are matched case-insensitively"
# A checkout authored on Windows keeps its casing once bind-mounted onto a
# case-sensitive Linux filesystem, and MSBuild happily builds `Legacy.CSPROJ` —
# writing bin/obj beside it and recreating the host/container collision this
# scan exists to prevent.  A case-SENSITIVE `-name` would never see the project.
ws="$(new_ws dotnet-case-ext)"
mkdir -p "$ws/upper" "$ws/mixed" "$ws/vb"
touch "$ws/upper/Legacy.CSPROJ" "$ws/mixed/App.FsProj" "$ws/vb/Old.VBPROJ"
assert_emits "$ws" "$ws/upper/bin" "an upper-case .CSPROJ is discovered"
assert_emits "$ws" "$ws/upper/obj" "an upper-case .CSPROJ emits obj too"
assert_emits "$ws" "$ws/mixed/obj" "a mixed-case .FsProj is discovered"
assert_emits "$ws" "$ws/vb/obj" "an upper-case .VBPROJ is discovered"
# The EMITTED names stay lower case whatever the project file was called: that is
# what a container-side `dotnet build` writes.  Pinned so a future `-iname` on the
# emit side cannot start mirroring the source casing.
assert_absent "$ws" "$ws/upper/Bin" "the emitted artifact dir is lower-case regardless"

echo "Test: a capitalised Bin/Obj is pruned like its lower-case spelling"
# Same host-casing argument on the prune side: an output directory spelled `Bin`
# (an older template, or an OutputPath written that way) must not be walked into,
# or a project file copied under it seeds a nested scan.
ws="$(new_ws dotnet-case-prune)"
mkdir -p "$ws/app/Bin/Release/net8.0" "$ws/app/Obj/Debug"
touch "$ws/app/App.csproj" \
	"$ws/app/Bin/Release/net8.0/Copied.csproj" \
	"$ws/app/Obj/Debug/Stale.csproj"
assert_emits "$ws" "$ws/app/bin" "the project's own bin is still emitted"
assert_absent "$ws" "$ws/app/Bin/Release/net8.0/bin" "csproj under Bin/ pruned"
assert_absent "$ws" "$ws/app/Obj/Debug/obj" "csproj under Obj/ pruned"

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

echo "Test: a workspace argument that is itself a symlink is still scanned"
# `find` with the default -P does not descend into a command-line symlink, so a
# hand-run `shadow-refresh.sh /path/to/symlink-to-workspace` scanned nothing and
# silently emitted no .NET shadows.  -H dereferences the ARGUMENT only.
symlink_target="$(new_ws dotnet-symlinked-root-target)"
symlink_ws="$(dirname "$symlink_target")/dotnet-symlinked-root"
ln -s "$symlink_target" "$symlink_ws"
mkdir -p "$symlink_target/app"
touch "$symlink_target/app/App.csproj"
# add_shadow_path realpaths every candidate, so the emitted paths are spelled
# with the resolved root rather than the symlink that was passed in.
assert_emits "$symlink_ws" "$symlink_target/app/bin" "a symlinked workspace root still yields bin"
assert_emits "$symlink_ws" "$symlink_target/app/obj" "a symlinked workspace root still yields obj"

echo "Test: -H still refuses to descend a symlinked directory INSIDE the tree"
# The guard the whole .NET branch leans on: repo content must not be able to aim
# the walk.  Only the operator's own argument is dereferenced, so a `vendor ->`
# symlink pointing out of the workspace is never followed — if it were, the
# outside project's bin/obj would reach add_shadow_path and be rejected there
# with a diagnostic, which is the oracle below.
outside_ws="$(new_ws dotnet-inner-symlink-target)"
mkdir -p "$outside_ws/app"
touch "$outside_ws/app/App.csproj"
ws="$(new_ws dotnet-inner-symlink)"
mkdir -p "$ws/own"
touch "$ws/own/Own.csproj"
ln -s "$outside_ws" "$ws/vendor"
# Positive companion first: without it the two negatives below would also hold if
# discovery had died outright.
assert_emits "$ws" "$ws/own/bin" "the workspace's own project is still found"
assert_absent "$ws" "$outside_ws/app/bin" "the project behind an inner symlink is never reached"
assert_stderr_absent "$ws" "resolves outside workspace root" \
	"no outside candidate was even considered, so nothing had to be rejected"

# --- .NET: an existing bin/obj holding tracked content is never masked ---
#
# A project redirecting its output (ArtifactsPath/OutputPath) can keep tracked
# scripts or fixtures in a sibling bin/obj.  Shadowing one would make them read
# as deleted for the session and send edits to a tmpfs that dies with the
# container, so tracked content vetoes the shadow.  `git add -f` mirrors the
# real situation (the file IS in the index) regardless of any ignore rules.

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

echo "Test: tracked content in a NESTED repo at bin/ still vetoes the shadow"
# A checkout AT bin/ is caught by the .git stat before any query runs.
ws="$(git_ws dotnet-nested-repo)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/tool.sh"
git -c init.defaultBranch=main init -q "$ws/app/bin"
git -C "$ws/app/bin" add -f tool.sh
assert_absent "$ws" "$ws/app/bin" "a nested repo's tracked content vetoes the shadow"
assert_emits "$ws" "$ws/app/obj" "the untracked sibling obj is still shadowed"

echo "Test: a repo nested ABOVE the candidate owns the tracked-ness question"
# The workspace's own index cannot see inside an initialized submodule or a
# nested clone, so batching such a candidate into the outer query would answer
# "untracked" for genuinely tracked content. Those few are asked separately.
ws="$(git_ws dotnet-nested-above)"
mkdir -p "$ws/vendor/lib/app/bin"
touch "$ws/vendor/lib/app/App.csproj" "$ws/vendor/lib/app/bin/tool.sh"
git -c init.defaultBranch=main init -q "$ws/vendor/lib"
git -C "$ws/vendor/lib" add -f app/bin/tool.sh
assert_absent "$ws" "$ws/vendor/lib/app/bin" "tracked content in a repo nested above bin/ vetoes the shadow"
assert_emits "$ws" "$ws/vendor/lib/app/obj" "the untracked sibling obj is still shadowed"

echo "Test: an unreadable index in a repo nested above the candidate fails closed"
ws="$(git_ws dotnet-nested-above-broken)"
mkdir -p "$ws/vendor/lib/app/bin"
touch "$ws/vendor/lib/app/App.csproj" "$ws/vendor/lib/app/bin/tool.sh"
git -c init.defaultBranch=main init -q "$ws/vendor/lib"
git -C "$ws/vendor/lib" add -f app/bin/tool.sh
printf 'not an index' >"$ws/vendor/lib/.git/index"
assert_absent "$ws" "$ws/vendor/lib/app/bin" "an unreadable nested index preserves the directory"
# Companions, so the negative above cannot pass merely because the scan found
# nothing, and so "withheld" is pinned to the fail-closed path rather than to
# the ordinary tracked-content veto, which says something different.
assert_emits "$ws" "$ws/vendor/lib/app/obj" "the absent sibling obj is still shadowed"
assert_stderr "$ws" "could not read the Git index for the repository owning '$ws/vendor/lib/app/bin'" \
	"the nested fail-closed reason is announced on stderr"

echo "Test: a tracked bin/ that is ABSENT on disk is still not shadowed"
# "Absent means it cannot hold tracked content" is false: a gitlink whose
# submodule was never initialized, or a path a sparse checkout left out, is
# tracked with nothing on disk — and shadowing it sends the eventual checkout
# into a tmpfs that dies with the container.
ws="$(git_ws dotnet-tracked-absent)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/tool.sh"
git -C "$ws" add -f app/bin/tool.sh
rm -rf "$ws/app/bin"
assert_absent "$ws" "$ws/app/bin" "an absent-but-tracked bin is not shadowed"
assert_emits "$ws" "$ws/app/obj" "the untracked sibling obj is still shadowed"

echo "Test: a never-built project still gets both shadows (the whole point)"
ws="$(git_ws dotnet-fresh-clone)"
mkdir -p "$ws/app"
touch "$ws/app/App.csproj"
git -C "$ws" add -f app/App.csproj
assert_emits "$ws" "$ws/app/bin" "absent bin emitted on a fresh clone"
assert_emits "$ws" "$ws/app/obj" "absent obj emitted on a fresh clone"

echo "Test: a BARE repository at bin/ is not shadowed"
# It has no .git of its own and the outer index does not track it, so nothing
# else would stop its object store being masked.
ws="$(git_ws dotnet-bare-repo)"
mkdir -p "$ws/app"
touch "$ws/app/App.csproj"
git -c init.defaultBranch=main init -q --bare "$ws/app/bin"
assert_absent "$ws" "$ws/app/bin" "a bare repo at bin/ is not shadowed"
assert_stderr "$ws" "Git repository or submodule checkout" "bare-repo skip is announced on stderr"
assert_emits "$ws" "$ws/app/obj" "the sibling obj is unaffected"

echo "Test: a bare repository with a DANGLING symlink HEAD is not shadowed"
# `-e` follows symlinks, so a HEAD pointing at a branch that does not exist
# reads as absent while `objects` and `refs` sit right there as real
# directories — and git still calls the result a repository (validate_headref
# checks the link's target STRING starts with refs/, it never stats it).  Left
# unrecognized, the whole object store would be tmpfs-masked.
#
# The symlink is built directly rather than via `core.prefersymlinkrefs`: that
# deprecated option is one route to this shape, but so is deleting the branch a
# symlinked HEAD points at, so keying the test on the option would let it skip
# forever on a git that changed the option's behavior while the bug stayed live.
ws="$(git_ws dotnet-bare-symlink-head)"
mkdir -p "$ws/app"
touch "$ws/app/App.csproj"
git -c init.defaultBranch=main init -q --bare "$ws/app/bin"
rm -f "$ws/app/bin/HEAD"
ln -s refs/heads/no-such-branch "$ws/app/bin/HEAD"
if [ -L "$ws/app/bin/HEAD" ] && [ ! -e "$ws/app/bin/HEAD" ]; then
	ok "precondition: HEAD is a dangling symlink and objects/refs are real dirs"
else
	ko "precondition: could not build a dangling symlink HEAD"
fi
assert_absent "$ws" "$ws/app/bin" "a bare repo with a dangling symlink HEAD is not shadowed"
assert_stderr "$ws" "Git repository or submodule checkout" "the symlinked-HEAD bare-repo skip is announced on stderr"
assert_emits "$ws" "$ws/app/obj" "the sibling obj is unaffected"

echo "Test: a project path with glob metacharacters is probed literally"
# --literal-pathspecs keeps `app[1]` from being read as a character class.
ws="$(git_ws dotnet-metachars)"
mkdir -p "$ws/app[1]/bin"
touch "$ws/app[1]/App.csproj" "$ws/app[1]/bin/publish.sh"
git -C "$ws" add -f 'app[1]/bin/publish.sh'
assert_absent "$ws" "$ws/app[1]/bin" "tracked bin under a bracketed path is not shadowed"
assert_emits "$ws" "$ws/app[1]/obj" "the untracked sibling obj is still shadowed"

echo "Test: trailing slashes on the workspace argument change nothing"
# shadow-refresh.sh passes its argument through verbatim, and tab completion
# produces `/workspace/<slug>/`.
ws="$(git_ws dotnet-trailing-slash)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/publish.sh"
git -C "$ws" add -f app/bin/publish.sh
assert_absent "$ws/" "$ws/app/bin" "tracked bin is vetoed with a trailing-slash workspace too"
assert_emits "$ws/" "$ws/app/obj" "obj still emitted (and normalized) with a trailing slash"
assert_absent "$ws//" "$ws/app/bin" "tracked bin is vetoed with a doubled trailing slash too"
assert_emits "$ws//" "$ws/app/obj" "obj still emitted with a doubled trailing slash"

echo "Test: a MISSING index fails closed, not as an empty one"
# `ls-files --cached` reads the index, and an absent index reads as an empty one
# with a success status — so the exit code alone cannot tell the two apart.
ws="$(git_ws dotnet-missing-index)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/tool.sh"
git -C "$ws" add -f app/bin/tool.sh
git -C "$ws" -c user.email=t@example.com -c user.name=t commit -qm "seed"
rm -f "$ws/.git/index"
assert_absent "$ws" "$ws/app/bin" "an existing bin is left un-shadowed when the index is missing"
assert_emits "$ws" "$ws/app/obj" "an absent obj is still shadowed"

echo "Test: a fresh repo with nothing staged is not mistaken for a broken one"
# `git init` writes no index until something is staged, so a brand-new repo
# legitimately has none — and nothing can be tracked, so its empty answer is the
# truth. Treating it as broken would withhold the shadows and print an alarm on
# an ordinary "start a new project here".
ws="$(git_ws dotnet-fresh-init)"
mkdir -p "$ws/app/bin" "$ws/app/obj"
touch "$ws/app/App.csproj" "$ws/app/bin/App.dll"
assert_emits "$ws" "$ws/app/bin" "an existing bin is still shadowed in a repo with no index yet"
assert_emits "$ws" "$ws/app/obj" "an existing obj is still shadowed in a repo with no index yet"
assert_stderr_absent "$ws" "could not read the Git index" "no fail-closed alarm for a fresh repo"

echo "Test: an unreadable .git fails CLOSED rather than reading as a non-repo"
# `rev-parse` reports "not a git repository" for an unreadable .git, so the
# existence of the entry — not that probe alone — is what withholds the shadow.
ws="$(git_ws dotnet-unreadable-gitdir)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/publish.sh"
git -C "$ws" add -f app/bin/publish.sh
chmod 000 "$ws/.git"
assert_absent "$ws" "$ws/app/bin" "an existing bin is left un-shadowed when .git is unreadable"
# Companions, as above: the negative alone would also hold if nothing was
# scanned, and it does not distinguish the fail-closed path (which withholds
# only what EXISTS) from the tracked-content veto (which withholds either way).
assert_emits "$ws" "$ws/app/obj" "the absent sibling obj is still shadowed"
# Pinned to the OUTER diagnostic, subject and all.  A bare "could not read the
# Git index for" is also a prefix of the nested wording ("...for the repository
# owning '..."), so the loose form would let a nested-path message satisfy an
# assertion about the workspace's own repository.
assert_stderr "$ws" "could not read the Git index for '$ws'" "the fail-closed reason is announced on stderr"
chmod 755 "$ws/.git"

echo "Test: a DANGLING .git symlink still counts as repository evidence"
# `-e` follows symlinks, so it answers false for a dangling `.git` — and both
# `rev-parse` and `ls-files` fail too, so nothing would be left to stop the
# non-repository fail-OPEN path from shadowing an existing bin without ever
# establishing whether it holds tracked content.  Lexical existence is the test.
ws="$(new_ws dotnet-dangling-gitlink)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/publish.sh"
ln -s "$ws/.git-moved-away" "$ws/.git"
assert_absent "$ws" "$ws/app/bin" "an existing bin is withheld when .git is a dangling symlink"
assert_stderr "$ws" "could not read the Git index for '$ws'" "the dangling-.git fail-closed is announced on stderr"
assert_emits "$ws" "$ws/app/obj" "an absent obj is still shadowed behind a dangling .git"

echo "Test: a dangling .git symlink on a nested ANCESTOR still routes to that repo"
# nested_repo_owns decides which index owns the question by stat'ing ancestors;
# missing a dangling one would fold the candidate into the outer batched query,
# which answers "untracked" for content the outer index cannot see.
ws="$(git_ws dotnet-dangling-nested)"
mkdir -p "$ws/vendor/lib/app/bin"
touch "$ws/vendor/lib/app/App.csproj" "$ws/vendor/lib/app/bin/tool.sh"
ln -s "$ws/vendor/lib/.git-moved-away" "$ws/vendor/lib/.git"
assert_absent "$ws" "$ws/vendor/lib/app/bin" "an existing bin under a dangling nested .git is withheld"
# Paired with a positive assertion so the one above cannot pass vacuously —
# it would also hold if project discovery regressed and the scan found nothing.
assert_emits "$ws" "$ws/vendor/lib/app/obj" "the absent sibling obj is still shadowed"

echo "Test: a dangling .git symlink INSIDE a candidate marks it a checkout"
# Same lexical rule at the third site: app/bin/.git pointing nowhere still means
# app/bin is a repository checkout rather than MSBuild output.
ws="$(git_ws dotnet-dangling-in-bin)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj"
ln -s "$ws/app/bin/.git-moved-away" "$ws/app/bin/.git"
assert_absent "$ws" "$ws/app/bin" "a bin holding a dangling .git symlink is not shadowed"
assert_stderr "$ws" "Git repository or submodule checkout" "the repo-in-bin skip is announced on stderr"
assert_emits "$ws" "$ws/app/obj" "the sibling obj is unaffected"

echo "Test: an undetermined NESTED answer withholds only what exists"
# The nested probe is three-way, like the batched one: "could not determine" must
# not withhold an ABSENT bin/obj — there is nothing there to mask, and that is
# the fresh-clone case the feature exists for.  The outer path already behaves
# this way; collapsing the nested one onto "tracked" made the two disagree.
ws="$(git_ws dotnet-nested-undetermined)"
mkdir -p "$ws/vendor/lib/bin"
touch "$ws/vendor/lib/Lib.csproj" "$ws/vendor/lib/bin/tool.sh"
git -c init.defaultBranch=main init -q "$ws/vendor/lib"
git -C "$ws/vendor/lib" add -f bin/tool.sh
git -C "$ws/vendor/lib" -c user.email=t@example.com -c user.name=t commit -qm "seed"
rm -f "$ws/vendor/lib/.git/index"
assert_absent "$ws" "$ws/vendor/lib/bin" "an existing bin is withheld when the nested index is missing"
assert_emits "$ws" "$ws/vendor/lib/obj" "an absent obj is still shadowed when the nested index is missing"

echo "Test: an undetermined nested answer is not reported as tracked content"
# Saying "contains Git-tracked files" when nothing was established sends an
# operator looking for files that are not there.
assert_stderr "$ws" "could not read the Git index for the repository owning '$ws/vendor/lib/bin'" \
	"the nested fail-closed names the real reason"
assert_stderr_absent "$ws" "contains Git-tracked files" \
	"an undetermined nested answer does not claim tracked content"

echo "Test: a fresh nested repo with no index yet still gets both shadows"
# `git init` inside vendor/lib with nothing staged writes no index; that empty
# answer is the truth, not a failure, exactly as for the workspace's own repo.
ws="$(git_ws dotnet-nested-fresh-init)"
mkdir -p "$ws/vendor/lib/bin"
touch "$ws/vendor/lib/Lib.csproj" "$ws/vendor/lib/bin/Lib.dll"
git -c init.defaultBranch=main init -q "$ws/vendor/lib"
assert_emits "$ws" "$ws/vendor/lib/bin" "an existing bin is shadowed in a fresh nested repo"
assert_emits "$ws" "$ws/vendor/lib/obj" "an absent obj is shadowed in a fresh nested repo"
assert_stderr_absent "$ws" "could not read the Git index" "no fail-closed alarm for a fresh nested repo"

echo "Test: ambient pathspec-mode variables do not disable the scan"
# Any of GIT_*_PATHSPECS makes the explicit --literal-pathspecs fatal, which
# would fail the whole probe closed and silently switch the feature off.
ws="$(git_ws dotnet-pathspec-env)"
mkdir -p "$ws/app/bin" "$ws/other/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/publish.sh" "$ws/other/Other.csproj" "$ws/other/bin/out.dll"
git -C "$ws" add -f app/bin/publish.sh
glob_out="$(GIT_GLOB_PATHSPECS=1 GIT_ICASE_PATHSPECS=1 run_out "$ws")"
if grep -qxF "$ws/app/bin" <<<"$glob_out"; then
	ko "tracked bin was shadowed under GIT_GLOB_PATHSPECS"
else
	ok "tracked bin still vetoed under ambient pathspec-mode variables"
fi
if grep -qxF "$ws/other/bin" <<<"$glob_out"; then
	ok "an untracked bin is still shadowed under ambient pathspec-mode variables"
else
	ko "the scan failed closed under GIT_GLOB_PATHSPECS instead of working"
fi

echo "Test: a bin/ that is itself a repository checkout is never shadowed"
# An initialized submodule or a nested clone at app/bin holds files the
# workspace's own index cannot see, so a .git inside the candidate settles it
# without asking git anything.
ws="$(git_ws dotnet-repo-in-bin)"
mkdir -p "$ws/app"
touch "$ws/app/App.csproj"
git -c init.defaultBranch=main init -q "$ws/app/bin"
assert_absent "$ws" "$ws/app/bin" "a bin/ containing .git is not shadowed"
assert_stderr "$ws" "Git repository or submodule checkout" "repo-in-bin skip is announced on stderr"
assert_emits "$ws" "$ws/app/obj" "the sibling obj is unaffected"

echo "Test: a plain FILE named bin/obj is skipped, not emitted"
ws="$(new_ws dotnet-file-named-bin)"
mkdir -p "$ws/app"
touch "$ws/app/App.csproj" "$ws/app/bin"
assert_absent "$ws" "$ws/app/bin" "a regular file named bin is not emitted"
assert_stderr "$ws" "not a directory" "non-directory skip is announced on stderr"
assert_emits "$ws" "$ws/app/obj" "the sibling obj is still emitted"

echo "Test: an inherited GIT_DIR cannot redirect the tracked-content probe"
# shadow-refresh.sh runs from whatever environment invoked it — a Git hook has
# GIT_DIR/GIT_INDEX_FILE set, and `git -C` does not override them.
ws="$(git_ws dotnet-hostile-gitdir)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/publish.sh"
git -C "$ws" add -f app/bin/publish.sh
decoy="$(new_ws gitdir-decoy)"
git -c init.defaultBranch=main init -q "$decoy"
hostile_out="$(GIT_DIR="$decoy/.git" GIT_INDEX_FILE="$decoy/.git/index" run_out "$ws")"
if grep -qxF "$ws/app/bin" <<<"$hostile_out"; then
	ko "an inherited GIT_DIR redirected the probe and the tracked bin was shadowed"
else
	ok "tracked bin still vetoed under a hostile GIT_DIR"
fi
if grep -qxF "$ws/app/obj" <<<"$hostile_out"; then
	ok "the untracked sibling obj is still emitted under a hostile GIT_DIR"
else
	ko "obj went missing under a hostile GIT_DIR"
fi

echo "Test: an unreadable index fails CLOSED for directories that exist"
# Cannot tell disposable output from tracked content, and masking tracked files
# loses edits — so leave the existing ones alone rather than guess.
ws="$(git_ws dotnet-broken-index)"
mkdir -p "$ws/app/bin"
touch "$ws/app/App.csproj" "$ws/app/bin/publish.sh"
git -C "$ws" add -f app/bin/publish.sh
printf 'not an index' >"$ws/.git/index"
assert_absent "$ws" "$ws/app/bin" "an existing bin is left un-shadowed when the index is unreadable"
assert_emits "$ws" "$ws/app/obj" "an absent obj is still shadowed (withholding it would break the fresh-clone case)"
assert_stderr "$ws" "could not read the Git index for '$ws'" "the fail-closed decision is announced on stderr"

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
