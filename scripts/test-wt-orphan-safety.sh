#!/usr/bin/env bash
# Unit + integration tests for safe worktree-orphan handling (task 017).
#
# Focus: with DURABLE worktree metadata, a recycled worktree is reused; a dir
# that is NOT a live worktree (partial create, or a pre-durable-metadata dir
# whose tmpfs .git/worktrees was lost) must be reaped SAFELY — empty dirs
# deleted, NON-EMPTY dirs preserved (moved to a quarantine dir), never rm -rf'd.
# This guards the acceptance criterion that the sole surviving copy of dirty
# work is never deleted just because its git metadata disappeared.
#
# Covers:
#   * wt-common.sh wt_reap_orphan_dir directly (empty -> pruned, non-empty ->
#     quarantined with contents preserved). wt-bootstrap's prune loop uses this
#     exact function, so its safety is covered here without the mountpoint checks
#     wt-bootstrap needs (those require a real image + volumes — see the smoke).
#   * wt-enter and wt-remove end-to-end against a real temp git repo, with a
#     dead-metadata orphan simulated by deleting .git/worktrees/<slug>.
#   * wt-remove's OPERATION-IN-PROGRESS guard (task 039 found the hole, task 057
#     closed it): the helper promises to remove a worktree but never work, and
#     `git status --porcelain` is EMPTY for a bisect, a `git am`, a rebase paused
#     at a `break`, a cherry-pick/revert SEQUENCE stopped on an empty patch, a
#     conflicted `git notes merge` (whose conflict lives entirely in the admin
#     dir, so `git status` says nothing at all), and any conflict resolved back to
#     HEAD's content — so each of those was, or could have been, deleted silently.
#     Every state git can leave behind is fabricated with REAL git and pinned: the
#     removal must be refused WITH and WITHOUT --force, the worktree and its state
#     files must survive untouched, the refusal must NAME the operation, and it
#     must pass the same destructive_advice detector wt-enter's messages do —
#     naming `--abort` or `bisect reset` is the same loss by another route. The
#     fail-safe direction is pinned too (metadata that cannot be read ⇒ refuse,
#     the opposite of wt-enter's bias, and now including a ref LOOKUP that dies
#     rather than answers), as is the absence of FALSE refusals: a
#     clean worktree is still removed, --force still reaches git once the clean
#     checks pass, a bisect in the MAIN checkout does not leak into a task
#     worktree's verdict, BRANCHES named after the state markers are data rather
#     than state (which is what forbids a DWIMing `rev-parse` probe), and a notes
#     merge CONCLUDED with either --commit or
#     --abort still removes cleanly despite the NOTES_MERGE_WORKTREE dir git
#     leaves behind (which is why the guard keys on the markers, not that dir).
#     The guarded states are pinned under BOTH ref backends, because four of the
#     markers — CHERRY_PICK_HEAD, REVERT_HEAD, NOTES_MERGE_PARTIAL and
#     NOTES_MERGE_REF — are pseudo-REFS that leave no file on disk at all under
#     `--ref-format=reftable`, where a file-only probe silently removed the
#     worktree. Those cases SKIP (counted separately, never silently) on a git
#     too old to create a reftable repo.
#     The one deliberate NON-guard that is neither a refusal nor a removal is
#     pinned too: a `locked` worktree is left entirely to git, which declines a
#     single --force exactly as vanilla does. And the SQUASH_MSG exclusion is
#     pinned from BOTH sides, since it is the one place the guard set stops short
#     of a state file that looks like an operation: git's own verdict on a squash
#     merge abandoned with `git restore` (no merge to abort, a fresh merge
#     starts) despite the surviving SQUASH_MSG, that such a worktree is still
#     REMOVED — guarding it would false-refuse — that `git checkout HEAD -- .`
#     reaches that same stale-marker-with-a-clean-tree state for a squash that
#     modified a TRACKED file (a second false-refusal shape, on its own fixture
#     because the add-a-file fixture cannot reach it), and the cost all that
#     buys, a no-net-change squash with a clean status being removed with only
#     its pending message lost.
#   * wt-enter's branch-conflict diagnosis (task 039): when <branch> is already
#     checked out, the error must name the blocking worktree — and say plainly
#     when that blocker is the SHARED primary checkout, the case agents keep
#     misreading as a stale worktree — while stdout stays empty on failure. The
#     blocker is also named when an interrupted rebase or a bisect leaves the
#     holding worktree reporting as `detached`. The diagnosis stays SILENT when
#     the blocker git names is wt-enter's own destination, so git's prune/remove
#     advice stands.
#   * that the diagnosis NEVER advises discarding the blocking worktree OR the
#     operation in flight inside it, in ANY of the states it can be found in — an
#     idle one, a rebase, a bisect, an interrupted revert, one whose state cannot
#     even be read. wt-enter names the blocker, points at inspection and at the
#     worktree's owner, and stops; the one remedy it offers is git's own
#     `worktree prune`, for a blocker whose directory is already gone — and it
#     WITHHOLDS even that when the record is LOCKED, which git skips when pruning
#     (the directory is then deliberately absent, not stale).
#   * wt-common.sh wt_branch_held_by_operation against fabricated operation
#     state, pinned to what real git does with the same state — it decides
#     whether a DETACHED worktree is nevertheless identified as the blocker.
#   * wt-common.sh wt_worktree_gitdir locating that state from the COMMON
#     repository metadata rather than from inside the worktree: a blocker whose
#     directory has been DELETED still holds its branch and is still prunable, and
#     is exactly the one no probe run inside it can reach; the main working tree
#     resolves to the common dir; an unregistered path answers "unknown".
#   * wt-common.sh wt_worktree_for_branch reporting the blocking worktree's path
#     (and only that) for both porcelain record kinds, and wt_primary_checkout
#     naming the MAIN working tree (pinned directly: the integration case cannot
#     tell a broken implementation apart, since in an ordinary repo the main tree
#     is the repo root wt-enter already knows).
#   * wt-common.sh wt_read_path REFUSING an out-variable name that collides with
#     its own `__wt_`-prefixed locals — non-zero and silent — because obeying it
#     writes the answer into the helper's own local and reports success over the
#     caller's untouched (stale) variable, the one failure shape a caller cannot
#     branch on. Ordinary names must keep working.
#   * the non-destruction DETECTOR itself (destructive_advice below), because
#     every case above delegates to it: a hostile dynamic value — a branch named
#     `abort`, `force`, `remove`, `hard`, `rf` or `restore`, or a name/path
#     carrying glob metacharacters — must still be treated as data, WITHOUT
#     disarming the detector for a separate destructive command in the same
#     message.
#   * that a worktree path containing a NEWLINE survives the porcelain read
#     whole, at unit level for both resolvers and end-to-end through wt-enter —
#     a line-based read answers the path's prefix, which is not on disk, so the
#     live blocker gets misreported as a stale record and 'worktree prune'
#     recommended for it. A path ENDING in a newline is pinned the same way and
#     covers the other half of that defect: the answer's own handoff, where a
#     command substitution would strip the byte the `-z` read preserved. Both
#     halves are pinned for a DETACHED blocker too, where the path is what the
#     worktree's own operation state has to be located by, and losing the byte
#     costs the entire diagnosis instead of degrading it.
#   * wt-common.sh wt_worktree_locked, which is what lets that withholding
#     happen: it reads the porcelain `locked` attribute, keeps a free-form
#     multi-line lock reason inside its own record, and degrades to "not locked"
#     when git cannot be asked.
#   * that git's fatal status (128) is PROPAGATED rather than flattened, and that
#     every path wt-enter echoes back is shell-quoted — inside the commands it
#     suggests, so advice about a worktree under a spaced path stays pasteable
#     and safe to paste, AND in its own prose, so a path carrying terminal
#     control bytes cannot rewrite what the reader sees. Pinned once more under
#     bash's `xpg_echo`, arriving from an exported BASHOPTS: `echo` would re-expand
#     the escapes `printf %q` just produced and hand the terminal the raw byte
#     back, so the diagnostics have to be emitted with `printf`.
#
# WHY each expectation is what it is (git's own precedence, its object-id
# parsing, its bare stat()) is documented once, in docker/shared/wt-common.sh.
# This file pins the OUTCOMES and deliberately does not restate the rationale.
#
# Runs directly against the repo copies — no image build needed. Requires bash
# and git on PATH (present in the agent image).
#
# The smoke harness re-runs this against the BAKED helpers by pointing the three
# override vars at /usr/local/bin (matching how test-sensitive-host-path.sh is
# smoke-driven): POWBOX_WT_COMMON / POWBOX_WT_ENTER / POWBOX_WT_REMOVE. wt-enter
# and wt-remove locate wt-common.sh via their own sibling dir, so pointing them at
# the baked binaries automatically exercises the baked wt-common too.
#
# Usage: scripts/test-wt-orphan-safety.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$SCRIPT_DIR/../docker/shared"
WT_COMMON="${POWBOX_WT_COMMON:-$SHARED/wt-common.sh}"
WT_ENTER="${POWBOX_WT_ENTER:-$SHARED/wt-enter}"
WT_REMOVE="${POWBOX_WT_REMOVE:-$SHARED/wt-remove}"

for f in "$WT_COMMON" "$WT_ENTER" "$WT_REMOVE"; do
	[ -f "$f" ] || {
		echo "FATAL: missing $f" >&2
		exit 1
	}
done

pass=0
fail=0
skipped=0
ok() {
	pass=$((pass + 1))
	echo "ok - $1"
}
# skip <label> — the ONE thing a case may do instead of passing or failing, and
# only for a capability the running git does not have (the `reftable` ref backend,
# git 2.45+). It is counted and reported separately so a suite that quietly
# stopped exercising the reftable cases cannot read as a clean run.
skip() {
	skipped=$((skipped + 1))
	echo "SKIP - $1"
}
no() {
	fail=$((fail + 1))
	echo "NOT OK - $1" >&2
}

# destructive_advice <errfile> [<dynamic-value>...] — echo a `miss` fragment when
# wt-enter's stderr points the caller at anything that could DISCARD the blocking
# worktree or the in-flight work inside it. This is the invariant every
# branch-conflict case below re-checks, because the class of bug it guards (advice
# that throws away state `git status` does not show) has recurred once per state
# git can leave behind.
#
# "Clear the operation yourself" counts, not just "delete the worktree": every
# `rebase|am|cherry-pick|revert --abort` discards the conflict resolution done so
# far, and `reset --hard`, `checkout -f`, `clean -fd`, `restore`, `switch -f` and
# `branch -D` each discard work the blocking worktree may be the only copy of. So
# the patterns below are command shapes. Prose is deliberately NOT matched (a grep
# cannot tell "wt-enter will not discard anything" from "discard it"); wt-enter
# states its refusals in prose and offers remedies as commands, so command shapes
# are where advice actually lives. Short flags are matched as CLUSTERS rather than
# whole tokens, so `-fd`, `-df`, `-rf` and `-fx` are all caught by the one
# pattern, and the classes spell both cases rather than leaning on `grep -i`.
# Subcommands are matched WITHOUT requiring a leading `git`, because the real
# invocation carries `-C <path>` in between (`git -C … restore --worktree .`);
# `abort` and `restore` are matched as bare words for the same reason, and can be,
# now that the values wt-enter echoes back are neutralised first.
#
# Every DYNAMIC value wt-enter echoes back — the branch name, the blocker path,
# the repo root — is neutralised BEFORE matching, because those are data, not
# advice: a branch legitimately named `abort-retry` or `force-push-fix`, or a
# worktree path containing `--force`, must not be read as a suggested command.
# Callers therefore pass every value that reached the message. Fixed message text
# and git's own diagnostics stay in scope: whoever printed it, a command that
# could destroy the blocker is something a human should look at.
#
# Neutralisation is ANCHORED to the positions a dynamic value can actually be
# emitted in, never applied as a free substring replacement over the whole text.
# A free replacement is a trapdoor: it deletes the value wherever the characters
# happen to line up, so a branch named `abort` would erase the `abort` out of a
# genuinely suggested `rebase --abort`, `force` out of `--force`, `remove` out of
# `worktree remove`, and `rf` out of `rm -rf` — silently turning the detector off
# for exactly the advice it exists to catch. The anchors are the three shapes
# observed in the real messages (both wt-enter's own lines and git's fatals):
#
#   '<value>'        single-quoted prose — git's `fatal: '<branch>' is already
#                    used by worktree at '<path>'`, and wt-enter's `branch
#                    '<branch>'` / `once '<branch>' is free`
#   at <value>       the blocker path in wt-enter's prose (paths only), which it
#                    shell-quotes there too
#   -C <value>       the argument of a suggested `git -C … status`, in the bare
#                    and the shell-quoted spelling wt-enter actually prints
#
# Each anchor removes the value TOGETHER with its surrounding context, so for a
# destructive pattern to be hidden it would have to sit inside that context —
# i.e. inside the dynamic value itself, which is the intended exemption. Text
# belonging to a separate command is unreachable. The trade is one-directional
# and safe: should wt-enter ever emit a value in some fourth position, the value
# is simply NOT neutralised there, which can only produce a false positive — a
# loud test failure — and never a silent miss.
#
# That containment depends on the anchors matching LITERALLY, and they do: in
# `${text//"…$value…"/…}` the pattern word is QUOTED, which strips every glob
# character in it of its meaning, so `[`, `*` and `?` inside a branch name or a
# worktree path match only themselves. Were the pattern left unquoted, `*` would
# match across the surrounding context — greedily, and across newlines — and one
# `*` in a blocker path could swallow a destructive command printed between two
# occurrences of it. Quoting is therefore load-bearing, not tidiness, and the
# pinning case below is what keeps it that way.
#
# The single exemption is git's own `git worktree prune`, which drops a stale
# record for a directory that is already gone and can destroy nothing. It is
# applied by deleting just that two-word phrase before scanning — never by
# skipping the line that carries it — so a message naming `prune` is still checked
# for everything else it says.
#
# The detector is used on wt-remove's refusals too (task 057), which means one
# more piece of non-advice has to be taken out of scope: the SPEAKER LABEL each
# helper prefixes its own lines with. `wt-remove` is itself one of the patterns —
# it is exactly what wt-enter must never point at — so every line wt-remove
# prints would otherwise trip the detector on its own name. Only the anchored
# `^<helper>: ` prefix is removed, once per line, so a `wt-remove <slug>` offered
# as a COMMAND anywhere in the text is still caught; the label is stripped
# whoever emitted it, since no helper names another one that way.
destructive_advice() {
	local errfile="$1" text value quoted
	shift
	text="$(cat -- "$errfile" 2>/dev/null)" || return 0
	for value in "$@"; do
		[ -n "$value" ] || continue
		# Each anchor is tried in BOTH spellings: wt-enter prints these values
		# bare in prose and shell-quoted (`shq`, itself `printf %q`) inside the
		# commands it suggests, and for a plain value the two coincide.
		printf -v quoted '%q' "$value"
		text="${text//"'$value'"/'<dynamic>'}"
		text="${text//"'$quoted'"/'<dynamic>'}"
		text="${text//"-C $value"/-C <dynamic>}"
		text="${text//"-C $quoted"/-C <dynamic>}"
		# Only a path is ever printed after `at `, and anchoring this one to
		# absolute paths keeps a short branch name out of the substitution. Both
		# spellings again: wt-enter shell-quotes the path in this position too
		# (the two coincide for a plain path), and the bare spelling stays in the
		# list so the anchor keeps holding for any message that does not.
		case "$value" in
		/*)
			text="${text//"at $value"/at <dynamic>}"
			text="${text//"at $quoted"/at <dynamic>}"
			;;
		esac
	done
	printf '%s\n' "$text" |
		LC_ALL=C sed -E 's/^(wt-enter|wt-remove|wt-bootstrap): //' |
		LC_ALL=C sed 's/worktree[[:space:]][[:space:]]*prune//g' |
		grep -qiE 'wt-remove|worktree[[:space:]]+remove|\brm[[:space:]]+-[a-zA-Z]*[rRfF]|\babort\b|reset[[:space:]]+--hard|checkout[[:space:]]+-[a-zA-Z]*[fF]|checkout[[:space:]]+--[[:space:]]|switch[[:space:]]+-[a-zA-Z]*[fF]|--discard-changes\b|\brestore\b|clean[[:space:]]+-[a-zA-Z]*[fFdDxX]|branch[[:space:]]+-[dD]\b|bisect[[:space:]]+reset\b|--skip\b|--quit\b|--delete\b|--force\b' &&
		echo " destructive-advice"
	return 0
}

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

export CONTAINER_NAME="testcont"

# ---------------------------------------------------------------------------
# Unit: destructive_advice ITSELF. Every branch-conflict case below leans on it,
# so a blind spot in the detector silently disarms all of them — and the defect
# class it guards has recurred often enough on this branch that "the net looks
# fine" is not evidence.
#
# The blind spot it can plausibly grow is over-broad neutralisation. Neutralising
# a dynamic value ANYWHERE its characters occur would delete the matching text
# out of a genuinely destructive command printed elsewhere in the same message: a
# branch named `abort` disarms `rebase --abort`, `force` disarms `--force`,
# `remove` disarms `worktree remove`, `hard` disarms `reset --hard`, `rf` disarms
# `rm -rf`, `restore` disarms `restore --worktree`. None of the fixtures below
# happens to use such a name today, which is precisely why this is pinned here
# rather than left to be discovered by the fixture that eventually does.
#
# Each hostile name is checked in BOTH directions, since either alone is
# trivially satisfiable — neutralise nothing and the first passes, neutralise
# everything and the second does:
#   1. it is still treated as DATA where wt-enter echoes it back (no false alarm)
#   2. a separate destructive command in the same message is STILL caught
# ---------------------------------------------------------------------------
DA_ERR="$WORK_ROOT/da.err"
DA_BLOCKER="/w/.worktrees/$CONTAINER_NAME/task-a"
DA_ROOT="/w"

# da_message <branch> [<extra-line>] — the real branch-conflict message shape
# (git's fatal, then wt-enter's diagnosis), optionally plus one more line. The
# branch name lands in every position the real messages put it in.
da_message() {
	{
		printf "Preparing worktree (checking out '%s')\n" "$1"
		printf "fatal: '%s' is already used by worktree at '%s'\n" "$1" "$DA_BLOCKER"
		printf "wt-enter: branch '%s' is already checked out in another worktree at %s; git refuses to check one branch out twice.\n" "$1" "$DA_BLOCKER"
		printf "wt-enter: look at it yourself: 'git -C %s status', or coordinate with whoever owns that worktree. Rerun wt-enter once '%s' is free.\n" "$DA_BLOCKER" "$1"
		[ -z "${2:-}" ] || printf '%s\n' "$2"
	} >"$DA_ERR"
}

# <hostile branch>|<short label>|<a destructive line the same message also carries>
while IFS='|' read -r hostile label destructive; do
	[ -n "$hostile" ] || continue
	da_message "$hostile"
	if [ -z "$(destructive_advice "$DA_ERR" "$DA_BLOCKER" "$DA_ROOT" "$hostile" task-b)" ]; then
		ok "a branch named '$hostile' is data, not advice"
	else
		no "destructive_advice false-alarms on a branch merely named '$hostile'"
	fi
	da_message "$hostile" "$destructive"
	if [ -n "$(destructive_advice "$DA_ERR" "$DA_BLOCKER" "$DA_ROOT" "$hostile" task-b)" ]; then
		ok "a suggested '$label' is caught even beside a branch named '$hostile'"
	else
		no "a suggested '$label' was HIDDEN by neutralising a branch named '$hostile'"
	fi
done <<EOF
abort|rebase --abort|wt-enter: then run 'git -C $DA_BLOCKER rebase --abort' to clear it.
restore|restore --worktree|wt-enter: then run 'git -C $DA_BLOCKER restore --worktree --staged .' to clear it.
force|checkout --force|wt-enter: then run 'git -C $DA_BLOCKER checkout --force main' to free it.
remove|worktree remove|wt-enter: then run 'git -C $DA_BLOCKER worktree remove' to free it.
hard|reset --hard|wt-enter: then run 'git -C $DA_BLOCKER reset --hard' to clear it.
rf|rm -rf|wt-enter: then run 'rm -rf $DA_BLOCKER' to free it.
EOF

# A dynamic value carrying GLOB metacharacters — a legal branch name, and a legal
# path. Same two directions, but the failure mode being pinned is the other one:
# an unquoted pattern would make `*` match across the anchor's context, greedily
# and across newlines, so the `-C <blocker>` anchor would run from the FIRST
# `-C /w/wt` to the LAST `/end` and take the `reset --hard` between them with it.
# Every branch-conflict case above delegates to this detector, so that would
# disarm all of them at once, silently, for any repository checked out under a
# path with a `*`, `?` or `[` in it.
DA_GLOB_BLOCKER='/w/wt*/end'
da_glob_message() {
	{
		printf "wt-enter: branch '%s' is already checked out in another worktree at %s; git refuses to check one branch out twice.\n" "$1" "$DA_GLOB_BLOCKER"
		printf "wt-enter: look at it yourself: 'git -C %s status', or coordinate with whoever owns that worktree.\n" "$DA_GLOB_BLOCKER"
		[ -z "${2:-}" ] || printf '%s\n' "$2"
		# A second occurrence of the anchor, AFTER the (optional) extra line, so a
		# greedy match has something to run to.
		printf "wt-enter: running this task on a different branch avoids the conflict entirely (-C /w/wtB/end).\n"
	} >"$DA_ERR"
}

da_glob_message 'b[a-z]*'
if [ -z "$(destructive_advice "$DA_ERR" "$DA_GLOB_BLOCKER" "$DA_ROOT" 'b[a-z]*' task-b)" ]; then
	ok "glob metacharacters in a branch name and a blocker path are data, not advice"
else
	no "destructive_advice false-alarms on glob metacharacters in a branch name or path"
fi

da_glob_message 'b[a-z]*' "wt-enter: then run 'git -C /w/wtA/end reset --hard' to clear it."
if [ -n "$(destructive_advice "$DA_ERR" "$DA_GLOB_BLOCKER" "$DA_ROOT" 'b[a-z]*' task-b)" ]; then
	ok "a suggested 'reset --hard' survives neutralising glob-bearing dynamic values"
else
	no "a suggested 'reset --hard' was HIDDEN by a glob metacharacter in a dynamic value (unquoted substitution pattern?)"
fi

# A blocker path that must be QUOTED to be printed at all — it contains a space —
# and whose own bytes read as a destructive flag. wt-enter shell-quotes the path
# in the `at ` position too, so that anchor has to know the quoted spelling:
# without it, a worktree somebody legitimately named `wt --force` raises a false
# alarm on every branch-conflict case at once. (git's own fatal prints the same
# path bare inside single quotes, which the first anchor already covers — so this
# pins the second spelling specifically.)
DA_Q_BLOCKER='/w/wt --force/end'
{
	printf "fatal: '%s' is already used by worktree at '%s'\n" nb "$DA_Q_BLOCKER"
	printf "wt-enter: branch '%s' is already checked out in another worktree at %q; git refuses to check one branch out twice.\n" nb "$DA_Q_BLOCKER"
} >"$DA_ERR"
if [ -z "$(destructive_advice "$DA_ERR" "$DA_Q_BLOCKER" "$DA_ROOT" nb)" ]; then
	ok "a blocker path needing shell-quoting is data in the 'at' position too"
else
	no "destructive_advice false-alarms on a shell-quoted blocker path in the 'at' position"
fi

# The SPEAKER LABEL is not advice: wt-remove prefixes every line it prints with
# its own name, which is itself one of the detector's patterns. Both directions
# again, because the strip that makes wt-remove's refusals checkable at all is
# exactly the kind of edit that can quietly disarm the pattern it touches: a
# `wt-remove <slug>` offered as a COMMAND — the thing wt-enter must never point
# at — has to stay caught, wherever in the line it sits.
{
	printf "wt-remove: a bisect (BISECT_LOG) is in progress in the worktree at %s; nothing was changed.\n" "$DA_BLOCKER"
	printf "wt-remove: look at it yourself: 'git -C %s status'.\n" "$DA_BLOCKER"
} >"$DA_ERR"
if [ -z "$(destructive_advice "$DA_ERR" "$DA_BLOCKER" "$DA_ROOT" task-a)" ]; then
	ok "a helper's own 'wt-remove:' line prefix is a speaker label, not advice"
else
	no "destructive_advice false-alarms on wt-remove's own line prefix"
fi
{
	printf "wt-enter: branch 'task-a' is already checked out in another worktree at %s.\n" "$DA_BLOCKER"
	printf "wt-enter: run 'wt-remove task-a' to free it.\n"
} >"$DA_ERR"
if [ -n "$(destructive_advice "$DA_ERR" "$DA_BLOCKER" "$DA_ROOT" task-a)" ]; then
	ok "a suggested 'wt-remove <slug>' is still caught after the line-prefix strip"
else
	no "the speaker-label strip HID a suggested 'wt-remove <slug>' command"
fi

# ---------------------------------------------------------------------------
# Unit: wt_reap_orphan_dir
# ---------------------------------------------------------------------------
# shellcheck source=docker/shared/wt-common.sh
. "$WT_COMMON"

# Empty dir -> pruned (deleted).
u1="$WORK_ROOT/u1/.worktrees/$CONTAINER_NAME/empty"
mkdir -p "$u1"
out="$(wt_reap_orphan_dir "$u1")"
if [ "$out" = "pruned" ] && [ ! -e "$u1" ]; then
	ok "empty orphan is pruned and removed"
else
	no "empty orphan: out='$out' exists=$([ -e "$u1" ] && echo yes || echo no)"
fi

# Non-empty dir -> quarantined; contents preserved; original gone.
u2root="$WORK_ROOT/u2"
u2="$u2root/.worktrees/$CONTAINER_NAME/dirty"
mkdir -p "$u2"
echo "precious uncommitted work" >"$u2/UNSAVED.txt"
out="$(wt_reap_orphan_dir "$u2")"
dest="${out#quarantined:}"
dest_ok=false
case "$dest" in "$u2root/.worktrees/.orphaned/$CONTAINER_NAME/dirty."*) dest_ok=true ;; esac
case "$out" in
quarantined:*)
	if [ ! -e "$u2" ] &&
		[ -f "$dest/UNSAVED.txt" ] &&
		[ "$(cat "$dest/UNSAVED.txt")" = "precious uncommitted work" ] &&
		[ "$dest_ok" = true ]; then
		ok "non-empty orphan is quarantined with contents preserved"
	else
		no "non-empty orphan quarantine mismatch: dest='$dest'"
	fi
	;;
*)
	no "non-empty orphan not quarantined: out='$out'"
	;;
esac

# ---------------------------------------------------------------------------
# Integration helpers
# ---------------------------------------------------------------------------
git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

# make_repo <name> [<git init flag>...] -> echoes ROOT of a fresh repo with one
# commit. The extra flags exist for `--ref-format=reftable`, which is what makes
# four of the guarded state markers pseudo-refs with no file on disk at all.
make_repo() {
	local root="$WORK_ROOT/$1"
	shift
	mkdir -p "$root"
	git_quiet -C "$root" init -q "$@"
	echo seed >"$root/seed.txt"
	git_quiet -C "$root" add -A
	git_quiet -C "$root" commit -qm init
	echo "$root"
}

# Does this git support the `reftable` ref backend (2.45+)? The cases that need
# it are SKIPPED rather than failed when it does not — the suite runs on the
# host as well as in the image (commands/smoke-test.sh Stage 0c/0d), and an
# older host git can no more create a reftable repo than wt-remove can meet one.
REFTABLE_OK=""
if git_quiet -C "$WORK_ROOT" init -q --ref-format=reftable "$WORK_ROOT/.reftable-probe" >/dev/null 2>&1 &&
	[ "$(git -C "$WORK_ROOT/.reftable-probe" rev-parse --show-ref-format 2>/dev/null)" = reftable ]; then
	REFTABLE_OK=1
fi
rm -rf "$WORK_ROOT/.reftable-probe"

# break_metadata <root> <slug> — simulate a recycle that lost tmpfs .git/worktrees
# metadata: delete the admin dir so the working tree's .git pointer dangles.
break_metadata() {
	rm -rf "$1/.git/worktrees/$2"
}

# Sentinel for the resolver cases below: pre-set the out-variable before each call
# so "left untouched" stays distinguishable from "answered empty".
UNSET_MARK='(no answer)'

# ---------------------------------------------------------------------------
# Unit: wt_branch_held_by_operation must read a DETACHED worktree's operation
# state the way GIT reads it, because git is what decides whether the branch may
# be checked out again. Each case states the fabricated state and what real git
# does with it (ALLOWS / REFUSES a second checkout of the same branch); the
# reasoning is in wt-common.sh.
# ---------------------------------------------------------------------------
RU="$(make_repo ru)"
git_quiet -C "$RU" branch foo
git_quiet -C "$RU" worktree add -q --detach "$RU/w" >/dev/null 2>&1
GDU="$RU/.git/worktrees/w"

# `git am` (rebase-apply + `applying`) beside a stale rebase-merge: git ALLOWS.
mkdir -p "$GDU/rebase-merge" "$GDU/rebase-apply"
printf 'refs/heads/foo\n' >"$GDU/rebase-merge/head-name"
printf 'refs/heads/foo\n' >"$GDU/rebase-apply/head-name"
: >"$GDU/rebase-apply/applying"
if wt_branch_held_by_operation "$RU" "$RU/w" foo; then
	no "a git am beside a stale rebase-merge must not count as holding the branch (git allows the checkout)"
else
	ok "operation state honours git's rebase-apply-before-rebase-merge precedence"
fi
rm -rf "$GDU/rebase-merge" "$GDU/rebase-apply"

# A real apply-backend rebase (no `applying` marker): git REFUSES.
mkdir -p "$GDU/rebase-apply"
printf 'refs/heads/foo\n' >"$GDU/rebase-apply/head-name"
if wt_branch_held_by_operation "$RU" "$RU/w" foo; then
	ok "an apply-backend rebase is recognised as holding the branch"
else
	no "apply-backend rebase not recognised as holding the branch"
fi
rm -rf "$GDU/rebase-apply"

# NON-directory rebase-apply beside a rebase-merge naming the branch: git stops
# at the apply backend, finds no head-name, and ALLOWS.
mkdir -p "$GDU/rebase-merge"
printf 'refs/heads/foo\n' >"$GDU/rebase-merge/head-name"
printf 'junk\n' >"$GDU/rebase-apply"
if wt_branch_held_by_operation "$RU" "$RU/w" foo; then
	no "a non-directory rebase-apply must stop the scan like git's stat() does (git allows the checkout)"
else
	ok "a non-directory rebase-apply degrades to unknown instead of falling through"
fi
rm -f "$GDU/rebase-apply"

# DANGLING-SYMLINK rebase-apply: stat() follows and fails, so git falls through
# to rebase-merge and REFUSES.
ln -s /nonexistent-rebase-apply-target "$GDU/rebase-apply"
if wt_branch_held_by_operation "$RU" "$RU/w" foo; then
	ok "a dangling-symlink rebase-apply falls through to rebase-merge, as stat() does"
else
	no "a dangling-symlink rebase-apply must not hide the rebase-merge state (git refuses the checkout)"
fi
rm -rf "$GDU/rebase-apply" "$GDU/rebase-merge"

# BISECT_START in refs/heads/ form (git writes the bare name but strips the
# prefix on read): git REFUSES.
: >"$GDU/BISECT_LOG"
printf 'refs/heads/foo\n' >"$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU" "$RU/w" foo; then
	ok "a BISECT_START written in refs/heads/ form is recognised (git strips the prefix too)"
else
	no "BISECT_START in refs/heads/ form not recognised as holding the branch"
fi

# A bisect from a detached HEAD records the object id; git abbreviates it before
# comparing, so it can never match a branch of that name (and a 40-hex refname is
# unusable in git anyway). Comparing the raw value would be wrong either way.
HEXB=0123456789abcdef0123456789abcdef01234567
printf '%s\n' "$HEXB" >"$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU" "$RU/w" "$HEXB"; then
	no "a full object id in BISECT_START must not match a same-named branch"
else
	ok "a full object id in BISECT_START is treated as a detached start, not a branch"
fi

# get_oid_hex() is CASE-INSENSITIVE: a mixed-case object id is a detached start.
printf '%s\n' "0123456789ABCDEF0123456789abcdef01234567" >"$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU" "$RU/w" "0123456789ABCDEF0123456789abcdef01234567"; then
	no "a mixed-case object id in BISECT_START must not match a same-named branch"
else
	ok "object-id recognition in BISECT_START is case-insensitive, as git's is"
fi

# 41+ hex digits, or 40 with trailing junk: an object id to git yet a legal
# branch name — git ALLOWS the second checkout of the same-named branch.
for oidish in \
	0123456789abcdef0123456789abcdef0123456789abc \
	0123456789abcdef0123456789abcdef01234567zz; do
	printf '%s\n' "$oidish" >"$GDU/BISECT_START"
	if wt_branch_held_by_operation "$RU" "$RU/w" "$oidish"; then
		no "BISECT_START '$oidish' (${#oidish} chars) must not match a same-named branch (git allows the checkout)"
	else
		ok "a ${#oidish}-char BISECT_START opening with a full object id is treated as an id, not a branch"
	fi
done

# Below the hash width a hex string is just a branch name: git REFUSES. The
# threshold must not over-reach and lose a real diagnosis.
HEX39=0123456789abcdef0123456789abcdef0123456
printf '%s\n' "$HEX39" >"$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU" "$RU/w" "$HEX39"; then
	ok "a hex branch name shorter than the hash width is still recognised as held"
else
	no "a 39-hex branch name in BISECT_START must still count as holding the branch"
fi

# git probes bisect INDEPENDENTLY of the rebase state, so a broken rebase entry
# must not mask a live bisect: git REFUSES.
printf 'refs/heads/foo\n' >"$GDU/BISECT_START"
printf 'junk\n' >"$GDU/rebase-apply"
if wt_branch_held_by_operation "$RU" "$RU/w" foo; then
	ok "a non-directory rebase-apply does not mask a live bisect"
else
	no "a live bisect must still be recognised beside a non-directory rebase-apply"
fi
rm -f "$GDU/rebase-apply"

# Unreadable state must degrade to "unknown" (never held) for a DETACHED record,
# so the caller falls back to git's own error instead of guessing.
rm -f "$GDU/BISECT_START"
mkdir -p "$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU" "$RU/w" foo; then
	no "an unreadable BISECT_START must degrade to unknown, not report the branch as held"
else
	ok "unreadable operation state degrades to unknown"
fi
rm -rf "$GDU/BISECT_LOG" "$GDU/BISECT_START"

# A worktree that lost its own .git pointer still satisfies `rev-parse`, because
# task worktrees sit INSIDE the main working tree — the answer then describes the
# ENCLOSING repo, whose operation state belongs to a different checkout. Reading
# it as the worktree's own would identify a blocker that git is not blocking on.
RO="$(make_repo ro)"
git_quiet -C "$RO" worktree add -q --detach "$RO/.worktrees/$CONTAINER_NAME/inside" >/dev/null 2>&1
rm -f "$RO/.worktrees/$CONTAINER_NAME/inside/.git"
mkdir -p "$RO/.git/rebase-merge"
printf 'refs/heads/main\n' >"$RO/.git/rebase-merge/head-name"
if git -C "$RO/.worktrees/$CONTAINER_NAME/inside" rev-parse --absolute-git-dir >/dev/null 2>&1; then
	if wt_branch_held_by_operation "$RO" "$RO/.worktrees/$CONTAINER_NAME/inside" main; then
		no "a worktree without its .git pointer must not have the ENCLOSING repo's state read as its own"
	else
		ok "operation state is read from the worktree's OWN git dir, never the enclosing repo's"
	fi
else
	no "precondition: rev-parse should still resolve upwards from a worktree that lost its .git"
fi
rm -rf "$RO/.git/rebase-merge"

# ---------------------------------------------------------------------------
# Unit: wt_worktree_gitdir locates a worktree's OWN state from the common
# metadata, which is the only place it can be read from when the worktree's
# directory is not there to run git in. git keeps refusing the branch such a
# record holds, and `worktree prune` is the remedy — the one wt-enter withholds
# entirely when the blocker cannot be identified.
# ---------------------------------------------------------------------------
RD="$(make_repo rd)"
git_quiet -C "$RD" branch gone-b
GONE_WT="$RD/.worktrees/$CONTAINER_NAME/gone"
git_quiet -C "$RD" worktree add -q "$GONE_WT" gone-b >/dev/null 2>&1
GDD="$RD/.git/worktrees/gone"
: >"$GDD/BISECT_LOG"
printf 'gone-b\n' >"$GDD/BISECT_START"
rm -rf "$GONE_WT" # registered, state intact, directory gone
out="$UNSET_MARK"
if wt_read_path out wt_worktree_gitdir "$RD" "$GONE_WT" && [ "$out" = "$GDD" ]; then
	ok "wt_worktree_gitdir resolves the admin git dir of a worktree deleted from disk"
else
	no "wt_worktree_gitdir lost a deleted worktree's admin git dir: got '$out', expected '$GDD'"
fi
if wt_branch_held_by_operation "$RD" "$GONE_WT" gone-b; then
	ok "a deleted worktree's surviving operation state still marks the branch as held"
else
	no "the operation state of a deleted-but-registered worktree was not read"
fi

# The MAIN working tree has no admin dir of its own — its git dir IS the common
# dir — and it can be the detached blocker too, so it must still resolve.
out="$UNSET_MARK"
if wt_read_path out wt_worktree_gitdir "$RD" "$RD" && [ "$out" = "$RD/.git" ]; then
	ok "wt_worktree_gitdir names the common dir for the MAIN working tree"
else
	no "wt_worktree_gitdir mis-resolved the main working tree: got '$out', expected '$RD/.git'"
fi

# A path that is not a registered worktree must answer "unknown", never some
# neighbouring record's state.
out="$UNSET_MARK"
if wt_read_path out wt_worktree_gitdir "$RD" "$RD/never-registered"; then
	no "wt_worktree_gitdir answered '$out' for a path that is not a registered worktree"
else
	ok "wt_worktree_gitdir returns unknown for a path that is not a registered worktree"
fi

# ---------------------------------------------------------------------------
# Unit: wt_worktree_for_branch identifies the blocking worktree — a PATH, and
# nothing else — for both porcelain record kinds, and claims nothing when no
# worktree holds the branch.
#
# The resolvers answer NUL-terminated and are therefore read with wt_read_path
# throughout, never `$( )`, which is both how wt-enter reads them and what keeps
# the trailing-newline cases below meaningful. `out` is pre-set to a SENTINEL
# before each call so "left untouched" is distinguishable from "answered empty".
# ---------------------------------------------------------------------------
RG="$(make_repo rg)"
git_quiet -C "$RG" worktree add -q "$RG/plain" -b plain-b >/dev/null 2>&1
out="$UNSET_MARK"
if wt_read_path out wt_worktree_for_branch "$RG" plain-b && [ "$out" = "$RG/plain" ]; then
	ok "wt_worktree_for_branch names the worktree holding a branch (porcelain 'branch' record)"
else
	no "plain blocker not identified: got '$out'"
fi

# A DETACHED record: only the operation state links it back to the branch.
git_quiet -C "$RG" branch det-b
git_quiet -C "$RG" worktree add -q --detach "$RG/det" >/dev/null 2>&1
mkdir -p "$RG/.git/worktrees/det/rebase-merge"
printf 'refs/heads/det-b\n' >"$RG/.git/worktrees/det/rebase-merge/head-name"
out="$UNSET_MARK"
if git -C "$RG" worktree list --porcelain | grep -qx detached &&
	wt_read_path out wt_worktree_for_branch "$RG" det-b && [ "$out" = "$RG/det" ]; then
	ok "wt_worktree_for_branch names a DETACHED worktree that holds the branch through a rebase"
else
	no "detached rebase blocker not identified"
fi
rm -rf "$RG/.git/worktrees/det/rebase-merge"

# ---------------------------------------------------------------------------
# Unit: wt_primary_checkout names the repository's MAIN working tree. wt-enter
# uses it to decide whether the blocker is the shared checkout, so it is pinned
# directly: the integration case below would also pass on a broken (always-fail)
# implementation, because in an ordinary repo the main working tree is the repo
# root wt-enter already knows.
# ---------------------------------------------------------------------------
out="$UNSET_MARK"
if wt_read_path out wt_primary_checkout "$RG" && [ "$out" = "$RG" ]; then
	ok "wt_primary_checkout names the main working tree"
else
	no "wt_primary_checkout on the main tree: got '$out', expected '$RG'"
fi

# Asked from INSIDE a linked worktree it must still answer the MAIN tree, never
# the one it was asked from — git lists the main working tree first regardless.
out="$UNSET_MARK"
if wt_read_path out wt_primary_checkout "$RG/plain" && [ "$out" = "$RG" ]; then
	ok "wt_primary_checkout answers the main tree even when queried from a linked worktree"
else
	no "wt_primary_checkout from a linked worktree: got '$out', expected '$RG'"
fi

# Outside a repository it must FAIL, emitting NOTHING at all (not even a stray
# terminator) rather than invent a path, so wt-enter falls back instead of
# comparing against a bogus answer — and so `out` is left as the caller had it.
notrepo="$WORK_ROOT/not-a-repo"
mkdir -p "$notrepo"
out="$UNSET_MARK"
if wt_read_path out wt_primary_checkout "$notrepo"; then
	no "wt_primary_checkout must fail outside a repository (got '$out')"
elif [ "$out" = "$UNSET_MARK" ] && [ "$(wt_primary_checkout "$notrepo" | wc -c)" -eq 0 ]; then
	ok "wt_primary_checkout fails and emits nothing outside a repository"
else
	no "wt_primary_checkout outside a repository: expected no answer, got '$out'"
fi

git_quiet -C "$RG" branch unheld-b
out="$UNSET_MARK"
if wt_read_path out wt_worktree_for_branch "$RG" unheld-b; then
	no "wt_worktree_for_branch must not claim a blocker for an unheld branch (got '$out')"
elif [ "$out" = "$UNSET_MARK" ] && [ "$(wt_worktree_for_branch "$RG" unheld-b | wc -c)" -eq 0 ]; then
	ok "wt_worktree_for_branch emits nothing and fails when no worktree holds the branch"
else
	no "unheld branch: expected no answer, got '$out'"
fi

# ---------------------------------------------------------------------------
# Unit: wt_worktree_locked. "The directory is gone" does NOT imply "the record is
# stale": `git worktree prune` deliberately skips a LOCKED worktree, so a caller
# that offers prune without asking this hands out a remedy that cannot work, for
# a checkout whose owner locked it precisely to say "leave this alone" (typically
# one parked on removable or currently-unmounted storage that still holds the
# work). It answers through its exit status only — nothing on stdout — and a repo
# it cannot query must answer "not locked", the direction that merely leaves the
# caller where it already was.
# ---------------------------------------------------------------------------
git_quiet -C "$RG" worktree lock "$RG/plain" >/dev/null 2>&1
if wt_worktree_locked "$RG" "$RG/plain" && [ -z "$(wt_worktree_locked "$RG" "$RG/plain")" ]; then
	ok "wt_worktree_locked reports a locked worktree, silently"
else
	no "wt_worktree_locked missed a locked worktree (or printed something)"
fi
if wt_worktree_locked "$RG" "$RG/det"; then
	no "wt_worktree_locked must not report an UNLOCKED worktree as locked"
else
	ok "wt_worktree_locked leaves an unlocked worktree alone"
fi
if wt_worktree_locked "$RG" "$RG/never-registered"; then
	no "wt_worktree_locked must not claim a lock for a path git does not list"
else
	ok "wt_worktree_locked answers 'not locked' for an unregistered path"
fi
if wt_worktree_locked "$notrepo" "$notrepo"; then
	no "wt_worktree_locked must answer 'not locked' when git cannot be queried"
else
	ok "wt_worktree_locked degrades to 'not locked' outside a repository"
fi

# The lock REASON is free-form human text, and git leaves it UNQUOTED in `-z`
# mode — so the attribute genuinely spans several "lines". Pinned with a reason
# that spells a FAKE porcelain record, the shape that would do the most damage
# if a record boundary were ever taken from that text: the `locked` attribute
# landing on a worktree that is not locked at all, which would have wt-enter
# suppress the one correct remedy for a genuinely stale record. NUL-delimited it
# is a single field and cannot.
git_quiet -C "$RG" worktree unlock "$RG/plain" >/dev/null 2>&1
FAKE_REASON=$'parked\nworktree '"$RG/det"$'\nlocked'
git_quiet -C "$RG" worktree lock --reason "$FAKE_REASON" "$RG/plain" >/dev/null 2>&1
if wt_worktree_locked "$RG" "$RG/det"; then
	no "a lock reason spelling a fake porcelain record must not mark another worktree locked"
elif wt_worktree_locked "$RG" "$RG/plain"; then
	ok "a multi-line lock reason stays inside its own record"
else
	no "wt_worktree_locked lost the lock when the reason contained newlines"
fi
git_quiet -C "$RG" worktree unlock "$RG/plain" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Unit: wt_read_path REFUSES an out-variable name carrying its own `__wt_`
# prefix, non-zero, instead of obeying it. Such a name collides with the
# helper's locals, so `printf -v` writes the answer into the helper's OWN
# variable: the caller's is left at whatever it held before while the call still
# reports success — a stale value dressed as an answer, which is the one failure
# shape a caller cannot branch on. The refusal is silent by design (no stderr):
# the status is the whole signal, and it lands the caller on the same "unknown"
# branch an unanswerable resolver does. Every prefixed name is refused, not just
# the two locals that exist today, so adding a local cannot quietly re-open this.
# ---------------------------------------------------------------------------
for collide in __wt_out_var __wt_path __wt_future_local; do
	printf -v "$collide" '%s' "$UNSET_MARK"
	if wt_read_path "$collide" wt_primary_checkout "$RG"; then
		no "wt_read_path reported SUCCESS for colliding out-variable '$collide' (left it '${!collide}')"
	elif [ "${!collide}" = "$UNSET_MARK" ] &&
		[ -z "$(wt_read_path "$collide" wt_primary_checkout "$RG" 2>&1)" ]; then
		ok "wt_read_path refuses colliding out-variable '$collide' quietly, leaving it untouched"
	else
		no "wt_read_path refused '$collide' but did not stay quiet/untouched: '${!collide}'"
	fi
done

# ...and the ordinary case is untouched by that guard: a plain name still gets
# the answer, and still reports success.
out="$UNSET_MARK"
if wt_read_path out wt_primary_checkout "$RG" && [ "$out" = "$RG" ]; then
	ok "wt_read_path still answers an ordinary out-variable name"
else
	no "wt_read_path with an ordinary out-variable name: got '$out', expected '$RG'"
fi

# ---------------------------------------------------------------------------
# Unit: a worktree path containing a NEWLINE must come back WHOLE. A newline is
# a legal path byte and `git worktree list --porcelain` prints it raw, so a
# line-based reader silently answers the prefix — a path that does not exist,
# which downstream reads as "registered but missing" and earns the caller the one
# remedy that is wrong there ('worktree prune'). Both resolvers are pinned, for
# the main record and for a linked one, since they read the same listing.
# ---------------------------------------------------------------------------
NL="$(printf 'odd\npath')"
RZ="$(make_repo "$NL")" # the MAIN working tree's own path carries the newline
out="$UNSET_MARK"
if wt_read_path out wt_primary_checkout "$RZ" && [ "$out" = "$RZ" ]; then
	ok "wt_primary_checkout returns a main-tree path containing a newline intact"
else
	no "wt_primary_checkout truncated a newline path: got '$out', expected '$RZ'"
fi

WTZ="$WORK_ROOT/nl-blocker-$NL" # a LINKED worktree, newline in its own path
git_quiet -C "$RZ" worktree add -q "$WTZ" -b nl-b >/dev/null 2>&1
out="$UNSET_MARK"
if wt_read_path out wt_worktree_for_branch "$RZ" nl-b && [ "$out" = "$WTZ" ]; then
	ok "wt_worktree_for_branch returns a blocker path containing a newline intact"
else
	no "wt_worktree_for_branch truncated a newline path: got '$out', expected '$WTZ'"
fi

# The same byte decides whether a LOCK is seen at all, and it is the PATH — not
# the lock reason — that carries it unescaped in either porcelain format. Read
# line-wise, the `worktree ` line answers the path's prefix, and the record's
# `locked` attribute is then compared against a path nobody has: a locked
# worktree reads as unlocked, and wt-enter goes on to offer `worktree prune` for
# the one record git will not prune.
git_quiet -C "$RZ" worktree lock "$WTZ" >/dev/null 2>&1
if wt_worktree_locked "$RZ" "$WTZ"; then
	ok "wt_worktree_locked sees the lock on a worktree whose path contains a newline"
else
	no "wt_worktree_locked missed the lock on a newline-path worktree"
fi
git_quiet -C "$RZ" worktree unlock "$WTZ" >/dev/null 2>&1

# The truncation this guards is not hypothetical: the prefix is a path that is
# not there, so a caller acting on it would diagnose the wrong failure entirely.
if [ -e "${WTZ%%$'\n'*}" ]; then
	no "precondition: the truncated prefix of the newline path should not exist"
else
	ok "the truncated prefix of a newline worktree path is a non-existent path"
fi

# ---------------------------------------------------------------------------
# Unit: a path ENDING in a newline is the second half of the same defect, and
# the porcelain read alone does not cover it: `$( )` strips TRAILING newlines,
# so handing the answer back through a command substitution re-truncates the
# path the `-z` read just preserved. Hence the NUL-terminated answer and
# wt_read_path — pinned here for both resolvers.
#
# The repo path is built directly rather than taken from make_repo's own `echo`,
# which is itself read with `$( )` and would drop the trailing byte on the way
# in. Nothing about the fixture may depend on the thing under test.
# ---------------------------------------------------------------------------
NLT_NAME=$'tail\n' # trailing newline, kept out of any `$( )`
NLT_ROOT="$WORK_ROOT/$NLT_NAME"
make_repo "$NLT_NAME" >/dev/null
out="$UNSET_MARK"
if wt_read_path out wt_primary_checkout "$NLT_ROOT" && [ "$out" = "$NLT_ROOT" ]; then
	ok "wt_primary_checkout returns a main-tree path ENDING in a newline intact"
else
	no "wt_primary_checkout truncated a trailing-newline path: got '$out', expected '$NLT_ROOT'"
fi

WTT="$WORK_ROOT/nlt-blocker"$'\n' # a LINKED worktree whose path ends in a newline
git_quiet -C "$NLT_ROOT" worktree add -q "$WTT" -b nlt-b >/dev/null 2>&1
out="$UNSET_MARK"
if wt_read_path out wt_worktree_for_branch "$NLT_ROOT" nlt-b && [ "$out" = "$WTT" ]; then
	ok "wt_worktree_for_branch returns a blocker path ENDING in a newline intact"
else
	no "wt_worktree_for_branch truncated a trailing-newline path: got '$out', expected '$WTT'"
fi

# The same byte reaches wt_worktree_gitdir, which used to cross-check the path
# against `rev-parse --show-toplevel` read through `$( )`: the trailing newline
# came off the reply, the two paths compared unequal, and a perfectly good
# worktree resolved to "unknown" — losing the whole diagnosis for every DETACHED
# blocker under such a path. Matching the registered `gitdir` file has no such
# step. (git sanitizes the admin dir's own NAME, so it cannot be checked for.)
out="$UNSET_MARK"
if wt_read_path out wt_worktree_gitdir "$NLT_ROOT" "$WTT" && [ -d "$out" ] &&
	[ "$(cat "$out/gitdir")" = "$WTT/.git" ]; then
	ok "wt_worktree_gitdir resolves the admin git dir of a worktree whose path ENDS in a newline"
else
	no "wt_worktree_gitdir could not resolve a trailing-newline worktree's admin git dir: got '$out'"
fi

# Same non-hypothetical: strip the trailing newline and the path is not there,
# which is what turns a live blocker into a "registered but missing" record.
if [ -e "${WTT%$'\n'}" ]; then
	no "precondition: the trailing-newline-stripped blocker path should not exist"
else
	ok "a blocker path with its trailing newline stripped is a non-existent path"
fi

# ---------------------------------------------------------------------------
# Integration: wt-enter reuses a LIVE worktree (durable-metadata happy path)
# ---------------------------------------------------------------------------
R1="$(make_repo r1)"
WB1="$R1/.worktrees/$CONTAINER_NAME"
git_quiet -C "$R1" worktree add -q "$WB1/task-a" -b task-a >/dev/null 2>&1
if out="$(cd "$R1" && bash "$WT_ENTER" task-a task-a 2>/dev/null)" && [ "$out" = "$WB1/task-a" ]; then
	ok "wt-enter reuses a live worktree (durable metadata survives)"
else
	no "wt-enter did not reuse live worktree: out='${out:-}'"
fi

# ---------------------------------------------------------------------------
# Integration: wt-enter preserves a dead-metadata dirty orphan, recreates fresh
# ---------------------------------------------------------------------------
R2="$(make_repo r2)"
WB2="$R2/.worktrees/$CONTAINER_NAME"
git_quiet -C "$R2" worktree add -q "$WB2/task-b" -b task-b >/dev/null 2>&1
echo "dirty work" >"$WB2/task-b/UNSAVED.txt"
break_metadata "$R2" task-b
# Orphan confirmed (git no longer recognises it):
if git -C "$WB2/task-b" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	no "precondition: task-b should be a dead-metadata orphan but git still recognises it"
else
	if out="$(cd "$R2" && bash "$WT_ENTER" task-b task-b 2>/dev/null)" &&
		[ "$out" = "$WB2/task-b" ] &&
		git -C "$WB2/task-b" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		# The recreated worktree is fresh (no UNSAVED.txt), and the dirty work was
		# preserved under the quarantine dir rather than deleted.
		q="$(find "$R2/.worktrees/.orphaned/$CONTAINER_NAME" -name UNSAVED.txt -type f 2>/dev/null | head -1)"
		if [ -n "$q" ] && [ "$(cat "$q")" = "dirty work" ] && [ ! -f "$WB2/task-b/UNSAVED.txt" ]; then
			ok "wt-enter quarantines dead-metadata dirty orphan and recreates fresh"
		else
			no "wt-enter: dirty work not preserved in quarantine (q='${q:-}')"
		fi
	else
		no "wt-enter did not recreate task-b: out='${out:-}'"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: wt-remove preserves a dead-metadata dirty orphan (never rm -rf)
# ---------------------------------------------------------------------------
R3="$(make_repo r3)"
WB3="$R3/.worktrees/$CONTAINER_NAME"
git_quiet -C "$R3" worktree add -q "$WB3/task-c" -b task-c >/dev/null 2>&1
echo "dirty work c" >"$WB3/task-c/UNSAVED.txt"
break_metadata "$R3" task-c
if (cd "$R3" && bash "$WT_REMOVE" task-c >/dev/null 2>&1); then
	q="$(find "$R3/.worktrees/.orphaned/$CONTAINER_NAME" -name UNSAVED.txt -type f 2>/dev/null | head -1)"
	if [ ! -e "$WB3/task-c" ] && [ -n "$q" ] && [ "$(cat "$q")" = "dirty work c" ]; then
		ok "wt-remove quarantines a dead-metadata dirty orphan instead of deleting it"
	else
		no "wt-remove: orphan not safely preserved (q='${q:-}', still=$([ -e "$WB3/task-c" ] && echo yes || echo no))"
	fi
else
	no "wt-remove failed on a dead-metadata orphan"
fi

# ---------------------------------------------------------------------------
# Integration: wt-remove on an already-absent slug is a clean no-op (idempotent).
# (The empty-dir prune branch of wt_reap_orphan_dir is exercised at the unit
# level above; a truly empty leftover dir with no dangling .git is seen by git as
# part of the PARENT work tree, so it never reaches the reap path.)
# ---------------------------------------------------------------------------
R4="$(make_repo r4)"
if (cd "$R4" && bash "$WT_REMOVE" never-existed >/dev/null 2>&1) &&
	[ ! -d "$R4/.worktrees/.orphaned" ]; then
	ok "wt-remove on an absent slug is a clean no-op"
else
	no "wt-remove on an absent slug did not succeed cleanly"
fi

# ---------------------------------------------------------------------------
# THE OPERATION-IN-PROGRESS GUARD (task 057). wt-remove's contract is to remove a
# worktree but NEVER work, and `git status --porcelain` is the wrong instrument
# for that on its own: it is EMPTY for a bisect, for a `git am`, for a rebase
# stopped at a `break`, for a cherry-pick/revert SEQUENCE stopped on an empty
# patch, and for any conflict whose resolution happens to equal HEAD — every one
# of which is state that exists nowhere else and that removing the worktree
# destroys. (`git worktree remove` behaves the same way, so this helper's guard
# is the only protection there is.)
#
# Each fixture below is built with REAL git rather than by fabricating files, and
# every case asserts the porcelain is CLEAN first — otherwise the pre-existing
# uncommitted-changes guard would be what refused and the operation guard would
# go untested. The refusal must hold BOTH with and without --force (the
# documented inversion of vanilla `git worktree remove --force`), must leave the
# worktree AND its state files exactly where they were, must NAME the operation,
# and must pass the non-destruction detector: naming a way to clear the state
# (`--abort`, `bisect reset`, `reset --hard`, ...) is the same loss by another
# route, and task 039 removed that class of advice from wt-enter.
#
# wt_remove_must_refuse <expected phrase> <root> <slug> <state marker path>
#                       [clean|dirty]
#   Echo a `miss` fragment (empty when all is well), in the same shape the
#   wt-enter cases use.
#
#   The last argument declares what the fixture's porcelain is expected to be,
#   and is asserted rather than assumed. `clean` (the default) is the shape this
#   guard exists for — nothing the pre-existing uncommitted-changes check would
#   already have caught, so the operation guard is provably what refused. `dirty`
#   is the opposite shape, an operation stopped ON a conflict: BOTH guards would
#   refuse, and the point of the case is WHICH diagnosis comes out, so it
#   additionally requires that the message does NOT fall back to naming the dirt.
# ---------------------------------------------------------------------------

# marker_present <marker> — is the state marker still there? A <marker> is
# normally a PATH inside the worktree's admin dir, but under the `reftable` ref
# backend four of the guarded markers are pseudo-refs with NO file on disk, so
# they are spelled `<gitdir>:ref:<NAME>` and looked up in the ref storage
# instead. (`:ref:` cannot occur by accident in these fixtures: every path here
# is rooted at a mktemp dir.)
#
# `<gitdir>:symref:<NAME>` is the third spelling, for a marker that exists as a
# SYMBOLIC ref whose target does not resolve — NOTES_MERGE_REF after the notes
# ref it points at is deleted. `show-ref --verify` answers 1 there (it reports
# what a name RESOLVES to, not what exists), so the `:ref:` spelling would call
# such a fixture's marker missing; `symbolic-ref` is what answers about
# existence. The `:symref:` arm is matched FIRST so the `:ref:` glob, which the
# longer spelling would otherwise be tested against, cannot claim it.
marker_present() {
	case "$1" in
	*:symref:*) [ -n "$(git --git-dir="${1%%:symref:*}" symbolic-ref --quiet "${1##*:symref:}" 2>/dev/null)" ] ;;
	*:ref:*) git --git-dir="${1%%:ref:*}" show-ref --verify --quiet "${1##*:ref:}" ;;
	*) [ -e "$1" ] ;;
	esac
}

wt_remove_must_refuse() {
	local phrase="$1" root="$2" slug="$3" marker="$4" expect="${5:-clean}"
	local wt="$root/.worktrees/$CONTAINER_NAME/$slug"
	local err="$WORK_ROOT/wtrm-$slug.err" miss="" mode rc

	[ -d "$wt" ] || {
		printf '%s' " fixture-worktree-missing"
		return 0
	}
	marker_present "$marker" || {
		printf '%s' " fixture-state-missing"
		return 0
	}
	case "$expect" in
	clean) [ -z "$(git -C "$wt" status --porcelain)" ] || miss="$miss fixture-porcelain-not-clean" ;;
	dirty) [ -n "$(git -C "$wt" status --porcelain)" ] || miss="$miss fixture-porcelain-not-dirty" ;;
	*) miss="$miss fixture-bad-porcelain-expectation" ;;
	esac

	for mode in plain force; do
		rc=0
		if [ "$mode" = plain ]; then
			(cd "$root" && bash "$WT_REMOVE" "$slug" 2>"$err") || rc=$?
		else
			(cd "$root" && bash "$WT_REMOVE" "$slug" --force 2>"$err") || rc=$?
		fi
		[ "$rc" -ne 0 ] || miss="$miss $mode-REMOVED-ANYWAY"
		[ -d "$wt" ] || miss="$miss $mode-worktree-gone"
		marker_present "$marker" || miss="$miss $mode-state-lost"
		grep -qF "$phrase" "$err" || miss="$miss $mode-operation-not-named"
		if [ "$expect" = dirty ]; then
			! grep -qF "uncommitted changes" "$err" ||
				miss="$miss $mode-named-the-dirt-instead-of-the-operation"
		fi
		miss="$miss$(destructive_advice "$err" "$wt" "$root" "$slug")"
	done
	printf '%s' "$miss"
}

# --- bisect, DETACHED (`git bisect start <bad> <good>`) ---------------------
RB1="$(make_repo rb-detached)"
for i in 1 2 3; do
	echo "rev $i" >"$RB1/seed.txt"
	git_quiet -C "$RB1" commit -qam "c$i"
done
git_quiet -C "$RB1" branch bis-d
git_quiet -C "$RB1" worktree add -q "$RB1/.worktrees/$CONTAINER_NAME/bis-d" bis-d >/dev/null 2>&1
git_quiet -C "$RB1/.worktrees/$CONTAINER_NAME/bis-d" bisect start HEAD HEAD~2 >/dev/null 2>&1 || true
miss="$(wt_remove_must_refuse "a bisect (BISECT_LOG)" "$RB1" bis-d "$RB1/.git/worktrees/bis-d/BISECT_LOG")"
if [ -z "$miss" ]; then
	ok "wt-remove refuses a worktree with a DETACHED bisect in progress, with and without --force"
else
	no "wt-remove detached-bisect guard inadequate:$miss"
fi

# --- bisect, still ON its branch (`git bisect start` with no revs) ----------
# The shape that started this: the worktree is not even detached, `git status
# --porcelain` is empty, and every guard wt-remove used to have passed.
RB2="$(make_repo rb-onbranch)"
git_quiet -C "$RB2" branch bis-b
git_quiet -C "$RB2" worktree add -q "$RB2/.worktrees/$CONTAINER_NAME/bis-b" bis-b >/dev/null 2>&1
git_quiet -C "$RB2/.worktrees/$CONTAINER_NAME/bis-b" bisect start >/dev/null 2>&1 || true
if git -C "$RB2" worktree list --porcelain | grep -qx "branch refs/heads/bis-b"; then
	miss="$(wt_remove_must_refuse "a bisect (BISECT_LOG)" "$RB2" bis-b "$RB2/.git/worktrees/bis-b/BISECT_START")"
	if [ -z "$miss" ]; then
		ok "wt-remove refuses a worktree bisecting ON its branch (clean status, nothing else to see)"
	else
		no "wt-remove on-branch-bisect guard inadequate:$miss"
	fi
else
	no "precondition: 'git bisect start' should leave the worktree on its branch"
fi

# --- bisect, HALF TORN DOWN: BISECT_START with NO BISECT_LOG ----------------
# The guard names BISECT_START alongside BISECT_LOG deliberately, and this is the
# only fixture that can prove that half load-bearing: both cases above carry BOTH
# files, so deleting `BISECT_START` from wt-remove's state list would leave them
# passing. Here git itself no longer considers a bisect to be running (`git
# status` reports a plain detached HEAD and the porcelain is empty) — but
# BISECT_START is where the branch to come back to is recorded, and
# BISECT_TERMS/BISECT_NAMES still sit beside it, so what the search had
# established exists nowhere else once the worktree is gone. That makes this a
# deliberate over-reach relative to git's own reading, in the only direction that
# is cheap: refusing costs a re-run, removing costs the state.
RB3="$(make_repo rb-startonly)"
for i in 1 2 3; do
	echo "rev $i" >"$RB3/seed.txt"
	git_quiet -C "$RB3" commit -qam "c$i"
done
git_quiet -C "$RB3" branch bis-s
git_quiet -C "$RB3" worktree add -q "$RB3/.worktrees/$CONTAINER_NAME/bis-s" bis-s >/dev/null 2>&1
git_quiet -C "$RB3/.worktrees/$CONTAINER_NAME/bis-s" bisect start HEAD HEAD~2 >/dev/null 2>&1 || true
rm -f "$RB3/.git/worktrees/bis-s/BISECT_LOG"
if [ ! -e "$RB3/.git/worktrees/bis-s/BISECT_LOG" ] && [ -e "$RB3/.git/worktrees/bis-s/BISECT_START" ]; then
	miss="$(wt_remove_must_refuse "a bisect (BISECT_START)" "$RB3" bis-s "$RB3/.git/worktrees/bis-s/BISECT_START")"
	if [ -z "$miss" ]; then
		ok "wt-remove refuses a half-torn-down bisect: BISECT_START with no BISECT_LOG"
	else
		no "wt-remove BISECT_START-only guard inadequate:$miss"
	fi
else
	no "precondition: the half-torn-down fixture should hold BISECT_START and no BISECT_LOG"
fi

# --- multi-commit revert stopped on an EMPTY revert -------------------------
# sequencer/ + MERGE_MSG, clean porcelain, and NO REVERT_HEAD — so `sequencer/`
# is the only thing that marks it.
RS1="$(make_repo rs-seq)"
echo x >"$RS1/other.txt"
git_quiet -C "$RS1" add -A
git_quiet -C "$RS1" commit -qm "add other"
echo one >"$RS1/seed.txt"
git_quiet -C "$RS1" commit -qam c1
echo y >"$RS1/other.txt"
git_quiet -C "$RS1" commit -qam c2
echo seed >"$RS1/seed.txt" # undoes c1 by hand, so reverting c1 later is empty
git_quiet -C "$RS1" commit -qam "undo c1"
git_quiet -C "$RS1" branch seq-u
git_quiet -C "$RS1" worktree add -q "$RS1/.worktrees/$CONTAINER_NAME/seq-u" seq-u >/dev/null 2>&1
git_quiet -C "$RS1/.worktrees/$CONTAINER_NAME/seq-u" revert --no-edit \
	"$(git -C "$RS1" rev-parse seq-u~1)" "$(git -C "$RS1" rev-parse seq-u~2)" >/dev/null 2>&1 || true
if [ ! -e "$RS1/.git/worktrees/seq-u/REVERT_HEAD" ]; then
	miss="$(wt_remove_must_refuse "a cherry-pick/revert sequence (sequencer/)" "$RS1" seq-u "$RS1/.git/worktrees/seq-u/sequencer/todo")"
	if [ -z "$miss" ]; then
		ok "wt-remove refuses a worktree stopped mid-SEQUENCE (sequencer/, clean status, no REVERT_HEAD)"
	else
		no "wt-remove sequencer guard inadequate:$miss"
	fi
else
	no "precondition: the empty-revert stop should leave no REVERT_HEAD (else sequencer/ is not what is under test)"
fi

# --- REVERT_HEAD alone, with a CLEAN porcelain ------------------------------
# A single-commit revert whose conflict is resolved back to HEAD's own content:
# the index matches HEAD, `git status --porcelain` is empty, and REVERT_HEAD is
# all that is left of the revert. git reads REVERT_HEAD independently of the
# sequencer, so it has to be guarded independently too.
RS2="$(make_repo rs-revhead)"
printf 'a\n' >"$RS2/f.txt"
git_quiet -C "$RS2" add -A
git_quiet -C "$RS2" commit -qm f1
printf 'b\n' >"$RS2/f.txt"
git_quiet -C "$RS2" commit -qam f2
printf 'c\n' >"$RS2/f.txt"
git_quiet -C "$RS2" commit -qam f3
git_quiet -C "$RS2" branch rev-h
git_quiet -C "$RS2" worktree add -q "$RS2/.worktrees/$CONTAINER_NAME/rev-h" rev-h >/dev/null 2>&1
git_quiet -C "$RS2/.worktrees/$CONTAINER_NAME/rev-h" revert --no-edit HEAD~1 >/dev/null 2>&1 || true
printf 'c\n' >"$RS2/.worktrees/$CONTAINER_NAME/rev-h/f.txt"
git_quiet -C "$RS2/.worktrees/$CONTAINER_NAME/rev-h" add f.txt
if [ ! -e "$RS2/.git/worktrees/rev-h/sequencer" ]; then
	miss="$(wt_remove_must_refuse "a revert (REVERT_HEAD)" "$RS2" rev-h "$RS2/.git/worktrees/rev-h/REVERT_HEAD")"
	if [ -z "$miss" ]; then
		ok "wt-remove refuses a worktree holding REVERT_HEAD with a clean status"
	else
		no "wt-remove REVERT_HEAD guard inadequate:$miss"
	fi
else
	no "precondition: a single-commit revert should leave no sequencer/ (else REVERT_HEAD is not what is under test)"
fi

# --- a conflicted `git notes merge` -----------------------------------------
# The gap the round-3 audit found. A notes merge is the one operation whose whole
# conflict lives in the worktree's ADMIN dir and nowhere in the working tree at
# all, so `git status --porcelain` is empty and `git status` says nothing
# whatsoever — there is not even a "You have unmerged paths" line to notice.
# Removing the worktree takes NOTES_MERGE_WORKTREE, i.e. the unresolved notes,
# with it.
#
# The markers are strictly PER-WORKTREE (verified: the same merge run in the main
# checkout writes them into `.git/`, not into `.git/worktrees/<slug>/`), so
# guarding them cannot make a sibling's notes merge block this removal.
# notes_merge_repo <name> <slug> [<git init flag>...] -> echoes ROOT, with
# worktree <slug> mid-notes-merge. The trailing flags are for
# `--ref-format=reftable`, which turns the two markers into pseudo-refs with no
# file on disk; the reftable cases further down build the SAME shape with them.
notes_merge_repo() {
	local root name="$1" slug="$2"
	shift 2
	root="$(make_repo "$name" "$@")"
	git_quiet -C "$root" branch "$slug-b" >/dev/null 2>&1
	git_quiet -C "$root" worktree add -q "$root/.worktrees/$CONTAINER_NAME/$slug" "$slug-b" >/dev/null 2>&1
	git_quiet -C "$root" notes --ref=A add -m "note from A" HEAD >/dev/null 2>&1
	git_quiet -C "$root" notes --ref=B add -m "note from B" HEAD >/dev/null 2>&1
	git_quiet -C "$root/.worktrees/$CONTAINER_NAME/$slug" notes --ref=A merge B >/dev/null 2>&1 || true
	printf '%s' "$root"
}

RS8="$(notes_merge_repo rs-notes nm)"
GD8="$RS8/.git/worktrees/nm"
if [ -e "$GD8/NOTES_MERGE_PARTIAL" ] && [ -e "$GD8/NOTES_MERGE_REF" ] &&
	[ -n "$(ls -A "$GD8/NOTES_MERGE_WORKTREE" 2>/dev/null)" ]; then
	miss="$(wt_remove_must_refuse "a 'git notes' merge (NOTES_MERGE_PARTIAL)" "$RS8" nm "$GD8/NOTES_MERGE_PARTIAL")"
	# The unresolved notes themselves, not just the marker, have to survive.
	[ -n "$(ls -A "$GD8/NOTES_MERGE_WORKTREE" 2>/dev/null)" ] ||
		miss="$miss unresolved-notes-lost"
	if [ -z "$miss" ]; then
		ok "wt-remove refuses a worktree with a conflicted 'git notes merge' (clean status, nothing in the working tree at all)"
	else
		no "wt-remove notes-merge guard inadequate:$miss"
	fi
else
	no "precondition: a conflicting notes merge should leave NOTES_MERGE_PARTIAL, NOTES_MERGE_REF and a non-empty NOTES_MERGE_WORKTREE in the worktree's admin dir"
fi

# NOTES_MERGE_REF alone. Both markers are guarded because `git notes merge
# --commit` needs BOTH — with NOTES_MERGE_PARTIAL gone it dies with "failed to
# read ref NOTES_MERGE_PARTIAL" (verified) — so this half-torn-down shape is one
# where the notes CANNOT be recovered by concluding the merge and the conflict
# directory is the only copy left. It is also the only fixture that can prove the
# NOTES_MERGE_REF half of the guard load-bearing: the case above carries both
# files, so dropping REF from wt-remove's state list would leave it passing.
RS9="$(notes_merge_repo rs-notesref nmr)"
GD9="$RS9/.git/worktrees/nmr"
rm -f "$GD9/NOTES_MERGE_PARTIAL"
if [ ! -e "$GD9/NOTES_MERGE_PARTIAL" ] && [ -e "$GD9/NOTES_MERGE_REF" ]; then
	miss="$(wt_remove_must_refuse "a 'git notes' merge (NOTES_MERGE_REF)" "$RS9" nmr "$GD9/NOTES_MERGE_REF")"
	if [ -z "$miss" ]; then
		ok "wt-remove refuses a half-torn-down notes merge: NOTES_MERGE_REF with no NOTES_MERGE_PARTIAL"
	else
		no "wt-remove NOTES_MERGE_REF-only guard inadequate:$miss"
	fi
else
	no "precondition: the half-torn-down notes fixture should hold NOTES_MERGE_REF and no NOTES_MERGE_PARTIAL"
fi

# --- the same states under the `reftable` ref backend -----------------------
# The round-4 audit's finding, and a fail-OPEN in the guard rather than a gap in
# its list: CHERRY_PICK_HEAD, REVERT_HEAD, NOTES_MERGE_PARTIAL and
# NOTES_MERGE_REF are pseudo-REFS, not files. Under `extensions.refStorage =
# reftable` (git 2.45+) they live in the ref backend and NOTHING is written to
# the admin dir, so a probe that only stats `$GITDIR/<name>` sees nothing and
# the worktree is removed — measured before the fix, on the notes-merge fixture
# below, whose conflict lives entirely inside NOTES_MERGE_WORKTREE and was
# destroyed. The default `files` backend is unaffected, which is why every case
# above passes either way and none of them can pin this.
#
# These fixtures are the SAME shapes as the ones above, rebuilt with
# `--ref-format=reftable`, and each asserts its precondition explicitly: the
# marker must be ABSENT as a file and PRESENT as a ref, or the case would be
# re-proving the file probe rather than the ref probe.
if [ -z "$REFTABLE_OK" ]; then
	skip "reftable ref-backend cases (this git cannot create a --ref-format=reftable repo)"
else
	# (a) a conflicted `git notes merge` — the shape that was actually removed.
	RT1="$(notes_merge_repo rt-notes rtnm --ref-format=reftable)"
	GDT1="$RT1/.git/worktrees/rtnm"
	if [ ! -e "$GDT1/NOTES_MERGE_PARTIAL" ] && [ ! -e "$GDT1/NOTES_MERGE_REF" ] &&
		git --git-dir="$GDT1" show-ref --verify --quiet NOTES_MERGE_PARTIAL &&
		[ -n "$(ls -A "$GDT1/NOTES_MERGE_WORKTREE" 2>/dev/null)" ]; then
		miss="$(wt_remove_must_refuse "a 'git notes' merge (NOTES_MERGE_PARTIAL)" "$RT1" rtnm "$GDT1:ref:NOTES_MERGE_PARTIAL")"
		# The unresolved notes are the work at risk, and there is no file marker
		# left to stand in for them here.
		[ -n "$(ls -A "$GDT1/NOTES_MERGE_WORKTREE" 2>/dev/null)" ] ||
			miss="$miss unresolved-notes-lost"
		if [ -z "$miss" ]; then
			ok "wt-remove refuses a conflicted 'git notes merge' under the reftable backend (no marker FILE exists at all)"
		else
			no "wt-remove notes-merge guard fails open under reftable:$miss"
		fi
	else
		no "precondition: under reftable a conflicting notes merge should leave NO marker files, the markers as REFS, and a non-empty NOTES_MERGE_WORKTREE"
	fi

	# (b) CHERRY_PICK_HEAD with a clean porcelain (conflict resolved back to
	# HEAD's content) — the same fixture as the files-backend case above.
	RT2="$(make_repo rt-cp --ref-format=reftable)"
	printf 'a\n' >"$RT2/f.txt"
	git_quiet -C "$RT2" add -A
	git_quiet -C "$RT2" commit -qm f1
	git_quiet -C "$RT2" checkout -q -b cp-side
	printf 'side\n' >"$RT2/f.txt"
	git_quiet -C "$RT2" commit -qam s1
	git_quiet -C "$RT2" checkout -q main
	printf 'main\n' >"$RT2/f.txt"
	git_quiet -C "$RT2" commit -qam m1
	git_quiet -C "$RT2" branch rtcp-b
	git_quiet -C "$RT2" worktree add -q "$RT2/.worktrees/$CONTAINER_NAME/rtcp" rtcp-b >/dev/null 2>&1
	git_quiet -C "$RT2/.worktrees/$CONTAINER_NAME/rtcp" cherry-pick cp-side >/dev/null 2>&1 || true
	printf 'main\n' >"$RT2/.worktrees/$CONTAINER_NAME/rtcp/f.txt"
	git_quiet -C "$RT2/.worktrees/$CONTAINER_NAME/rtcp" add f.txt
	GDT2="$RT2/.git/worktrees/rtcp"
	if [ ! -e "$GDT2/CHERRY_PICK_HEAD" ] &&
		git --git-dir="$GDT2" show-ref --verify --quiet CHERRY_PICK_HEAD; then
		miss="$(wt_remove_must_refuse "a cherry-pick (CHERRY_PICK_HEAD)" "$RT2" rtcp "$GDT2:ref:CHERRY_PICK_HEAD")"
		if [ -z "$miss" ]; then
			ok "wt-remove refuses CHERRY_PICK_HEAD under the reftable backend (a ref, not a file)"
		else
			no "wt-remove CHERRY_PICK_HEAD guard fails open under reftable:$miss"
		fi
	else
		no "precondition: under reftable a stopped cherry-pick should leave CHERRY_PICK_HEAD as a REF and no file"
	fi

	# (c) REVERT_HEAD, likewise — git reads it independently of the sequencer, so
	# it is guarded independently and has to be probed independently too.
	RT3="$(make_repo rt-rev --ref-format=reftable)"
	printf 'a\n' >"$RT3/f.txt"
	git_quiet -C "$RT3" add -A
	git_quiet -C "$RT3" commit -qm f1
	printf 'b\n' >"$RT3/f.txt"
	git_quiet -C "$RT3" commit -qam f2
	printf 'c\n' >"$RT3/f.txt"
	git_quiet -C "$RT3" commit -qam f3
	git_quiet -C "$RT3" branch rtrev-b
	git_quiet -C "$RT3" worktree add -q "$RT3/.worktrees/$CONTAINER_NAME/rtrev" rtrev-b >/dev/null 2>&1
	git_quiet -C "$RT3/.worktrees/$CONTAINER_NAME/rtrev" revert --no-edit HEAD~1 >/dev/null 2>&1 || true
	printf 'c\n' >"$RT3/.worktrees/$CONTAINER_NAME/rtrev/f.txt"
	git_quiet -C "$RT3/.worktrees/$CONTAINER_NAME/rtrev" add f.txt
	GDT3="$RT3/.git/worktrees/rtrev"
	if [ ! -e "$GDT3/REVERT_HEAD" ] && [ ! -e "$GDT3/sequencer" ] &&
		git --git-dir="$GDT3" show-ref --verify --quiet REVERT_HEAD; then
		miss="$(wt_remove_must_refuse "a revert (REVERT_HEAD)" "$RT3" rtrev "$GDT3:ref:REVERT_HEAD")"
		if [ -z "$miss" ]; then
			ok "wt-remove refuses REVERT_HEAD under the reftable backend (a ref, not a file)"
		else
			no "wt-remove REVERT_HEAD guard fails open under reftable:$miss"
		fi
	else
		no "precondition: under reftable a stopped single-commit revert should leave REVERT_HEAD as a REF, no file and no sequencer/"
	fi

	# (d) NOTES_MERGE_REF alone, under reftable — the same half-torn-down shape
	# the files-backend case above builds by deleting NOTES_MERGE_PARTIAL, and the
	# only fixture that can prove the NOTES_MERGE_REF half of the guard
	# load-bearing HERE: case (a) carries both markers, so dropping REF from
	# wt-remove's state list would leave (a) passing. `update-ref -d` is the
	# reftable equivalent of that case's `rm -f` — there is no file to remove.
	RT4="$(notes_merge_repo rt-notesref rtnmr --ref-format=reftable)"
	WT4="$RT4/.worktrees/$CONTAINER_NAME/rtnmr"
	GDT4="$RT4/.git/worktrees/rtnmr"
	git_quiet -C "$WT4" update-ref -d NOTES_MERGE_PARTIAL >/dev/null 2>&1
	if [ ! -e "$GDT4/NOTES_MERGE_PARTIAL" ] && [ ! -e "$GDT4/NOTES_MERGE_REF" ] &&
		! git --git-dir="$GDT4" show-ref --verify --quiet NOTES_MERGE_PARTIAL &&
		git --git-dir="$GDT4" show-ref --verify --quiet NOTES_MERGE_REF; then
		miss="$(wt_remove_must_refuse "a 'git notes' merge (NOTES_MERGE_REF)" "$RT4" rtnmr "$GDT4:ref:NOTES_MERGE_REF")"
		if [ -z "$miss" ]; then
			ok "wt-remove refuses a half-torn-down notes merge under reftable: NOTES_MERGE_REF as a ref, no NOTES_MERGE_PARTIAL"
		else
			no "wt-remove NOTES_MERGE_REF-only guard fails open under reftable:$miss"
		fi
	else
		no "precondition: under reftable the half-torn-down notes fixture should hold NOTES_MERGE_REF as a REF, no NOTES_MERGE_PARTIAL and no marker files"
	fi

	# (e) NOTES_MERGE_REF as a symbolic ref whose TARGET is gone. `git notes merge`
	# writes NOTES_MERGE_REF as a symref to `refs/notes/<ref>` (measured under both
	# backends), and `show-ref --verify` reports what a name RESOLVES to, not
	# whether it exists: delete the notes ref while the merge is unconcluded and
	# that probe answers 1, "absent". Under `files` the marker FILE still catches
	# it — which is why this fixture is reftable-only, where there is no file and
	# the guard fell through to "nothing in flight" and REMOVED the worktree
	# (measured before the symbolic-ref probe was added). NOTES_MERGE_PARTIAL is
	# torn down as in (d) so nothing but this probe can refuse.
	RT5="$(notes_merge_repo rt-notesdangling rtnmd --ref-format=reftable)"
	WT5="$RT5/.worktrees/$CONTAINER_NAME/rtnmd"
	GDT5="$RT5/.git/worktrees/rtnmd"
	git_quiet -C "$WT5" update-ref -d NOTES_MERGE_PARTIAL >/dev/null 2>&1
	git_quiet -C "$RT5" update-ref -d refs/notes/A >/dev/null 2>&1
	if [ ! -e "$GDT5/NOTES_MERGE_PARTIAL" ] && [ ! -e "$GDT5/NOTES_MERGE_REF" ] &&
		! git --git-dir="$GDT5" show-ref --verify --quiet NOTES_MERGE_PARTIAL &&
		! git --git-dir="$GDT5" show-ref --verify --quiet NOTES_MERGE_REF &&
		[ "$(git --git-dir="$GDT5" symbolic-ref --quiet NOTES_MERGE_REF 2>/dev/null)" = refs/notes/A ] &&
		[ -n "$(ls -A "$GDT5/NOTES_MERGE_WORKTREE" 2>/dev/null)" ]; then
		miss="$(wt_remove_must_refuse "a 'git notes' merge (NOTES_MERGE_REF)" "$RT5" rtnmd "$GDT5:symref:NOTES_MERGE_REF")"
		# The conflict directory is the whole reason to refuse: with both the
		# notes ref and NOTES_MERGE_PARTIAL gone it is the only copy left.
		[ -n "$(ls -A "$GDT5/NOTES_MERGE_WORKTREE" 2>/dev/null)" ] ||
			miss="$miss unresolved-notes-lost"
		if [ -z "$miss" ]; then
			ok "wt-remove refuses NOTES_MERGE_REF under reftable when it is a symref whose target was deleted (show-ref alone calls it absent)"
		else
			no "wt-remove NOTES_MERGE_REF guard fails open for an unresolvable symref under reftable:$miss"
		fi
	else
		no "precondition: under reftable the deleted-notes-ref fixture should hold NOTES_MERGE_REF as an UNRESOLVABLE symref to refs/notes/A, no NOTES_MERGE_PARTIAL and a non-empty NOTES_MERGE_WORKTREE"
	fi
fi

# --- the states that were ALREADY guarded, re-pinned in their CLEAN shapes ---
# They are in the guard set because git's own wt-status.c reads them, and each is
# reachable with an empty porcelain — the shape in which only the guard stands
# between the state and deletion. Regression pins for the audit, not new gaps.

# CHERRY_PICK_HEAD: conflict resolved back to HEAD's content.
RS3="$(make_repo rs-cp)"
printf 'a\n' >"$RS3/f.txt"
git_quiet -C "$RS3" add -A
git_quiet -C "$RS3" commit -qm f1
git_quiet -C "$RS3" checkout -q -b cp-side
printf 'b\n' >"$RS3/f.txt"
git_quiet -C "$RS3" commit -qam s1
git_quiet -C "$RS3" checkout -q main
printf 'c\n' >"$RS3/f.txt"
git_quiet -C "$RS3" commit -qam m1
git_quiet -C "$RS3" branch cp-h
git_quiet -C "$RS3" worktree add -q "$RS3/.worktrees/$CONTAINER_NAME/cp-h" cp-h >/dev/null 2>&1
git_quiet -C "$RS3/.worktrees/$CONTAINER_NAME/cp-h" cherry-pick cp-side >/dev/null 2>&1 || true
printf 'c\n' >"$RS3/.worktrees/$CONTAINER_NAME/cp-h/f.txt"
git_quiet -C "$RS3/.worktrees/$CONTAINER_NAME/cp-h" add f.txt
miss="$(wt_remove_must_refuse "a cherry-pick (CHERRY_PICK_HEAD)" "$RS3" cp-h "$RS3/.git/worktrees/cp-h/CHERRY_PICK_HEAD")"
if [ -z "$miss" ]; then
	ok "wt-remove refuses a worktree holding CHERRY_PICK_HEAD with a clean status"
else
	no "wt-remove CHERRY_PICK_HEAD guard inadequate:$miss"
fi

# MERGE_HEAD: same trick, an interrupted merge whose resolution equals HEAD.
RS4="$(make_repo rs-merge)"
printf 'a\n' >"$RS4/f.txt"
git_quiet -C "$RS4" add -A
git_quiet -C "$RS4" commit -qm f1
git_quiet -C "$RS4" checkout -q -b mg-side
printf 'b\n' >"$RS4/f.txt"
git_quiet -C "$RS4" commit -qam s1
git_quiet -C "$RS4" checkout -q main
printf 'c\n' >"$RS4/f.txt"
git_quiet -C "$RS4" commit -qam m1
git_quiet -C "$RS4" branch mg-h
git_quiet -C "$RS4" worktree add -q "$RS4/.worktrees/$CONTAINER_NAME/mg-h" mg-h >/dev/null 2>&1
git_quiet -C "$RS4/.worktrees/$CONTAINER_NAME/mg-h" merge mg-side >/dev/null 2>&1 || true
printf 'c\n' >"$RS4/.worktrees/$CONTAINER_NAME/mg-h/f.txt"
git_quiet -C "$RS4/.worktrees/$CONTAINER_NAME/mg-h" add f.txt
miss="$(wt_remove_must_refuse "a merge (MERGE_HEAD)" "$RS4" mg-h "$RS4/.git/worktrees/mg-h/MERGE_HEAD")"
if [ -z "$miss" ]; then
	ok "wt-remove refuses a worktree holding MERGE_HEAD with a clean status"
else
	no "wt-remove MERGE_HEAD guard inadequate:$miss"
fi

# rebase-merge: an interactive rebase stopped at a `break` — clean porcelain, and
# the whole rebase plan lives in that directory.
RS5="$(make_repo rs-rebase)"
for i in 1 2 3; do
	echo "rev $i" >"$RS5/seed.txt"
	git_quiet -C "$RS5" commit -qam "c$i"
done
git_quiet -C "$RS5" branch rb-h
git_quiet -C "$RS5" worktree add -q "$RS5/.worktrees/$CONTAINER_NAME/rb-h" rb-h >/dev/null 2>&1
(
	export GIT_SEQUENCE_EDITOR='sed -i "1i break"'
	git_quiet -C "$RS5/.worktrees/$CONTAINER_NAME/rb-h" rebase -i HEAD~2 >/dev/null 2>&1
) || true
miss="$(wt_remove_must_refuse "a rebase, merge/interactive backend (rebase-merge/)" "$RS5" rb-h "$RS5/.git/worktrees/rb-h/rebase-merge")"
if [ -z "$miss" ]; then
	ok "wt-remove refuses a worktree with an interactive rebase stopped at a break"
else
	no "wt-remove rebase-merge guard inadequate:$miss"
fi

# rebase-apply + `applying`: an interrupted `git am`, which git distinguishes
# from a rebase by that marker — the refusal names the am session, not a rebase.
RS6="$(make_repo rs-am)"
printf 'a\n' >"$RS6/f.txt"
git_quiet -C "$RS6" add -A
git_quiet -C "$RS6" commit -qm f1
git_quiet -C "$RS6" checkout -q -b am-side
printf 'a\nb\n' >"$RS6/f.txt"
git_quiet -C "$RS6" commit -qam s1
git_quiet -C "$RS6" format-patch -1 -q -o "$WORK_ROOT/am-patches"
git_quiet -C "$RS6" checkout -q main
printf 'a\nX\n' >"$RS6/f.txt"
git_quiet -C "$RS6" commit -qam divergent
git_quiet -C "$RS6" branch am-h
git_quiet -C "$RS6" worktree add -q "$RS6/.worktrees/$CONTAINER_NAME/am-h" am-h >/dev/null 2>&1
git_quiet -C "$RS6/.worktrees/$CONTAINER_NAME/am-h" am "$WORK_ROOT/am-patches"/*.patch >/dev/null 2>&1 || true
miss="$(wt_remove_must_refuse "a 'git am' session (rebase-apply/applying)" "$RS6" am-h "$RS6/.git/worktrees/am-h/rebase-apply/applying")"
if [ -z "$miss" ]; then
	ok "wt-remove refuses a worktree with an interrupted 'git am' and names it as an am session"
else
	no "wt-remove git-am guard inadequate:$miss"
fi

# --- an operation stopped ON its conflict: DIRTY *and* in flight -------------
# Every fixture above resolves its conflict back to a clean porcelain, which is
# what isolates the operation guard — and is also why the ORDER of the two guards
# was invisible to them. The ordinary way to meet a stopped operation is with the
# conflict still open, i.e. both guards firing at once, and then the diagnosis
# matters: "worktree has uncommitted changes; commit them" is advice that cannot
# be followed mid-merge and says nothing about the merge, while naming the merge
# tells the caller what is actually there. So the operation guard runs first, and
# this case is what holds it there.
RS7="$(make_repo rs-conflict)"
printf 'a\n' >"$RS7/f.txt"
git_quiet -C "$RS7" add -A
git_quiet -C "$RS7" commit -qm f1
git_quiet -C "$RS7" checkout -q -b cf-side
printf 'b\n' >"$RS7/f.txt"
git_quiet -C "$RS7" commit -qam s1
git_quiet -C "$RS7" checkout -q main
printf 'c\n' >"$RS7/f.txt"
git_quiet -C "$RS7" commit -qam m1
git_quiet -C "$RS7" branch cf-h
git_quiet -C "$RS7" worktree add -q "$RS7/.worktrees/$CONTAINER_NAME/cf-h" cf-h >/dev/null 2>&1
# Left UNRESOLVED this time: the index carries the conflict, so the porcelain is
# non-empty and the pre-existing uncommitted-changes guard would also fire.
git_quiet -C "$RS7/.worktrees/$CONTAINER_NAME/cf-h" merge cf-side >/dev/null 2>&1 || true
miss="$(wt_remove_must_refuse "a merge (MERGE_HEAD)" "$RS7" cf-h "$RS7/.git/worktrees/cf-h/MERGE_HEAD" dirty)"
if [ -z "$miss" ]; then
	ok "wt-remove names the OPERATION, not the dirt, for a merge stopped on an open conflict"
else
	no "wt-remove conflicted-merge diagnosis inadequate:$miss"
fi

# --- fail safe: state that cannot be READ must refuse, not permit -----------
# The opposite of wt-enter's bias, and correctly so: there an unknown blocker
# degrades to git's own message and costs nothing, here an unknown means we
# cannot PROVE the tree is safe to delete. Both halves of the lookup are pinned,
# each with a fixture that leaves git itself perfectly able to work in the
# worktree (`rev-parse` succeeds, the porcelain is empty) so that nothing but the
# unreadable metadata is under test.
#
# fs_case <label> <root> <slug> <before-hook> <after-hook> — break the metadata,
# run wt-remove both ways, restore, and report.
#
# Each refusal is also held to the two properties every wt-remove diagnostic has
# to have, which these paths are the natural place to pin because they are the
# only ones that print the ADMIN dir as well as the worktree: the worktree is
# NAMED (escaped, in the `at <path>` position the destructive_advice detector
# neutralises dynamic values in), and no terminal control byte reaches stderr
# raw. The control-byte repo below is what makes those two assertions bite; for
# an ordinary path they hold trivially and cost nothing.
fs_case() {
	local label="$1" root="$2" slug="$3" break_cmd="$4" restore_cmd="$5"
	local wt="$root/.worktrees/$CONTAINER_NAME/$slug" miss="" rc rcf
	# NB: no `label` here — that is this function's own first parameter.
	local gitdir="$root/.git/worktrees/$slug" errtext want mode tag
	eval "$break_cmd"
	rc=0
	(cd "$root" && bash "$WT_REMOVE" "$slug" 2>"$WORK_ROOT/fs-$slug.err") || rc=$?
	rcf=0
	(cd "$root" && bash "$WT_REMOVE" "$slug" --force 2>"$WORK_ROOT/fs-$slug-force.err") || rcf=$?
	# Tolerant on purpose: restoring the fixture is hygiene, and a helper that
	# FAILS this case has typically removed the very worktree the restore points
	# into. That must be reported as a failed assertion below, not as a `set -e`
	# abort that takes the rest of the suite (and the summary) with it.
	eval "$restore_cmd" 2>/dev/null || :
	[ "$rc" -ne 0 ] || miss="$miss REMOVED-ANYWAY"
	[ "$rcf" -ne 0 ] || miss="$miss force-REMOVED-ANYWAY"
	[ -d "$wt" ] || miss="$miss worktree-gone"
	# The worktree is named in the escaped spelling. Both invocations are held to
	# it: --force must not reach a different, laxer message.
	printf -v want "at %q" "$wt"
	for mode in "" "-force"; do
		tag="${mode:-plain}"
		errtext="$(cat "$WORK_ROOT/fs-$slug$mode.err")"
		grep -qF "refusing to remove it" "$WORK_ROOT/fs-$slug$mode.err" ||
			miss="$miss $tag-no-refusal-wording"
		case "$errtext" in *$'\033'*) miss="$miss $tag-raw-control-byte-on-stderr" ;; esac
		case "$errtext" in
		*"$want"*) ;;
		*) miss="$miss $tag-worktree-not-named" ;;
		esac
		# The admin dir is a dynamic value these messages echo back too, so it is
		# neutralised alongside the others — and BEFORE the root, which is a prefix
		# of it and would otherwise consume the anchor first.
		miss="$miss$(destructive_advice "$WORK_ROOT/fs-$slug$mode.err" "$wt" "$gitdir" "$root" "$slug")"
	done
	if [ -z "$miss" ]; then
		ok "$label"
	else
		no "$label — inadequate:$miss"
	fi
}

# (a) The REGISTRATION cannot be read, so the worktree's admin dir cannot even be
# identified. git needs no such lookup to operate inside the worktree — the
# `gitdir` file exists for `worktree prune` — so this is precisely the shape where
# the tree looks fine and its state is unknowable.
RF1="$(make_repo rf-registration)"
git_quiet -C "$RF1" worktree add -q "$RF1/.worktrees/$CONTAINER_NAME/opaque" -b opaque-b >/dev/null 2>&1
fs_case "wt-remove refuses when a worktree's registration cannot be read (fail safe)" \
	"$RF1" opaque \
	"chmod 000 '$RF1/.git/worktrees/opaque/gitdir'" \
	"chmod 644 '$RF1/.git/worktrees/opaque/gitdir'"

# (b) The admin dir resolves but is not READABLE, so its state files cannot be
# enumerated. Mode 111 is still traversable, so an `-e` probe BY NAME does answer
# correctly here — which is exactly why the guard requires `-r` as well and not
# just `-x`: a dir that cannot be listed is one whose contents nobody, including
# git itself, can establish, and "we could not read the state" has to mean refuse
# rather than "nothing in flight". Dropping the `-r` would also leave a mode-000
# dir (not traversable, `-e` then answers "absent" for every state file) resting
# on `-x` alone.
RF2="$(make_repo rf-admindir)"
git_quiet -C "$RF2" worktree add -q "$RF2/.worktrees/$CONTAINER_NAME/shut" -b shut-b >/dev/null 2>&1
fs_case "wt-remove refuses when a worktree's admin git dir is unreadable (fail safe)" \
	"$RF2" shut \
	"chmod 111 '$RF2/.git/worktrees/shut'" \
	"chmod 700 '$RF2/.git/worktrees/shut'"

# (c) `git status` itself FAILS. The sharpest shape of the fail-open trap: an
# unreadable index makes git exit non-zero with a COMPLETELY EMPTY stdout, so a
# guard written as `[ -z "$(git ... status --porcelain)" ]` reads the failure as
# "clean" and proceeds to delete a worktree it never checked. The exit status has
# to be captured separately from the output, and this is the case that says so.
RF3="$(make_repo rf-status)"
git_quiet -C "$RF3" worktree add -q "$RF3/.worktrees/$CONTAINER_NAME/noidx" -b noidx-b >/dev/null 2>&1
# Precondition: the fixture really does produce the empty-stdout failure (if git
# ever started reporting something on stdout here, this case would be proving the
# ordinary non-empty-porcelain path instead and would need rebuilding).
chmod 000 "$RF3/.git/worktrees/noidx/index"
fs_probe_out="$(git --git-dir="$RF3/.git/worktrees/noidx" --work-tree="$RF3/.worktrees/$CONTAINER_NAME/noidx" status --porcelain 2>/dev/null)" && fs_probe_rc=0 || fs_probe_rc=$?
chmod 644 "$RF3/.git/worktrees/noidx/index"
if [ "$fs_probe_rc" -ne 0 ] && [ -z "$fs_probe_out" ]; then
	fs_case "wt-remove refuses when the worktree's status cannot be read (empty stdout is not proof of clean)" \
		"$RF3" noidx \
		"chmod 000 '$RF3/.git/worktrees/noidx/index'" \
		"chmod 644 '$RF3/.git/worktrees/noidx/index'"
else
	no "precondition: an unreadable index should make 'git status --porcelain' fail with empty stdout (rc=$fs_probe_rc, out='$fs_probe_out')"
fi

# (d) The worktree has LOST ITS `.git` POINTER while holding real uncommitted
# work. This is the shape that makes reading the porcelain as `git -C "$wt"`
# unsafe rather than merely untidy: task worktrees live INSIDE the main working
# tree, so the probe resolves UPWARD into the enclosing checkout — which ignores
# `.worktrees/` in any real powbox repo — and reports a perfectly clean porcelain
# for a worktree full of uncommitted changes. Verified end to end on this
# fixture: `git -C "$wt" status --porcelain` prints NOTHING while seed.txt is
# modified. Reading through the registered git dir cannot make that mistake, and
# the refusal must name the uncommitted changes rather than fall through.
RF4="$(make_repo rf-nopointer)"
printf '.worktrees/\n' >"$RF4/.gitignore"
git_quiet -C "$RF4" add -A
git_quiet -C "$RF4" commit -qm "ignore .worktrees, as a real powbox repo does"
git_quiet -C "$RF4" worktree add -q "$RF4/.worktrees/$CONTAINER_NAME/nopt" -b nopt-b >/dev/null 2>&1
NOPT="$RF4/.worktrees/$CONTAINER_NAME/nopt"
printf 'work that exists nowhere else\n' >"$NOPT/seed.txt"
rm -f "$NOPT/.git"
miss=""
# Preconditions: the upward probe really is the misleading one here, and the
# enclosing checkout really is clean (else something else is being measured).
[ -n "$(git --git-dir="$RF4/.git/worktrees/nopt" --work-tree="$NOPT" status --porcelain)" ] ||
	miss="$miss fixture-worktree-not-actually-dirty"
[ -z "$(git -C "$NOPT" status --porcelain)" ] ||
	miss="$miss fixture-upward-probe-not-misleading"
for mode in plain force; do
	rc=0
	if [ "$mode" = plain ]; then
		(cd "$RF4" && bash "$WT_REMOVE" nopt 2>"$WORK_ROOT/rf4-$mode.err") || rc=$?
	else
		(cd "$RF4" && bash "$WT_REMOVE" nopt --force 2>"$WORK_ROOT/rf4-$mode.err") || rc=$?
	fi
	[ "$rc" -ne 0 ] || miss="$miss $mode-REMOVED-ANYWAY"
	[ -d "$NOPT" ] || miss="$miss $mode-worktree-gone"
	grep -qx "work that exists nowhere else" "$NOPT/seed.txt" 2>/dev/null ||
		miss="$miss $mode-uncommitted-work-lost"
	grep -qF "uncommitted changes" "$WORK_ROOT/rf4-$mode.err" ||
		miss="$miss $mode-dirt-not-named"
	miss="$miss$(destructive_advice "$WORK_ROOT/rf4-$mode.err" "$NOPT" "$RF4" nopt)"
done
if [ -z "$miss" ]; then
	ok "wt-remove reads the porcelain through the worktree's OWN git dir, not upward into the enclosing checkout"
else
	no "wt-remove porcelain-identity guard inadequate:$miss"
fi

# (e) The SAME two metadata refusals under a repo path carrying TERMINAL CONTROL
# BYTES. These messages print the admin git dir as well as the worktree, and both
# are attacker-chosen bytes: a raw ESC echoed back is a live ANSI sequence in the
# reader's terminal, in a message whose whole job is to be trusted about what
# must not be destroyed. fs_case asserts escaped-and-named on every refusal it
# drives; this repo is what gives that assertion something to catch.
CTRL_ESC=$'\033'
RF5="$(make_repo "rf-esc-${CTRL_ESC}[31mRED")"
git_quiet -C "$RF5" worktree add -q "$RF5/.worktrees/$CONTAINER_NAME/escreg" -b escreg-b >/dev/null 2>&1
git_quiet -C "$RF5" worktree add -q "$RF5/.worktrees/$CONTAINER_NAME/escdir" -b escdir-b >/dev/null 2>&1
case "$RF5" in
*"$CTRL_ESC"*)
	fs_case "wt-remove escapes control bytes when a worktree's registration cannot be read" \
		"$RF5" escreg \
		"chmod 000 \"\$RF5/.git/worktrees/escreg/gitdir\"" \
		"chmod 644 \"\$RF5/.git/worktrees/escreg/gitdir\""
	fs_case "wt-remove escapes control bytes when a worktree's admin git dir is unreadable" \
		"$RF5" escdir \
		"chmod 111 \"\$RF5/.git/worktrees/escdir\"" \
		"chmod 700 \"\$RF5/.git/worktrees/escdir\""
	;;
*) no "precondition: the control-byte repo path should carry an ESC byte" ;;
esac

# (f) The REF lookup itself FAILS. Probing the ref backend for the pseudo-ref
# markers added a second way for the operation state to be unknowable, and it has
# to fail in the same direction as everything else here: a `git show-ref` that
# DIES (exit 128) must not be read as "nothing in flight". One realistic shape is
# a git that cannot open the repository's ref storage at all — an older binary
# meeting `extensions.refStorage = reftable`, say — which is precisely why no
# fixture built with the one git on PATH can produce it. (It is not the only one:
# a marker pointing at an object a `git gc --prune=now` removed also exits 128,
# out of a repository that opens perfectly — measured under both backends, which
# is why the refusal message names the broader condition rather than blaming the
# ref storage.) It is forced instead
# with a `git` SHIM on PATH that fails exactly the `show-ref` call and delegates
# every other invocation to the real binary, since the failure is a property of
# the BINARY rather than of the repository. The worktree is otherwise pristine,
# so without this branch it is simply removed — which is what makes the case
# load-bearing rather than decorative.
RF6="$(make_repo rf-refstore)"
git_quiet -C "$RF6" worktree add -q "$RF6/.worktrees/$CONTAINER_NAME/rstore" -b rstore-b >/dev/null 2>&1
GIT_SHIM="$WORK_ROOT/git-shim"
mkdir -p "$GIT_SHIM"
{
	printf '#!/usr/bin/env bash\n'
	# shellcheck disable=SC2016 # the SHIM expands these, not this script
	printf 'for a in "$@"; do [ "$a" = show-ref ] && exit 128; done\n'
	printf 'exec %s "$@"\n' "$(printf '%q' "$(command -v git)")"
} >"$GIT_SHIM/git"
chmod 755 "$GIT_SHIM/git"
RF6_WT="$RF6/.worktrees/$CONTAINER_NAME/rstore"
miss=""
# Precondition: the shim really does break only show-ref.
rf6_rc=0
PATH="$GIT_SHIM:$PATH" git --git-dir="$RF6/.git/worktrees/rstore" show-ref --verify --quiet MERGE_HEAD 2>/dev/null || rf6_rc=$?
[ "$rf6_rc" -eq 128 ] || miss="$miss shim-does-not-fail-show-ref"
PATH="$GIT_SHIM:$PATH" git -C "$RF6_WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
	miss="$miss shim-broke-more-than-show-ref"
for mode in plain force; do
	rc=0
	if [ "$mode" = plain ]; then
		(cd "$RF6" && PATH="$GIT_SHIM:$PATH" bash "$WT_REMOVE" rstore 2>"$WORK_ROOT/rf6-$mode.err") || rc=$?
	else
		(cd "$RF6" && PATH="$GIT_SHIM:$PATH" bash "$WT_REMOVE" rstore --force 2>"$WORK_ROOT/rf6-$mode.err") || rc=$?
	fi
	[ "$rc" -ne 0 ] || miss="$miss $mode-REMOVED-ANYWAY"
	[ -d "$RF6_WT" ] || miss="$miss $mode-worktree-gone"
	# The refusal must name the ref lookup as the thing that failed, and say WHICH
	# name it died on — the two halves a reader needs. It must NOT diagnose it
	# narrowly as unreadable ref storage: exit 128 also comes out of a perfectly
	# readable storage holding a marker whose target object was pruned away
	# (measured under both backends), so the message states the broader condition.
	grep -qF "the ref lookup failed outright" "$WORK_ROOT/rf6-$mode.err" ||
		miss="$miss $mode-ref-lookup-failure-not-named"
	grep -qF "looking up MERGE_HEAD" "$WORK_ROOT/rf6-$mode.err" ||
		miss="$miss $mode-failing-marker-not-named"
	grep -qF "refusing to remove it" "$WORK_ROOT/rf6-$mode.err" ||
		miss="$miss $mode-no-refusal-wording"
	miss="$miss$(destructive_advice "$WORK_ROOT/rf6-$mode.err" "$RF6_WT" "$RF6" rstore)"
done
if [ -z "$miss" ]; then
	ok "wt-remove refuses when the REF lookup for a state marker fails (a dead show-ref is not 'nothing in flight')"
else
	no "wt-remove ref-lookup fail-safe inadequate:$miss"
fi

# (g) The same refusal reached from the REPOSITORY side instead of the binary's.
# Under `reftable` the ref storage is a directory, and a mode-000 `reftable/` is
# one this git cannot read — no shim needed. The point of the case is WHICH probe
# notices, and WHICH diagnosis comes out: `show-ref --verify --quiet` answers 1
# there, "absent" (measured), so on that probe alone the operation guard walks the
# whole state list finding nothing and the refusal falls through to the
# uncommitted-changes check below it, which reports "worktree has uncommitted
# changes" about a repository whose refs simply cannot be READ (measured — the
# worktree does survive, by accident and under the wrong name). `symbolic-ref
# --quiet` exits 128, which is why it carries the same 0/1/refuse contract as
# probe 2 rather than being read as a plain yes/no, and why the lookup failure is
# named as itself rather than as dirt.
if [ -z "$REFTABLE_OK" ]; then
	skip "an unreadable reftable ref storage (this git cannot create a --ref-format=reftable repo)"
else
	RF7="$(make_repo rf-reftable --ref-format=reftable)"
	git_quiet -C "$RF7" worktree add -q "$RF7/.worktrees/$CONTAINER_NAME/rtstore" -b rtstore-b >/dev/null 2>&1
	rf7_rc=0
	chmod 000 "$RF7/.git/worktrees/rtstore/reftable"
	git --git-dir="$RF7/.git/worktrees/rtstore" show-ref --verify --quiet CHERRY_PICK_HEAD 2>/dev/null || rf7_rc=$?
	chmod 755 "$RF7/.git/worktrees/rtstore/reftable"
	[ "$rf7_rc" -eq 1 ] ||
		no "precondition: an unreadable reftable/ should make show-ref answer 1 (absent), which is what makes this case load-bearing (got $rf7_rc)"
	fs_case "wt-remove refuses when a reftable ref storage cannot be READ (show-ref calls it absent, symbolic-ref does not)" \
		"$RF7" rtstore \
		"chmod 000 '$RF7/.git/worktrees/rtstore/reftable'" \
		"chmod 755 '$RF7/.git/worktrees/rtstore/reftable'"
fi

# ---------------------------------------------------------------------------
# Integration: the inspection commands wt-remove offers must be PASTEABLE, the
# same property wt-enter's spaced-path case pins for its own advice further down.
# The two helpers share one message shape — `look at it yourself: '<command>'`,
# with the command DELIMITED by single quotes in the prose and the path inside it
# rendered by `shq` — so a reader lifts what is between the delimiters and the
# quoting inside it is what survives a path containing spaces or a quote of its
# own. That split is the whole contract: the outer quotes mark where the command
# ends in a sentence that keeps going (`(and '…'), or coordinate with …`), and
# `shq` makes the command reach the intended worktree and nothing else.
#
# It is worth pinning HERE, on the refusal side, rather than leaning on the
# wt-enter case: wt-remove is the helper that emits TWO commands on one line (the
# bisect refusals carry the extra `bisect log` hint), which is exactly where a
# missing delimiter would leave the boundary between them unreadable. Both are
# extracted from between their delimiters and RUN, as `rev-parse` rather than
# `status`/`log` so the answer is comparable, and both must land on the bisecting
# worktree — under a path carrying a space AND a single quote, the two characters
# that break an unquoted paste and an unescaped one respectively.
# ---------------------------------------------------------------------------
RQ="$(make_repo "rq s'p")"
WBQ="$RQ/.worktrees/$CONTAINER_NAME"
EQ="$WORK_ROOT/rq.err"
git_quiet -C "$RQ" branch bq-b
git_quiet -C "$RQ" worktree add -q "$WBQ/task-q" bq-b >/dev/null 2>&1
git_quiet -C "$WBQ/task-q" bisect start >/dev/null 2>&1 || true
if [ ! -e "$RQ/.git/worktrees/task-q/BISECT_START" ]; then
	no "precondition: bisect did not start in the spaced-path worktree of $RQ"
elif (cd "$RQ" && bash "$WT_REMOVE" task-q 2>"$EQ"); then
	no "wt-remove must refuse a bisecting worktree under a spaced path"
else
	miss=""
	# The quoted spelling is what is offered; the raw one — which would paste as
	# `git -C <first-word>` and hand the rest of the path to git as arguments —
	# must not appear anywhere on stderr.
	printf -v want_status 'git -C %q status' "$WBQ/task-q"
	printf -v want_bisect 'git -C %q bisect log' "$WBQ/task-q"
	grep -qF "$want_status" "$EQ" || miss="$miss no-quoted-status-hint"
	grep -qF "$want_bisect" "$EQ" || miss="$miss no-quoted-bisect-hint"
	! grep -qF "git -C $WBQ/task-q status" "$EQ" || miss="$miss unquoted-path"
	# End-to-end, per command: lift it from between its delimiters and run it.
	q_status="$(LC_ALL=C sed -n "s/^wt-remove: look at it yourself: '\(git -C .* status\)'.*/\1/p" "$EQ" | head -1)"
	q_bisect="$(LC_ALL=C sed -n "s/.*(and '\(git -C .* bisect log\)').*/\1/p" "$EQ" | head -1)"
	for hint in "$q_status" "$q_bisect"; do
		if [ -z "$hint" ]; then
			miss="$miss no-inspection-command"
			continue
		fi
		# Strip the trailing subcommand (`status`, or `bisect log`) and ask the
		# `git -C <path>` prefix that remains which tree it actually reaches. The
		# path token is left exactly as printed — it is the thing under test, and
		# it carries the escapes that must survive the shell.
		case "$hint" in
		*" status") prefix="${hint% status}" ;;
		*" bisect log") prefix="${hint% bisect log}" ;;
		*)
			miss="$miss unrecognized-hint-shape"
			continue
			;;
		esac
		got="$(eval "$prefix rev-parse --show-toplevel" 2>/dev/null || true)"
		[ "$got" = "$WBQ/task-q" ] || miss="$miss inspection-command-not-pasteable"
	done
	miss="$miss$(destructive_advice "$EQ" "$WBQ/task-q" "$RQ" task-q)"
	if [ -z "$miss" ]; then
		ok "wt-remove's inspection hints paste verbatim from between their delimiters"
	else
		no "wt-remove spaced-path refusal advice inadequate:$miss"
	fi
fi

# --- and NO false refusals: a clean worktree is still removed with no friction
# wt-remove is called by the batch skills after every PR is opened, so a guard
# that refused a clean tree would be its own kind of breakage.
RC1="$(make_repo rc-clean)"
git_quiet -C "$RC1" worktree add -q "$RC1/.worktrees/$CONTAINER_NAME/clean" -b clean-b >/dev/null 2>&1
if (cd "$RC1" && bash "$WT_REMOVE" clean 2>"$WORK_ROOT/rc.err") &&
	[ ! -e "$RC1/.worktrees/$CONTAINER_NAME/clean" ] &&
	git -C "$RC1" show-ref --verify --quiet refs/heads/clean-b; then
	ok "wt-remove still removes a clean, operation-free worktree (branch kept)"
else
	no "wt-remove refused or mishandled a clean worktree: $(cat "$WORK_ROOT/rc.err")"
fi

# ...and a BRANCH named after a state marker is not a state marker. This is what
# decides HOW the ref-backed markers may be looked up: `rev-parse --verify <name>`
# DWIMs through git's ref_rev_parse_rules and so also matches `refs/heads/<name>`
# (measured — it answers for a branch called `MERGE_HEAD`, `sequencer` or
# `rebase-apply` alike), which would refuse EVERY worktree in such a repository,
# forever, whether or not anything is in flight. `show-ref --verify` takes an
# exact ref path and cannot make that mistake, and neither does `symbolic-ref`,
# which reads the name as given. Branch names are chosen by task files and by
# people, so this is data, exactly like the hostile branch names the
# destructive_advice detector has to survive.
#
# It is run under BOTH ref backends, because where a DWIMing lookup would FIND
# the branch differs: under `files` a branch is a loose file beneath
# `refs/heads/`, under `reftable` it is a record in the very table the guarded
# pseudo-refs live in — the storage in which an inexact lookup has the least
# distance to travel to reach the wrong answer.
marker_branch_case() { # <backend label> <repo name> <slug> [<git init flag>...]
	local root backend="$1" name="$2" slug="$3" b
	shift 3
	root="$(make_repo "$name" "$@")"
	for b in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD NOTES_MERGE_PARTIAL NOTES_MERGE_REF sequencer rebase-apply rebase-merge BISECT_LOG BISECT_START; do
		git_quiet -C "$root" branch "$b" >/dev/null 2>&1 ||
			no "precondition: git refused to create a branch named '$b'"
	done
	git_quiet -C "$root" worktree add -q "$root/.worktrees/$CONTAINER_NAME/$slug" -b "$slug-b" >/dev/null 2>&1
	if (cd "$root" && bash "$WT_REMOVE" "$slug" 2>"$WORK_ROOT/$slug.err") &&
		[ ! -e "$root/.worktrees/$CONTAINER_NAME/$slug" ] &&
		git -C "$root" show-ref --verify --quiet "refs/heads/$slug-b"; then
		ok "wt-remove is not fooled by BRANCHES named after the state markers, $backend backend (the ref probes are exact, not DWIM)"
	else
		no "wt-remove FALSE-REFUSED a clean worktree in a repo holding branches named after state markers, $backend backend: $(cat "$WORK_ROOT/$slug.err")"
	fi
}
marker_branch_case files rc-markerbranch mb
if [ -z "$REFTABLE_OK" ]; then
	skip "branches named after the state markers under the reftable backend (this git cannot create a --ref-format=reftable repo)"
else
	marker_branch_case reftable rc-markerbranch-rt mbrt --ref-format=reftable
fi

# The main checkout being mid-operation must not leak into a task worktree's
# verdict: the state is read from the worktree's OWN admin dir, and the primary
# checkout's `.git` is a different one. A bisecting main tree is the case that
# would misfire if the two were ever conflated.
RC2="$(make_repo rc-mainbisect)"
for i in 1 2 3; do
	echo "rev $i" >"$RC2/seed.txt"
	git_quiet -C "$RC2" commit -qam "c$i"
done
git_quiet -C "$RC2" worktree add -q "$RC2/.worktrees/$CONTAINER_NAME/sib" -b sib-b >/dev/null 2>&1
git_quiet -C "$RC2" bisect start HEAD HEAD~2 >/dev/null 2>&1 || true
if [ -e "$RC2/.git/BISECT_LOG" ]; then
	if (cd "$RC2/.worktrees/$CONTAINER_NAME" && bash "$WT_REMOVE" sib 2>"$WORK_ROOT/rc2.err") &&
		[ ! -e "$RC2/.worktrees/$CONTAINER_NAME/sib" ] &&
		[ -e "$RC2/.git/BISECT_LOG" ]; then
		ok "a bisect in the MAIN checkout does not block removing a clean task worktree"
	else
		no "wt-remove read the main checkout's operation state as the worktree's own: $(cat "$WORK_ROOT/rc2.err")"
	fi
else
	no "precondition: bisect did not start in the main checkout of $RC2"
fi

# --force still reaches `git worktree remove` once the clean checks pass — it is
# gated, not disabled. Ignored build artifacts are the case it exists for.
RC3="$(make_repo rc-force)"
printf 'build/\n' >"$RC3/.gitignore"
git_quiet -C "$RC3" add -A
git_quiet -C "$RC3" commit -qm ignore
git_quiet -C "$RC3" worktree add -q "$RC3/.worktrees/$CONTAINER_NAME/art" -b art-b >/dev/null 2>&1
mkdir -p "$RC3/.worktrees/$CONTAINER_NAME/art/build"
echo artifact >"$RC3/.worktrees/$CONTAINER_NAME/art/build/out.o"
if [ -z "$(git -C "$RC3/.worktrees/$CONTAINER_NAME/art" status --porcelain)" ] &&
	(cd "$RC3" && bash "$WT_REMOVE" art --force 2>"$WORK_ROOT/rc3.err") &&
	[ ! -e "$RC3/.worktrees/$CONTAINER_NAME/art" ] &&
	git -C "$RC3" show-ref --verify --quiet refs/heads/art-b; then
	ok "wt-remove --force still removes a clean worktree carrying ignored build artifacts (branch kept)"
else
	no "wt-remove --force did not remove a clean worktree with ignored artifacts: $(cat "$WORK_ROOT/rc3.err")"
fi

# `locked` is EXCLUDED from the guard set on purpose (see the audit block in
# wt-remove): a `git worktree lock` holds no work in flight, so wt-remove neither
# refuses on it nor overrides it — it is left ENTIRELY to git, which declines a
# single `--force` exactly as vanilla `git worktree remove --force` does and
# wants `-f -f` (which this script never passes). Pinned so the exclusion stays
# checkable: the outcome must be GIT's refusal (exit 128, git's own wording), not
# a `wt-remove:` refusal and not a removal.
RCL="$(make_repo rc-locked)"
git_quiet -C "$RCL" worktree add -q "$RCL/.worktrees/$CONTAINER_NAME/lk" -b lk-b >/dev/null 2>&1
git_quiet -C "$RCL" worktree lock "$RCL/.worktrees/$CONTAINER_NAME/lk" >/dev/null 2>&1 || true
LK_WT="$RCL/.worktrees/$CONTAINER_NAME/lk"
miss=""
[ -e "$RCL/.git/worktrees/lk/locked" ] || miss="$miss fixture-not-locked"
[ -z "$(git -C "$LK_WT" status --porcelain 2>/dev/null)" ] || miss="$miss fixture-porcelain-not-clean"
if [ -z "$miss" ]; then
	for lk_mode in plain force; do
		rc=0
		if [ "$lk_mode" = plain ]; then
			(cd "$RCL" && bash "$WT_REMOVE" lk 2>"$WORK_ROOT/rcl-$lk_mode.err") || rc=$?
		else
			(cd "$RCL" && bash "$WT_REMOVE" lk --force 2>"$WORK_ROOT/rcl-$lk_mode.err") || rc=$?
		fi
		[ "$rc" -eq 128 ] || miss="$miss $lk_mode-rc-$rc-not-128"
		[ -d "$LK_WT" ] || miss="$miss $lk_mode-worktree-gone"
		grep -qF 'cannot remove a locked working tree' "$WORK_ROOT/rcl-$lk_mode.err" ||
			miss="$miss $lk_mode-not-gits-own-refusal"
		! grep -q '^wt-remove: .* is in progress' "$WORK_ROOT/rcl-$lk_mode.err" ||
			miss="$miss $lk_mode-wt-remove-guarded-it"
	done
	# And the same invocation against vanilla git, so "matches vanilla" is
	# asserted rather than assumed: `--force` refuses identically, `-f -f` removes.
	rc=0
	git -C "$RCL" worktree remove --force "$LK_WT" >/dev/null 2>"$WORK_ROOT/rcl-vanilla.err" || rc=$?
	[ "$rc" -eq 128 ] || miss="$miss vanilla-force-rc-$rc-not-128"
	[ -d "$LK_WT" ] || miss="$miss vanilla-force-removed-it"
	if [ -z "$miss" ]; then
		ok "a locked but clean worktree is left to git: wt-remove (with and without --force) exits 128 with git's own 'cannot remove a locked working tree', same as vanilla --force"
	else
		no "wt-remove's handling of a locked worktree diverged from git's own:$miss"
	fi
else
	no "precondition: could not fabricate a clean, locked worktree:$miss"
fi

# A CONCLUDED notes merge must still remove. This is the case that decides WHICH
# notes marker the guard may probe, and it is not academic: `NOTES_MERGE_WORKTREE`
# — the directory git's own error message points the user at — SURVIVES both
# termination paths as an empty dir, and git treats an empty one as "no merge in
# progress" (a fresh `git notes merge` starts fine beside it). Guarding it with
# `-e` would refuse every worktree that had ever finished a notes merge, forever.
# NOTES_MERGE_PARTIAL and NOTES_MERGE_REF are cleared by BOTH paths, which is why
# they are what the guard keys on; both paths are pinned here so a later widening
# of the guard to the directory cannot pass unnoticed.
for nm_end in abort commit; do
	RC4="$(notes_merge_repo "rc-notes-$nm_end" "nm$nm_end")"
	NM_WT="$RC4/.worktrees/$CONTAINER_NAME/nm$nm_end"
	NM_GD="$RC4/.git/worktrees/nm$nm_end"
	if [ "$nm_end" = commit ]; then
		# Resolve the conflicted note, then conclude the merge for real.
		for nm_f in "$NM_GD/NOTES_MERGE_WORKTREE"/*; do
			[ -e "$nm_f" ] || continue
			printf 'resolved\n' >"$nm_f"
		done
	fi
	git_quiet -C "$NM_WT" notes merge "--$nm_end" >/dev/null 2>&1 || true
	miss=""
	[ ! -e "$NM_GD/NOTES_MERGE_PARTIAL" ] || miss="$miss fixture-PARTIAL-not-cleared"
	[ ! -e "$NM_GD/NOTES_MERGE_REF" ] || miss="$miss fixture-REF-not-cleared"
	# The precondition that makes this case worth having: the directory is still
	# there. If git ever starts removing it, this assertion is the thing that says
	# the exclusion can be revisited.
	[ -d "$NM_GD/NOTES_MERGE_WORKTREE" ] || miss="$miss fixture-dir-no-longer-survives"
	if [ -z "$miss" ]; then
		if (cd "$RC4" && bash "$WT_REMOVE" "nm$nm_end" 2>"$WORK_ROOT/rc4-$nm_end.err") &&
			[ ! -e "$NM_WT" ]; then
			ok "wt-remove still removes a worktree whose notes merge was concluded with --$nm_end (the leftover NOTES_MERGE_WORKTREE dir is not state)"
		else
			no "wt-remove FALSE-REFUSED a worktree after 'git notes merge --$nm_end': $(cat "$WORK_ROOT/rc4-$nm_end.err")"
		fi
	else
		no "precondition: 'git notes merge --$nm_end' should clear both markers and leave the dir:$miss"
	fi
done

# SQUASH_MSG is EXCLUDED from the guard set, and this is where that decision is
# recorded as an observation rather than as a principle. `git merge --squash`
# writes SQUASH_MSG but leaves NO operation git tracks — no MERGE_HEAD, and
# `git merge --abort` answers "There is no merge to abort" — so the guard set,
# which is keyed on what git itself consults, does not see it. Guarding it anyway
# was considered and rejected on the measurement below: `git restore` ABANDONS a
# squash merge WITHOUT clearing SQUASH_MSG, so the marker outlives the operation
# with a fully clean tree, and a guard would refuse such a worktree until some
# later commit happened to unlink the file. The cost of not guarding — the one
# shape knowingly removed — is pinned right after, so it cannot change silently.
#
# squash_repo <name> <slug> [<shape>] -> echoes ROOT with worktree <slug>
# holding an UNCONCLUDED `git merge --squash`.
#
# <shape> decides WHAT the squashed branch changed, and that matters: the discard
# command which abandons the squash into a clean tree is shape-dependent.
#   add (default) the branch ADDS sq.txt. `git checkout HEAD -- .` cannot unstage
#                 it (the path is absent from HEAD), so the porcelain stays `A`.
#   mod           the branch MODIFIES the tracked seed.txt. `git checkout
#                 HEAD -- .` DOES unstage that (it writes HEAD's blob into the
#                 index), so this is the shape that reaches the same clean tree
#                 with a surviving SQUASH_MSG that `git restore` reaches — the
#                 second false-refusal shape, pinned in (d) below.
squash_repo() {
	local root slug="$2" shape="${3:-add}"
	root="$(make_repo "$1")"
	git_quiet -C "$root" branch "$slug-src" >/dev/null 2>&1
	git_quiet -C "$root" worktree add -q "$root/.worktrees/$CONTAINER_NAME/$slug" -b "$slug-b" >/dev/null 2>&1
	# Give <slug>-src a commit the worktree's own branch does not have, from a
	# THIRD worktree so the main checkout stays on its own branch.
	git_quiet -C "$root" worktree add -q "$root/.src-$slug" "$slug-src" >/dev/null 2>&1
	if [ "$shape" = mod ]; then
		echo squashed >"$root/.src-$slug/seed.txt"
	else
		echo squashed >"$root/.src-$slug/sq.txt"
	fi
	git_quiet -C "$root/.src-$slug" add -A >/dev/null 2>&1
	git_quiet -C "$root/.src-$slug" commit -qm "to squash" >/dev/null 2>&1
	git_quiet -C "$root/.worktrees/$CONTAINER_NAME/$slug" merge --squash "$slug-src" >/dev/null 2>&1 || true
	printf '%s' "$root"
}

# (a) GIT'S OWN VERDICT on the abandoned-with-`restore` state, in its own
#     fixture. This probe MUTATES the worktree (a successful merge writes a
#     commit and unlinks SQUASH_MSG), which is exactly why it cannot share a
#     fixture with the removal case below — doing so would hand wt-remove a
#     worktree with no SQUASH_MSG left and quietly stop testing anything.
RSQ0="$(squash_repo rc-squash-verdict sqv)"
SQ0_WT="$RSQ0/.worktrees/$CONTAINER_NAME/sqv"
SQ0_GD="$RSQ0/.git/worktrees/sqv"
git_quiet -C "$SQ0_WT" restore --staged --worktree . >/dev/null 2>&1 || true
miss=""
[ -e "$SQ0_GD/SQUASH_MSG" ] || miss="$miss SQUASH_MSG-cleared-by-restore"
[ -z "$(git -C "$SQ0_WT" status --porcelain 2>/dev/null)" ] || miss="$miss porcelain-not-clean"
# `git merge --abort` is git saying, in its own words, that it is not in a merge.
git_quiet -C "$SQ0_WT" merge --abort >/dev/null 2>"$WORK_ROOT/rc-sqv-abort.err" &&
	miss="$miss merge--abort-unexpectedly-succeeded"
grep -qF 'There is no merge to abort' "$WORK_ROOT/rc-sqv-abort.err" ||
	miss="$miss merge--abort-did-not-say-there-is-no-merge"
# And a fresh merge from that state starts and succeeds, the same way a fresh
# `git notes merge` starts beside a leftover NOTES_MERGE_WORKTREE.
git_quiet -C "$SQ0_WT" merge --no-edit sqv-src >/dev/null 2>&1 ||
	miss="$miss fresh-merge-blocked-so-something-IS-in-flight"
if [ -z "$miss" ]; then
	ok "git itself treats a squash merge abandoned with 'git restore' as nothing in progress (no merge to abort, a fresh merge starts) even though SQUASH_MSG survives"
else
	no "the basis of the SQUASH_MSG exclusion no longer holds:$miss"
fi

# (b) the FALSE-REFUSAL case proper, on an UNPROBED fixture: that same stale
#     SQUASH_MSG with a clean tree must still be REMOVED, with and without
#     --force. This is the observation that decides the exclusion — guarding
#     SQUASH_MSG would refuse this worktree until some later commit happened to
#     unlink the file.
for sq_mode in plain force; do
	RSQ1="$(squash_repo "rc-squash-restore-$sq_mode" "sqr$sq_mode")"
	SQ1_WT="$RSQ1/.worktrees/$CONTAINER_NAME/sqr$sq_mode"
	SQ1_GD="$RSQ1/.git/worktrees/sqr$sq_mode"
	git_quiet -C "$SQ1_WT" restore --staged --worktree . >/dev/null 2>&1 || true
	miss=""
	[ -e "$SQ1_GD/SQUASH_MSG" ] || miss="$miss fixture-SQUASH_MSG-cleared-by-restore"
	[ -z "$(git -C "$SQ1_WT" status --porcelain 2>/dev/null)" ] || miss="$miss fixture-porcelain-not-clean"
	if [ -z "$miss" ]; then
		rc=0
		if [ "$sq_mode" = plain ]; then
			(cd "$RSQ1" && bash "$WT_REMOVE" "sqr$sq_mode" 2>"$WORK_ROOT/rc-sqr-$sq_mode.err") || rc=$?
		else
			(cd "$RSQ1" && bash "$WT_REMOVE" "sqr$sq_mode" --force 2>"$WORK_ROOT/rc-sqr-$sq_mode.err") || rc=$?
		fi
		[ "$rc" -eq 0 ] || miss="$miss rc-$rc-not-0"
		[ ! -e "$SQ1_WT" ] || miss="$miss worktree-still-present"
		if [ -z "$miss" ]; then
			ok "wt-remove ($sq_mode) still removes a worktree whose squash merge was abandoned with 'git restore' — SQUASH_MSG outlives it with a clean tree, so guarding it would false-refuse"
		else
			no "wt-remove ($sq_mode) FALSE-REFUSED a worktree carrying only a stale SQUASH_MSG:$miss $(cat "$WORK_ROOT/rc-sqr-$sq_mode.err")"
		fi
	else
		no "precondition: 'git restore --staged --worktree .' should abandon a squash merge leaving a stale SQUASH_MSG and a clean tree ($sq_mode):$miss"
	fi
done

# (c) the COST of that exclusion, pinned: an UNCONCLUDED squash whose result
#     equals HEAD's own content has an EMPTY porcelain, so neither the operation
#     guard nor the uncommitted-changes guard holds it, and wt-remove removes it
#     — with and without --force. Only the pending message is lost. Asserted so
#     the trade-off stays visible and a later change of mind is a test change.
for sq_mode in plain force; do
	RSQ2="$(squash_repo "rc-squash-noop-$sq_mode" "sqn$sq_mode")"
	SQ2_WT="$RSQ2/.worktrees/$CONTAINER_NAME/sqn$sq_mode"
	SQ2_GD="$RSQ2/.git/worktrees/sqn$sq_mode"
	# Resolve the squash back to HEAD's own content: drop the staged file, so the
	# index and the tree match HEAD while SQUASH_MSG still marks a live squash.
	git_quiet -C "$SQ2_WT" rm -q -f --cached sq.txt >/dev/null 2>&1 || true
	rm -f "$SQ2_WT/sq.txt"
	miss=""
	[ -e "$SQ2_GD/SQUASH_MSG" ] || miss="$miss fixture-SQUASH_MSG-missing"
	[ -z "$(git -C "$SQ2_WT" status --porcelain 2>/dev/null)" ] || miss="$miss fixture-porcelain-not-clean"
	if [ -z "$miss" ]; then
		rc=0
		if [ "$sq_mode" = plain ]; then
			(cd "$RSQ2" && bash "$WT_REMOVE" "sqn$sq_mode" 2>"$WORK_ROOT/rc-sqn-$sq_mode.err") || rc=$?
		else
			(cd "$RSQ2" && bash "$WT_REMOVE" "sqn$sq_mode" --force 2>"$WORK_ROOT/rc-sqn-$sq_mode.err") || rc=$?
		fi
		[ "$rc" -eq 0 ] || miss="$miss rc-$rc-not-0"
		[ ! -e "$SQ2_WT" ] || miss="$miss worktree-still-present"
		git -C "$RSQ2" show-ref --verify --quiet "refs/heads/sqn$sq_mode-b" || miss="$miss branch-deleted"
		if [ -z "$miss" ]; then
			ok "wt-remove ($sq_mode) removes a worktree holding a no-change 'merge --squash' — the one shape knowingly removed, and only its pending message is lost"
		else
			no "the documented no-change squash outcome changed:$miss $(cat "$WORK_ROOT/rc-sqn-$sq_mode.err")"
		fi
	else
		no "precondition: could not fabricate a no-change unconcluded squash merge ($sq_mode):$miss"
	fi
done

# (d) the SECOND false-refusal shape, on the `mod` fixture: `git checkout
#     HEAD -- .` also abandons a squash into a clean tree with SQUASH_MSG
#     surviving, because it writes HEAD's blob into the index and so unstages a
#     MODIFIED tracked file. Pinned separately from (b) because the `add` fixture
#     structurally cannot reach it — `checkout HEAD -- .` leaves an added path
#     staged, which the porcelain guard then holds. Without this case the
#     audit comment's claim about `checkout HEAD -- .` rests on nothing the suite
#     runs. Both halves of that claim are asserted: `git checkout -- .` must
#     leave the tree DIRTY (guard holds it) and `git checkout HEAD -- .` must
#     leave it CLEAN (guard must not hold it). --force adds no dimension here —
#     (b) already pins that the refusal-or-not is mode-independent — so this runs
#     plain only.
RSQ3="$(squash_repo rc-squash-cohead sqc mod)"
SQ3_WT="$RSQ3/.worktrees/$CONTAINER_NAME/sqc"
SQ3_GD="$RSQ3/.git/worktrees/sqc"
miss=""
# Half one: the non-unstaging spelling leaves the porcelain dirty.
git_quiet -C "$SQ3_WT" checkout -- . >/dev/null 2>&1 || true
[ -n "$(git -C "$SQ3_WT" status --porcelain 2>/dev/null)" ] ||
	miss="$miss checkout--dot-unexpectedly-cleaned-the-tree"
# Half two: the HEAD spelling unstages, landing on a clean tree + stale marker.
git_quiet -C "$SQ3_WT" checkout HEAD -- . >/dev/null 2>&1 || true
[ -e "$SQ3_GD/SQUASH_MSG" ] || miss="$miss fixture-SQUASH_MSG-cleared-by-checkout-HEAD"
[ -z "$(git -C "$SQ3_WT" status --porcelain 2>/dev/null)" ] || miss="$miss fixture-porcelain-not-clean"
if [ -z "$miss" ]; then
	rc=0
	(cd "$RSQ3" && bash "$WT_REMOVE" sqc 2>"$WORK_ROOT/rc-sqc.err") || rc=$?
	[ "$rc" -eq 0 ] || miss="$miss rc-$rc-not-0"
	[ ! -e "$SQ3_WT" ] || miss="$miss worktree-still-present"
	git -C "$RSQ3" show-ref --verify --quiet refs/heads/sqc-b || miss="$miss branch-deleted"
	if [ -z "$miss" ]; then
		ok "wt-remove still removes a worktree whose squash merge was abandoned with 'git checkout HEAD -- .' — it unstages a modified tracked file, so that is a SECOND stale-SQUASH_MSG shape a guard would false-refuse"
	else
		no "wt-remove FALSE-REFUSED a worktree carrying only a stale SQUASH_MSG after 'git checkout HEAD -- .':$miss $(cat "$WORK_ROOT/rc-sqc.err")"
	fi
else
	no "precondition: 'git checkout -- .' should leave a modify-shape squash dirty and 'git checkout HEAD -- .' should clean it while SQUASH_MSG survives:$miss"
fi

# ---------------------------------------------------------------------------
# Integration: wt-enter names the PRIMARY checkout when it is what blocks the
# branch (a human or peer agent switched the shared main working tree onto it).
# The error must identify the main checkout, flag that it is shared, and point
# at coordination — never auto-detach — and stdout must stay empty on failure.
# ---------------------------------------------------------------------------
R5="$(make_repo r5)"
E5="$WORK_ROOT/r5.err"
# make_repo leaves the primary checkout on 'main', so requesting a worktree on
# 'main' is blocked by the primary checkout itself.
rc5=0
out="$(cd "$R5" && bash "$WT_ENTER" task-e main 2>"$E5")" || rc5=$?
if [ "$rc5" -eq 0 ]; then
	no "wt-enter must fail when the branch is checked out in the primary checkout (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	# git's own status is PROPAGATED, not flattened: `git worktree add` fails
	# fatally with 128, and a caller distinguishing git's refusal from wt-enter's
	# own usage/validation errors (which `die` with 1) needs that to survive.
	[ "$rc5" -eq 128 ] || miss="$miss exit-status-$rc5"
	grep -qiF "primary" "$E5" || miss="$miss no-primary-wording"
	# The path must appear on wt-enter's OWN line, not only in git's fatal.
	grep -F "$R5" "$E5" | grep -q '^wt-enter:' || miss="$miss no-primary-path"
	grep -qiF "shared" "$E5" || miss="$miss no-shared-warning"
	grep -qiF "coordinate" "$E5" || miss="$miss no-coordination-hint"
	# The shared main checkout is the worst thing to be told to discard, so the
	# non-destruction invariant is pinned for this message too.
	miss="$miss$(destructive_advice "$E5" "$R5/.worktrees/$CONTAINER_NAME/task-e" "$R5" task-e main)"
	# Nothing may be silently remediated: the main checkout stays on 'main' and
	# no worktree is left behind.
	[ "$(git -C "$R5" branch --show-current)" = "main" ] || miss="$miss primary-branch-moved"
	[ ! -e "$R5/.worktrees/$CONTAINER_NAME/task-e" ] || miss="$miss worktree-created"
	if [ -z "$miss" ]; then
		ok "wt-enter names the shared primary checkout when it blocks the branch"
	else
		no "wt-enter primary-checkout conflict message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: the same, with the primary checkout DETACHED by a bisect. It is
# still holding 'main' as far as git is concerned, but the porcelain says
# `detached`, so the answer has to come from the primary's own operation state —
# and the main working tree is the one checkout with no admin dir of its own (its
# git dir IS the common dir), i.e. the branch of the lookup that has no `gitdir`
# file to match. Getting it wrong loses the loudest message wt-enter has.
# ---------------------------------------------------------------------------
RY="$(make_repo ry)"
EY="$WORK_ROOT/ry.err"
for i in 1 2 3; do
	echo "rev $i" >"$RY/seed.txt"
	git_quiet -C "$RY" commit -qam "c$i"
done
git_quiet -C "$RY" bisect start HEAD HEAD~2 >/dev/null 2>&1 || true
if git -C "$RY" worktree list --porcelain | grep -qx detached; then
	if out="$(cd "$RY" && bash "$WT_ENTER" task-y main 2>"$EY")"; then
		no "wt-enter must fail when a bisecting primary checkout holds the branch (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		grep -qiF "primary" "$EY" || miss="$miss no-primary-wording"
		grep -F "$RY" "$EY" | grep -q '^wt-enter:' || miss="$miss no-primary-path"
		grep -qiF "coordinate" "$EY" || miss="$miss no-coordination-hint"
		miss="$miss$(destructive_advice "$EY" "$RY/.worktrees/$CONTAINER_NAME/task-y" "$RY" task-y main)"
		[ ! -e "$RY/.worktrees/$CONTAINER_NAME/task-y" ] || miss="$miss worktree-created"
		if [ -z "$miss" ]; then
			ok "wt-enter names the primary checkout even when a bisect leaves it detached"
		else
			no "wt-enter detached-primary conflict message inadequate:$miss"
		fi
	fi
else
	no "precondition: bisect did not leave the primary checkout of $RY detached"
fi

# ---------------------------------------------------------------------------
# Integration: blocked by a SIBLING task worktree keeps the ordinary semantics
# (failure, empty stdout) but must surface the blocking worktree path rather
# than swallowing it — and must NOT claim the primary checkout is involved.
# The hand-over is non-destructive: the caller is pointed AT the worktree and at
# its owner, never at a way to get rid of it or of the work in flight inside it.
# ---------------------------------------------------------------------------
R6="$(make_repo r6)"
WB6="$R6/.worktrees/$CONTAINER_NAME"
E6="$WORK_ROOT/r6.err"
git_quiet -C "$R6" worktree add -q "$WB6/task-f" -b task-f >/dev/null 2>&1
rc6=0
out="$(cd "$R6" && bash "$WT_ENTER" task-g task-f 2>"$E6")" || rc6=$?
if [ "$rc6" -eq 0 ]; then
	no "wt-enter must fail when the branch is checked out in a sibling worktree (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	# git's fatal status (128) is propagated rather than flattened to 1.
	[ "$rc6" -eq 128 ] || miss="$miss exit-status-$rc6"
	# Surfaced by wt-enter itself, not merely left inside git's fatal text.
	grep -F "$WB6/task-f" "$E6" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
	! grep -qiF "primary" "$E6" || miss="$miss claims-primary"
	# The caller is told how to look at the blocker, not how to delete it.
	grep -qF "git -C $WB6/task-f status" "$E6" || miss="$miss no-inspection-hint"
	miss="$miss$(destructive_advice "$E6" "$WB6/task-f" "$WB6/task-g" "$R6" task-f task-g)"
	[ ! -e "$WB6/task-g" ] || miss="$miss worktree-created"
	if [ -z "$miss" ]; then
		ok "wt-enter surfaces the blocking sibling worktree path and hands over non-destructively"
	else
		no "wt-enter sibling-worktree conflict message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: the blocker path and the branch name are DATA, not advice. A
# branch called 'abort-the-migration' puts the word 'abort' into the message
# purely because wt-enter quotes back what it was asked for — the diagnosis is
# byte-for-byte the same one the case above passes. Pinned so the non-destruction
# check cannot degrade into a text search that fails on legitimate names.
# ---------------------------------------------------------------------------
RN="$(make_repo rn)"
WBN="$RN/.worktrees/$CONTAINER_NAME"
EN="$WORK_ROOT/rn.err"
NOISY_BRANCH="abort-the-migration"
git_quiet -C "$RN" worktree add -q "$WBN/task-w" -b "$NOISY_BRANCH" >/dev/null 2>&1
if out="$(cd "$RN" && bash "$WT_ENTER" task-x "$NOISY_BRANCH" 2>"$EN")"; then
	no "wt-enter must fail when a branch named '$NOISY_BRANCH' is checked out elsewhere (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	grep -F "$WBN/task-w" "$EN" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
	# Precondition: the noisy word really is in the output (else this proves nothing).
	grep -qF "$NOISY_BRANCH" "$EN" || miss="$miss branch-name-not-echoed"
	miss="$miss$(destructive_advice "$EN" "$WBN/task-w" "$WBN/task-x" "$RN" "$NOISY_BRANCH" task-x)"
	[ ! -e "$WBN/task-x" ] || miss="$miss worktree-created"
	if [ -z "$miss" ]; then
		ok "a branch name containing 'abort' is treated as data, not as destructive advice"
	else
		no "wt-enter noisy-branch-name case inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: the suggested inspection commands must be SHELL-SAFE. A worktree
# can live under a path containing spaces (or shell metacharacters), and advice
# that cannot be pasted verbatim is not advice — while advice that pastes into
# something OTHER than the intended command is worse than none. The emitted
# command must therefore carry the path as one quoted token.
# ---------------------------------------------------------------------------
RS="$(make_repo "r s'p")"
WBS="$RS/.worktrees/$CONTAINER_NAME"
ES="$WORK_ROOT/rs.err"
git_quiet -C "$RS" worktree add -q "$WBS/task-y" -b task-y >/dev/null 2>&1
if out="$(cd "$RS" && bash "$WT_ENTER" task-z task-y 2>"$ES")"; then
	no "wt-enter must fail when a blocker under a spaced path holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	printf -v want_status 'git -C %q status' "$WBS/task-y"
	grep -qF "$want_status" "$ES" || miss="$miss no-quoted-inspection-hint"
	# The raw, unquoted form must NOT be what is offered: pasting it would run
	# `git -C <first-word>` and treat the rest of the path as arguments.
	! grep -qF "git -C $WBS/task-y status" "$ES" || miss="$miss unquoted-path"
	# End-to-end: take the command wt-enter actually printed and RUN it (as
	# `rev-parse` rather than `status`, so the answer is comparable). Pasting it
	# must reach the blocking worktree and nothing else.
	hint_cmd="$(LC_ALL=C sed -n "s/^wt-enter: look at it yourself: '\(git -C .* status\)'.*/\1/p" "$ES" | head -1)"
	if [ -n "$hint_cmd" ]; then
		got="$(eval "${hint_cmd% status} rev-parse --show-toplevel" 2>/dev/null || true)"
		[ "$got" = "$WBS/task-y" ] || miss="$miss inspection-command-not-pasteable"
	else
		miss="$miss no-inspection-command"
	fi
	miss="$miss$(destructive_advice "$ES" "$WBS/task-y" "$WBS/task-z" "$RS" task-y task-z)"
	if [ -z "$miss" ]; then
		ok "wt-enter shell-quotes the paths in the commands it suggests"
	else
		no "wt-enter spaced-path message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: a blocker path carrying TERMINAL CONTROL BYTES must not reach the
# terminal raw, in ANY position — the bare prose one included, which is the only
# place a discovered path was ever printed unquoted. A worktree path is arbitrary
# bytes chosen by somebody else, and an ESC echoed back verbatim is a live ANSI
# sequence in the reader's terminal: enough to recolour, overwrite or fabricate
# the lines around it, i.e. to forge advice wt-enter never gave — in the one
# message whose whole job is to be trusted about what must not be destroyed. git
# sanitizes such bytes in its own fatal, but prints them RAW in the porcelain
# these diagnostics are built from, so the escaping is wt-enter's to do. Escaped,
# not dropped: the blocker still has to be named.
# ---------------------------------------------------------------------------
ESC=$'\033'
RE="$(make_repo re)"
WBE="$RE/.worktrees/$CONTAINER_NAME"
EE="$WORK_ROOT/re.err"
ESC_WT="$WORK_ROOT/esc-blocker-${ESC}[31mRED"
git_quiet -C "$RE" worktree add -q "$ESC_WT" -b esc-b >/dev/null 2>&1
if out="$(cd "$RE" && bash "$WT_ENTER" task-esc esc-b 2>"$EE")"; then
	no "wt-enter must fail when a blocker under a control-byte path holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	errtext="$(cat "$EE")"
	# Precondition: the fixture really does carry the byte (else this proves nothing).
	case "$ESC_WT" in *"$ESC"*) ;; *) miss="$miss fixture-has-no-control-byte" ;; esac
	# Nothing on stderr may carry it, whoever printed the line.
	case "$errtext" in *"$ESC"*) miss="$miss raw-control-byte-on-stderr" ;; esac
	# The blocker is still NAMED — in the escaped spelling, with the `;` pinning
	# that nothing was trimmed off the end of it.
	printf -v want_esc "wt-enter: branch 'esc-b' is already checked out in another worktree at %q;" "$ESC_WT"
	case "$errtext" in
	*"$want_esc"*) ;;
	*) miss="$miss no-blocking-path" ;;
	esac
	miss="$miss$(destructive_advice "$EE" "$ESC_WT" "$WBE/task-esc" "$RE" esc-b task-esc)"
	[ ! -e "$WBE/task-esc" ] || miss="$miss worktree-created"
	if [ -z "$miss" ]; then
		ok "wt-enter escapes terminal control bytes in a blocker path instead of echoing them raw"
	else
		no "wt-enter control-byte blocker message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: the SAME message under bash's `xpg_echo` option, which makes the
# `echo` builtin expand backslash escapes — including the ones `printf %q` has
# just produced, so `\E` becomes a live ESC byte again and the escaping above
# buys nothing. The option is not wt-enter's to choose: bash enables everything
# listed in an exported BASHOPTS before it reads any startup file, so it arrives
# from the environment, which is why every diagnostic is emitted with `printf`
# instead. Handed in through `env` because BASHOPTS is READONLY inside a running
# bash and cannot be set as an assignment prefix here.
# ---------------------------------------------------------------------------
EX="$WORK_ROOT/re-xpg.err"
if out="$(cd "$RE" && env BASHOPTS=xpg_echo bash "$WT_ENTER" task-escx esc-b 2>"$EX")"; then
	no "wt-enter must fail under xpg_echo when a control-byte-path blocker holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	errtext="$(cat "$EX")"
	# Precondition: the option really does reach a script invoked this way (else
	# this case is the previous one over again and proves nothing).
	env BASHOPTS=xpg_echo bash -c 'shopt -q xpg_echo' || miss="$miss fixture-xpg-echo-not-set"
	case "$errtext" in *"$ESC"*) miss="$miss raw-control-byte-on-stderr" ;; esac
	printf -v want_escx "wt-enter: branch 'esc-b' is already checked out in another worktree at %q;" "$ESC_WT"
	case "$errtext" in
	*"$want_escx"*) ;;
	*) miss="$miss no-blocking-path" ;;
	esac
	miss="$miss$(destructive_advice "$EX" "$ESC_WT" "$WBE/task-escx" "$RE" esc-b task-escx)"
	[ ! -e "$WBE/task-escx" ] || miss="$miss worktree-created"
	if [ -z "$miss" ]; then
		ok "wt-enter's escaping survives xpg_echo, which would make 'echo' re-expand it"
	else
		no "wt-enter control-byte message under xpg_echo inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# THE NON-DESTRUCTION INVARIANT, which the next several cases each probe from a
# different angle: whatever state the blocking worktree is in, wt-enter names it
# and stops. It does not try to decide that a worktree is safe to throw away —
# that would mean enumerating every state git can leave behind and keeping the
# list in lockstep with wt-remove's own guards, and each state missed from either
# list is a deleted worktree. The fixtures below are exactly the states that gap
# has produced: a rebase, a bisect (twice, because one shape keeps the worktree
# on its branch with a CLEAN `git status`), and an interrupted revert (same clean
# shape). Task 057 closed the wt-remove side for all of them — see the
# operation-in-progress guard cases above — which is exactly why wt-enter still
# must not lean on that list: the two are maintained independently, and the
# reason wt-enter is safe is that it enumerates nothing at all.
#
# Integration: blocked by a worktree with an INTERRUPTED REBASE. git reports such
# a worktree as `detached` in the porcelain yet still refuses to check its branch
# out elsewhere, so the diagnosis must consult the operation state instead of
# concluding "no worktree holds this branch".
# ---------------------------------------------------------------------------
R7="$(make_repo r7)"
WB7="$R7/.worktrees/$CONTAINER_NAME"
E7="$WORK_ROOT/r7.err"
git_quiet -C "$R7" checkout -q -b task-h
echo "branch side" >"$R7/seed.txt"
git_quiet -C "$R7" commit -qam "task-h edit"
git_quiet -C "$R7" checkout -q main
echo "main side" >"$R7/seed.txt"
git_quiet -C "$R7" commit -qam "main edit"
git_quiet -C "$R7" worktree add -q "$WB7/task-h" task-h >/dev/null 2>&1
# Conflicting rebase: it stops mid-flight and leaves the worktree detached.
git_quiet -C "$WB7/task-h" rebase main >/dev/null 2>&1 || true
if git -C "$R7" worktree list --porcelain | grep -qx detached; then
	if out="$(cd "$R7" && bash "$WT_ENTER" task-i task-h 2>"$E7")"; then
		no "wt-enter must fail when the branch is held by an interrupted rebase (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		grep -F "$WB7/task-h" "$E7" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
		! grep -qiF "primary" "$E7" || miss="$miss claims-primary"
		miss="$miss$(destructive_advice "$E7" "$WB7/task-h" "$WB7/task-i" "$R7" task-h task-i)"
		[ ! -e "$WB7/task-i" ] || miss="$miss worktree-created"
		if [ -z "$miss" ]; then
			ok "wt-enter names the blocking worktree even when a rebase leaves it detached"
		else
			no "wt-enter interrupted-rebase conflict message inadequate:$miss"
		fi
	fi
else
	no "precondition: rebase did not leave $WB7/task-h detached"
fi

# ---------------------------------------------------------------------------
# Integration: blocked by a BISECT — same detached shape as the rebase above.
# ---------------------------------------------------------------------------
R8="$(make_repo r8)"
WB8="$R8/.worktrees/$CONTAINER_NAME"
E8="$WORK_ROOT/r8.err"
for i in 1 2 3; do
	echo "rev $i" >"$R8/seed.txt"
	git_quiet -C "$R8" commit -qam "c$i"
done
git_quiet -C "$R8" branch task-j
git_quiet -C "$R8" worktree add -q "$WB8/task-j" task-j >/dev/null 2>&1
git_quiet -C "$WB8/task-j" bisect start HEAD HEAD~2 >/dev/null 2>&1 || true
if git -C "$R8" worktree list --porcelain | grep -qx detached; then
	if out="$(cd "$R8" && bash "$WT_ENTER" task-k task-j 2>"$E8")"; then
		no "wt-enter must fail when the branch is held by a bisect (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		grep -F "$WB8/task-j" "$E8" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
		! grep -qiF "primary" "$E8" || miss="$miss claims-primary"
		miss="$miss$(destructive_advice "$E8" "$WB8/task-j" "$WB8/task-k" "$R8" task-j task-k)"
		[ ! -e "$WB8/task-k" ] || miss="$miss worktree-created"
		if [ -z "$miss" ]; then
			ok "wt-enter names the blocking worktree when a bisect leaves it detached"
		else
			no "wt-enter bisect conflict message inadequate:$miss"
		fi
	fi
else
	no "precondition: bisect did not leave $WB8/task-j detached"
fi

# ---------------------------------------------------------------------------
# Integration: a bisect not yet given a good/bad commit does NOT detach — the
# worktree stays ON its branch and `git status` is clean — the shape in which
# nothing wt-remove checked used to stop it discarding the bisect (guarded since
# task 057, pinned above). Identification comes free from the `branch` record;
# what is pinned here is that the advice stays hands-off.
# ---------------------------------------------------------------------------
RA="$(make_repo ra)"
WBA="$RA/.worktrees/$CONTAINER_NAME"
EA="$WORK_ROOT/ra.err"
git_quiet -C "$RA" branch task-m
git_quiet -C "$RA" worktree add -q "$WBA/task-m" task-m >/dev/null 2>&1
git_quiet -C "$WBA/task-m" bisect start >/dev/null 2>&1 || true
if git -C "$RA" worktree list --porcelain | grep -qx "branch refs/heads/task-m" &&
	[ -z "$(git -C "$WBA/task-m" status --porcelain)" ]; then
	if out="$(cd "$RA" && bash "$WT_ENTER" task-n task-m 2>"$EA")"; then
		no "wt-enter must fail when the branch is held by an on-branch bisect (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		grep -F "$WBA/task-m" "$EA" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
		miss="$miss$(destructive_advice "$EA" "$WBA/task-m" "$WBA/task-n" "$RA" task-m task-n)"
		[ ! -e "$WBA/task-n" ] || miss="$miss worktree-created"
		if [ -z "$miss" ]; then
			ok "wt-enter stays hands-off for a bisect that has not detached the worktree yet"
		else
			no "wt-enter on-branch-bisect conflict message inadequate:$miss"
		fi
	fi
else
	no "precondition: 'git bisect start' should leave $WBA/task-m on its branch with a clean status"
fi

# ---------------------------------------------------------------------------
# Integration: blocked by a worktree with an INTERRUPTED REVERT. `git revert A B`
# where B's revert turns out empty stops the sequence with the worktree ON its
# branch, `git status --porcelain` EMPTY, and nothing but sequencer/ + MERGE_MSG
# to show for it — none of which used to appear in wt-remove's guard list, so
# removing that worktree took the revert sequence with it and no guard objected
# (closed by task 057, pinned above). wt-enter must not point anywhere near
# removal regardless: it is the state it cannot see that makes the advice wrong,
# not whether some other script happens to check for it today.
# ---------------------------------------------------------------------------
RR="$(make_repo rr)"
WBR="$RR/.worktrees/$CONTAINER_NAME"
ER="$WORK_ROOT/rr.err"
echo x >"$RR/other.txt"
git_quiet -C "$RR" add -A
git_quiet -C "$RR" commit -qm "add other"
echo one >"$RR/seed.txt"
git_quiet -C "$RR" commit -qam c1
echo y >"$RR/other.txt"
git_quiet -C "$RR" commit -qam c2
echo seed >"$RR/seed.txt" # undoes c1 by hand, so reverting c1 later is empty
git_quiet -C "$RR" commit -qam "undo c1"
git_quiet -C "$RR" branch task-u
git_quiet -C "$RR" worktree add -q "$WBR/task-u" task-u >/dev/null 2>&1
git_quiet -C "$WBR/task-u" revert --no-edit \
	"$(git -C "$RR" rev-parse task-u~1)" "$(git -C "$RR" rev-parse task-u~2)" >/dev/null 2>&1 || true
if [ -e "$RR/.git/worktrees/task-u/sequencer" ] &&
	[ -z "$(git -C "$WBR/task-u" status --porcelain)" ] &&
	git -C "$RR" worktree list --porcelain | grep -qx "branch refs/heads/task-u"; then
	if out="$(cd "$RR" && bash "$WT_ENTER" task-v task-u 2>"$ER")"; then
		no "wt-enter must fail when the branch is held by an interrupted revert (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		grep -F "$WBR/task-u" "$ER" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
		miss="$miss$(destructive_advice "$ER" "$WBR/task-u" "$WBR/task-v" "$RR" task-u task-v)"
		# The revert sequence is still there afterwards.
		[ -e "$RR/.git/worktrees/task-u/sequencer" ] || miss="$miss revert-state-lost"
		[ ! -e "$WBR/task-v" ] || miss="$miss worktree-created"
		if [ -z "$miss" ]; then
			ok "wt-enter stays hands-off for a worktree stopped mid-revert (clean status, invisible to git status)"
		else
			no "wt-enter interrupted-revert conflict message inadequate:$miss"
		fi
	fi
else
	no "precondition: the revert should stop mid-sequence in $WBR/task-u with a clean status"
fi

# ---------------------------------------------------------------------------
# Integration: the blocker is a SIBLING worktree registered in git's metadata but
# MISSING on disk. `git worktree prune` is the remedy here — git's own, it drops
# a stale record and can destroy nothing — and it must be named, because generic
# "go and look at that worktree" advice points at a directory that is not there.
# ---------------------------------------------------------------------------
RP="$(make_repo rp)"
WBP="$RP/.worktrees/$CONTAINER_NAME"
EP="$WORK_ROOT/rp.err"
git_quiet -C "$RP" worktree add -q "$WBP/task-q" -b task-q >/dev/null 2>&1
rm -rf "$WBP/task-q"
if out="$(cd "$RP" && bash "$WT_ENTER" task-r task-q 2>"$EP")"; then
	no "wt-enter must fail when a registered-but-missing sibling holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	grep -F "$WBP/task-q" "$EP" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
	grep -qF "worktree prune" "$EP" || miss="$miss no-prune-remedy"
	miss="$miss$(destructive_advice "$EP" "$WBP/task-q" "$WBP/task-r" "$RP" task-q task-r)"
	if [ -z "$miss" ]; then
		ok "wt-enter advises 'worktree prune' for a registered-but-missing sibling blocker"
	else
		no "wt-enter prunable-sibling message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: registered-but-missing AND detached — a worktree that was left
# mid-bisect and then deleted from disk. Git reads the state that survives in the
# admin dir and keeps refusing the branch, and `worktree prune` really would clear
# the record (pinned below with `prune -n`), so this is the case where the prune
# remedy is both correct and the only thing to say. It is also the case a probe
# run INSIDE the blocker cannot reach: there is no directory left to run git in,
# so the blocker went unnamed and the remedy unoffered.
# ---------------------------------------------------------------------------
RM="$(make_repo rm-gone)"
WBM="$RM/.worktrees/$CONTAINER_NAME"
EM="$WORK_ROOT/rm-gone.err"
for i in 1 2 3; do
	echo "rev $i" >"$RM/seed.txt"
	git_quiet -C "$RM" commit -qam "c$i"
done
git_quiet -C "$RM" branch task-w
git_quiet -C "$RM" worktree add -q "$WBM/task-w" task-w >/dev/null 2>&1
git_quiet -C "$WBM/task-w" bisect start HEAD HEAD~2 >/dev/null 2>&1 || true
if git -C "$RM" worktree list --porcelain | grep -qx detached; then
	rm -rf "$WBM/task-w" # detached by the bisect, now gone from disk
	if git -C "$RM" worktree prune -n -v 2>&1 | grep -qF "worktrees/task-w"; then
		if out="$(cd "$RM" && bash "$WT_ENTER" task-x task-w 2>"$EM")"; then
			no "wt-enter must fail when a deleted mid-bisect worktree holds the branch (got '$out')"
		else
			miss=""
			[ -z "$out" ] || miss="$miss stdout-not-empty"
			grep -F "$WBM/task-w" "$EM" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
			grep -qF "worktree prune" "$EM" || miss="$miss no-prune-remedy"
			! grep -qiF "primary" "$EM" || miss="$miss claims-primary"
			miss="$miss$(destructive_advice "$EM" "$WBM/task-w" "$WBM/task-x" "$RM" task-w task-x)"
			[ ! -e "$WBM/task-x" ] || miss="$miss worktree-created"
			if [ -z "$miss" ]; then
				ok "wt-enter names a deleted mid-bisect blocker and offers the prune remedy for it"
			else
				no "wt-enter deleted-detached-blocker message inadequate:$miss"
			fi
		fi
	else
		no "precondition: 'worktree prune -n' should report the deleted $WBM/task-w record as prunable"
	fi
else
	no "precondition: bisect did not leave $WBM/task-w detached"
fi

# ---------------------------------------------------------------------------
# Integration: the same registered-but-missing sibling, but LOCKED. git skips
# locked worktrees when pruning, so the remedy the case above earns is exactly
# wrong here: pasting it changes nothing and the caller comes straight back to a
# branch that is still held — a loop that cannot terminate. The record is not
# stale either; a lock is how one marks a checkout parked on removable or
# unmounted storage whose work is intact where it lives. So the blocker must
# still be named, the lock must be stated, and 'worktree prune' must NOT appear.
#
# git's refusal to prune it is the fact the whole message rests on, so it is
# pinned as a precondition rather than assumed.
# ---------------------------------------------------------------------------
RL="$(make_repo rl)"
WBL="$RL/.worktrees/$CONTAINER_NAME"
EL="$WORK_ROOT/rl.err"
git_quiet -C "$RL" worktree add -q "$WBL/task-lk" -b task-lk >/dev/null 2>&1
git_quiet -C "$RL" worktree lock --reason "parked on an unmounted share" "$WBL/task-lk" >/dev/null 2>&1
rm -rf "$WBL/task-lk"
if [ -n "$(git -C "$RL" worktree prune -n -v 2>&1)" ]; then
	no "precondition: git must not offer to prune a LOCKED worktree whose directory is gone"
elif out="$(cd "$RL" && bash "$WT_ENTER" task-lm task-lk 2>"$EL")"; then
	no "wt-enter must fail when a locked-but-missing sibling holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	grep -F "$WBL/task-lk" "$EL" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
	grep -qiF "locked" "$EL" || miss="$miss no-lock-wording"
	# The stale-record remedy must not be offered for a record git will not touch.
	! grep -qF "worktree prune" "$EL" || miss="$miss prune-advised-for-locked-blocker"
	miss="$miss$(destructive_advice "$EL" "$WBL/task-lk" "$WBL/task-lm" "$RL" task-lk task-lm)"
	[ ! -e "$WBL/task-lm" ] || miss="$miss worktree-created"
	# Nothing was remediated: the locked record is still registered, still holding.
	git -C "$RL" worktree list --porcelain | grep -qx "branch refs/heads/task-lk" ||
		miss="$miss lock-record-gone"
	if [ -z "$miss" ]; then
		ok "wt-enter withholds the 'worktree prune' remedy for a LOCKED registered-but-missing blocker"
	else
		no "wt-enter locked-blocker message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: a blocker whose own git dir cannot be read (it lost its .git
# pointer). git still refuses the checkout, so the blocker is real and must still
# be named — from the porcelain alone, without needing to read anything inside it.
# ---------------------------------------------------------------------------
RV="$(make_repo rv)"
WBV="$RV/.worktrees/$CONTAINER_NAME"
EV="$WORK_ROOT/rv.err"
git_quiet -C "$RV" worktree add -q "$WBV/task-s" -b task-s >/dev/null 2>&1
git_quiet -C "$WBV/task-s" bisect start >/dev/null 2>&1 || true
rm -f "$WBV/task-s/.git"
if out="$(cd "$RV" && bash "$WT_ENTER" task-t task-s 2>"$EV")"; then
	no "wt-enter must fail when an unreadable sibling holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	grep -F "$WBV/task-s" "$EV" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
	miss="$miss$(destructive_advice "$EV" "$WBV/task-s" "$WBV/task-t" "$RV" task-s task-t)"
	if [ -z "$miss" ]; then
		ok "wt-enter names a blocker whose own git dir cannot be read, and still advises nothing destructive"
	else
		no "wt-enter unreadable-blocker message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: the blocker sits under a path containing a NEWLINE. End to end,
# this is where a line-based read of the porcelain does real damage: the blocker
# resolves to the path's prefix, which is not on disk, so wt-enter takes the
# registered-but-missing branch and tells the caller to 'worktree prune' — advice
# for a stale record, aimed at a worktree that is very much alive. The full path
# must be named and the prune remedy must NOT appear.
# (Substring assertions use bash `case` rather than grep: a pattern containing a
# newline is two patterns to grep, which would match either half on its own.)
# ---------------------------------------------------------------------------
EZ="$WORK_ROOT/rz.err"
if out="$(cd "$RZ" && bash "$WT_ENTER" task-nl nl-b 2>"$EZ")"; then
	no "wt-enter must fail when a blocker under a newline path holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	errtext="$(cat "$EZ")"
	# wt-enter's OWN sibling-conflict line, carrying the path in full — in the
	# shell-quoted spelling, which is also what keeps the newline from splitting
	# the diagnosis across two lines on the way out.
	printf -v want_nl "wt-enter: branch 'nl-b' is already checked out in another worktree at %q;" "$WTZ"
	case "$errtext" in
	*"$want_nl"*) ;;
	*) miss="$miss no-blocking-path" ;;
	esac
	# The symptom of a truncated parse: the live blocker misreported as a stale
	# record, with git's prune remedy offered for it.
	case "$errtext" in
	*"worktree prune"*) miss="$miss prune-advised-for-live-blocker" ;;
	esac
	miss="$miss$(destructive_advice "$EZ" "$WTZ" "$RZ/.worktrees/$CONTAINER_NAME/task-nl" "$RZ" nl-b task-nl)"
	[ ! -e "$RZ/.worktrees/$CONTAINER_NAME/task-nl" ] || miss="$miss worktree-created"
	if [ -z "$miss" ]; then
		ok "wt-enter names a blocking worktree whose path contains a newline, in full"
	else
		no "wt-enter newline-path blocker message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: the blocker's path ENDS in a newline. Identical symptom, different
# byte: here it is the handoff out of the resolver, not the porcelain read, that
# can eat the last byte — `$( )` strips trailing newlines — and the misdiagnosis
# lands in exactly the same place ('worktree prune' aimed at a live worktree).
# ---------------------------------------------------------------------------
ET="$WORK_ROOT/rt.err"
if out="$(cd "$NLT_ROOT" && bash "$WT_ENTER" task-nlt nlt-b 2>"$ET")"; then
	no "wt-enter must fail when a blocker under a trailing-newline path holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	errtext="$(cat "$ET")"
	# The `;` right after the path is what pins that NOTHING was trimmed off it.
	printf -v want_nlt "wt-enter: branch 'nlt-b' is already checked out in another worktree at %q;" "$WTT"
	case "$errtext" in
	*"$want_nlt"*) ;;
	*) miss="$miss no-blocking-path" ;;
	esac
	case "$errtext" in
	*"worktree prune"*) miss="$miss prune-advised-for-live-blocker" ;;
	esac
	miss="$miss$(destructive_advice "$ET" "$WTT" "$NLT_ROOT/.worktrees/$CONTAINER_NAME/task-nlt" "$NLT_ROOT" nlt-b task-nlt)"
	[ ! -e "$NLT_ROOT/.worktrees/$CONTAINER_NAME/task-nlt" ] || miss="$miss worktree-created"
	if [ -z "$miss" ]; then
		ok "wt-enter names a blocking worktree whose path ENDS in a newline, in full"
	else
		no "wt-enter trailing-newline blocker message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: a trailing-newline path AND a DETACHED blocker, which is where the
# byte used to cost the entire diagnosis rather than degrade it. A `branch` record
# names the blocker by itself, so the case above survived on the porcelain read
# alone; a bisect makes the record `detached`, the answer has to come from the
# worktree's own operation state, and locating that state used to compare the path
# against a `$( )`-read toplevel — which this path can never equal. wt-enter then
# printed git's fatal and nothing of its own.
# ---------------------------------------------------------------------------
NLD_ROOT="$(make_repo rnld)"
NLD_WT="$WORK_ROOT/nld-blocker"$'\n'
END="$WORK_ROOT/rnld.err"
for i in 1 2 3; do
	echo "rev $i" >"$NLD_ROOT/seed.txt"
	git_quiet -C "$NLD_ROOT" commit -qam "c$i"
done
git_quiet -C "$NLD_ROOT" branch nld-b
git_quiet -C "$NLD_ROOT" worktree add -q "$NLD_WT" nld-b >/dev/null 2>&1
git_quiet -C "$NLD_WT" bisect start HEAD HEAD~2 >/dev/null 2>&1 || true
if git -C "$NLD_ROOT" worktree list --porcelain | grep -qx detached; then
	if out="$(cd "$NLD_ROOT" && bash "$WT_ENTER" task-nld nld-b 2>"$END")"; then
		no "wt-enter must fail when a detached blocker under a trailing-newline path holds the branch (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		errtext="$(cat "$END")"
		printf -v want_nld "wt-enter: branch 'nld-b' is already checked out in another worktree at %q;" "$NLD_WT"
		case "$errtext" in
		*"$want_nld"*) ;;
		*) miss="$miss no-blocking-path" ;;
		esac
		# The blocker is alive: no stale-record remedy may be aimed at it.
		case "$errtext" in
		*"worktree prune"*) miss="$miss prune-advised-for-live-blocker" ;;
		esac
		miss="$miss$(destructive_advice "$END" "$NLD_WT" "$NLD_ROOT/.worktrees/$CONTAINER_NAME/task-nld" "$NLD_ROOT" nld-b task-nld)"
		[ ! -e "$NLD_ROOT/.worktrees/$CONTAINER_NAME/task-nld" ] || miss="$miss worktree-created"
		if [ -z "$miss" ]; then
			ok "wt-enter still diagnoses a DETACHED blocker whose path ENDS in a newline"
		else
			no "wt-enter trailing-newline detached-blocker message inadequate:$miss"
		fi
	fi
else
	no "precondition: bisect did not leave the trailing-newline worktree detached"
fi

# ---------------------------------------------------------------------------
# Integration: `git worktree add` also fails when the DESTINATION worktree is
# registered but missing on disk (hand-deleted, or a pre-durable-metadata
# leftover). git's own message carries the right remedy there ("prune"/"remove"),
# and the porcelain still lists that path as holding the branch — so the
# branch-conflict diagnosis must stay silent rather than tell the caller the path
# it just asked for is blocked by "another worktree".
# ---------------------------------------------------------------------------
R9="$(make_repo r9)"
WB9="$R9/.worktrees/$CONTAINER_NAME"
E9="$WORK_ROOT/r9.err"
git_quiet -C "$R9" worktree add -q "$WB9/task-l" -b task-l >/dev/null 2>&1
rm -rf "$WB9/task-l" # registered in .git/worktrees, gone from disk
rc9=0
out="$(cd "$R9" && bash "$WT_ENTER" task-l task-l 2>"$E9")" || rc9=$?
if [ "$rc9" -eq 0 ]; then
	no "wt-enter must fail when its destination is registered but missing (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	# git's own remedy stands — and so does its status.
	[ "$rc9" -eq 128 ] || miss="$miss exit-status-$rc9"
	# No tailored branch-conflict diagnosis: git's own remedy must stand alone.
	! grep -q '^wt-enter: branch ' "$E9" || miss="$miss self-blocker-diagnosis"
	if [ -z "$miss" ]; then
		ok "wt-enter leaves git's own remedy standing when the blocker is its own destination"
	else
		no "wt-enter self-blocker message inadequate:$miss"
	fi
fi

echo
if [ "$skipped" -gt 0 ]; then
	echo "wt-orphan-safety: $pass passed, $fail failed, $skipped skipped"
else
	echo "wt-orphan-safety: $pass passed, $fail failed"
fi
[ "$fail" -eq 0 ]
