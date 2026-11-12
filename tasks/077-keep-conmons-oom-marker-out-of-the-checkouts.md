# 077 — Keep conmon's `oom` marker out of the checkouts

**Relates to:** the full layer's rootless Podman (`docker/layers/full`, `docs/rootless-podman.md`).

## Why this task exists

Empty files named `oom` keep appearing at the root of agents' checkouts, where they show up as unexplained paths in the batch skills' main-checkout cleanliness reports. One traced in a jabko session on 2026-10-10 appeared a fraction of a second after an agent ran `podman stop` on a minio container it had started from that checkout.

conmon writes an empty `oom` marker into its working directory when it sees an OOM event for a container it monitors, and a container started with a plain `podman run -d …` from a checkout leaves conmon there. In the same agent container, the marker does not establish that the container ran out of memory: `podman inspect` reported the nested container's `CgroupPath` as `/`, that cgroup's `memory.events` already showed a nonzero `oom_kill`, and an idle alpine container left an `oom` file both when stopped and when it exited by itself. A pre-existing OOM counter in the shared cgroup may explain the markers.

## Goal

Starting and stopping a nested container from an agent's default directory leaves no `oom` file there, while existing relative-path and Compose-discovery behavior is preserved. The agent notes' Containers entry stays accurate for whatever the fix leaves agents to do.
