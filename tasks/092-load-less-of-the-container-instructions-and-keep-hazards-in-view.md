# 092 — Load less of the container instructions by default, and keep the hazards in view

**Depends on:** 086, because its pointer to the peer-review helper and its safe one-shot forms are part of what has to stay always loaded; 091, because it edits the tooling rows this pass relocates.

**Relates to:** `docker/shared/container-agent.md.tmpl`, the layer-set notes (`docker/layers/<set>/agent-notes.md`) and their staging (`scripts/stage-agent-template.sh`, `scripts/stage-agent-template.ps1`), the per-agent seeding hooks (`docker/shared/entrypoint-claude-hook.sh`, `docker/shared/entrypoint-codex-hook.sh`), and README "Updating Agent Instructions".

## Why this task exists

The rendered instruction file is loaded into every session of both agents, in every project, and it grows with each fix. It carries tool tables with version and caveat prose, the full reasoning behind a helper's rarest edge case, and a filesystem table. A layer set's notes are appended to it whole. A session pays for all of that before it reads its first request, whether or not it will ever convert a document or meet a squash merge.

At the same time, a handful of hazards that have each cost real work are not in the file at all. Adding them on top of an unchanged document would make the first problem worse.

The skills in `Roubtec/agent-skills` faced the same pressure and answered it by moving seldom-used guidance into bundled reference files that an agent reads when the situation calls for them. The container instructions should take the same shape.

## Goal

An average session loads markedly less. Every session still sees every hazard, meaning the places where a mistake is silent or destroys someone's work. Reference material is one cheap read away, and the always-loaded text says when to make that read.

## What stays always loaded

This is the judgment the task turns on, and it cannot be reduced to a list. One test for any sentence: would an agent that has not read it do damage, or waste a session, with no signal that would send it looking? If so, the sentence stays.

Material an agent would look up when the need shows itself moves to a reference file. Which tool converts a PDF, why a helper refuses a particular state, and the shape of a helper's JSON output are all of that kind. Where the tool's own help or error message already says it, the text can go altogether.

Guidance a modern agent follows happily without being told is removed. Naming the core runtimes up front is fine. The rest of the tooling can shrink to a line such as "common document tools and a browser are available, see the tool list".

## Hazards this pass adds

Each of these is backed by an incident. The substance matters, not the wording, and each should cost about a sentence.

- A pipeline reports the status of its last command, so a failure before the pipe is hidden. A state-changing command chained after an unchecked `cd` runs wherever the shell happened to be left. Agents have run git commands against the shared main checkout this way.
- Path-level discards (`git checkout -- <path>`, `git restore`, `git stash`) belong beside the broad cleanups in the shared-surfaces warning. They have destroyed a sibling's uncommitted work as surely as a hard reset would.
- A worktree's `node_modules` is not private scratch. Installs hardlink from the shared store, so editing a file in place edits every worktree's copy. A symlink to another checkout's `node_modules` is not matched by a `node_modules/` ignore pattern, which matches directories only, so it ends up staged. The answer in both cases is to install in the worktree.
- `dc-remove` finds a clone only from the worktree that ran `dc-enter`. From anywhere else it says there is nothing to remove and succeeds.
- `pnpm-shadow-doctor` exists, and is the answer when an install reports nothing to do while a package's binaries are missing. Nothing names it today.
- `markdownlint-cli2` exits zero when its globs match no files, so a wrong path or an over-broad ignore reads as a clean pass.
- The baked `yq` is the jq wrapper. Its filters are jq syntax, not the Go tool's.
- For a layer set that carries Go: several worktrees each running a test suite at full parallelism exhaust the container's memory. The signature is a killed process or an unrelated timeout, never an error that names memory.

## Direction and constraints

- One template renders both agents' instruction files, and a layer set contributes through its notes. The on-demand files must be readable by both agents at the same place, and a set must be able to contribute its own reference material as it contributes notes today. Most of a set's current notes are reference.
- Landmine: the rendered instruction file lives on a config volume shared by containers that may run different image builds and different layer sets, and whichever started last rendered it. A pointer can therefore be read in a container whose image lacks the file it names. Reference material that describes an image is more truthful read from that image than from the shared volume, which argues for baking it. Pointers still have to degrade gracefully, in the spirit of today's advice to check with `command -v`.
- The hooks substitute a fixed list of variables into the template. A reference file that needs one of them must be rendered as well, or do without.
- A pointer that only says a file exists does not get followed. Each one should name the situation that makes the read worthwhile.
- Some hazards are better fixed in the helper than described. Where the helper is powbox's own, prefer the fix. Where it is baked from `Roubtec/agent-skills`, the sentence is what this repository can do.
- Suites and smoke stages assert on the template's text and on the rendered files: the staging suite, the layer-set suite's check of the appended heading, the `rm`-prompt waiver suite that seeds from the real template, Tier 1's seeded-template check, and the exact-version smoke assertions tied to the tooling rows. They move with the text.
- Nothing should be lost by accident. Treat every removal of "obvious" guidance as a deliberate deletion and name it in the PR, so a reviewer can object. Moved content should be findable under a recognisable heading.
- Report what a session loads before and after, for the lean image and for one with a populated layer set. There is no numeric target, but a pass that does not shrink the always-loaded text substantially has not done its job.
- Seeding and rendering happen in the entrypoint, so validation needs a built image and a restarted container. Tier 1 covers the lean image and the committed `browser` set; a change to the `full` set's notes needs the maintainer's host build.
- Update the documents that describe how the instructions are built and seeded.
