# 075 — Evaluate dropping the Podman-only security relaxations for images without Podman

## Why this task is deferred

It only becomes actionable once task 073 has made Podman optional, and it needs an investigation on real hosts before anyone can say whether it is viable.
Move it to `tasks/` when 073 has merged.

## Why this task exists

`compose.shared.yml` applies `security_opt: seccomp=unconfined, apparmor=unconfined, systempaths=unconfined` to **every** agent container.
The comment above those lines explains that they exist so rootless Podman can run nested containers (`keyctl`, `pivot_root`, writable `/proc/sys`).

After task 073 the lean image has no Podman, yet its containers still run with those three relaxations.
The lean image is aimed at unattended agent runs with web access, which is exactly where a tighter sandbox is worth the most.

## Scope

**In scope:**

1. Establish which of the three `security_opt` entries a Podman-less container still needs for powbox's own features.
2. If at least one can be dropped: gate it on the image, using the `powbox.podman` label task 073 introduces, in both launchers.
3. Decide whether the `/dev/fuse` and `/dev/net/tun` passthrough should follow the same gate at that point.

**Out of scope:**

- Changing anything for images that have Podman.
- The `cap_add` entries (`NET_ADMIN`, `NET_RAW`, `SYS_ADMIN`): the firewall and the shadow mounts need them.

## Context and references

- `compose.shared.yml`, the `security_opt` block and its comment.
- `compose.fuse.yml`, `compose.netdev.yml`, and `PODMAN_DEVICE_MODE` in `scripts/launch-agent.sh` with its `powbox.podman-devices` label and recreate-on-change handling; `scripts/launch-agent.ps1` mirrors it.
- Task 073's "Decisions" section records why the devices were left alone at that time: they add no capability while seccomp is unconfined and `SYS_ADMIN` is granted. That reasoning changes if this task restores the default seccomp profile.
- `docs/rootless-podman.md`.

## Target files or areas

The investigation itself changes no file. Which of these change depends on its outcome:

- `compose.shared.yml` — the `security_opt` block and the comment above it (the entries leave, or the comment records why they stay).
- A new compose overlay file next to `compose.fuse.yml` and `compose.netdev.yml`, holding whichever entries turn out to be Podman-only.
- `scripts/launch-agent.sh`, `scripts/launch-agent.ps1` — add the overlay for images carrying `powbox.podman`, with label-and-recreate handling like `PODMAN_DEVICE_MODE` has.
- `scripts/smoke-test-worktree-metadata.{sh,ps1}` and `scripts/smoke-test-podman.{sh,ps1}` — they replicate the compose security options on their own `docker run` command lines (grep for `seccomp=unconfined`) and must keep matching what the launcher gives each kind of image.
- `docs/rootless-podman.md`, and `AGENTS.md` ("Security") and `README.md` ("Workspace Shadow Mounts → Security") where they describe the container's security posture.

## Open questions the investigation must answer

- **AppArmor and shadow mounts.** Docker's default AppArmor profile denies `mount` even with `CAP_SYS_ADMIN`. `shadow-mounts.sh` mounts tmpfs over workspace subdirectories, so `apparmor=unconfined` may be required regardless of Podman on AppArmor-enforcing hosts. Test on one.
- **Seccomp and bubblewrap.** The agent harnesses sandbox commands with `bwrap`, which creates user namespaces. Confirm it works under Docker's default seccomp profile with `SYS_ADMIN` granted.
- **Seccomp and the firewall.** Confirm `init-firewall.sh` is unaffected.
- **`systempaths`.** Nothing but Podman is known to write `/proc/sys`; confirm.
- **Docker Desktop / WSL2.** The answers may differ from native Linux.

## Implementation notes

- A per-image security profile is frozen at container creation like the device set, so a change needs the same label-and-recreate handling `PODMAN_DEVICE_MODE` already has.
- Compose cannot conditionally drop a key from `compose.shared.yml`; the relaxations would move into an overlay file that the launcher adds only for images with Podman, as `compose.fuse.yml` is added today.
- If the investigation shows all three are needed without Podman, close this task with the findings written into `docs/rootless-podman.md` and the `compose.shared.yml` comment, so the question is not reopened.

## Acceptance criteria

- A written answer, per `security_opt` entry, to "does a Podman-less powbox container need this, and for what", backed by a test on native Linux with AppArmor enforcing and on Docker Desktop.
- Either the droppable entries are gated on the image in both launchers, with the smoke stages passing for a lean and a `full` image, or the task is closed with the evidence recorded in the docs.
- The decision on device passthrough is recorded either way.

## Validation

Every check here needs a real Docker host; none of it can run inside a powbox container. Ask the maintainer to run the lean image's smoke test (`./commands/smoke-test.sh`, including the dir-mount and self-hosted stages) with each entry removed in turn.

## Review plan

Read the recorded evidence first and check each claim names the host it was tested on. If code changed, trace one lean launch and one `full` launch through the launcher to confirm the compose file set differs only by the intended overlay.
