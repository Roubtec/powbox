---
name: learnings-sweep
description: Session-learnings reports have piled up on throwaway branches across the repositories that use powbox and need to be harvested. Trigger when the maintainer asks to sweep, collect, triage or distribute accumulated session learnings, to clean up learnings branches across repos, or runs learnings-sweep. Collects every report into one local-only branch here, deletes the source branches, checks each finding against the current code, and turns what survives into tasks in the repository each belongs to. Not for recording a single session's learnings (that is session-learnings) and not for implementing the resulting tasks.
---

# Learnings sweep

The `session-learnings` skill leaves one report per session on a `learnings/…` branch of whatever repository the session ran in.
A sweep harvests them: gather, verify against today's code, decide with the maintainer, and hand each surviving item to the repository that can act on it — powbox, `agent-skills`, or the project itself.

Run it from the powbox checkout.
The other repositories are the checkouts the maintainer names, usually the folders under `/ctx`.

## Rules

- **The raw material is private; powbox and `agent-skills` are public.** Reports, digests, verdicts and the triage stay on a local-only branch of this checkout and are never pushed. Anything written into a public repository follows [the privacy rules](formats.md#privacy-rules-for-public-repositories), and a commit drafted by a subagent is checked against them before it is published.
- **Leave the other checkouts alone.** They are someone's working copies, often mid-task. Read their origins; do not fetch into, switch, or edit them. Task files for another repository are written in a fresh clone.
- **A report is a claim, not a fact.** The reporting agent saw one session through a narrow window. Every finding is checked against the current code before it counts, and a `Target:` line on a report is a hint. Most old findings turn out to be fixed already.
- **Not every glitch earns a fix.** The toolset need not cover every edge case. A finding becomes a task when the fix is cheap or the problem is general; otherwise it is recorded as an accepted limitation so it stops being re-raised.
- **Prefer a script, a check, or a result field over another sentence of guidance.** Where a rule already existed and the failure recurred anyway, more prose will not help.
- **Decisions are the maintainer's.** Bring a recommendation for each; do not write tasks for powbox or `agent-skills` before the selection is agreed.

## Procedure

1. **Scope.** Confirm which checkouts take part. `collect.sh list <checkout>...` shows what each origin holds; add `--also '<glob>'` for a repository that still carries older branch naming. Look at the total volume before choosing how to read it.

2. **Collect.** Create a branch named `local/learnings-sweep-<date>` from `origin/main`, set its `pushRemote` to a name that does not exist so a bare push fails, and run `collect.sh export --into learnings-sweep <checkout>...`. Commit. The directory name of each report is its attribution.

3. **Delete the sources.** `collect.sh delete --from learnings-sweep` prints what it would remove; `--yes` does it. It only removes a branch whose every file is committed here with identical content, under a lease on the commit it recorded. Anything it holds back carries more than a report or has an open pull request: tell the maintainer what the extra content is rather than deleting by hand, since something may depend on that branch. Stale local branches in the other checkouts are the maintainer's to prune.

4. **Digest.** Turn the reports into one findings list per repository in [the digest format](formats.md#digest-entry), merging repeats and keeping every source so recurrence is visible. A handful of reports can be read directly. Beyond that, give each repository's reports to its own reader and work from the digests; extraction is safe to delegate because it involves no judgment.

5. **Verify.** For each finding, establish what is true now in the repository it targets, with [a verdict and evidence](formats.md#verdicts). Look at open pull requests and all three task folders, not only the default branch: in-flight work often covers a finding already. Group the findings by target before handing them out so each verifier reads one repository.

6. **Triage.** Reduce the open findings to clusters, and for each one recommend: a task (where, how large, script or prose), an accepted limitation, or nothing. Read `docs/known-limitations.md` first if it exists. Note contradictions between reports and between the skills themselves; they are findings too. Write the synthesis beside the verdicts.

7. **Decide.** Put the recommendations and the genuinely open decisions to the maintainer, and record the answers next to the triage so an implementer can be given that file as a brief.

8. **Distribute.**
   - *A project repository:* task files on a branch pushed to its origin, no pull request. Re-check each premise on its current default branch, follow its own task conventions, and choose numbers that are free on open pull-request heads and unmerged branches as well.
   - *powbox and `agent-skills`:* task files on a branch with a pull request each, grouped so a task is one deliverable change. Small, certain fixes may simply be made.
   - *Accepted limitations:* added to the known-limitations document.
   - *Upstream:* nothing by default. Raise a harness or vendor limitation with the maintainer only when it has no apparent policy reason and a report could help.

9. **Close out.** Tell the maintainer what was deleted, what was held and why, what was pushed where, and that the local branch remains as the private record.

## When the volume is large

Readers, verifiers and task writers can each run as separate agents.
They share one scratchpad and one checkout, so give every one a single named output file, forbid git state changes, and have task writers commit without pushing.
State the privacy rules in full in any prompt that produces text for a public repository.
