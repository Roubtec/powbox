# Upstream report — Claude Code harness findings from heavy multi-agent use

Ferried out on a **transport-only commit** (companion to `LEARNINGS-CLEANUP.md`; drop the commit before opening the PR); paste sections as individual issues at <https://github.com/anthropics/claude-code/issues> (or one meta-issue linking split-outs).
Context that applies to every item: Claude Code runs headless (`--dangerously-skip-permissions`) inside Docker containers, driving parallel subagent fan-outs (up to ~6 concurrent) over git worktrees, often alongside a second CLI harness in the same container.
Observations are from July 2026 sessions on Opus-class models; each item was hit in real work, most more than once.

---

## 1. Read/Edit serve stale cached file contents after out-of-band changes (bug)

**What happens:** when a file changes on disk outside the harness's own writes — an external `git reset`/`clean`, a rebase, or a sibling process writing into a linked worktree — the Read tool can return cached content that disagrees with disk, and Edit's `old_string` fails to match text that `grep` confirms is present. Observed twice independently: (a) a subagent whose worktree was reset by an external process kept "reading" the pre-reset content and produced a broken commit from that false view; (b) a subagent in a linked worktree got Read output with line numbers offset from disk and had to fall back to `grep`/`sed`/`perl` against live disk to complete its edits.

**Impact:** wasted turns diagnosing "impossible" edit failures, and a correctness hazard — the agent cannot trust reads to detect that its work changed underneath it.

**Ask:** invalidate the file cache when mtime/size/inode changes out from under a tracked read, and after any git operation that can rewrite the tree (or at minimum on HEAD/index changes the harness didn't initiate). A visible warning ("file changed on disk since last read") would already prevent the broken-commit case.

---

## 2. Session scratchpad is shared across concurrent subagents, undocumented (bug/doc)

**What happens:** the per-session scratchpad directory advertised in the system prompt ("session-specific, isolated from the user's project") is one directory shared by every concurrently running subagent of that session. Two parallel reviewers both redirected validation output to `<scratchpad>/verify.log`; one read the other's results and reported a verdict for the wrong worktree. Parallel PR-fixers similarly clobbered a shared `threads.json`. In one case the collision was then misdiagnosed by the affected subagent as a working-directory bug, and the wrong mitigation propagated to ~10 later subagent prompts.

**Impact:** silent cross-contamination of validation results between parallel workers; caught only by content mismatches.

**Ask:** hand each subagent a private subdirectory (e.g. `<scratchpad>/<agentId>/`) as its scratchpad, or explicitly document the sharing so orchestrators know fixed filenames are unsafe. We now enforce unique naming via our own skill conventions, but the default is a trap.

---

## 3. Backgrounded Bash completion notification describes the launcher, not detached children (bug/doc)

**What happens:** launching external CLI processes from a `run_in_background` Bash call (`nohup some-cli … &`) makes the tracked task "complete" the moment the wrapper shell exits, while the real children keep running detached. The completion notification reads as if the work finished; nothing ever fires for the children.

**Impact:** misleading "completed (exit 0)" notifications; orchestrators hand-roll `pgrep`/output-file polling for every fan-out (we eventually built our own supervised runner to escape this).

**Ask:** either track process-group descendants of a backgrounded call (notify when the group drains), or document plainly that the notification is launcher-only and one-process-per-invocation is the supported pattern for tracked background work.

---

## 4. Subagents' background children are not reaped; subagents cannot await external events (bug/doc)

**What happens:** (a) a subagent spawned a detached reviewer process and returned; the orphan kept running, wandered into an unrelated sibling worktree (it lacked a tight `--cd`), and had to be hunted down by the orchestrator. (b) A different subagent ended its turn with "I'll wait for the monitor notification" — but subagents are never resumed, so it effectively returned an incomplete packet with a dirty worktree, silently.

**Impact:** orphaned processes doing wrong-scope work; incomplete results that look like completions.

**Ask:** reap (or at least report) a subagent's surviving process tree when it returns, and state in subagent-facing docs/system prompts that a subagent cannot be woken later — it must block on its own children or finalize. We now forbid both patterns via prompt contracts, but the failure mode is invisible until it bites.

---

## 5. Workflow tool: no drain-mode stop, retroactive resume of inserted stages, opaque agent metadata (feature)

Three related gaps hit while iterating on a live long-running workflow:

- **No drain:** the only edit path is `TaskStop` + resume, which aborts in-flight `agent()` calls mid-implementation; their work is lost even though the resume cache would have covered them had they finished. A "stop scheduling, let in-flight agents finish and journal, then exit" mode would make mid-run edits affordable — the friction directly changed what we shipped (the user declined a second stop to fix a known protocol gap).
- **Retroactive stage firing on resume:** inserting a new stage upstream of already-completed work fires it for items whose downstream stages already ran (e.g. PRs already opened), with no in-script way to detect this. Exposing per-call cache-hit status (`agent()` returning a `fromCache` marker, or a `resumed.hits` global) would let scripts skip already-delivered items; failing that, document the retroactive behavior in the resume section.
- **Opaque metadata:** per-agent `*.meta.json` carries only `{"agentType","spawnDepth"}` — no label, phase, or terminal status — so correlating agent transcripts with the plan requires jq archaeology over `journal.jsonl`. Writing `label`/`phase`/`status` at spawn/completion would make runs inspectable.

---

## 6. Skill tool: "already loaded above; instructions unchanged" when the body was never delivered (bug)

**What happens:** invoking a skill returned `Skill /<name> is already loaded above; instructions unchanged`, but the instruction body was not present anywhere in context — the dedup asserted a prior load that had not happened (plausibly summarization-related). The skill was only recoverable because the user's slash-command preamble duplicated the invocation contract.

**Ask:** when the dedup fires, verify the body is actually still in context (post-summarization), and re-deliver it if not; or have the message point at the exact prior message carrying the body.

---

## 7. Feature request: declarative co-tenant resource budget

Long agent runs increasingly share machines with latency-sensitive workloads (in our case a 24-hour soak with a hard sampling deadline in a sibling container). The orchestrating agent had to hand-throttle itself — "waves of 2 heavy subagents, avoid these ports" — tracked in a scratch file across the whole run. A declarative budget the harness enforces (max concurrent heavy subagents, aggregate CPU ceiling, reserved ports) would replace per-wave manual pacing and make co-tenant safety auditable.

---

## 8. Docs nit: subagent-transcript warning discourages the cheapest verification tool

The Agent tool result warns "Do NOT Read or tail this file … reading it will overflow your context." Taken literally, this discouraged the two bounded greps (`grep -o 'START "[^"]*"'`-style, tiny output) that would have root-caused a subagent's wrong environment diagnosis immediately instead of ten subagents later. Suggest softening to: never read/tail the whole file; bounded greps for specific strings are fine and often the fastest way to verify a subagent's claim.
