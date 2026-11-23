#!/usr/bin/env bash
# shellcheck disable=SC2034 # The POWBOX_EGRESS_* outputs are read by the sourcing scripts.
# Egress-exception rule grammar, shared by the host launcher
# (scripts/launch-agent.sh, which parses .powbox-egress) and the in-container
# firewall (init-firewall.sh, which runs as root on the value the launcher
# passed). Sourcing both from this one file is what keeps them agreeing on what
# is valid; launch-agent.ps1 is a separate implementation that
# scripts/test-egress-allow-list.sh holds to the same fixtures.
#
# Definitions only: this file is sourced on the host and by root in the
# container, so it must never run a command at top level.
#
# A rule is "<proto> <destination> <port>": tcp or udp; an IPv4 or IPv6 address
# or CIDR (a bare address is one host); a port 1-65535 or `any`. Its canonical
# form is "proto,address/prefix,port", lowercased, with a bare address given its
# full-length prefix.

# The ranges the default policy drops. init-firewall.sh spells its DROP rules
# out literally so the default policy never depends on this file loading;
# scripts/test-egress-allow-list.sh fails if the two lists differ.
POWBOX_EGRESS_BLOCKED_V4=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10)
POWBOX_EGRESS_BLOCKED_V6=(fc00::/7 fe80::/10)

# Dotted quad, no leading zeros (some parsers read them as octal) -> _PE_V4.
_powbox_egress_v4() {
	local IFS=. octet value=0
	local -a octets=()
	[[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
	read -r -a octets <<<"$1"
	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
		((10#$octet <= 255)) || return 1
		value=$(((value << 8) | 10#$octet))
	done
	_PE_V4="$value"
}

# Colon-separated groups (lowercase hex) -> _PE_V6, eight 16-bit integers.
# One `::` may stand for one or more zero groups. Embedded dotted-quad and zone
# (`%eth0`) forms are not accepted.
_powbox_egress_v6_groups() {
	local IFS=: group
	local -a parts=()
	[ -n "$1" ] || return 0
	case "$1" in
	:* | *:) return 1 ;;
	esac
	read -r -a parts <<<"$1"
	for group in "${parts[@]}"; do
		[[ "$group" =~ ^[0-9a-f]{1,4}$ ]] || return 1
		_PE_GROUPS+=("$((16#$group))")
	done
}

_powbox_egress_v6() {
	local addr="$1" head tail i fill
	local -a head_groups=()
	_PE_V6=()
	[[ "$addr" =~ ^[0-9a-f:]{2,39}$ ]] || return 1
	if [[ "$addr" == *::* ]]; then
		head="${addr%%::*}"
		tail="${addr#*::}"
		[[ "$tail" != *::* ]] || return 1
		_PE_GROUPS=()
		_powbox_egress_v6_groups "$head" || return 1
		head_groups=("${_PE_GROUPS[@]}")
		_PE_GROUPS=()
		_powbox_egress_v6_groups "$tail" || return 1
		fill=$((8 - ${#head_groups[@]} - ${#_PE_GROUPS[@]}))
		((fill >= 1)) || return 1
		_PE_V6=("${head_groups[@]}")
		for ((i = 0; i < fill; i++)); do
			_PE_V6+=(0)
		done
		_PE_V6+=("${_PE_GROUPS[@]}")
	else
		_PE_GROUPS=()
		_powbox_egress_v6_groups "$addr" || return 1
		[ "${#_PE_GROUPS[@]}" -eq 8 ] || return 1
		_PE_V6=("${_PE_GROUPS[@]}")
	fi
}

# powbox_egress_validate <proto> <destination> <port>
# Success: POWBOX_EGRESS_RULE holds the canonical rule and POWBOX_EGRESS_FAMILY
# 4 or 6. Failure: returns 1 with POWBOX_EGRESS_ERROR saying why.
powbox_egress_validate() {
	local proto port dest addr prefix family max i start bits
	# The trailing "." keeps $(...) from stripping a trailing newline, which
	# would let "tcp<newline>" pass as "tcp" where launch-agent.ps1 rejects it.
	proto="$(printf '%s.' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
	dest="$(printf '%s.' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
	port="$(printf '%s.' "$3" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
	proto="${proto%.}" dest="${dest%.}" port="${port%.}"
	POWBOX_EGRESS_RULE=""
	POWBOX_EGRESS_FAMILY=""
	POWBOX_EGRESS_ERROR=""

	case "$proto" in
	tcp | udp) ;;
	*)
		POWBOX_EGRESS_ERROR="protocol '$1' is not tcp or udp"
		return 1
		;;
	esac

	if [ "$port" != any ]; then
		if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || ((10#$port > 65535)); then
			POWBOX_EGRESS_ERROR="port '$3' is not a number from 1 to 65535 or 'any'"
			return 1
		fi
	fi

	addr="${dest%%/*}"
	prefix=""
	if [[ "$dest" == */* ]]; then
		prefix="${dest#*/}"
		if ! [[ "$prefix" =~ ^(0|[1-9][0-9]{0,2})$ ]]; then
			POWBOX_EGRESS_ERROR="destination '$2' has an invalid prefix length"
			return 1
		fi
	fi
	if [[ "$addr" == *:* ]]; then
		family=6
		max=128
		if ! _powbox_egress_v6 "$addr"; then
			POWBOX_EGRESS_ERROR="destination '$2' is not an IPv6 address or CIDR"
			return 1
		fi
	else
		family=4
		max=32
		if ! _powbox_egress_v4 "$addr"; then
			POWBOX_EGRESS_ERROR="destination '$2' is not an IPv4 address or CIDR"
			return 1
		fi
	fi
	[ -n "$prefix" ] || prefix="$max"
	if ((10#$prefix == 0)); then
		POWBOX_EGRESS_ERROR="destination '$2' is a /0, which would open every address; it is not allowed"
		return 1
	fi
	if ((10#$prefix > max)); then
		POWBOX_EGRESS_ERROR="destination '$2' has a prefix longer than /${max}"
		return 1
	fi
	prefix=$((10#$prefix))

	# A set host bit would make iptables widen the rule to the whole network
	# silently, which is rarely what was meant: refuse it rather than guess.
	if [ "$family" = 4 ]; then
		if (((_PE_V4 & ((1 << (32 - prefix)) - 1)) != 0)); then
			POWBOX_EGRESS_ERROR="destination '$2' has host bits set beyond /${prefix}"
			return 1
		fi
	else
		for ((i = 0; i < 8; i++)); do
			start=$((i * 16))
			if ((start >= prefix)); then
				bits=16
			elif ((start + 16 > prefix)); then
				bits=$((start + 16 - prefix))
			else
				continue
			fi
			if (((_PE_V6[i] & ((1 << bits) - 1)) != 0)); then
				POWBOX_EGRESS_ERROR="destination '$2' has host bits set beyond /${prefix}"
				return 1
			fi
		done
	fi

	POWBOX_EGRESS_RULE="${proto},${addr}/${prefix},${port}"
	POWBOX_EGRESS_FAMILY="$family"
}

# _powbox_egress_overlap <prefix> <blocked-cidr>: whether the destination just
# parsed into _PE_V4/_PE_V6 with <prefix> shares an address with the range.
_powbox_egress_overlap() {
	local prefix="$1" range="$2" rprefix m i bits saved_v4
	local -a mine=() theirs=()
	rprefix="${range#*/}"
	m=$((prefix < rprefix ? prefix : rprefix))
	if [ "$POWBOX_EGRESS_FAMILY" = 4 ]; then
		saved_v4="$_PE_V4"
		_powbox_egress_v4 "${range%/*}" || return 1
		theirs=("$_PE_V4")
		_PE_V4="$saved_v4"
		if (((saved_v4 >> (32 - m)) == (theirs[0] >> (32 - m)))); then
			return 0
		fi
		return 1
	fi
	mine=("${_PE_V6[@]}")
	_powbox_egress_v6 "${range%/*}" || return 1
	theirs=("${_PE_V6[@]}")
	_PE_V6=("${mine[@]}")
	for ((i = 0; i < 8; i++)); do
		bits=$((m - i * 16))
		if ((bits <= 0)); then
			break
		fi
		if ((bits > 16)); then
			bits=16
		fi
		if (((mine[i] >> (16 - bits)) != (theirs[i] >> (16 - bits)))); then
			return 1
		fi
	done
	return 0
}

# powbox_egress_classify <canonical-rule>: POWBOX_EGRESS_NOTE becomes empty for
# a rule that opens part of a blocked range, `outside` for one that touches no
# blocked range (the default already allows it, so the rule does nothing), or
# `broad <range>` for one covering at least half of a blocked range.
powbox_egress_classify() {
	local rule="$1" dest prefix range overlapped=false
	local -a ranges=()
	POWBOX_EGRESS_NOTE=""
	dest="${rule#*,}"
	dest="${dest%,*}"
	prefix="${dest#*/}"
	powbox_egress_validate "${rule%%,*}" "$dest" "${rule##*,}" || return 1
	if [ "$POWBOX_EGRESS_FAMILY" = 4 ]; then
		ranges=("${POWBOX_EGRESS_BLOCKED_V4[@]}")
	else
		ranges=("${POWBOX_EGRESS_BLOCKED_V6[@]}")
	fi
	for range in "${ranges[@]}"; do
		if _powbox_egress_overlap "$prefix" "$range"; then
			overlapped=true
			if ((prefix <= ${range#*/} + 1)); then
				POWBOX_EGRESS_NOTE="broad ${range}"
				return 0
			fi
		fi
	done
	$overlapped || POWBOX_EGRESS_NOTE="outside"
	return 0
}
