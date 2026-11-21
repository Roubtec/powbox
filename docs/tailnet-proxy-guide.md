# Reaching a tailnet proxy from powbox containers

This chapter is a worked case study. You start with containers on one machine that cannot reach anything on your Tailscale tailnet. You end with those containers reaching exactly one proxy port on a second machine, and that proxy forwarding only to the destinations you chose.

Routed from the README's [Egress exceptions](../README.md#egress-exceptions-powbox-egress) section and from [AGENTS.md](../AGENTS.md) → "Where to read more".

Powbox owns only one step of this: the `.powbox-egress` allow-list. Joining the tailnet, writing its policy and running the proxy happen on machines and in a console that you control, outside any container. Each stage below says where it runs and ends with a check.

The vendor commands and settings were checked against the Tailscale and tinyproxy documentation in November 2026, and against tinyproxy 1.11. Both projects change, so if a step fails as written, compare it with the current vendor docs before assuming the guide is right.

## The setup at a glance

```text
 host A (remote, e.g. a VPS)                      host B (home)
+-----------------------------+                  +-----------------------------+
| powbox container            |                  |                             |
|   in-container firewall     |                  |                             |
|   + .powbox-egress rule     |                  |                             |
|             |               |                  |                             |
|             v (NAT)         |     tailnet      |                             |
| Tailscale on host A --------+----------------->+ Tailscale on host B         |
|                             |  policy: host A  |             |               |
|                             |  may reach only  |             v               |
|                             |  proxy-host:8888 | tinyproxy on 100.x.y.z:8888 |
|                             |                  |   Allow: host A only        |
|                             |                  |   Filter: default deny      |
|                             |                  |             |               |
|                             |                  |             v               |
|                             |                  | residential uplink          |
+-----------------------------+                  +-------------+---------------+
                                                               |
                                                               v
                                                  target service (e.g. api.meta.ai)
```

The machines and places involved:

- **Host A** is the remote machine that runs powbox, such as an always-on VPS. Tailscale runs on host A itself, never inside a container.
- **Host B** is a machine on your home network, joined to the same tailnet. It runs the forward proxy, and its traffic leaves through your residential connection. This guide assumes host B runs Linux (a small always-on box or a Linux VM is enough). Running the proxy natively on Windows or macOS is not covered.
- **The Tailscale admin console** is where the tailnet policy lives. It is a web page, not a machine, and only you can change it.

The guide uses these placeholders. Replace each with your own value, and never commit real addresses.

| Placeholder | Meaning | Where to find it |
|---|---|---|
| `100.x.y.z` | Host B's tailnet IPv4 address | `tailscale ip -4` on host B |
| `100.a.b.c` | Host A's tailnet IPv4 address | `tailscale ip -4` on host A |
| `8888` | The proxy port (tinyproxy's default) | Your choice |
| `proxy-host` | A name for host B inside the tailnet policy | Your choice |
| `tag:powbox-host` | The tag that identifies host A | Your choice |

Tailnet IP addresses are used everywhere instead of MagicDNS names. `.powbox-egress` accepts no hostnames, and a node keeps its tailnet IP for as long as it stays in the tailnet, including when it is tagged.

## Where each limit is enforced

Three separate limits stand between a container on host A and your home network. Only the first one runs inside the container.

| Limit | Enforced by | Stops | Can anything in the container undo it? |
|---|---|---|---|
| In-container firewall with the `.powbox-egress` rule | `init-firewall.sh` in the container | A container reaching any other tailnet, LAN or CGNAT address by mistake | Yes |
| Tailnet policy | Tailscale on each receiving device (host B for the proxy), using the policy from your admin console | Host A reaching anything on the tailnet except the proxy port | No |
| Proxy `Allow` and `Filter` | tinyproxy on host B | Any other tailnet peer using the proxy, and host A sending traffic anywhere other than your chosen destinations | No |

The in-container firewall guards against accidents. A mistyped address or a casual probe stays blocked. It is not a boundary against a process that holds root in the container. Such a process can flush the rules. How easily an agent can reach root in the container is a separate question (see the trust model in the README's [Egress exceptions](../README.md#egress-exceptions-powbox-egress) section), and nothing in this guide relies on the answer.

The tailnet policy and the proxy filter are the hard limits. Neither depends on anything that happens on host A:

- Tailscale enforces access rules on the device that receives the connection. Host B's Tailscale refuses any packet from host A that the policy does not grant, even if host A were completely compromised.
- tinyproxy runs on host B, so nothing on host A can change its client list or its destination filter.

Both hard limits apply to host A as a whole. The tailnet sees one device, so every process on host A shares the one grant: each powbox container, and the host's own services too. Grant host A only what you are content for all of them to use.

## Why a per-tool proxy, not an exit node

A Tailscale exit node would also send traffic out through your home connection, but it applies to the whole device. Every request from host A would leave from home: package downloads, agent API calls, the VPS's own services. A forward proxy is opt-in per tool and per command, so only the traffic you point at it leaves from home, and only to destinations its filter allows.

## Why Tailscale runs on the host, not in the container

Running `tailscaled` inside a powbox container would look simpler, but it costs three things:

- **The node key would sit where the agent can read it.** Tailscale keeps the device's identity in its state directory. Inside the container, anything with the agent's access could copy it and join your tailnet as that device from anywhere.
- **Userspace networking would bypass the firewall.** Without a TUN device, Tailscale offers its tailnet as a local SOCKS5 or HTTP proxy on loopback. The in-container firewall always allows loopback, so tailnet traffic would no longer pass the CGNAT block at all.
- **Every container would become a tailnet node.** Each one would need its own key and tag, and every recreated container would add a machine to your admin console.

On the host, the key stays outside every container, and container traffic crosses the in-container firewall first and then the tailnet policy.

## Stage 1: join the home machine to the tailnet

**Where:** host B.

If you have no tailnet yet, create one by signing in at the Tailscale website. Then install Tailscale and bring it up:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

`tailscale up` prints a login URL. Open it, sign in, and the machine joins your tailnet. Then note host B's address, which is `100.x.y.z` in the rest of this guide:

```bash
tailscale ip -4
```

Host B stays a device owned by your user, with no tag. The policy refers to it by a `hosts` alias instead, because tagging a device removes its user identity, and that is rarely wanted for a personal machine.

Tailscale node keys expire, by default after 180 days. To keep the proxy from dropping off the tailnet unattended, open host B's menu on the **Machines** page of the admin console and choose **Disable key expiry**.

**Check:** `tailscale status` on host B lists the machine, and the admin console's **Machines** page shows it as connected.

## Stage 2: write the tailnet policy

**Where:** the Tailscale admin console, **Access controls** page (the tailnet policy file editor).

A new tailnet's policy allows every device to reach every other device. Before host A joins, replace that with rules that keep your own devices working and give the tagged host one port on host B. Merge this into the existing file rather than pasting over it, and keep sections you already rely on, such as `ssh`:

```jsonc
{
  // Who may apply the tag. autogroup:admin is the tailnet's admins.
  "tagOwners": {
    "tag:powbox-host": ["autogroup:admin"],
  },

  // A name for host B, so grants and tests can refer to it.
  "hosts": {
    "proxy-host": "100.x.y.z",
  },

  "grants": [
    // Your own (user-owned) devices keep reaching everything, host A included.
    // Tagged devices are not members, so this grants host A nothing.
    {"src": ["autogroup:member"], "dst": ["*"], "ip": ["*"]},

    // Host A may open TCP connections to the proxy port on host B, and nothing else.
    {"src": ["tag:powbox-host"], "dst": ["proxy-host"], "ip": ["tcp:8888"]},
  ],

  // Assertions checked on every save.
  "tests": [
    {
      "src": "tag:powbox-host",
      "accept": ["proxy-host:8888"],
      "deny": ["proxy-host:22", "proxy-host:80", "proxy-host:9999"],
    },
  ],
}
```

Remove the allow-all rule while merging. In a grants-based file it is `{"src": ["*"], "dst": ["*"], "ip": ["*"]}`. In a file that still uses the older `acls` section, it is an `accept` rule from `*` to `*:*`. Either one would let host A reach every device. Grants and `acls` can coexist in one file, so an existing `acls` section can stay as long as no rule in it has a source that includes host A. That covers `tag:powbox-host` and `*`, and also `autogroup:tagged`, a CIDR such as `100.64.0.0/10`, and any `hosts` alias or group that resolves to host A.

The member grant is a starting point that keeps today's behaviour for your own devices. Narrow it if you already have a stricter policy.

**Check:** the console saves the file. It runs the `tests` block on every save and rejects a policy whose assertions fail, so a successful save proves that `tag:powbox-host` reaches `proxy-host:8888` and none of the denied ports. Add a `deny` entry for any other device or port you want the policy to guarantee.

## Stage 3: join the remote host with its tag

**Where:** host A.

Install Tailscale and join with the tag. The account you sign in with must be allowed to apply it: Stage 2 made `autogroup:admin` the tag's owner, and the tailnet's Owner, Admins and Network admins can apply any tag anyway:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-tags=tag:powbox-host
tailscale ip -4
```

The last command prints host A's address, which is `100.a.b.c` below. If host A is already on the tailnet as a user-owned device, re-running `tailscale up` with the extra flag may ask for `--force-reauth`. The CLI prints a copyable command that keeps your other flags. Alternatively, apply the tag on the admin console's **Machines** page with **Edit tags**. Either way, the device's tailnet IP stays the same. Key expiry differs between the two routes. A device that authenticates with the tag has key expiry disabled by default. A device tagged through **Edit tags** keeps its current expiry until it re-authenticates, so on that route also choose **Disable key expiry** in host A's menu, as in Stage 1, or host A drops off the tailnet when its key expires.

Do not pass `--exit-node` or `--accept-routes` on host A for this setup. Neither is needed, and both change what host A's traffic does outside the tailnet.

**Check:** prove the policy with two throwaway listeners on host B. If host B runs its own firewall, such as `ufw`, first allow TCP 8888 inbound on the `tailscale0` interface only; the proxy in Stage 4 needs that too. For this check, also allow TCP 9999 on `tailscale0` for a moment, so that only the tailnet policy can block it. Then start the listeners, one on the granted port and one on a port the policy denies. Both serve an empty temporary directory: `http.server` otherwise serves the directory it starts in, hidden files such as `.ssh/` included, to host A and to every device the member grant lets in. On host B, in one shell:

```bash
d="$(mktemp -d)"                                                  # empty, so no host files are served
python3 -m http.server 8888 --bind 100.x.y.z --directory "$d" &
python3 -m http.server 9999 --bind 100.x.y.z --directory "$d" &
```

On host A:

```bash
curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://100.x.y.z:8888/   # prints 200
curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://100.x.y.z:9999/   # fails
```

The second request must fail, by timeout or refusal. From one of your own devices, the same request to port 9999 succeeds, which shows that the policy and not something else is blocking host A. Afterwards, in the same shell on host B, stop both listeners (`kill %1 %2`) so port 8888 is free for the proxy, remove the temporary directory (`rmdir "$d"`), and remove any temporary firewall rule for 9999.

## Stage 4: run tinyproxy on the home machine

**Where:** host B.

Install tinyproxy from the distribution. On Debian and Ubuntu:

```bash
sudo apt-get install tinyproxy
```

The configuration below keeps tinyproxy's default regular-expression filter type, so it does not depend on the `FilterType` directive that newer releases add.

Edit `/etc/tinyproxy/tinyproxy.conf`. Keep the packaged `User`, `Group`, `LogFile` and `PidFile` lines, delete the packaged `Allow 127.0.0.1` and `Allow ::1` lines, and make sure these lines are present. `ConnectPort 443` must be the only uncommented `ConnectPort` line: some packaged configurations also enable `ConnectPort 563`, and with no `ConnectPort` line at all, tinyproxy tunnels to any port.

```text
Port 8888

# Listen on the tailnet address only, never on the LAN or the internet.
Listen 100.x.y.z

# Serve host A only. Once any Allow line exists, every other client is refused.
Allow 100.a.b.c

# Forward only to the destinations in the filter file; deny everything else.
Filter "/etc/tinyproxy/filter"
FilterDefaultDeny Yes

# Tunnel HTTPS (CONNECT) to port 443 only.
ConnectPort 443
```

Then create `/etc/tinyproxy/filter` with one rule per line. The rules are POSIX basic regular expressions (BRE), tinyproxy's default filter type in every release this guide covers, matched case-insensitively against the destination host name. In BRE, `?`, `+`, `|` and unescaped parentheses are literal characters, so write one rule per host rather than alternations. That holds for HTTPS tunnels too, as long as `FilterURLs` stays off. Anchor each rule at both ends: an unanchored `meta.ai` would also match `meta.ai.example.net`. For Muse, the worked example, the model API host is enough:

```text
# One anchored host per line. Everything not listed is refused.
^api\.meta\.ai$
```

A request for a host given as a bare IP address is matched against that address, so with this filter no IP-addressed destination is reachable through the proxy. That includes the devices on your home LAN.

`Listen` binds only an address that already exists, so tinyproxy fails to start if it comes up before Tailscale has assigned the address. Debian's unit does not restart on failure, so add a drop-in with `sudo systemctl edit tinyproxy`:

```ini
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Restart=on-failure
RestartSec=5
```

Then enable the service and restart it, so it picks up both the new configuration and the drop-in:

```bash
sudo systemctl enable tinyproxy
sudo systemctl restart tinyproxy
```

**Check:** on host B, `sudo ss -ltnp | grep 8888` shows tinyproxy listening on `100.x.y.z:8888` and on no other address. Then, on host A:

```bash
# An allowed destination: prints the target's own HTTP status (any number), not a curl error.
curl -sS -o /dev/null -w '%{http_code}\n' -x http://100.x.y.z:8888 https://api.meta.ai/

# A destination outside the filter: curl reports "CONNECT tunnel failed, response 403"
# (older curl releases word it differently, but name the 403).
curl -sS -o /dev/null -x http://100.x.y.z:8888 https://example.com/
```

On host B, `/var/log/tinyproxy/tinyproxy.log` shows `Proxying refused on filtered domain "example.com"` for the second request. To check `Allow`, run the first request on host B itself: it also fails with a 403, and the log shows `Unauthorized connection from "100.x.y.z"`, because host B is not host A.

tinyproxy reads the filter file only when it starts or reloads, so after every later edit of `/etc/tinyproxy/filter` run `sudo systemctl restart tinyproxy` on host B. A restart works whatever reload signal the packaged unit uses.

To confirm that the traffic leaves from home, add an IP-echo service of your choice to the filter for a moment, restart tinyproxy, request the service through the proxy from host A, and compare the answer with your home connection's public address. Remove the rule and restart tinyproxy again afterwards.

## Stage 5: open the port in powbox

**Where:** host A, in the powbox checkout.

Add one line for the proxy to `.powbox-egress`, beside `.powbox-layers`. The README's [Egress exceptions](../README.md#egress-exceptions-powbox-egress) section and `.powbox-egress.example` document the format:

```bash
cp .powbox-egress.example .powbox-egress     # first time only
echo 'tcp 100.x.y.z 8888' >> .powbox-egress
```

With the PowerShell launcher, use the PowerShell forms instead. `echo … >>` in Windows PowerShell 5.1 writes UTF-16, which the launcher refuses with a `holds a NUL byte` error:

```powershell
Copy-Item .powbox-egress.example .powbox-egress     # first time only
Add-Content .powbox-egress 'tcp 100.x.y.z 8888'
```

A text editor works too, as long as it saves the file as UTF-8.

Use the IPv4 address. Powbox containers normally have no IPv6 route out, so the tailnet IPv6 address would not help.

The rule applies only to containers created after the change. A stopped container whose rules differ is recreated at its next launch. The launcher refuses to attach to a running container whose rules differ, so stop it first. The rule also needs a base image built with egress-exception support. An older base ignores it, and the proxy stays blocked.

**Check:** launch a container (for example with `cc` or `cx`). The firewall's start banner lists the exception:

```text
Egress exceptions (from .powbox-egress):
  allow tcp 100.x.y.z/32 port 8888
```

## Stage 6: verify from inside a container

**Where:** inside a powbox container on host A.

Each of these checks exercises a different limit:

```bash
# The exception is in place.
echo "$POWBOX_EGRESS_ALLOW"                # tcp,100.x.y.z/32,8888

# The proxy port answers (in-container firewall and tailnet policy both allow it).
nc -vz -w 5 100.x.y.z 8888                 # succeeds

# Another port on the same host stays blocked (in-container firewall).
nc -vz -w 5 100.x.y.z 22                   # times out

# The proxy forwards an allowed destination.
curl -sS -o /dev/null -w '%{http_code}\n' -x http://100.x.y.z:8888 https://api.meta.ai/

# The proxy refuses a destination outside its filter (proxy filter).
curl -sS -o /dev/null -x http://100.x.y.z:8888 https://example.com/   # CONNECT tunnel failed, response 403
```

The blocked port in the container fails before its traffic leaves, so it shows only the first limit. Stage 3's check showed the tailnet policy blocking the same kind of request from host A itself, where no in-container firewall is involved. That is the limit that still holds if the in-container rules are ever flushed.

If the port does not answer from the container but does from host A, see [Native Linux: the host reaches the proxy but containers do not](#native-linux-the-host-reaches-the-proxy-but-containers-do-not).

## Stage 7: point a tool at the proxy

**Where:** inside a powbox container on host A.

### Any tool, for one command

Most HTTP clients read the conventional proxy variables. Set them for one command only:

```bash
HTTPS_PROXY=http://100.x.y.z:8888 curl -sS https://api.meta.ai/ -o /dev/null -w '%{http_code}\n'
```

Do not export a proxy variable for the whole container or put it in a shell profile. Every tool would then send its traffic to the proxy, and the proxy would refuse everything outside its filter, so package installs and agent API calls would fail.

### Muse

Muse has its own persisted proxy setting, `endpoint_transport.proxy`, which takes an `http://` or `https://` proxy URL. Muse refuses a `socks5://` URL. The setting lives in Muse's settings file, `~/.config/muse/settings.json`, which in powbox sits on the shared `muse-config` volume. A change therefore applies to every container on host A at once. [Muse Code operational notes](muse-code-notes.md) describes the file and explains why Muse needs a residential connection at all.

The setting's name and form were confirmed against Muse 1.4.24 itself, by read-only means, because Muse's public documentation does not describe it:

- `muse config validate --plane defaults --file <file>` checks an enterprise defaults-plane document, `{"schema_version": 1, "settings": {…}}`, not the flat `settings.json`. It accepts one whose `settings` set `endpoint_transport.proxy` to an `http://` or `https://` URL, and reports that member as `user_overridable=true`, which is what ties it to the user's own setting. It rejects a misspelled member name, a `socks5://` URL and a value that is not a URL.
- `muse exec -c 'endpoint_transport.proxy="…"'` accepts the key as a one-run override, while a misspelled key is refused with `unknown key: no such setting`. With the override pointing at a closed local port, the model request to `https://api.meta.ai/v1/responses` failed with a transport error, so the setting does route Muse's model traffic.

Try it for one run first. The `-c` value is JSON, hence the inner quotes. Run it from a checkout or a scratch directory, not from under `~/.config/muse`:

```bash
printf 'Reply with the single word: hello\n' > prompt.md
muse exec -c 'endpoint_transport.proxy="http://100.x.y.z:8888"' \
  --prompt-file prompt.md --disable-write --no-foreign-personal-context
```

A reply of `hello` means models are served through the proxy. Then persist the setting by adding a top-level `endpoint_transport` member to the settings file. With `jq`, from any container on host A, while no Muse run is in progress:

```bash
f=~/.config/muse/settings.json
jq '.endpoint_transport.proxy = "http://100.x.y.z:8888"' "$f" > "$f.new" && chmod 600 "$f.new" && mv "$f.new" "$f"
```

If the file does not exist yet, create it with `{"schema_version": 1, "endpoint_transport": {"proxy": "http://100.x.y.z:8888"}}`. Muse refuses to start on a settings file without `schema_version`.

**Check:** run the same probe without `-c`. On host B, the tinyproxy log shows a `Connect (file descriptor …): 100.a.b.c` line followed by `Request (file descriptor …): CONNECT api.meta.ai:443 HTTP/1.1`. If it also shows `Proxying refused on filtered domain` for another host that Muse needs, decide whether that host should leave from home too, and add it to the filter deliberately.

Two limits of what was confirmed:

- The setting belongs to Muse's model-endpoint transport. Whether other Muse requests, such as `muse login` or `muse usage`, also use it was not established. The probe above is what shows whether reviews work.
- With the setting persisted, Muse fails in any container on host A that cannot reach the proxy: one created before the `.powbox-egress` rule, one on an older base image, or any container while host B is offline. `peer-review-run` then reports Muse as unavailable. Remove the setting to go back to direct connections.

## Native Linux: the host reaches the proxy but containers do not

On a native-Linux host, a container's packets are not sent by the host itself. They are forwarded from the Docker bridge to the `tailscale0` interface and masqueraded on the way out, so that they carry host A's tailnet address, `100.a.b.c`. Docker's default rules masquerade everything that leaves a bridge network through another interface, `tailscale0` included, so this usually works without any change.

When `curl -x` to the proxy works on host A but `nc -vz 100.x.y.z 8888` fails from a container that lists the exception, check these on host A:

- **Forwarding is on:** `sysctl net.ipv4.ip_forward` prints `1`.
- **Container traffic is masqueraded:** `sudo iptables -t nat -S POSTROUTING` shows a `MASQUERADE` rule for each Docker network's subnet that is not limited to a single outgoing interface. On a host whose Docker uses the nftables backend, look in `sudo nft list ruleset` instead. Docker's `"ip-masq": false` setting, or a host firewall that rewrites Docker's rules, removes it.
- **The forward path is open:** a host firewall such as `ufw` or `firewalld` may drop forwarded traffic towards `tailscale0` even though host-originated traffic passes. `sudo iptables -S FORWARD` shows the rules in the way.
- **The source address is right:** `sudo tcpdump -ni tailscale0 tcp port 8888` on host A, while a container retries, should show `100.a.b.c` as the source. A Docker subnet address such as `172.17.0.2` there means the masquerade is missing, and host B's Tailscale drops the packets because they do not come from a tailnet address.

## Host VPNs

A full-tunnel VPN on the host needs no powbox change. Container traffic is NAT'd by the host and follows the host's routes, so it leaves through the VPN like the host's own traffic. Public destinations behind the VPN are already allowed by the default policy.

The caveats:

- **Private and CGNAT resources still need a rule.** A database or intranet service that the VPN reaches at a `10.x`, `172.16.x`, `192.168.x` or `100.64.x` address is blocked by the in-container firewall like any other private address. Add a `.powbox-egress` line for it, exactly as for the proxy above.
- **Per-app split tunnelling may not cover containers.** A VPN client that tunnels only chosen applications decides by the sending process. Forwarded container traffic may not count as the chosen app, so it may bypass the tunnel. Check the public address a container sees before relying on it.
- **A kill switch can drop container traffic.** Some VPN clients block all traffic outside the tunnel, and they may treat forwarded container traffic as outside it even while the tunnel is up. Containers then lose network access entirely while the host keeps working.

## Docker Desktop on Windows (WSL2)

The guide needs no powbox change on Docker Desktop either: the same `.powbox-egress` line in the checkout works with the PowerShell launcher. Add it with Stage 5's PowerShell form, so the file stays UTF-8.

The network path is different, though. Docker Desktop relays container connections through its own processes, and they leave through the Windows host's network stack. So the Windows Tailscale client is what joins the tailnet, the device to tag is the Windows machine, and the proxy's `Allow` line takes that machine's tailnet address. Tagging a personal Windows machine removes its user identity in the tailnet, so weigh that before using one as host A.

Check that the Windows Tailscale client's routes apply to that traffic rather than assuming it. In PowerShell on Windows:

```powershell
tailscale ip -4
Find-NetRoute -RemoteIPAddress 100.x.y.z     # the route should use the Tailscale interface
Test-NetConnection 100.x.y.z -Port 8888      # TcpTestSucceeded : True
```

Then run Stage 6's checks inside a container. If Windows reaches the port but the container does not, the gap lies in Docker Desktop's networking rather than in powbox. Look at Docker Desktop's network settings and any VPN or security software on Windows that filters its traffic.

## Undoing it

Each limit can be removed on its own, in any order:

- **Powbox:** delete the line from `.powbox-egress`, stop running containers and relaunch them. Containers created afterwards carry the default policy again.
- **Muse:** remove the `endpoint_transport` member from `~/.config/muse/settings.json`.
- **Tailnet:** remove the `tag:powbox-host` grant, or remove host A from the tailnet on the **Machines** page.
- **Proxy:** `sudo systemctl disable --now tinyproxy` on host B.
