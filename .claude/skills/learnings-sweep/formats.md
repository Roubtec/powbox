# Learnings sweep formats

Read the section a step points at; nothing here is needed before then.

## Layout of the local branch

```text
learnings-sweep/
  MANIFEST.tsv           one row per collected file (written by collect.sh)
  DELETED-BRANCHES.tsv   repo, branch, commit of each deleted source
  reports/<repo>/        reports copied verbatim
  digests/<repo>.md      findings per source repository
  triage/verify-*.md     verdicts per target repository
  triage/TRIAGE.md       the synthesis and recommendations
  triage/DECISIONS.md    the maintainer's answers
```

A deleted branch can be recreated from its manifest row while the remote still holds the object: `gh api repos/<owner>/<repo>/git/refs -f ref=refs/heads/<branch> -f sha=<commit>`.

## Digest entry

```markdown
### <repo>-NN <short specific title>
- Sources: <report> #<issue>; … (every report that raised it)
- First/last seen: <date> / <date>
- Reported type/severity: <as written>
- What happened: one to four sentences naming the tool, command, file and error, so a reader who never saw the report knows what failed and when.
- Suggested improvement (as reported): the reporter's own specifics.
- Target guess: powbox | agent-skills | project | upstream | unclear (two when it splits, saying which part goes where)
- Self-reported status: whether a report says it was fixed or worked around, and how.
```

Order by recurrence, then severity.
Keep one-off and low-severity items as one-liners rather than dropping them.
Record things that worked and should be preserved in their own closing section.

## Verdicts

One row per finding: verdict, evidence or what was searched, what remains, the cheapest credible fix, and whether it is general or needed an unusual coincidence.

| Verdict | Meaning | Needs |
|---|---|---|
| ADDRESSED | The current code, docs or image already do what was asked, or make the failure impossible | A path and a quoted phrase, a delivered task confirmed present, or a live probe |
| TRACKED | An open task or pull request covers it | The reference, and whether it covers all of it |
| DEFERRED | A deferred task covers it | The reference, and whether this looks like its trigger firing |
| PARTIAL | Some of it is handled | Exactly what remains |
| OPEN | Nothing addresses it | What was searched, so a false OPEN can be caught |
| STALE | The mechanism it concerns was removed or replaced | What replaced it |
| KEEP | A practice worth preserving | Whether the current text still preserves it |
| NOT-OURS | What remains belongs to another target | Which one |

Never ADDRESSED on plausibility.
Spend depth where a finding recurs or was reported as severe; a targeted search is enough for a one-off.

## Privacy rules for public repositories

Text written for powbox or `agent-skills` must not contain:

- the name of any private repository, organization, product, package scope or domain term;
- a finding identifier, since it carries the repository name;
- another repository's task numbers, pull-request numbers, branch names, file paths or script names;
- a quotation from a report;
- any mention of the sweep, the triage, or the local branch.

Describe evidence generically ("a project with database-backed integration tests", "several long review batches").
Provenance is deliberately sacrificed; the task text has to carry the intent on its own.
Before publishing, search the outgoing commit for every private name collected in this sweep and for the directory name of the local branch.
