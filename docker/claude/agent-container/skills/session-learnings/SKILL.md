---
name: session-learnings
description: "Capture actionable learnings from a substantial Claude agent run as an uncommitted Markdown note: review the visible session transcript/context, identify powbox sandbox deficiencies, orchestration friction, wasted turns, missing tooling, docs gaps, and automation opportunities, then write a concise report under docs/ or the repo root without staging or committing it. Trigger when the user asks to record session learnings, run a post-run retrospective, capture environment issues, document improvement opportunities after an agent session, or improve powbox based on agent-run friction. Do not trigger for ordinary code review or project bug reports unless they affected the agent environment or workflow."
---

# Session Learnings

Record practical improvement opportunities discovered during a Claude run.

This skill is a retrospective capture tool, not a repair workflow. The output is a Markdown artifact for humans to triage later.

## Rules

- Create a new, untracked Markdown file only when there is at least one concrete learning, unless the user explicitly asks for a no-issue report.
- Never stage or commit the file.
- If the broader task also involves committing code, keep this retrospective file out of the commit.
- Do not paste raw transcripts, long command logs, credentials, tokens, API keys, private URLs, or secret-looking values.
- Prefer observed facts over speculation; label uncertain inferences as such.
- Keep the audit efficient. Use the transcript/context already available first, and inspect files or logs only when they materially improve the report.

## Scope

Capture issues and opportunities related to the powbox environment or agent orchestration, such as:

- missing or stale tools, package caches, browser/runtime setup, shell defaults, or lint/test helpers
- sandbox, firewall, mount, volume, permissions, path, line-ending, or cross-platform friction
- ambiguous container instructions, skills, task workflows, or agent delegation mechanics
- repeated manual commands, avoidable waits, noisy output, brittle setup, or wasted turns
- cases where better default docs, scripts, smoke tests, hooks, status lines, or baked assets would have saved time
- project-specific friction only when it points to an environment, documentation, or workflow improvement

Do not use this skill to file ordinary product bugs, code-review findings, or feature requests unless they explain agent-run friction or a powbox improvement.

## Procedure

1. **Review the run.** Use the current conversation transcript/context, your command history, failed commands, interruptions, retries, and any relevant user corrections. If the user provides a transcript path, read it. If no transcript path is provided, do not spend more than a few minutes searching for on-disk session logs; the visible context is sufficient.

2. **Filter for actionability.** Keep only items with a plausible improvement path. Merge duplicates. Drop complaints that cannot be reproduced, cannot be acted on, or are purely about task complexity.

3. **Choose an output path.** Prefer `docs/agent-session-learnings-YYYYMMDD-HHMM.md` when `docs/` exists. Otherwise use `agent-session-learnings-YYYYMMDD-HHMM.md` at the repo root. Use UTC timestamps from `date -u +%Y%m%d-%H%M`. If the path already exists, append a short numeric suffix instead of overwriting it.

4. **Write the report.** Keep it concise but specific enough that a maintainer can convert entries into tasks. Use this structure:

   ```markdown
   # Agent Session Learnings - YYYY-MM-DD HH:MM UTC

   Repository: <repo name or path>
   Agent: Claude
   Session focus: <one-line summary of the work>
   Status: Uncommitted retrospective note

   ## Summary

   - <highest-signal takeaway>

   ## Issues and Opportunities

   ### 1. <short title>

   - Type: <tooling | sandbox | docs | workflow | automation | agent-instructions | other>
   - Severity: <low | medium | high>
   - Evidence: <brief observed symptom; no raw secrets or long logs>
   - Impact: <how it wasted turns or blocked work>
   - Suggested improvement: <specific fix, experiment, or investigation>
   - Repro/trigger: <when this happens again>
   - Confidence: <observed | inferred>

   ## Follow-Up Candidates

   - <small actionable next step>
   ```

   Omit empty sections. Add a short "No concrete issues found" summary only when the user explicitly requested a report even if nothing went wrong.

5. **Verify it remains uncommitted.** Run `git status --short -- <file>` when inside a git repo. The file should appear as `??`. If it was accidentally staged, unstage it with `git restore --staged -- <file>` and re-check.

6. **Report back.** Tell the user the file path, the number of issues captured, and that it was left untracked. If you found no concrete learnings and did not write a file, say that directly.
