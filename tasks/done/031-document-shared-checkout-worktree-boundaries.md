# Task 031: Document shared-checkout boundaries for parallel worktrees

## Why this task exists

Powbox's worktree helpers safely scope creation, pruning, and removal by container, but a primary agent can invoke its peer harness inside the same container.

Those processes share the main checkout and the container's `.worktrees` volume. A broad root-checkout `git clean -fdx`, `git reset --hard`, or raw deletion of `.worktrees` can therefore discard another in-container worker's uncommitted files despite the normal worktree convention.

The original report could not attribute a specific reset to a particular process, and maintainers do not want Powbox to prohibit ordinary Git recovery commands globally. The appropriate response is an accurate contract and non-destructive visibility, not a new command-policy wall.

## Scope

- Document which surfaces are shared and which are container- or worktree-scoped when Claude and Codex operate in one container versus separate `--isolated` containers.
- Add a concise worktree-contract reminder to the Powbox-owned workflow/seed guidance at the point where agents start parallel work.
- Add a non-destructive pre/post-batch main-checkout cleanliness report or warning where it can be implemented without rejecting legitimate user-owned changes.

Out of scope: blocking `git reset --hard` or `git clean`, wrapping all Git commands, moving the worktree volume outside the repository, changing branch naming, or claiming that the historical data loss has a proven single cause.

## Context and references

- `README.md` documents `.worktrees/$CONTAINER_NAME/<slug>`, persistent worktree metadata, and `--isolated` clones, but it does not plainly connect same-container peer execution with the shared main checkout risk.
- `docker/shared/container-agent.md.tmpl` becomes the in-container `AGENTS.md` contract and is the most useful point for a worker before it starts cleanup.
- `docker/claude/agent-container/workflows/wf-address-tasks.js` already supplies a worktree contract and owns batch control flow.
- `wt-bootstrap` and `wt-remove` remain the authoritative mechanics; this task must not reimplement or weaken their safety checks.

## Target files or areas

- `README.md`
- `docker/shared/container-agent.md.tmpl`
- `docker/claude/agent-container/workflows/README.md`
- `docker/claude/agent-container/workflows/wf-address-tasks.js`
- The corresponding Powbox-owned Codex worktree guidance, if it duplicates the same contract
- Focused workflow/helper tests if a new cleanliness-report function is added

## Implementation notes

- State the distinction precisely: separate agent containers have separate worktree volumes; two harnesses invoked inside one container share that container's worktree volume and main checkout; `--isolated` gives a full private clone when a stronger boundary is needed.
- Recommend scoped cleanup (`git -C <assigned-worktree> …`) and committing meaningful checkpoints. Warn that `git clean -fdx` ignores `.gitignore`, so it is unsuitable as a broad concurrent-run cleanup in the shared main checkout.
- Do not say that a normal clean/reset is never allowed. Explain the concurrency precondition and recommend pausing/finishing sibling work first.
- For batch observability, capture the main-checkout porcelain status at a defined boundary and report a dirty result with paths. It must not delete, reset, stash, or fail merely because the user deliberately started dirty; distinguish pre-existing dirt from new unexpected paths when practical.
- Keep instructions compatible with both agent types and avoid assuming unavailable collaboration API controls.

## Acceptance criteria

- README and in-container guidance accurately describe the shared-main/shared-volume versus separate-container/isolated-clone boundaries.
- Parallel-work guidance recommends explicit worktree CWD checks and scoped cleanup, and explains the `git clean -fdx` caveat without imposing a global ban.
- The Powbox-owned batch workflow reports main-checkout dirt at the chosen pre/post boundaries without modifying it and without producing a false claim that all dirt is agent-created.
- Existing worktree helper behavior, orphan preservation, and legitimate single-checkout development remain unchanged.
- Documentation follows the repository's one-paragraph-per-line convention and links to the existing worktree/isolated-mode material rather than duplicating it wholesale.

## Validation

- Run the relevant JavaScript syntax/lint checks and any workflow-focused tests available in the repository.
- Run `shellcheck`/`shfmt` only if shell helpers change.
- Review rendered Markdown links and ensure the template wording will be included in generated container instructions after an image rebuild.
- Because workflow/template changes are image-affecting, request host/CI image validation before final merge.

## Review plan

Review for accurate scoping and non-destructive behavior. Confirm the change informs agents about concurrent cleanup risk without forbidding legitimate recovery work or misrepresenting the historical attribution.
