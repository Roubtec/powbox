# Task 002b — Preserve root node_modules isolation when a JS project is scaffolded mid-session

Generic follow-up from the PR #59 review (per-agent volume isolation). Parked in
`tasks/deferred/` because the branch is defendable as-is — the gate fixes host litter for the
**common** case (launching an already-JS folder mounts the volume; a never-JS folder stays
clean) and the residual regression is confined to an uncommon, recoverable path — while a
proper fix expands scope (either regresses the litter gate or adds a new wrapper-level
diagnostic with its own validation).

Review thread: https://github.com/Roubtec/powbox/pull/59#discussion_r3439823386 (codex, P2).

## Background — the gap

To stop non-dev folders from accruing empty `node_modules`/`.worktrees` mountpoints (host
litter / native-binary pollution), PR #59 gates the root `node_modules` + `.worktrees` volume
mounts and `PNPM_STORE_DIR` behind `MOUNT_WORKSPACE_VOLUMES`, which is true only when the host
folder already declares a JS/powbox project at **launch time**
(`scripts/launch-agent.sh:411-423`, `scripts/launch-agent.ps1` parity):

```sh
if [ -f "$PROJECT_PATH/package.json" ] ||
   [ -f "$PROJECT_PATH/pnpm-workspace.yaml" ] ||
   [ -f "$PROJECT_PATH/.powbox.yml" ]; then
    MOUNT_WORKSPACE_VOLUMES=true
fi
```

The gap: if a folder is launched with **none** of those markers (`MOUNT_WORKSPACE_VOLUMES=false`,
so no `agent-nm-*` mount and no `PNPM_STORE_DIR`) and the user then **scaffolds a JS project in
that same session** (`pnpm init` / writes a `package.json`, then `pnpm install`), the in-container
pnpm wrapper can only (re)shadow subpackage `node_modules`; it cannot retrofit the missing root
mount. So `/workspace/<slug>/node_modules` is written straight onto the **host bind mount** —
reintroducing the exact host litter / native-binary pollution this change exists to prevent, and
regressing the previous always-mounted-root behavior.

This is narrow and recoverable (relaunching the agent once the folder has a `package.json`
mounts the volume), which is why it is P2 and deferrable rather than blocking — but it is a real
hole in the gate's own goal.

## Goal

Keep a mid-session-scaffolded project's root `node_modules` off the host bind mount, **without**
recreating empty mountpoints on folders that never become JS projects (the regression the gate
deliberately removed).

## Suggested approach (pick one)

**A. Wrapper-level diagnostic / refusal (preferred — preserves the gate).**
Have the `pnpm`/`pn` wrapper (`docker/shared/pnpm-shadow-wrapper.sh`) detect, in dir-mounted mode,
that it is about to run a **root** install while `<workspace>/node_modules` is **not** a mountpoint
(i.e. the volume was never mounted because the folder was non-dev at launch), and either:
- warn loudly and proceed — one line telling the user the install is landing on the host bind and
  to **relaunch the agent** (the folder now has a `package.json`, so the next launch mounts an
  isolated volume); or
- refuse with that same guidance (stricter; matches the "no host litter" intent more aggressively
  but is more disruptive to a quick scaffold).
  Detect "should have been mounted" via `mountpoint -q "<workspace>/node_modules"` plus the absence
  of `PNPM_STORE_DIR` (the launcher only sets it when it mounted the volume), so a genuinely
  self-hosted or already-mounted run never trips the check.

**B. Always create the volume but mount it lazily (narrower litter trade-off).**
Always pass the `-v agent-nm-<container>:.../node_modules` mount but accept the empty mountpoint;
revisit whether the empty-dir litter is actually worse than host-side `node_modules`. (This is the
behavior the gate replaced, so only revisit if A proves impractical.)

**C. Re-evaluate markers at install time and self-relaunch hint.**
Cheapest signal only — emit a hint from the entrypoint/wrapper rather than changing mount geometry.

Whichever is chosen, mirror behavior across **both** `launch-agent.sh`/`launch-agent.ps1` (if the
launch path changes) and the bash pnpm wrapper, and add a smoke check: a non-dev folder that gains
a `package.json` mid-session does not silently write root `node_modules` to the host bind without
at least a warning.

## Acceptance

- Scaffolding a JS project mid-session in a folder launched as non-dev no longer **silently**
  pollutes the host bind mount: the user is warned (or refused) and told to relaunch, or the root
  volume is in fact used.
- A folder that never becomes a JS project still gets **no** `node_modules`/`.worktrees`
  mountpoints (the gate's primary benefit is preserved — no new empty-dir litter).
- A normal already-JS dir-mounted launch and a self-hosted launch are unaffected (no spurious
  warning/refusal).
- Behavior consistent across bash and PowerShell launchers and the pnpm wrapper.
