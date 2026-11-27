# 093 — Bake a known-limitations document at a conventional path

**Relates to:** `docker/agent/Dockerfile` (baked assets), the layer-set layout under `docker/layers/`, README, and the `session-learnings` skill in `Roubtec/agent-skills`. Task 092 introduces on-demand reference files for agents, and this document is the same kind of thing.

## Why this task exists

Retrospective reports written after agent runs keep raising the same gaps: harness behaviour powbox cannot change, trade-offs that were decided on purpose, and one-off glitches that nobody could reproduce. Each time, someone verifies the finding again and reaches the same decision again. Nothing records that decision where the report's writer could see it.

The always-loaded instruction file is the wrong home. A limitation that has been accepted is of interest only at the moment someone is about to report it.

## Goal

Accepted limitations are written down once and baked into the image, at a place a report-writing agent can find without knowing it is in a powbox container. A writer that finds the document leaves out what it lists, or reports only what is new about it. A writer that finds no such document behaves exactly as it does today.

## The convention

The intended reader is the `session-learnings` skill, which lives in a separate repository and must not become coupled to powbox. So the convention is defined here, in terms any environment could satisfy: a plain Markdown file at a fixed, tool-neutral location, or at a location an environment variable names, holding entries a reader can match loosely against a finding.

This task defines and documents that convention and ships powbox's own document under it. Teaching the skill to look for such a document is a companion change in `Roubtec/agent-skills`, which should be able to describe the convention without mentioning powbox. Record the convention somewhere that change can cite.

## Direction and constraints

- An entry says what the limitation is, why it is accepted (upstream behaviour, a deliberate design choice, or never reproduced), and what would reopen it. New evidence must stay welcome: an unreproduced one-off should say plainly that a reproduction is what it is waiting for.
- This is not a place to park real bugs. Every entry has a decision behind it. A gap with a trigger for revisiting belongs in `tasks/deferred/`, and the document may point there.
- Some limitations exist only alongside a layer set's tools. A set should be able to contribute entries the way it contributes agent notes, and an image without those tools should not list them.
- The source lives in the repository as Markdown and changes by pull request. Human maintainers will want to read it too, so link it from the documentation.
- Do not load it by default. If the instructions mention it at all, one pointer is enough, and only if a report writer would not otherwise find it.
- Share a home with the reference files of task 092 where that exists. Neither task waits for the other.

## Seed content

Reword freely, and confirm that each entry still holds before recording it.

Harness and upstream behaviour:

- A background command's completion notice describes the command that was launched, not the processes it started, so a launcher that returns early looks finished.
- A long `claude -p` one-shot prints nothing until it ends. There is no heartbeat to wait on.
- `gh` prints a hint about event listening on stderr when it detects an agent, and no setting turns that off. It matters only where stderr is captured together with stdout.
- There is no declarative CPU or memory budget shared between agents and worktrees in one container. Throttling is the orchestrating skill's concern.
- Background polling loops from an earlier session can outlive it in a long-lived container and match a later process search.
- `.git` inside a linked worktree is a file, not a directory.

By design:

- `docker` is a Podman shim. There is no Docker daemon and none can be started, so behaviour specific to Docker Engine cannot be measured in the container and needs CI.
- Nested containers do not inherit the CPU affinity of the process that started them.

Raised once, and either not reproduced or deliberately left alone:

- zsh reads `$var:` followed by a letter as a modifier, so an exact force-with-lease built from two variables needs braces around them.
- The instructions do not say which GitHub identity pushes and pull requests go out under.
- The instructions do not say where subagent transcripts are kept, or that the main transcript omits a subagent's tool calls.
- A report that `wt-bootstrap` ended the calling shell, or swallowed the rest of a command chain, could not be explained from its source. A non-zero exit ahead of `&&` is documented behaviour.
- There is no recipe for building one test image from the main branch plus several open pull requests.
- The entrypoint's stderr from a launch is not kept anywhere.
- The extensionless helpers are committed without the executable bit. The image build sets their mode.
