---
name: session-learnings
description: "Capture actionable learnings from a substantial Claude agent run as a concise Markdown report, then ferry it off a remote machine by committing only the report on a dedicated temporary branch, pushing that branch to origin, and opening no PR. Review the visible session transcript/context for powbox sandbox deficiencies, orchestration friction, wasted turns, missing tooling, docs gaps, and automation opportunities. Trigger when the user asks to record session learnings, run a post-run retrospective, capture environment issues, document improvement opportunities after an agent session, or improve powbox based on agent-run friction. Do not trigger for ordinary code review or project bug reports unless they affected the agent environment or workflow."
---

# Session Learnings

Record practical improvement opportunities discovered during a Claude run.

This skill is a retrospective capture and transport tool, not a repair workflow. The output is a Markdown artifact for humans to triage later.

## Rules

- Create a report only when there is at least one concrete learning, unless the user explicitly asks for a no-issue report.
- Never stage or commit the report on the session's current branch or checkout.
- Publish the report through an isolated temporary worktree on a dedicated throwaway branch based on the remote default branch.
- Add exactly one report-only commit, push the branch to `origin`, and do not open a pull request.
- Do not switch, stash, clean, reset, or alter the session's current branch, tracked files, or pre-existing uncommitted changes.
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

3. **Choose artifact names.** Use one UTC timestamp from `date -u +%Y%m%d-%H%M%S` for both `docs/agent-session-learnings-YYYYMMDD-HHMMSS.md` (or the repo root when `docs/` does not exist) and `learnings/session-YYYYMMDD-HHMMSS`. If either the path or branch already exists locally or on `origin`, append the same short numeric suffix to both instead of overwriting or force-pushing.

4. **Prepare an isolated ferry branch.** Verify that the current directory belongs to a Git repository with an `origin` remote, resolve and fetch `origin`'s default branch, and create a temporary worktree with the ferry branch based on that remote default branch. When the powbox worktree helpers are available, run `wt-bootstrap` first and stop with a clear report if it fails; use a safely allocated temporary directory with `git worktree` only when those helpers are unavailable. Do not create or check out the ferry branch in the session's current worktree. If the repository or remote is unavailable, write the report at the chosen path in the current checkout as an untracked fallback, do not stage it, and clearly report that it could not be ferried.

5. **Write the report in the temporary worktree.** Keep it concise but specific enough that a maintainer can convert entries into tasks. Use this structure:

   ```markdown
   # Agent Session Learnings - YYYY-MM-DD HH:MM UTC

   Repository: <repo name or path>
   Agent: Claude
   Session focus: <one-line summary of the work>
   Transport: Temporary branch <branch> (no PR)

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

6. **Commit and publish only the report.** Check the temporary worktree's status, stage the report path explicitly, and verify that the staged path set contains only that file before committing. Create one commit with a descriptive session-learnings message, then push the ferry branch to `origin` with upstream tracking. Never force-push and never create a pull request.

7. **Clean up safely.** After a successful push, verify that the temporary worktree is clean and remove it; keep the local and remote ferry branch so the user can retrieve the report. If committing or pushing fails, preserve the report, branch, and temporary worktree for recovery, and report the exact failure instead of deleting the only usable copy. Leave the session's original checkout untouched except for the explicit untracked fallback when publication cannot be attempted.

8. **Report back.** Tell the user the report path, issue count, ferry branch, commit, and push status, and state that no pull request was opened. If no concrete learnings were found and no report was requested for that case, say directly that no file or branch was created.
