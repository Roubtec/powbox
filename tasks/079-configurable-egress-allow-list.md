# 079 — Add a configurable egress allow-list to the container firewall

**Relates to:** the egress firewall (`docker/shared/init-firewall.sh`); task 078 (Muse PR reviews from a network Meta serves), whose network-filtered Muse catalog is the first concrete use case.

## Why this task exists

The firewall blocks every private, link-local and CGNAT destination, and it cannot be configured. That default has held well and stays the default. Some real setups need a narrow hole in it, though. The motivating one: containers on the always-on VPS should reach a forward proxy on the maintainer's home PC across the maintainer's Tailscale tailnet (CGNAT `100.64.0.0/10`), so that selected traffic leaves from a residential connection. Other users will have their own cases, for example a dev database on the LAN, or a service behind a corporate VPN.

Powbox should own only the allow-list. Joining a tailnet or a VPN, and running the proxy, stay host-side concerns (see task 080 for the guide). The design mirrors the `.powbox-layers` selector: one gitignored file per machine in the powbox checkout, with a committed example, applied to every container that machine launches.

## Goal

A user can write `.powbox-egress` in their powbox checkout. Every container the launcher creates afterwards then allows exactly those destinations and ports, on top of the unchanged default policy. A machine without the file behaves exactly as today.

## Scope

In scope:

- The file format, with a committed `.powbox-egress.example` and a `.gitignore` entry for `.powbox-egress`.
- Parsing, validation and normalization in both launchers (`scripts/launch-agent.sh` and its `.ps1` twin), for every launch mode (dir-mounted and `--isolated`).
- Passing the normalized rules into the container, and recreating a stopped container when its rules are out of date.
- Applying the rules in `init-firewall.sh`, IPv4 and IPv6 alike.
- Telling agents that exceptions may exist and where to read them.
- Docs, plus a hermetic test suite.

Out of scope:

- Per-project opt-in or narrowing from `.powbox.yml` / `.powbox.local.yml` (deferred as 079a). A committed `.powbox.yml` must never be able to widen egress: under `--isolated` the launcher works on arbitrary cloned repos, and one could otherwise ship a LAN-opening rule.
- Hostname destinations, ICMP, port ranges and multi-port lines.
- A per-launch proxy variable for Muse (deferred as 079b).
- Host-side enforcement (a `DOCKER-USER` chain, Tailscale ACLs). Task 080 documents those.
- Hardening the sudo allowlist (task 081).

## The agreed contract

- **File:** `<powbox checkout>/.powbox-egress`, found beside `.powbox-layers` and resolved the same way (`scripts/layers-select.sh` is the precedent for the location and BOM/CRLF tolerance). It is never read from a workspace.
- **Line format:** like a hosts file. One rule per line: `<proto> <destination> <port>`, separated by whitespace. `#` starts a comment that runs to the end of the line, whether it fills the line or follows a rule, and blank lines are ignored.
  - `proto` is `tcp` or `udp`.
  - `destination` is an IPv4 or IPv6 address or a CIDR. A bare address means a single host.
  - `port` is a single port number, or the literal `any`.
  - A user who wants several ports on one host writes several lines.
- **Validation:** a malformed line is a hard launcher error that names the file and line, following the `layers-select.sh` precedent: launching with a different policy than the one written would be worse than not launching. Reject `/0` in either family outright. Warn, but proceed, when a rule looks like a mistake rather than a policy:
  - A destination outside every blocked range. The default already allows it, so the rule does nothing.
  - A prefix broad enough to reopen most of a blocked range.
- **Normalization:** produce a canonical, deduplicated and order-independent form, so reordering lines or editing comments does not change the hash. Textual canonicalization (trim, lowercase, sort, dedupe) is enough; two spellings of the same IPv6 address may hash differently, which costs at most one needless recreate.
- **Transport:** the launcher passes the normalized rules as a container environment variable, and records their hash in a `powbox.egress-hash` label.
  - A stopped container whose label differs is recreated. A running one is refused with an error that says to stop it first, as the `powbox.ctx-hash` check does in both launchers. Attaching with a warning, as `powbox.continue` does, is not acceptable here: it would keep a removed exception open in a session the user believes is back on the default policy.
  - With no file, no label value and no variable are set. A container that carries no label, including one created before this feature, therefore counts as "no rules" and is not recreated needlessly. A container that carries a label while the file is now absent or empty differs, and is recreated.
- **Reading inside the container:** `init-firewall.sh` reads the rules as root from the container's creation-time environment (`/proc/1/environ`; PID 1 is `docker-init`, because compose sets `init: true`).
  - It never reads them from its own argv or environment, so an agent re-running `sudo init-firewall.sh` re-applies the launch-time policy rather than one it passes in. sudo's `env_reset` already strips the caller's environment; keep it that way rather than adding `env_keep`.
  - This is accident-grade protection, in line with task 081: it stops a mistaken or casual widening, not a determined agent. Word the trust model that way wherever it is documented.
  - The variable stays visible in the agent's own environment, and that is intended: it is how an agent sees which exceptions exist.
- **Applying:** the exceptions are ACCEPT rules placed after the loopback and ESTABLISHED rules and before the private-range DROPs. `iptables` takes the IPv4 rules and `ip6tables` the IPv6 rules. The start banner lists the active exceptions, and stays as it is today when there are none.

## Context and references

- `docker/shared/init-firewall.sh`: the whole current policy. It runs from `entrypoint-core.sh` on every container start, through the scoped sudoers entry in `docker/base/Dockerfile`.
- `scripts/launch-agent.sh`: `powbox_ctx_hash` and the `EXISTING_CTX_HASH` recreate block are the pattern to mirror. `COMPOSE_ARGS` / `CTX_LABEL_ARGS` show how per-container labels and arguments reach `docker compose run`.
- `scripts/launch-agent.ps1`: `Get-Powbox-CtxHash` and its recreate counterpart are the twin.
- `scripts/layers-select.sh` / `.ps1`: how a gitignored, per-machine selector file in the checkout is located and parsed in both shells.
- `docker/shared/container-agent.md.tmpl`, section "Network": the agent-facing description of the firewall. It also omits CGNAT today, which is worth fixing while touching it.
- `scripts/test-context-mount-config.sh`: the precedent for one pure-shell suite that covers a bash launcher helper and its PowerShell twin.
- `docs/rootless-podman.md`: where the docs describe what nested containers inherit from the firewall.

## Target files or areas

`docker/shared/init-firewall.sh`, `scripts/launch-agent.sh`, `scripts/launch-agent.ps1`, `.gitignore`, a new `.powbox-egress.example`, a new `scripts/test-*.sh` suite, `docker/shared/container-agent.md.tmpl`, `AGENTS.md` (Security), and `docs/rootless-podman.md`. Give the README a short description of the egress firewall, covering the default policy and the exceptions file; task 080 links its guide from there. Any new file baked into the base image needs its `COPY` in `docker/base/Dockerfile` and an entry in `scripts/base-source-files.txt`.

## Implementation notes and landmines

- **Never fail open.** The OUTPUT chain's policy is ACCEPT, and the script flushes the chain first. Any error between the flush and the DROP rules leaves the container wide open; under `set -e` it also aborts startup, but do not rely on that. Validate everything before the flush, and treat an entry that `init-firewall.sh` rejects as skipped with a warning. Never let it abort the default policy halfway.
- **Check again inside the container.** `init-firewall.sh` runs as root on input that crosses a trust boundary, so it must apply its own strict check rather than trusting the launcher's. The shells differ, so the parsing logic exists in the bash launcher, the PowerShell launcher and the firewall. The line format was chosen to keep that cheap. Keep them in agreement, and let the test suite pin them against shared fixtures.
- **Testability:** split rule generation from rule application, so the hermetic suite can check the generated iptables invocations (order included, so the exceptions are proven to sit before the DROPs) without `NET_ADMIN`. The suite must also show that an invalid entry never removes a default DROP.
- **Backward compatibility is deliberately not handled.** An older base image ignores the variable, which fails closed: the destination stays blocked. Document that the feature needs a base rebuild; no capability label or skew check is wanted.
- **Hash scope:** hash only the normalized rules, so a comment edit does not recreate containers.
- **Compare on every reuse.** The ctx-hash comparison runs only when a context mount is desired, so a literal copy would skip the case where `.powbox-egress` was deleted and leave a removed exception live. The egress comparison must run whenever an existing container is about to be reused.
- **The blocked ranges live in two places.** The launchers' "outside every blocked range" and "over-broad" warnings need the same range list `init-firewall.sh` blocks. Let the shared fixtures pin the launchers' copy against the firewall's, so the warnings cannot drift from the policy.
- **Verify the environ trust claim.** PID 1 runs as `node`, so `/proc/1/environ` stays trustworthy only while `node` cannot write PID 1's memory. That rests on the host's ptrace policy (yama `ptrace_scope` varies by host) with seccomp unconfined in `compose.shared.yml`. Check it on a real container, and keep the documented trust model no stronger than what holds.
- **Nested Podman containers** route through this container's network namespace and already inherit the firewall. They inherit the exceptions too, with no extra work. Mention this where the docs describe what nested containers inherit.
- **Agent instructions:** say that the user may configure exceptions, and that the variable lists them. Keep it short and free of values that could drift.

## Acceptance criteria

- With no `.powbox-egress`, the generated rule set and the banner are identical to today's, and a container without exceptions is not recreated. A container that still carries exceptions is recreated once the file is removed.
- With a valid file, a new container accepts exactly the listed protocol, destination and port combinations inside the blocked ranges, and still drops everything else there, on IPv4 and IPv6.
- Editing or removing the rules recreates a stopped container on its next launch, and refuses to attach to a running one. Editing only comments or line order does neither.
- A malformed line stops the launch with a message that names the file and line, in both launchers. `/0` is rejected, and a public or over-broad destination warns.
- `sudo init-firewall.sh` run by the agent re-applies the launch-time policy and accepts no other input.
- `.powbox-egress` is gitignored, and `.powbox-egress.example` documents the format with commented examples. One of them is a single tailnet host and port.
- The README, `AGENTS.md`, the agent instructions template and `docs/rootless-podman.md` describe the feature and its accident-grade trust model in line with the implementation.

## Validation

- The new hermetic suite passes under `./scripts/run-pure-shell-tests.sh`, including the PowerShell half where `pwsh` is available.
- `shellcheck`, `shfmt -d` and the recursive PSScriptAnalyzer pass are clean on the touched files.
- Host check by the maintainer (needs a base rebuild and cannot run in-container): with a rule for a reachable tailnet or LAN host, `curl` to that host and port succeeds from a fresh container. Another port on the same host and an unlisted private address both still fail. Removing the rule and relaunching restores the default.

## Review plan

Read `init-firewall.sh` first, adversarially: look for every path where a bad or hostile input could leave the chain more open than the defaults, or where the rules could come from somewhere other than the creation-time environment. Then check that the bash and PowerShell launchers agree on parsing, normalization and hash for the same fixtures, and that the recreate logic matches the ctx-hash behaviour, including for a deleted file and a running container.
