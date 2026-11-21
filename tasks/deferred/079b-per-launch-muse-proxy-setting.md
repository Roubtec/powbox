# 079b — A per-launch proxy setting for the Muse peer reviewer

**Depends on:** 079, because a tailnet proxy is only reachable through its allow-list.
**Relates to:** 078 (Muse reviews from a network Meta serves), 080 (the setup guide, which covers Muse's own proxy setting), and `peer-review-run --provider muse`.

## Why this task exists

Once a container can reach a residential proxy (tasks 079 and 080), Muse needs to send its requests through it. Muse has a persisted proxy setting of its own, which is a first-class feature meant for enterprise egress control. It lives on the shared `muse-config` volume, so it already applies to every container on that machine. A powbox-level variable (for example one that `peer-review-run` passes to `muse`) would duplicate that setting, so it is not built yet.

## When it becomes actionable

When the persisted Muse setting turns out to be too coarse. One example: a machine where some containers must go through the proxy and others must not, all sharing one `muse-config` volume. Another: Muse's setting fails to cover a request path that the review run depends on.

## Direction and constraints

- Scope the variable to the Muse invocation. Never export a proxy for the whole container, which would silently send every tool's traffic through the home connection.
- Keep `peer-review-run`'s "unavailable" verdict meaningful. An unreachable proxy should read as Muse being unavailable, not as a failed review.
