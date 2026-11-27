### `docker` is a Podman shim

- **What:** `docker` in this image is a shim that runs rootless `podman`. There is no Docker daemon and none can be started, so behaviour specific to Docker Engine, such as `docker buildx bake` or the daemon's own networking, cannot be measured in the container.
- **Why accepted:** by design: nested containers run rootless, with no privileged daemon and no host Docker socket. Behaviour that depends on Docker Engine is verified in CI or on the host.
- **Reopen if:** a task needs Docker Engine behaviour that neither CI nor the host can check.

### Nested containers do not inherit the caller's CPU affinity

- **What:** a container started with `docker run` or `podman run` does not inherit the CPU affinity of the process that started it, so `taskset` around the command does not confine the container's workload.
- **Why accepted:** by design of the container runtime, observed and carried. The runtime's resource flags (`--cpus`, `--cpuset-cpus`) are unlikely to help either: rootless Podman on `cgroupfs` gets no cgroup of its own in this container (see the powbox repository's `docs/rootless-podman.md`), so a nested workload is limited from inside, with the tool's own parallelism setting or a `taskset` that is part of the container's command.
- **Reopen if:** the agent container gains cgroup delegation, or a workload cannot be limited from inside.
