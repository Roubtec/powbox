---
description: Rebase a chain of stacked local branches onto a target branch, one at a time, replaying only each branch's unique commits and using agent intelligence to resolve conflicts.
argument-hint: [<source-branch>] [onto <target-branch>]
---

Rebase a chain of stacked local branches onto a target branch.

This command is built for the "stacked PRs" workflow where each feature branch was originally based on its predecessor.
After predecessors get merged into the target branch (typically `main`), the remaining branches need to be rebased so their unique commits land on top of the new target tip — and so each subsequent branch in the chain ends up cleanly stacked on the freshly rebased one above it.

It works one branch at a time, with explicit user confirmation up front and intelligent conflict resolution along the way.

## When to use this

Typical scenario: you implemented tasks via `/address-tasks`, producing branches `feature/01 → feature/02 → ... → feature/N` each PR'd into the previous.
After PR review, branches accumulate "fixes" commits.
After `feature/01` and `feature/02` are merged into `main`, the remaining branches still share an old common ancestor with `main` and contain commits that are now duplicated in `main` (with different hashes but identical patches).
Run this command from the topmost branch (or pass it explicitly) to bring the entire remaining stack forward, branch by branch, onto the new `main` tip.

It also handles "leafy" stacks — branches in the middle that have grown their own fix commits not yet present in their descendants.
The per-branch rebase naturally re-stacks them flatly: each rebased branch becomes the base for the next.

## Assumptions

- The team **rebases-and-merges** PRs rather than squashing.
  Git's default patch-id detection during rebase will drop commits already present in the new base, which is exactly what we rely on.
  This command does not implement squash-aware heuristics.
- Branches in the chain were created sequentially, each from the tip of its predecessor at branch-creation time.
- The user is responsible for fetch/pull hygiene.
  This command **does not run `git fetch`** and **does not pull**.
  It uses local refs only, so the user has complete control over which commits come into play.

## Invocation forms

All forms route through the same logic.
Be lenient about parsing: trust the agent to extract source, target, and (optionally) explicit chain, then rely on the confirmation listing as the safety net.

| Form | Meaning |
|---|---|
| `/rebase-stack` | Current branch onto `main`; chain auto-detected |
| `/rebase-stack onto <target>` | Current branch onto `<target>`; chain auto-detected |
| `/rebase-stack <source>` | `<source>` onto `main`; chain auto-detected |
| `/rebase-stack <source> onto <target>` | `<source>` onto `<target>`; chain auto-detected |
| `/rebase-stack <source> -> <target>` | Same; arrow tolerated |
| `/rebase-stack <source> → <target>` | Same; unicode arrow tolerated |
| `/rebase-stack chain <b1> <b2> ... <bN> onto <target>` | Explicit chain in stacking order; the last branch is the source; auto-detection is skipped entirely |
| `/rebase-stack chain <b1> -> <b2> -> ... -> <bN>` | Same with arrows; `onto <target>` defaults to `main` if omitted |

Quoting is optional; branch names with spaces should use quotes.
If `main` doesn't exist, fall back to `master`.
If neither exists, ask the user for the target branch.

**When to use the explicit `chain` form**: if auto-detection comes back empty or wrong (most often after a chain branch was merged via rebase-and-merge — see "Detection corner cases" below), the explicit form is the simple, robust answer.
You list the branches in stacking order, the command rebases each onto the previous one's new tip, and the patch-id-aware first step still drops commits already on the target.

## What the command does NOT do

- It does not push to origin. Pushing remains a manual step the user controls.
- It does not fetch from origin. Local refs are the source of truth.
- It does not delete branches, including chain branches that end up with no unique commits after rebase. Empty branches are reported in the final summary for the user to handle.
- It does not modify the target branch. The target ref is read-only throughout.
- It does not skip branches the user marks as "skip" during confirmation. Those branches are left entirely untouched.

## Procedure

### Step 1 — Preflight

1. **Working tree must be clean.**
   Run `git status --porcelain`.
   If anything is staged or modified, or any untracked file would be overwritten by a checkout (a `git checkout` or `git rebase` to another branch in the chain would fail), abort with a clear message asking the user to commit, stash, or clean.
   Do not auto-stash.
2. **Resolve target.**
   Default target is `main` (fall back to `master` if `main` is absent).
   Verify the local target ref exists.
3. **Resolve source.**
   Default source is the currently checked-out branch.
   If the user specified a source, locate it; the source need not be checked out yet — the command will check out branches as it goes.
4. **Check no rebase is already in progress.**
   If `.git/rebase-merge` or `.git/rebase-apply` exists, abort with a message asking the user to finish or abort the in-progress rebase first.

### Step 2 — Detect the chain

If the user supplied an explicit `chain` form (see Invocation forms), skip detection entirely and use the provided list as-is — the last branch is the source, the rest are chain branches in stacking order.

Otherwise, auto-detect:

#### 2a. Compute the **effective frontier** `EF` between source and target

The naïve "merge-base of source with target" is wrong whenever target has grown via rebase-and-merge: `git merge-base` only sees SHA-equality, so a chain branch's commits that **already landed on target with rewritten SHAs** look like part of source's unique history.
Patch-id detection is what fixes this — and `git rebase` already uses it internally to drop redundant commits.

Compute `EF` as the latest commit on source's history that is patch-equivalent to a commit reachable from target:

```sh
# Walk source's commits past the strict merge-base, marked + (unique) or = (patch-equiv on target).
git rev-list --right-only --cherry-mark --no-merges <target>...<source>
```

The newest `=`-marked commit is `EF` (which is the **first** `=` line in the output, since `git rev-list` emits commits newest-first).
If there are none, fall back to `EF = git merge-base <source> <target>` (the strict merge-base — same as `git rebase`'s default base in that case).

This single change handles three otherwise-awkward geometries with one rule:

- **Steady-state stack** (target hasn't moved since last rebase): `EF` ≈ `target`. Detection reduces to the simple "branches between target and source" case.
- **Ancient fork** (source diverged early, target has progressed via rebased-and-merged PRs): `EF` advances to source's last commit that's patch-equivalent to anything on target. Branches sitting on the abandoned line past `EF` are correctly identified as chain candidates.
- **Post-merge** (one chain branch was just merged into target via rebase-and-merge): `EF` advances to source's copy of the merged branch's tip. The remaining chain branches past `EF` are correctly identified.

#### 2b. Identify chain candidates

For each local branch `X` (excluding `source` and `target`):

```
mb = git merge-base X <source>
```

Include `X` as a chain candidate if all of these hold:
- `mb` is a descendant of `EF`: `git merge-base --is-ancestor <EF> mb` (and `mb != EF`)
- `mb` is an ancestor of `<source>`: `git merge-base --is-ancestor mb <source>`
- `X != <target>` and `X != <source>`
- **`X` has at least one unique commit past `<source>`**: `git rev-list --count <source>..<X>` is greater than zero. Branches whose tip is itself an ancestor of source contribute nothing to a rebase — replaying them would be a no-op. They typically arise as "snapshot" refs left behind from a prior workflow stage. (This filter is bypassed when the user supplied an explicit `chain` form — that list is authoritative.)

This is **heuristic, not metadata** — pure git topology with patch-id awareness.
It correctly catches "leafy" branches whose tip has diverged from their descendants (e.g., `feature/03` with a `fixes 03` commit that `feature/04` doesn't have), because the merge-base of any such leafy branch with the source still lies on the chain spine.
It can also catch unrelated branches that happen to share a merge-base on the spine (e.g., `login-tests` accidentally branched from `feature/03`).
The confirmation listing is how the user filters those out.

Order candidates by `git rev-list --count <EF>..<mb>` ascending — closest to the effective frontier comes first.

The full ordered chain to be rebased is `[chain_branch_1, chain_branch_2, ..., chain_branch_M, source]`.

#### 2c. Detection corner cases

- **Detection finds nothing**: surface this clearly, show `EF` and any nearby branches that *almost* qualified, and offer two paths: re-run with the explicit `chain` form, or proceed with just the source. Don't silently treat "empty chain" as "rebase the source alone" — confirm.
- **Source is a checkpoint, not a tip**: if `source` is itself an ancestor of some other local branch, the user probably meant that other branch as the source. Note this in the confirmation listing as a `[!]` flag.
- **A chain branch was just merged into target**: that branch's tip will be patch-equivalent to a commit on target, so `EF` advances past it — its merge-base with source is at-or-before `EF` and it's correctly excluded. Detection moves on to the next branch in the stack.

### Step 3 — Present the confirmation listing

Output a clear, scannable listing.
Include for each branch in the proposed chain:

- Branch name.
- Short SHA of its tip and tip subject line.
- Count of commits unique to this branch versus the next-up candidate (or versus the source for the topmost). Use this to highlight likely fix commits — small numbers are normal; large numbers on a branch with a name like `login-tests` are a red flag.
- For any branch that looks suspicious (e.g., an outlier in commit count or whose name doesn't fit the apparent chain pattern), flag it with `[!]` and a one-line reason.

Also report **target divergence info** as a non-blocking courtesy:
- Local target SHA.
- Cached `origin/<target>` SHA (read from local cache; do not fetch).
- Approximate time since last fetch (from the cached ref's mtime, if available).
- Whether they differ.

Do **not** block on divergence.
The user may pull manually while the confirmation prompt is open; on "go" the command re-reads the local target ref.

Example listing:

```
The following branches will be rebased on top of `main` (a03ab1f), in order:

  feature/03   1 commit  ahead of feature/04   tip: 0b34e10  fixes 03
  feature/04   1 commit  ahead of feature/05   tip: 9a2f1c0  fixes 04
  feature/05   0 commits ahead of feature/06   tip: 4e8dd11  feature/05 last commit
  feature/06   0 commits ahead of feature/07   tip: 7711a2b  feature/06 last commit
  feature/07   0 commits ahead of source       tip: c133bbe  feature/07 last commit  (current branch, source)

[!] login-tests  47 commits ahead of feature/03  tip: 88f9011  test login UI
                 Merge-base lies on the chain spine but commit count and name suggest unrelated work.

effective frontier (EF):  d4f12a8  01-12 conversion-blocks  (3 source commits patch-equivalent to main)
local main:               a03ab1f
cached origin/main:       a02ee02  (1 commit behind local main, last fetched 4h ago)

Pre-rebase refs will be saved at refs/pre-rebase/<branch>/<timestamp> so you can recover any branch if needed.

Conflicts: trivial resolutions will be applied silently; non-trivial ones will be confirmed with you before continuing.
Validation (build/test) will run only after a branch had conflicts to resolve. Clean rebases skip validation.

Confirm with `go` to proceed, or list branches to skip, or supply an explicit chain like `chain b1 -> b2 -> b3`.
```

Wait for user reply.

If the user provides branches to skip, remove them from the chain and re-display the updated listing for a final confirmation.
Skipped branches are **left entirely untouched** — they stay on their current commits, are not rebased, are not modified.

### Step 4 — Per-branch rebase loop

For each branch `X` in the confirmed chain (in order, with `<target>` as the new base for the first, and the just-rebased predecessor as the new base for each subsequent one):

1. **Save pre-rebase ref.**
   `git update-ref refs/pre-rebase/<X>/<timestamp> <X>` where `<timestamp>` is `YYYYMMDD-HHMMSS`.
   This is the safety net.
   These refs are not deleted automatically; document the cleanup pattern in the final summary.
2. **Checkout.**
   `git checkout <X>`.
3. **Rebase.**
   `git rebase <new-base>`.
   Git's default patch-id detection drops commits already in the new base.

   **Important caveat — patch-id cascades.** If the previous branch's rebase had to *resolve* a conflict (Step 5), that resolution mutated the resulting commit's content, so its patch-id no longer matches the original commit on the descendant's branch. When the descendant's rebase replays that same commit (still present in its history under the original SHA), git **will not** auto-skip it — it sees a different patch-id and tries to apply it as a new commit, which conflicts because the new base already represents the content (just with a different surface).

   The right move in that case is **`git rebase --skip`** for that single commit: HEAD already represents its content (sometimes literally the same, sometimes refined). See Step 5's "patch already represented in HEAD" rule.
4. **Conflict handling** — see Step 5.
5. **Validation** — see Step 6.
6. **Move on** to the next branch.

After the last branch in the chain, the source branch is checked out at its rebased tip.

### Step 5 — Conflict handling

When `git rebase` halts on a conflict:

1. **Inspect the conflict.**
   Read the conflicting files, the offending commit (`git show REBASE_HEAD`), and the recent history of the affected hunks.
2. **Classify.**
   A conflict is **trivial** if any of:
   - It's a pure import-ordering or formatting collision.
   - One side is an addition only and the other side is empty.
   - It's a whitespace-only difference.
   - The resolution is clearly traceable to a fix already applied earlier in this same rebase run (i.e., the same hunk's resolution was just chosen on a predecessor branch).
   - **Patch already represented in HEAD.** The incoming commit's content is *already on HEAD* — either literally (a true duplicate that patch-id should have skipped but didn't, because a predecessor's rebase mutated the patch-id — see Step 4's cascade caveat) or as a strict superset (HEAD has the same content plus refinements introduced by review-feedback fixups or by predecessor conflict resolutions). The resolution is `git rebase --skip`, **not** an in-file edit. Recognize this by inspecting `git show REBASE_HEAD` against HEAD's recent commits touching the same files: if every hunk REBASE_HEAD wants to add is already present in HEAD (with or without refinements), `--skip` is correct.

     **Recognition recipe (concrete)**: (a) every new file `REBASE_HEAD` adds (`A` lines in `git show --name-status REBASE_HEAD`) already exists on HEAD; AND (b) for every modified file, every hunk's *post-image* (the `+` lines) is already present at the corresponding location on HEAD (literally or refined by a later commit). If both hold, `--skip`. If (b) holds only partially, this is **not** the patch-already-represented case — fall through to non-trivial.

   Otherwise it is **non-trivial**.
3. **Trivial — resolve.** Two paths depending on the trivial subtype:
   - **In-file resolution** (import collisions, whitespace, predecessor-traceable): apply the merge, `git add` the resolved files, `git rebase --continue`. Mention briefly in the running narration ("resolved trivial conflict in `<file>`: kept both imports") so the user can scan after the fact, but don't pause.
   - **Patch already represented in HEAD**: run `git rebase --skip` (do *not* edit files). Narrate one line: "skipped redundant commit `<short-sha>` — content already on rebased base". Do not `git add` or `git rebase --continue` for this subtype; `--skip` advances the rebase by itself.
4. **Non-trivial → propose and confirm.**
   Present the conflict, the proposed resolution (with reasoning, including any traceable precedent), and ask the user to confirm before applying.
   On user "go": apply, `git add`, `git rebase --continue` (or `git rebase --skip` if the proposed resolution is "skip this commit").
   On user "no": stop the command (see step 7 below).
5. **If the agent cannot determine a confident resolution at all** — e.g., the conflict involves intent that isn't apparent from the code or history — **stop the command without aborting the rebase**.
   Leave the rebase in progress (working tree contains conflict markers, `.git/rebase-merge` exists).
   Tell the user clearly:
   - Which branch is mid-rebase (`<X>`).
   - Where the pre-rebase ref is saved.
   - That the user can finish the rebase manually with `git rebase --continue` after resolving, or `git rebase --abort` to roll back to the pre-rebase ref.
   - That subsequent branches in the chain have not been touched.
   - That re-invoking the command from the source branch (or any later branch) will produce a fresh, smaller chain detection on top of whatever state the user leaves things in.

   Do **not** run `git rebase --abort` automatically.
   The user may want to inspect the in-progress state.

### Step 6 — Validation

Run validation **only for branches whose rebase had at least one in-file conflict to resolve** (trivial in-file or non-trivial).
Skip validation entirely for:
- Clean rebases (no conflicts at all).
- `--skip`-only resolutions (the "patch already represented in HEAD" trivial subtype). These don't introduce semantic change — the new base already represents the dropped commit's content — so there's nothing to validate that wasn't already validated when the predecessor branch was built.

Many repos take minutes to build and we don't want to waste time on rebases that didn't change anything semantically.

When validation is required:

1. **Discover commands.**
   In order of preference:
   - `CLAUDE.md` or `AGENTS.md` in the project — look for explicit build/test instructions.
   - `package.json` `scripts` — common keys: `build`, `typecheck`, `lint`, `test`. Run the smallest sensible subset (e.g., `build` + `test` if both exist; just `build` if no `test`).
   - Other ecosystem signals: `Cargo.toml` → `cargo build && cargo test`; `pyproject.toml`/`setup.py` → `pytest` if present; `Makefile` → check for `make build` / `make test` targets.
2. **Run them.**
3. **On failure, attempt to fix.**
   The conflict resolution may have introduced a real issue (e.g., dropped a dependency, misnamed a symbol).
   Read the failure, attempt a focused fix, commit it as a follow-on commit on `<X>` (do not amend the rebased commits), re-run validation.
4. **If the fix is ambiguous or attempts fail** — stop the command at this branch.
   Tell the user:
   - The rebase succeeded but validation is failing.
   - The exact failure output.
   - What was attempted, if anything.
   - The pre-rebase ref location for rollback.

If no validation commands can be discovered, mention that fact and continue without validation.

### Step 7 — Stopping cleanly

The command can stop at three points:
- During confirmation (user declines).
- On non-trivial conflict the user rejects, or one the agent cannot resolve.
- On validation failure that cannot be auto-fixed.

In all cases:
- Earlier branches that completed are left **rebased and checked-in locally**, not pushed.
- The current branch is left in whatever state stopped progress (rebase in progress, or rebased-but-failing-validation).
- Subsequent chain branches are completely untouched.
- All pre-rebase refs created so far are preserved.

**Note on detached HEAD during in-progress rebase**: while a `git rebase` is paused mid-flight, the working tree is on a detached HEAD — `git branch --show-current` returns empty, which can be disorienting. Use `git status` (which reports the in-progress rebase, the branch being rebased, and the conflicted files) for orientation when resuming.

The user can resume by:
- Manually completing or aborting the in-progress rebase.
- Re-invoking `/rebase-stack` from the source (or any descendant of where things stopped). The new invocation will re-detect a fresh, smaller chain starting from the current state of the world.

The command itself is **not re-entrant** in the formal sense — it does not persist state across invocations. Each run is a fresh detection-and-execution cycle. Git is the only persistent state.

### Step 8 — Final summary

Output:
- The chain that was processed, in order, with one-line outcome per branch (`rebased clean`, `rebased with conflicts (resolved silently / with confirmation)`, `rebased + validation passed`, `stopped at this branch`).
- Any branches that ended up empty (no unique commits relative to their new base) — flagged for the user to delete or close as appropriate.
- The list of pre-rebase refs created, with **inspection** and **cleanup** hints. Pre-rebase refs live in a custom git ref namespace (`refs/pre-rebase/...`), not under `refs/heads/`, so they are **invisible to most git GUIs** (GitKraken, GitHub Desktop, Sourcetree). Use the CLI:
  ```sh
  # Inspect — see all pre-rebase refs and the SHAs they preserve:
  git for-each-ref refs/pre-rebase/

  # Restore a single branch from its pre-rebase snapshot:
  git update-ref refs/heads/<branch> $(git rev-parse refs/pre-rebase/<branch>/<timestamp>)

  # Delete all pre-rebase refs created in this run (cleanup):
  git for-each-ref --format='%(refname)' refs/pre-rebase/ | xargs -r -n1 git update-ref -d
  ```
- A reminder that nothing has been pushed.
- Any divergence between local target and cached `origin/<target>` (still a non-blocking note).

## Design notes

### Why per-branch rebase instead of `git rebase --update-refs`

Git 2.38+ supports `git rebase --update-refs <new-base> <tip-branch>`, which rebases an entire stack in one operation and automatically advances every intermediate local branch ref it encounters along the way.
That's a great fast-path for clean stacks where you trust the rebase to produce sensible results without per-step inspection.

This command does **not** use `--update-refs` because:
- Conflict resolution benefits from fresh shell state and per-branch reasoning.
- Validation is per-branch — easier to gate behind "did this branch have a conflict?".
- Stopping cleanly mid-chain is simpler when each branch is its own atomic step.

If you have a stack that you're confident will rebase without conflicts and you want to skip the ceremony, `git rebase --update-refs <target> <source>` is the manual fast-path.

### Why no fetch

Fetching is a side effect that influences which commits the rebase will see.
Doing it implicitly inside this command would surprise users who deliberately keep their local refs at a particular state.
Keep ref hygiene in the user's hands.

### Why keep pre-rebase refs

They are cheap (just refs, no extra blobs) and trivial to bulk-delete.
The cost of having them is near zero; the value if a rebase goes wrong is high.
The user can clean them up with the one-liner in the final summary.

## Checklist for the agent

- [ ] Working tree is clean before starting.
- [ ] Target branch resolved (default `main`, fallback `master`).
- [ ] Source branch resolved (default current); explicit `chain` form short-circuits detection.
- [ ] No rebase already in progress.
- [ ] Effective frontier `EF` computed via patch-id (`--cherry-mark`) before chain detection.
- [ ] Chain detected via `EF`-relative topology, or taken verbatim from explicit chain spec.
- [ ] Confirmation listing produced (with `EF` shown) and approved.
- [ ] Pre-rebase ref saved before each branch's rebase.
- [ ] Conflicts classified trivial (in-file resolve OR `--skip` for "patch already represented") vs non-trivial; non-trivial confirmed before applying.
- [ ] Validation only after branches that had conflicts.
- [ ] Stopping does not auto-abort in-progress rebases.
- [ ] No pushes, no fetches, no auto-deletion of branches.
- [ ] Final summary lists outcomes, empty branches, and cleanup hint.

$ARGUMENTS
