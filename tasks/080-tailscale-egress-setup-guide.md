# 080 — Write a host setup guide for reaching a tailnet proxy from containers

**Depends on:** 079, because the guide documents its `.powbox-egress` format and trust model.
**Relates to:** task 078 (Muse PR reviews from a self-hosted runner), whose network-filtered Muse catalog is the guide's worked example; task 081 (the narrowed `apt-get` grant), which shapes how easily the in-container firewall can be removed.

## Why this task exists

Task 079 gives powbox an egress allow-list, but powbox deliberately stops there. Joining a tailnet, running a proxy and restricting who may use it are host-side jobs the user owns. Without a worked example, a user new to Tailscale has to put that together from several vendors' docs. The guide also has to state the trust model plainly. The in-container firewall is the first line, but the hard limits on what a container may reach across the tailnet belong in the tailnet policy and in the proxy. Those are settings the user controls outside the agent's reach.

## Goal

A new `docs/` chapter that takes a reader from "containers on host A cannot reach anything on my tailnet" to "containers on host A reach exactly one proxy port on host B, and that proxy forwards only to the destinations I chose". Every step lands on a host the reader controls, and each stage ends with a way to verify it.

## Scope

In scope:

- **The topology:** a container on a remote host, the remote host's Tailscale, the tailnet, a forward proxy on a home machine, the residential uplink, and the target service. Briefly, why the proxy is per tool and not a Tailscale exit node: an exit node would route all of the remote host's traffic through home.
- **Tailscale on the host, not in the container,** and why:
  - In the container, the node key would sit where the agent can read it.
  - Userspace networking would carry traffic over loopback, out of the firewall's sight.
  - Every container would become a tailnet node.
- **Tailnet policy:** tag the remote host, and write a grant/ACL that lets that tag reach only the proxy host's proxy port. This is the real limit on what the container can touch on the tailnet, and it is set in the Tailscale admin console.
- **The home proxy,** with tinyproxy as the worked example:
  - It listens only on the machine's tailnet address.
  - It allows only the tailnet peer.
  - It filters destinations by default-deny, so the home connection is not a general-purpose egress.
  - How to run it as a service.
- **The `.powbox-egress` line** for the proxy's tailnet IP and port. Use tailnet IPs rather than MagicDNS names: 079 accepts no hostnames, and node IPs are stable.
- **Verification from inside a container:**
  - The proxy port answers.
  - Another port on the same host is still blocked.
  - The proxy refuses a destination outside its filter.
- **Pointing a tool at the proxy:** generic `HTTPS_PROXY` for a single command, and, for Muse, its own persisted proxy setting on the shared `muse-config` volume. The implementer must confirm the setting's real name and form from Muse's docs or from `muse` itself, and say how it was confirmed. Do not invent it.
- **A native-Linux routing note:** container traffic is forwarded and masqueraded into `tailscale0`, not host-originated. Docker's default masquerading usually covers this, but if the proxy answers from the host and not from a container, say what to check (forwarding and NAT for the Docker bridge toward the tailnet interface) instead of leaving the reader to infer it.
- **A short section on host VPNs.** A full-tunnel VPN on the host needs no powbox change, because container traffic is NAT'd by the host and follows its routes. The caveats: VPN-side resources in private or CGNAT ranges still need a 079 rule; per-app split tunnelling may not count Docker's forwarded traffic as the chosen app; and a host kill switch can drop that forwarded traffic.
- **A short Docker Desktop (Windows/WSL2) note:** container egress leaves through the Windows host's network stack. The reader should check that the Windows Tailscale client's routes apply, rather than assume it.

Out of scope:

- Any powbox code change. If writing the guide shows that 079's contract needs one, record that as a follow-up task.
- Setting up a self-hosted CI runner (task 078's other direction).
- Advice on any service's terms of use.

## Context and references

- Task 079, for the file format, the trust model and the recreate behaviour.
- `docker/shared/init-firewall.sh` for what is blocked by default.
- Task 078 for the Muse symptom: an empty model catalog from datacenter networks.
- The current Tailscale docs on tags, grants/ACLs and Linux installation, and the tinyproxy documentation (`Listen`, `Allow`, `Filter`, `FilterDefaultDeny` and related settings). Check the current syntax against the vendors' docs at writing time rather than from memory, since both evolve.

## Target files or areas

A new `docs/` chapter. A README pointer from the egress firewall description that task 079 adds. A row in `AGENTS.md` → "Where to read more" for tasks that touch egress exceptions.

## Implementation notes

- Write it as a case study a user can follow step by step, keeping one line per paragraph as the repo's Markdown convention asks. Use placeholders for tailnet IPs, ports and hostnames. Never commit the maintainer's real addresses.
- Mark plainly which steps happen on which machine. That split is the point of the guide.
- Word the trust model so it holds whatever root inside the container can do: the in-container firewall guards against accidents, while the tailnet policy and the proxy filter are the limits that do not depend on the container at all. Task 081 makes removing the firewall a deliberate act, but the guide's claims must not rest on it.

## Acceptance criteria

- A reader new to Tailscale can follow the guide end to end on their own machines, and each stage has a verification step.
- The guide states where each limit is enforced (in-container firewall, tailnet policy, proxy filter) and why the latter two are the hard ones.
- The VPN and Docker Desktop sections answer "do I need to change powbox for this?" directly.
- README and `AGENTS.md` link to the chapter.
- `markdownlint-cli2` reports no new findings against the base branch for the touched files.

## Validation

Lint as above. The maintainer walks the guide on their own VPS and home machine. That walk-through is the real test, and anything it shows to be wrong is fixed in this task.

## Review plan

Read the guide as a newcomer. Check that every command and config snippet matches current vendor documentation, that no real addresses leak, and that the trust model matches tasks 079 and 081.
