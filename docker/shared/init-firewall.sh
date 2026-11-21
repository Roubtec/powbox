#!/usr/bin/env bash
# Block local/private network access; allow all public internet; then open the
# egress exceptions the user listed in the powbox checkout's .powbox-egress.
# Run at container start via the shared entrypoint wrappers.
#
# The exceptions come only from the container's creation-time environment
# (POWBOX_EGRESS_ALLOW in PID 1's /proc/1/environ), never from this script's
# arguments or environment, so an agent re-running `sudo init-firewall.sh`
# re-applies the launch-time policy rather than one it passes in. This guards
# against a mistaken or casual widening, not a determined agent.
#
# Fail closed: the default policy is applied in full before any exception, and
# each exception is inserted above the DROP rules on its own, so a malformed
# value, a missing rule library or a failing iptables call can only leave a
# destination blocked, never remove a DROP.
#
# scripts/test-egress-allow-list.sh sources this file (main runs only when it is
# executed) and drives it against stubbed iptables/ip6tables.
set -euo pipefail

POWBOX_FW_ENVIRON=/proc/1/environ
POWBOX_FW_STATUS=/proc/1/status
# An absolute path, not one relative to how this script was invoked: root
# sources it, so it must be the image's copy and never one beside a path the
# caller chose.
POWBOX_FW_LIB=/usr/local/bin/egress-rules.sh

fw_warn() {
	echo "init-firewall: $*" >&2
}

fw_apply_default() {
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
	# CGNAT (100.64.0.0/10): not RFC-1918, but it is the range Tailscale assigns,
	# so on a tailnet-joined host an agent could otherwise reach every other
	# device on the user's tailnet. (Tailscale's IPv6 ULA fd7a:115c:a1e0::/48 is
	# already covered by the fc00::/7 drop below.)
	iptables -A OUTPUT -d 100.64.0.0/10 -j DROP

	# Allow everything else (public internet)
	iptables -A OUTPUT -j ACCEPT

	# IPv6: allow loopback and established traffic, block local/private ranges, allow the rest
	ip6tables -F OUTPUT 2>/dev/null || true
	ip6tables -A OUTPUT -o lo -j ACCEPT
	ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	ip6tables -A OUTPUT -d fc00::/7 -j DROP
	ip6tables -A OUTPUT -d fe80::/10 -j DROP
	ip6tables -A OUTPUT -j ACCEPT
}

# Print PID 1's environ (NUL-separated). PID 1 is docker-init running as node,
# and the kernel lets another uid read /proc/<pid>/environ only with
# CAP_SYS_PTRACE, which the container does not hold; so read it under PID 1's
# own uid and gid instead (the kernel checks both, and setpriv needs root's
# CAP_SETUID/CAP_SETGID to switch to them).
fw_pid1_environ() {
	local uid gid
	uid="$(awk '$1 == "Uid:" { if ($2 == $3 && $3 == $4) print $2; exit }' "$POWBOX_FW_STATUS" 2>/dev/null)" || return 1
	gid="$(awk '$1 == "Gid:" { if ($2 == $3 && $3 == $4) print $2; exit }' "$POWBOX_FW_STATUS" 2>/dev/null)" || return 1
	[[ "$uid" =~ ^[0-9]+$ ]] && [[ "$gid" =~ ^[0-9]+$ ]] || return 1
	setpriv --reuid="$uid" --regid="$gid" --clear-groups -- cat "$POWBOX_FW_ENVIRON"
}

# Print the first POWBOX_EGRESS_ALLOW value in a NUL-separated environment on
# stdin, the one getenv would return. The rest of stdin is still drained: a
# writer left blocked on a full pipe would die of SIGPIPE, and pipefail would
# then discard a value that was read correctly.
fw_extract_allow() {
	local entry
	while IFS= read -r -d '' entry || [ -n "$entry" ]; do
		case "$entry" in
		POWBOX_EGRESS_ALLOW=*)
			printf '%s' "${entry#POWBOX_EGRESS_ALLOW=}"
			cat >/dev/null
			return 0
			;;
		esac
	done
	return 0
}

# Print the valid, deduplicated launch-time exceptions, one "<4|6> <rule>" per
# line. fw_main runs this in a subshell, so even an unexpected abort in here
# only means no exceptions; it can never keep the default policy from loading.
fw_load_exceptions() {
	local raw entry proto dest port
	local -a entries=() seen=()
	# pipefail (set above) makes a failed read fail the substitution.
	if ! raw="$(fw_pid1_environ | fw_extract_allow)"; then
		fw_warn "cannot read the launch-time environment from ${POWBOX_FW_ENVIRON}; applying no egress exceptions"
		return 0
	fi
	[ -n "$raw" ] || return 0
	case "$raw" in
	*$'\n'* | *$'\r'*)
		fw_warn "POWBOX_EGRESS_ALLOW holds a line break, which the launcher never writes; applying no egress exceptions"
		return 0
		;;
	esac
	# shellcheck source=docker/shared/egress-rules.sh
	if ! [ -r "$POWBOX_FW_LIB" ] || ! . "$POWBOX_FW_LIB"; then
		fw_warn "cannot load ${POWBOX_FW_LIB}; applying no egress exceptions"
		return 0
	fi
	IFS=';' read -r -a entries <<<"$raw"
	for entry in "${entries[@]}"; do
		[ -n "$entry" ] || continue
		# Count the commas rather than reading a fourth field, which read leaves
		# empty for a trailing comma. An empty field fails validation below.
		if [[ "$entry" != *,*,* ]] || [[ "$entry" == *,*,*,* ]]; then
			fw_warn "skipping egress exception '${entry}': expected proto,destination,port"
			continue
		fi
		IFS=',' read -r proto dest port <<<"$entry"
		if ! powbox_egress_validate "$proto" "$dest" "$port"; then
			fw_warn "skipping egress exception '${entry}': ${POWBOX_EGRESS_ERROR}"
			continue
		fi
		case " ${seen[*]} " in
		*" ${POWBOX_EGRESS_RULE} "*) continue ;;
		esac
		seen+=("$POWBOX_EGRESS_RULE")
		printf '%s %s\n' "$POWBOX_EGRESS_FAMILY" "$POWBOX_EGRESS_RULE"
	done
}

FW_APPLIED=()

# fw_insert_exceptions <iptables|ip6tables> <rule>...: insert each rule as an
# ACCEPT just after the loopback and ESTABLISHED rules, above the DROPs.
fw_insert_exceptions() {
	local tool="$1" rule proto dest port pos=3
	local -a match=()
	shift
	for rule in "$@"; do
		IFS=',' read -r proto dest port <<<"$rule"
		match=(-p "$proto" -d "$dest")
		[ "$port" = any ] || match+=(--dport "$port")
		if "$tool" -I OUTPUT "$pos" "${match[@]}" -j ACCEPT; then
			pos=$((pos + 1))
			FW_APPLIED+=("$proto $dest port $port")
		else
			fw_warn "could not apply egress exception '${rule}'; it stays blocked"
		fi
	done
}

fw_main() {
	if [ "$#" -gt 0 ]; then
		fw_warn "arguments are ignored; egress exceptions come only from the launch-time environment"
	fi
	local loaded family rule
	local -a v4=() v6=()
	if ! loaded="$(fw_load_exceptions)"; then
		fw_warn "could not load the egress exceptions; applying none"
		loaded=""
	fi
	while read -r family rule; do
		case "$family" in
		4) v4+=("$rule") ;;
		6) v6+=("$rule") ;;
		esac
	done <<<"$loaded"
	fw_apply_default
	FW_APPLIED=()
	fw_insert_exceptions iptables "${v4[@]}"
	fw_insert_exceptions ip6tables "${v6[@]}"

	echo "Firewall active: local networks blocked, public internet allowed."
	if [ "${#FW_APPLIED[@]}" -gt 0 ]; then
		echo "Egress exceptions (from .powbox-egress):"
		printf '  allow %s\n' "${FW_APPLIED[@]}"
	fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	fw_main "$@"
fi
