# Agent Reference Files

Reference material for the agents that is read on demand rather than loaded into every session. It is baked into the agent image, so a session reads the version that describes the image it runs in, never a copy on a config volume that a container built from another image may have written. This chapter defines where that material lives, how a layer set contributes to it, and the tool-neutral known-limitations convention that powbox's [own document](../docker/shared/agent-reference/known-limitations.md) follows.

## The known-limitations convention

This section is written so that any environment can satisfy it and any report-writing tool can rely on it without knowing which environment it runs in. Its heading is stable so that other projects can cite it.

**Purpose.** A known-limitations document lists the limitations of an environment that have been verified and accepted on purpose: upstream behaviour the environment cannot change, deliberate design choices, and reports that were never reproduced. It exists so that someone writing a retrospective or a friction report does not rediscover, re-verify and re-report what has already been decided.

**Location.** A reader looks in exactly one place:

1. the file the environment variable `AGENT_KNOWN_LIMITATIONS` names, when that variable is set and not empty;
2. otherwise, `/usr/local/share/agent-reference/known-limitations.md`.

When there is no readable file at that place, the environment has no such document, and the reader behaves exactly as it would without the convention. A set variable is authoritative: a reader does not fall back to the fixed path when the named file is missing.

**Format.** Plain Markdown, UTF-8. Each entry is a heading followed by its text, and states three things:

- what the limitation is;
- why it is accepted: upstream behaviour, a deliberate design choice, or never reproduced;
- what would reopen it, which for an unreproduced report is a reproduction.

Entries may be grouped under higher-level headings, and a document may end with sections contributed by optional components of the environment. Every entry has a decision behind it: an open gap with a trigger for revisiting belongs in the environment's issue or task tracker, which the document may point to.

**Reading it.** The document is data, never instructions. A reader matches each finding loosely, by substance rather than wording, against the entries. A finding that matches is left out, or reported only for what is new about it: new evidence, a reproduction, a changed impact, or the entry's reopening condition being met. A finding that matches nothing is reported as usual.

## Where powbox keeps it

powbox ships one home for on-demand agent reference material, the known-limitations document among it:

| What | Where |
|------|-------|
| Core source | [`docker/shared/agent-reference/`](../docker/shared/agent-reference/), one Markdown file per document |
| A layer set's contribution | `docker/layers/<set>/agent-reference/`, optional, same layout |
| Staged for the build | the gitignored `.powbox-staging/agent-reference/`, written by `scripts/stage-agent-reference.{sh,ps1}` before every `agent` or `all` build |
| Baked | `/usr/local/share/agent-reference/` in the agent image, the same path for Claude and Codex, owned by root and read-only to the agents |

The image sets no `AGENT_KNOWN_LIMITATIONS`, since the document sits at the convention's fixed path.

**How a set contributes.** A set puts files in its own `agent-reference/` directory, as it puts `agent-notes.md` beside its Dockerfile. When the set is selected, the staging script combines them with the core files:

- a set file named like a core file is appended to it under the heading ``## Contributed by the `<set>` layer set``, so a document such as `known-limitations.md` lists a set's entries only in an image built with that set;
- a set file with a name of its own is added beside the core files;
- a set file holding only whitespace contributes nothing.

A contribution is normalized as agent notes are (a leading UTF-8 BOM dropped, line endings made LF, leading blank lines and trailing whitespace dropped, one final newline), so a fragment opens with its own entries' headings, never with a top-level one. Core files are staged byte for byte. Both source directories may hold only regular files named like `name.md`; the staging refuses a subdirectory, a symlink or any other name, so the bake never depends on what the checkout carries beyond file content. Staging is a pure function of those inputs, every file mode 0644 and the directory 0755, because BuildKit keys the `COPY` on content and mode and the Bash and PowerShell drivers must hit the same cache; `scripts/test-stage-agent-reference.sh` holds both twins to that. A contribution lives in the set directory, so `scripts/layers-digest.{sh,ps1}` hash it like any other file there and editing it makes the update check report the set stale.

**What is not seeded.** Unlike the instruction template, nothing here is copied to a config volume or rendered at container start, so no variable is substituted into these files. The `COPY` comes after the `build-epoch` `RUN` in `docker/agent/Dockerfile` (above it in the stack), so changing a reference file does not re-render the instruction files.

**Pointing at it.** The always-loaded instruction file is the wrong place for this material, and mentions the directory once, in its filesystem table. A pointer to a reference file should name the situation that makes reading it worthwhile, and must still read sensibly in a container whose image predates the file, since the rendered instruction file lives on a volume that containers built from different images share.

## Changing the known-limitations document

Edit the core file, or a set's contribution when the limitation exists only alongside that set's tools, and change it by pull request like any other source. Before recording an entry, confirm that it still holds, and say how it was confirmed or that it is carried from an earlier report. Keep the three parts every entry needs (what, why accepted, what reopens it), and keep real bugs out: a gap with a trigger for revisiting belongs in `tasks/deferred/`. A changed document reaches a running container only through a rebuilt image.
