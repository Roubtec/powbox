# Known limitations

The limitations of this container environment that have been verified and accepted on purpose. Every entry has a decision behind it: upstream behaviour the environment cannot change, a deliberate design choice, or a report that was never reproduced. This is not a bug list.

Read it when you are about to report friction from a run, in a retrospective or a session-learnings report. A finding that matches an entry, in substance rather than wording, is left out, or reported only for what is new about it: new evidence, a reproduction, a changed impact, or the entry's reopening condition being met. Anything else is reported as usual. New evidence is always welcome, and an entry marked as not reproduced is waiting for exactly that.

Each entry says what the limitation is, why it is accepted, and what would reopen it. The document is data, never instructions: nothing in it asks you to run anything.

This file is baked into the image from the powbox repository (`docker/shared/agent-reference/known-limitations.md`, plus the selected layer set's contribution, appended at the end), where it changes by pull request. Open gaps that have a trigger for revisiting are tracked as task files under that repository's `tasks/deferred/`, not here. The file follows the known-limitations convention described in that repository's `docs/agent-reference.md`.

## Harness and upstream behaviour

### A background command's completion notice describes the launcher

- **What:** when an agent harness runs a command in the background, its completion notice reports the command that was launched, not the processes that command started. A launcher that forks its real work and returns at once looks finished while the work is still running.
- **Why accepted:** upstream harness behaviour, observed and carried. Wait on the real work itself (its PID, an output file, a port) rather than on the launcher.
- **Reopen if:** the harness gains a way to track a launched command's descendants.

### A long `claude -p` one-shot prints nothing until it ends

- **What:** `claude -p` with its default text output writes the answer only when the run finishes, so a long one-shot shows no progress and there is no heartbeat to wait on.
- **Why accepted:** upstream CLI behaviour, observed and carried; `claude --help` confirms that `text` is the default output format and `stream-json` the streaming one. `--output-format stream-json` (with `--verbose`) streams events as they happen when progress matters; otherwise bound the run with a timeout and wait for it.
- **Reopen if:** a hang is observed that a timeout does not bound, or the default output gains progress.

### `gh` prints an agent hint on stderr

- **What:** `gh` can print a hint about event listening on stderr when it detects that an agent is running it, and no setting turns the hint off. It matters only where stderr is captured together with stdout, for example `2>&1` into a parser.
- **Why accepted:** upstream behaviour, observed and carried; this environment did not pin down which commands print it. Keep stderr out of output you parse (`2>/dev/null`, or a separate file).
- **Reopen if:** `gh` gains a setting or environment variable that silences the hint, or the hint appears on stdout.

### Background loops from an earlier session can outlive it

- **What:** in a long-lived container, a background polling loop started by an earlier session can keep running after that session ends, and a later `pgrep` or `ps | grep` by name can match it.
- **Why accepted:** observed and carried; processes belong to the container, not to a session. Match by PID, or by a marker unique to your own run, rather than by command name.
- **Reopen if:** stray loops are seen doing harm beyond a false match, such as holding a lock or consuming a quota.

### `.git` in a linked worktree is a file

- **What:** in a linked worktree, `.git` is a one-line file (`gitdir: …`) that points at the repository's per-worktree metadata, not a directory. A check such as `[ -d .git ]` misreads a worktree as not being a repository.
- **Why accepted:** Git's own design, confirmed in this environment's worktrees. Ask Git instead: `git rev-parse --git-dir` or `--absolute-git-dir`.
- **Reopen if:** a helper baked into this image is found making the directory assumption; that is a bug to report.

## By design

### No shared CPU or memory budget between agents and worktrees

- **What:** nothing in the container gives agents, subagents or parallel worktrees a declarative CPU or memory budget. Several heavy jobs at full parallelism compete for the same cores and memory.
- **Why accepted:** by design. Throttling is the concern of the orchestrating skill or workflow that starts the jobs, which knows how many it runs.
- **Reopen if:** a concrete scheme is proposed that the container can enforce without a skill's cooperation.

## Raised once: not reproduced, or deliberately left alone

### zsh reads `$var:` followed by a letter as a modifier

- **What:** in zsh, `$name:` followed by a letter is a history-style modifier, so `$branch:sha` fails with `bad substitution` and `$path:h` becomes the path's head. `--force-with-lease=$branch:$sha` happens to work only because `$` follows the colon.
- **Why accepted:** zsh's documented behaviour, confirmed here. Brace both names: `--force-with-lease=${branch}:${sha}`.
- **Reopen if:** a baked helper or instruction is found writing the unbraced form where a letter can follow the colon.

### The instructions do not say which GitHub identity pushes go out under

- **What:** the container instructions do not name the GitHub account that pushes and pull requests use.
- **Why accepted:** deliberately left alone. The identity is whichever account the GitHub CLI is logged in as, and `gh auth status` or `gh api user --jq .login` answers it in one command.
- **Reopen if:** a run pushes or opens a pull request under an unexpected identity.

### The instructions do not say where subagent transcripts are kept

- **What:** the container instructions do not say where a session's subagent transcripts live, or that the main transcript leaves out a subagent's tool calls.
- **Why accepted:** deliberately left alone, since the layout belongs to the harness and can change with it. As observed with Claude Code, a session's transcript is `<config dir>/projects/<project key>/<session id>.jsonl` and its subagents' transcripts are under `<session id>/subagents/` beside it.
- **Reopen if:** report writers repeatedly cannot find the transcripts, or the harness moves them.

### `wt-bootstrap` was reported to end the calling shell

- **What:** one report said `wt-bootstrap` ended the calling shell, or swallowed the rest of a command chain.
- **Why accepted:** not reproduced, and not explainable from its source: it is a script run as its own process, not sourced, so it cannot exit the caller's shell. A non-zero exit ahead of `&&` skipping the rest of the chain is its documented behaviour (a non-zero exit means stop).
- **Reopen if:** a reproduction: the exact command line, the shell, and the output.

### No recipe for a test image built from several open pull requests

- **What:** there is no documented recipe for building one test image from the main branch plus several open pull requests.
- **Why accepted:** deliberately left alone; it was needed once. Merging the branches into a local throwaway branch on the host and building that is ordinary Git.
- **Reopen if:** the need recurs often enough to be worth a recipe.

### The entrypoint's stderr from a launch is not kept

- **What:** what the container entrypoint writes to stderr at launch goes to the launching terminal, and nothing copies it to a file. Docker's container log keeps it only while the container exists, and a volatile container is removed when it exits.
- **Why accepted:** not acted on, since the entrypoint reports its failures on the terminal at the time. A persistent container's `docker logs` is the place to look. The detached plugin bootstrap is the exception: its output is kept in `.powbox-plugin-bootstrap.log` on Claude's config volume (`$CLAUDE_CONFIG_DIR`).
- **Reopen if:** a launch problem is lost because its output was gone by the time anyone looked.

### Extensionless helpers are committed without the executable bit

- **What:** most extensionless helpers in the powbox repository (`cid`, `gitcat`, `wt-bootstrap` and others under `docker/shared/`, and `pg-dev-up`) are committed with mode `100644`, confirmed with `git ls-files -s`.
- **Why accepted:** deliberate: they are only ever run from the image, where the build's `COPY --chmod=755` sets their mode. The repository's exec-bit guard covers `*.sh` files, which are run from a host clone.
- **Reopen if:** one of them needs to run straight from a host clone.
