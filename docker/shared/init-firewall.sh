#!/usr/bin/env bash
# Block local/private network access; allow all public internet.
# Run at container start via the shared entrypoint wrappers.
set -euo pipefail

# Flush existing rules
iptables -F OUTPUT 2>/dev/null || true

# Allow loopback (localhost — also covers Docker's embedded DNS resolver)
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Block private/local network ranges
iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
iptables -A OUTPUT -d 169.254.0.0/16 -j DROP

# Allow everything else (public internet)
iptables -A OUTPUT -j ACCEPT

# IPv6: allow loopback and established traffic, block local/private ranges, allow the rest
ip6tables -F OUTPUT 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -d fc00::/7 -j DROP
ip6tables -A OUTPUT -d fe80::/10 -j DROP
ip6tables -A OUTPUT -j ACCEPT

echo "Firewall active: local networks blocked, public internet allowed."
