# Verify Ephemeral Agent Settings

Working notes for validating commit `f9bad1d` (Make Claude/Codex settings per-container ephemeral) before the `usability-improvements` PR merges.

Delete this file before merge — it captures the test plan, not durable docs.

## Why this needs manual validation

The feature bind-mounts a `/dev/shm` copy of `settings.json` / `config.toml` over the persistent volume original.
Bind-mounted files return `EBUSY` for `rename(2)`, so the design only works if the agent CLI persists settings via in-place `writeFileSync`, not via write-temp-then-rename.

Strings in `/home/node/.local/share/claude/versions/2.1.138` show both `writeFileSync` and `renameSync` are imported but I could not tie either to `settings.json` from outside the running binary.
Same uncertainty for Codex `config.toml`.

I could not test in the agent sandbox itself because `mount --bind` requires `CAP_SYS_ADMIN`, which sub-containers do not hold.

## Pre-flight

Rebuild both images so the new `shadow-agent-config.sh` is baked in and the updated entrypoint hooks are present:

```sh
./build.sh           # or build.ps1 on Windows
```

Confirm the sudoers allowlist picked up the new script:

```sh
docker run --rm powbox-claude:latest cat /etc/sudoers.d/node
# expect: shadow-agent-config.sh in the comma-separated allowlist
```

## Claude — happy path

1. Launch a Claude container: `commands/claude-container.sh` (or the PowerShell equivalent).
2. Inside the container, confirm the shadow is active:
   ```sh
   mountpoint /home/node/.claude/settings.json
   # expect: "/home/node/.claude/settings.json is a mountpoint"
   ```
3. In Claude, run `/model` and pick a non-default model.
4. From a second shell inside the same container:
   ```sh
   jq .model /home/node/.claude/settings.json
   ```
   Expect the new model value — this proves in-place writes survive the bind mount.
   If the file looks stale or `jq` errors on truncation, Claude is using atomic-rename writes and the design does not work; see *Fallback* below.
5. Stop the container.
6. Launch a fresh Claude container.
7. Inside, check the model in `settings.json` again — expect the pre-shadow baseline (i.e. the new value from step 3 is gone).

## Codex — happy path

Same pattern with `commands/codex-container.sh` and `/home/node/.codex/config.toml`.
Use `/model` (or whatever the current Codex equivalent is) to change the active model, then verify with:

```sh
grep -E '^(model|model_reasoning_effort)' /home/node/.codex/config.toml
```

## Concurrent containers

1. Launch container A (Claude). Change model to value X via `/model`.
2. Without stopping A, launch container B (Claude). Change model to value Y via `/model`.
3. In A, run `/model` again — expect to still see X (each container has its own tmpfs shadow).
4. Stop both. Launch container C. Expect baseline model, not X or Y.

## Opt-out

```sh
AGENT_SETTINGS_EPHEMERAL=0 commands/claude-container.sh
```

Inside, `mountpoint /home/node/.claude/settings.json` should report it is **not** a mountpoint, and `/model` changes should persist into the next container (the pre-fix behaviour).

## Fallback

If Claude (or Codex) uses atomic-rename writes for its settings file, the shadow design silently drops user edits.
Indicators:

- `/model` appears to succeed in the TUI but the file content does not change when inspected.
- The CLI logs an `EBUSY` error on settings persistence.

In that case:

1. Set `AGENT_SETTINGS_EPHEMERAL=0` in `compose.claude.yml` / `compose.codex.yml` to disable the feature.
2. Revisit with a different approach — most likely a per-container `CLAUDE_CONFIG_DIR` on tmpfs with selective symlinks back to the persistent volume for `sessions`, `projects`, `plugins`, `.claude.json`, etc.
   That avoids `rename(2)` on bind-mounted files entirely but is significantly more code and needs an explicit persist-list.
