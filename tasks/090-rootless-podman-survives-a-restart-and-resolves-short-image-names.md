# 090 — Rootless Podman survives a container restart and resolves unqualified image names

**Relates to:** the Podman block of `docker/shared/entrypoint-core.sh`, `docker/layers/full/` (its Dockerfile and `containers.conf`), `scripts/smoke-test-podman.sh`, `docs/rootless-podman.md`, and the Containers entry of `docker/layers/full/agent-notes.md`.

## Why this task exists

The `docker` shim invites Docker assumptions. Some of them fail here in ways that read as a broken environment, not as a difference worth knowing about.

**After a restart, Podman refuses to start.** Podman keeps its runtime state under `XDG_RUNTIME_DIR` and expects that directory to vanish at boot. Here it is a home-directory path on the container's writable layer, so it survives a `docker restart` or a host crash. Podman then finds state describing containers and processes that no longer exist, and every `podman` and `docker compose` command fails until someone clears the stale state by hand. An agent in the middle of a task gets no hint that this is what happened.

**An unqualified image name that is not already local does not resolve.** No unqualified-search registry is configured, and the alias list covers only some popular names. Docker would fall back to Docker Hub. The pre-cached images hide the gap because they are already local, but any other public image that a project's compose file names without a registry fails to pull. This was reproduced end to end with a pinned public image referenced by its short name.

## Goal

After a container restart, clean or not, the first Podman command works. An unqualified image name resolves the way a Docker user expects. Both hold for `podman`, the `docker` shim and `podman compose`, and neither disturbs the shared read-only image store.

## Direction and constraints

- The halves are independent and can be separate commits. They are one task because the same host build and smoke run validate both.
- For the runtime state, the choice is between clearing it at start and keeping it somewhere that disappears with the container's processes, which is what Podman assumes anyway. Either way, never remove the state of a live Podman: the entrypoint also runs for the image-store writer role, and the code must be certain that nothing from this boot owns the state it clears.
- Only the runtime half is stale. The graph root holding images and named volumes is a persistent volume and must not be touched.
- Containers that were running before the restart are gone afterwards. If that would surprise an agent, the agent notes should say so.
- Configure one search registry, matching Docker. With more than one, a short name becomes ambiguous: that is a name-squatting risk, and Podman's answer to ambiguity depends on whether it has a terminal to ask on. Check what the short-name mode does for a non-interactive agent.
- The lean image has no Podman, and the entrypoint block is already gated on its presence. Keep it that way.
- Validation needs a host build with the `full` layer set, which CI never builds. Each half deserves a smoke probe: a start with leftover runtime state, and a pull by short name of an image that is not pre-cached. The second needs the network, so see `docs/smoke-tests.md` on which stages may use it.
- Compose health checks are task 025a and stay there.
