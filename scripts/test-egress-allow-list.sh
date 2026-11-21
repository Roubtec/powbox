#!/usr/bin/env bash
# Hermetic tests for the egress allow-list (.powbox-egress):
#
# - the rule grammar in docker/shared/egress-rules.sh (shared by the bash
#   launcher and the in-container firewall) and its PowerShell twin in
#   scripts/launch-agent.ps1, held to one fixture table: the same verdict,
#   canonical rule, error and warning class for every case;
# - each launcher's .powbox-egress parsing, normalization and hash, read from a
#   copy of the launcher in a fixture checkout (POWBOX_PRINT_EGRESS=1);
# - each launcher's create and reuse decisions, driven end to end against a fake
#   `docker` on PATH;
# - docker/shared/init-firewall.sh, sourced and executed against stub iptables
#   and ip6tables that log every call, which the suite replays into the final
#   OUTPUT chains, so it sees the rule set the firewall would apply, order
#   included, without NET_ADMIN.
#
# Without pwsh the PowerShell halves report an honest skip.
# shellcheck disable=SC2030,SC2031 # PATH is only ever changed inside subshells.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB="${ROOT_DIR}/docker/shared/egress-rules.sh"
FW="${ROOT_DIR}/docker/shared/init-firewall.sh"
LAUNCH_SH="${ROOT_DIR}/scripts/launch-agent.sh"
LAUNCH_PS="${ROOT_DIR}/scripts/launch-agent.ps1"

pass=0
fail=0
skip=0
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		printf '       %s\n' "${@:2}"
	fi
}

skipped() {
	skip=$((skip + 1))
	printf '  skip %s\n' "$1"
}

assert_eq() {
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		ko "$1" "expected: $3" "actual:   $2"
	fi
}

assert_contains() {
	if printf '%s' "$2" | grep -qF -- "$3"; then
		ok "$1"
	else
		ko "$1" "missing: $3" "in:      $2"
	fi
}

assert_not_contains() {
	if printf '%s' "$2" | grep -qF -- "$3"; then
		ko "$1" "unexpected: $3" "in:         $2"
	else
		ok "$1"
	fi
}

HAVE_PWSH=false
if command -v pwsh >/dev/null 2>&1; then
	HAVE_PWSH=true
fi

# PowerShell error records are colored and wrapped at the console width; strip
# both so a message can be matched as one line.
norm() {
	sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr '\r\n' '  ' | sed -e 's/ *| */ /g' -e 's/  */ /g'
}

sha256_of() {
	printf '%s' "$1" | sha256sum | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# The shared fixture table: want|proto|destination|port|canonical or error
# fragment|warning class ("" / outside / broad <range>).
# ---------------------------------------------------------------------------
FIXTURES="$WORK_ROOT/fixtures.txt"
cat >"$FIXTURES" <<'EOF'
ok|tcp|100.64.1.2|3128|tcp,100.64.1.2/32,3128|
ok|TCP|100.64.1.2/32|ANY|tcp,100.64.1.2/32,any|
ok|udp|192.168.1.1|53|udp,192.168.1.1/32,53|
ok|tcp|10.20.0.0/16|5432|tcp,10.20.0.0/16,5432|
ok|tcp|172.16.5.4|65535|tcp,172.16.5.4/32,65535|
ok|tcp|169.254.169.254|80|tcp,169.254.169.254/32,80|
ok|tcp|10.0.0.0/8|any|tcp,10.0.0.0/8,any|broad 10.0.0.0/8
ok|tcp|10.0.0.0/9|22|tcp,10.0.0.0/9,22|broad 10.0.0.0/8
ok|tcp|10.0.0.0/10|22|tcp,10.0.0.0/10,22|
ok|tcp|100.64.0.0/11|1|tcp,100.64.0.0/11,1|broad 100.64.0.0/10
ok|tcp|96.0.0.0/4|443|tcp,96.0.0.0/4,443|broad 100.64.0.0/10
ok|tcp|8.8.8.8|53|tcp,8.8.8.8/32,53|outside
ok|tcp|127.0.0.1|80|tcp,127.0.0.1/32,80|outside
ok|tcp|100.128.0.1|1|tcp,100.128.0.1/32,1|outside
ok|udp|FD7A:115C:A1E0::1|53|udp,fd7a:115c:a1e0::1/128,53|
ok|tcp|fd7a:115c:a1e0::/48|any|tcp,fd7a:115c:a1e0::/48,any|
ok|tcp|fd7a:8000::/17|22|tcp,fd7a:8000::/17,22|
ok|tcp|fe80::1|22|tcp,fe80::1/128,22|
ok|tcp|fc00::/8|22|tcp,fc00::/8,22|broad fc00::/7
ok|tcp|fe80::/11|22|tcp,fe80::/11,22|broad fe80::/10
ok|tcp|fe80::/12|22|tcp,fe80::/12,22|
ok|tcp|8000::/1|1|tcp,8000::/1,1|broad fc00::/7
ok|tcp|2001:db8::1|443|tcp,2001:db8::1/128,443|outside
ok|tcp|::1|80|tcp,::1/128,80|outside
ok|tcp|::|1|tcp,::/128,1|outside
ok|tcp|1:2:3:4:5:6:7:8|1|tcp,1:2:3:4:5:6:7:8/128,1|outside
ok|tcp|1:2:3:4:5:6:7::|1|tcp,1:2:3:4:5:6:7::/128,1|outside
ok|tcp|fd00:0:0:0:0:0:0:1|1|tcp,fd00:0:0:0:0:0:0:1/128,1|
ok|tcp|fd00::|1|tcp,fd00::/128,1|
bad|icmp|10.0.0.1|1|protocol 'icmp' is not tcp or udp
bad|tcp|10.0.0.1|0|port '0' is not a number from 1 to 65535 or 'any'
bad|tcp|10.0.0.1|65536|port '65536' is not
bad|tcp|10.0.0.1|080|port '080' is not
bad|tcp|10.0.0.1|22-25|port '22-25' is not
bad|tcp|10.0.0.1|22,23|port '22,23' is not
bad|tcp|0.0.0.0/0|any|is a /0, which would open every address
bad|tcp|10.0.0.0/0|any|is a /0
bad|udp|::/0|53|is a /0
bad|tcp|10.1.2.3/8|22|has host bits set beyond /8
bad|tcp|fd7a::1/16|22|has host bits set beyond /16
bad|tcp|fd7a:4000::/17|22|has host bits set beyond /17
bad|tcp|10.0.0.1/33|22|has a prefix longer than /32
bad|tcp|fd00::/129|22|has a prefix longer than /128
bad|tcp|10.0.0.1/|22|has an invalid prefix length
bad|tcp|10.0.0.1/08|22|has an invalid prefix length
bad|tcp|10.0.0.0/8/9|22|has an invalid prefix length
bad|tcp|010.0.0.1|22|is not an IPv4 address or CIDR
bad|tcp|10.0.0.256|22|is not an IPv4 address or CIDR
bad|tcp|10.0.0|22|is not an IPv4 address or CIDR
bad|tcp|myhost.lan|22|is not an IPv4 address or CIDR
bad|tcp|/8|22|is not an IPv4 address or CIDR
bad|tcp|1:2:3:4:5:6:7:8:9|1|is not an IPv6 address or CIDR
bad|tcp|1:2:3:4:5:6:7:8::|1|is not an IPv6 address or CIDR
bad|tcp|1::2::3|1|is not an IPv6 address or CIDR
bad|tcp|:1::2|1|is not an IPv6 address or CIDR
bad|tcp|:::|1|is not an IPv6 address or CIDR
bad|tcp|fd00::12345|1|is not an IPv6 address or CIDR
bad|tcp|::ffff:10.0.0.1|1|is not an IPv6 address or CIDR
bad|tcp|fe80::1%eth0|1|is not an IPv6 address or CIDR
EOF

# grammar_sh: one line per fixture, "<canonical>|<note>" or "ERR:<error>".
grammar_sh() {
	(
		# shellcheck source=docker/shared/egress-rules.sh
		. "$LIB"
		while IFS='|' read -r _want proto dest port _rest; do
			if powbox_egress_validate "$proto" "$dest" "$port"; then
				powbox_egress_classify "$POWBOX_EGRESS_RULE"
				printf '%s|%s\n' "$POWBOX_EGRESS_RULE" "$POWBOX_EGRESS_NOTE"
			else
				printf 'ERR:%s\n' "$POWBOX_EGRESS_ERROR"
			fi
		done <"$FIXTURES"
	)
}

# The launcher's egress functions, from the blocked-range lists to the end of
# Read-Powbox-EgressRules, plus the two helpers they call.
PS_EXTRACT="$WORK_ROOT/egress-functions.ps1"
tr -d '\r' <"$LAUNCH_PS" | awk '
	/^function (Get-Powbox-HashHexFromByteArray|Write-Powbox-Warning) / { helper = 1 }
	helper { print; if ($0 == "}") helper = 0; next }
	/^\$script:PowboxEgressBlockedV4 = / { on = 1 }
	on { print }
	on && /^function Read-Powbox-EgressRules / { last = 1 }
	on && last && $0 == "}" { exit }
' >"$PS_EXTRACT"

grammar_ps() {
	# shellcheck disable=SC2016 # PowerShell variables, expanded by pwsh
	PS_EXTRACT="$PS_EXTRACT" FIXTURES="$FIXTURES" pwsh -NoProfile -NonInteractive -Command '
		$ErrorActionPreference = "Stop"
		. $env:PS_EXTRACT
		foreach ($line in [System.IO.File]::ReadAllLines($env:FIXTURES)) {
			$f = $line.Split("|")
			$r = Test-Powbox-EgressRule $f[1] $f[2] $f[3]
			if ($r.Error -ne "") { "ERR:$($r.Error)" } else { "$($r.Rule)|$(Get-Powbox-EgressNote $r)" }
		}'
}

echo "Test: the rule grammar matches the fixture table"
GRAMMAR_SH="$(grammar_sh)"
mapfile -t sh_results <<<"$GRAMMAR_SH"
i=0
while IFS='|' read -r want proto dest port expect note; do
	got="${sh_results[$i]}"
	i=$((i + 1))
	what="[sh] ${proto} ${dest} ${port}"
	if [ "$want" = ok ]; then
		assert_eq "$what" "$got" "${expect}|${note}"
	elif [ "${got#ERR:}" != "$got" ] && [[ "$got" == *"$expect"* ]]; then
		ok "$what is rejected: $expect"
	else
		ko "$what is rejected" "expected an error containing: $expect" "actual: $got"
	fi
done <"$FIXTURES"

if $HAVE_PWSH; then
	echo "Test: launch-agent.ps1 agrees with the shared grammar on every fixture"
	if [ -s "$PS_EXTRACT" ] && grep -q '^function Read-Powbox-EgressRules ' "$PS_EXTRACT"; then
		ok "the PowerShell egress functions can be extracted from launch-agent.ps1"
	else
		ko "the PowerShell egress functions can be extracted from launch-agent.ps1"
	fi
	GRAMMAR_PS="$(grammar_ps 2>&1 | tr -d '\r')" || true
	mapfile -t ps_results <<<"$GRAMMAR_PS"
	i=0
	while IFS='|' read -r _want proto dest port _rest; do
		assert_eq "[ps1] ${proto} ${dest} ${port}" "${ps_results[$i]:-<missing>}" "${sh_results[$i]}"
		i=$((i + 1))
	done <"$FIXTURES"
else
	skipped "pwsh unavailable - PowerShell grammar parity not run"
fi

echo "Test: the blocked ranges agree across the firewall, the library and launch-agent.ps1"
fw_drops() {
	awk -v fam="$1" '
		/^fw_apply_default\(\) \{$/ { on = 1; next }
		on && /^\}$/ { exit }
		on && $1 == fam && $3 == "OUTPUT" && $4 == "-d" && $6 == "-j" && $7 == "DROP" { print $5 }
	' "$FW"
}
lib_v4="$(bash -c '. "$1"; printf "%s\n" "${POWBOX_EGRESS_BLOCKED_V4[@]}"' _ "$LIB")"
lib_v6="$(bash -c '. "$1"; printf "%s\n" "${POWBOX_EGRESS_BLOCKED_V6[@]}"' _ "$LIB")"
assert_eq "IPv4: init-firewall.sh DROPs = egress-rules.sh" "$(fw_drops iptables)" "$lib_v4"
assert_eq "IPv6: init-firewall.sh DROPs = egress-rules.sh" "$(fw_drops ip6tables)" "$lib_v6"
ps_list() {
	tr -d '\r' <"$LAUNCH_PS" | sed -n "s/^\\\$script:PowboxEgressBlocked$1 = @(\\(.*\\))\$/\\1/p" | tr -d '" ' | tr ',' '\n'
}
assert_eq "IPv4: launch-agent.ps1 = egress-rules.sh" "$(ps_list V4)" "$lib_v4"
assert_eq "IPv6: launch-agent.ps1 = egress-rules.sh" "$(ps_list V6)" "$lib_v6"

# ---------------------------------------------------------------------------
# The firewall. Stub iptables/ip6tables log each call as "<family> <args>";
# replay_chain turns that log into the final OUTPUT chain of one family.
# ---------------------------------------------------------------------------
STUB_BIN="$WORK_ROOT/stub-bin"
mkdir -p "$STUB_BIN"
for tool in iptables ip6tables; do
	fam=v4
	[ "$tool" = ip6tables ] && fam=v6
	cat >"$STUB_BIN/$tool" <<SH
#!/bin/sh
if [ "\${SIM_FAIL_INSERT:-}" = 1 ] && [ "\$1" = -I ]; then
	printf '%s FAILED %s\n' "$fam" "\$*" >>"\$SIM_LOG"
	exit 1
fi
printf '%s %s\n' "$fam" "\$*" >>"\$SIM_LOG"
exit 0
SH
	chmod +x "$STUB_BIN/$tool"
done

replay_chain() {
	awk -v fam="$1" '
		$1 != fam || $2 == "FAILED" { next }
		$2 == "-F" { n = 0; next }
		$2 == "-A" { rest = $0; sub(/^[^ ]+ -A OUTPUT /, "", rest); chain[++n] = rest; next }
		$2 == "-I" {
			pos = $4; rest = $0; sub(/^[^ ]+ -I OUTPUT [0-9]+ /, "", rest)
			for (j = n; j >= pos; j--) chain[j + 1] = chain[j]
			chain[pos] = rest; n++; next
		}
		{ print "UNEXPECTED " $0 }
		END { for (j = 1; j <= n; j++) print chain[j] }
	' "$2"
}

DEFAULT_V4="-o lo -j ACCEPT
-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-d 10.0.0.0/8 -j DROP
-d 172.16.0.0/12 -j DROP
-d 192.168.0.0/16 -j DROP
-d 169.254.0.0/16 -j DROP
-d 100.64.0.0/10 -j DROP
-j ACCEPT"
DEFAULT_V6="-o lo -j ACCEPT
-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-d fc00::/7 -j DROP
-d fe80::/10 -j DROP
-j ACCEPT"
BANNER="Firewall active: local networks blocked, public internet allowed."

# with_head <head> <chain>: the loopback and ESTABLISHED rules, then <head>,
# then the rest of <chain>.
with_head() {
	printf '%s\n' "$2" | sed -n '1,2p'
	printf '%s\n' "$1"
	printf '%s\n' "$2" | sed '1,2d'
}

# fw_run <environ-file> [<fw-args>...]: source init-firewall.sh, read PID 1's
# environ from <environ-file> instead of /proc/1/environ, and run its main.
# Leaves FW_OUT (stdout), FW_ERR (stderr), FW_V4 and FW_V6 (final chains).
fw_run() {
	local environ="$1" log="$WORK_ROOT/sim.log"
	shift
	: >"$log"
	set +e
	(
		export SIM_LOG="$log" PATH="$STUB_BIN:$PATH"
		# shellcheck source=docker/shared/init-firewall.sh
		. "$FW"
		POWBOX_FW_ENVIRON="$environ"
		# shellcheck disable=SC2329 # Replaces the setpriv reader fw_main calls.
		fw_pid1_environ() { cat "$POWBOX_FW_ENVIRON"; }
		# shellcheck disable=SC2034 # Read by the sourced init-firewall.sh.
		[ -z "${FW_LIB_OVERRIDE:-}" ] || POWBOX_FW_LIB="$FW_LIB_OVERRIDE"
		fw_main "$@"
	) >"$WORK_ROOT/fw.out" 2>"$WORK_ROOT/fw.err"
	FW_RC=$?
	set -e
	FW_OUT="$(cat "$WORK_ROOT/fw.out")"
	FW_ERR="$(cat "$WORK_ROOT/fw.err")"
	FW_V4="$(replay_chain v4 "$log")"
	FW_V6="$(replay_chain v6 "$log")"
}

# environ_file <name> [<VAR=value>...]: a NUL-separated environment.
environ_file() {
	local file="$WORK_ROOT/$1"
	shift
	: >"$file"
	local kv
	for kv in PATH=/usr/bin HOSTNAME=x "$@"; do
		printf '%s\0' "$kv" >>"$file"
	done
	printf '%s' "$file"
}

echo "Test: with no exceptions the firewall applies exactly today's rules"
env_none="$(environ_file env-none)"
fw_run "$env_none"
assert_eq "exit status" "$FW_RC" 0
assert_eq "IPv4 chain" "$FW_V4" "$DEFAULT_V4"
assert_eq "IPv6 chain" "$FW_V6" "$DEFAULT_V6"
assert_eq "banner" "$FW_OUT" "$BANNER"
assert_eq "no warnings" "$FW_ERR" ""
fw_run "$(environ_file env-empty POWBOX_EGRESS_ALLOW=)"
assert_eq "empty variable: IPv4 chain" "$FW_V4" "$DEFAULT_V4"
assert_eq "empty variable: banner" "$FW_OUT" "$BANNER"

echo "Test: valid exceptions are ACCEPTs between ESTABLISHED and the DROPs"
fw_run "$(environ_file env-valid 'POWBOX_EGRESS_ALLOW=tcp,100.64.1.2/32,3128;udp,fd7a:115c:a1e0::1/128,53;tcp,10.0.0.0/8,any;tcp,fe80::/10,22')"
assert_eq "exit status" "$FW_RC" 0
assert_eq "IPv4 chain" "$FW_V4" "$(with_head "-p tcp -d 100.64.1.2/32 --dport 3128 -j ACCEPT
-p tcp -d 10.0.0.0/8 -j ACCEPT" "$DEFAULT_V4")"
assert_eq "IPv6 chain" "$FW_V6" "$(with_head "-p udp -d fd7a:115c:a1e0::1/128 --dport 53 -j ACCEPT
-p tcp -d fe80::/10 --dport 22 -j ACCEPT" "$DEFAULT_V6")"
assert_eq "banner lists the exceptions" "$FW_OUT" "$BANNER
Egress exceptions (from .powbox-egress):
  allow tcp 100.64.1.2/32 port 3128
  allow tcp 10.0.0.0/8 port any
  allow udp fd7a:115c:a1e0::1/128 port 53
  allow tcp fe80::/10 port 22"
assert_eq "no warnings" "$FW_ERR" ""

echo "Test: the firewall agrees with the shared grammar on every fixture"
fixture_allow=""
while IFS='|' read -r want proto dest port expect _note; do
	fw_run "$(environ_file env-fixture "POWBOX_EGRESS_ALLOW=${proto},${dest},${port}")"
	what="[fw] ${proto} ${dest} ${port}"
	drops_intact=true
	printf '%s\n' "$FW_V4" | grep -qxF -- '-d 100.64.0.0/10 -j DROP' || drops_intact=false
	printf '%s\n' "$FW_V6" | grep -qxF -- '-d fe80::/10 -j DROP' || drops_intact=false
	if [ "$want" = ok ]; then
		IFS=',' read -r cproto cdest cport <<<"$expect"
		assert_contains "$what is applied" "$FW_OUT" "allow ${cproto} ${cdest} port ${cport}"
		fixture_allow+="${proto},${dest},${port};"
	else
		if [ "$FW_OUT" = "$BANNER" ] && [ "$FW_V4" = "$DEFAULT_V4" ] && [ "$FW_V6" = "$DEFAULT_V6" ] &&
			[[ "$FW_ERR" == *"skipping egress exception"* ]]; then
			ok "$what is skipped with a warning"
		else
			ko "$what is skipped with a warning" "out: $FW_OUT" "err: $FW_ERR"
		fi
	fi
	$drops_intact || ko "$what removed a default DROP"
done <"$FIXTURES"

echo "Test: an invalid entry never removes a default DROP"
fw_run "$(environ_file env-mixed "POWBOX_EGRESS_ALLOW=;tcp,0.0.0.0/0,any;garbage;tcp,10.0.0.5/32,22;udp,::/0,53;tcp,10.0.0.5/32,22,extra;tcp,10.0.0.5/32;;tcp,10.0.0.5/32,22")"
assert_eq "IPv4 chain keeps every DROP, with only the valid rule added once" "$FW_V4" "$(with_head "-p tcp -d 10.0.0.5/32 --dport 22 -j ACCEPT" "$DEFAULT_V4")"
assert_eq "IPv6 chain unchanged" "$FW_V6" "$DEFAULT_V6"
assert_eq "one skip warning per invalid entry" "$(printf '%s\n' "$FW_ERR" | grep -c 'skipping egress exception')" 5
fw_run "$(environ_file env-all-fixtures "POWBOX_EGRESS_ALLOW=${fixture_allow}")"
for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
	assert_eq "every valid fixture at once still ends with the DROP for $range" \
		"$(printf '%s\n' "$FW_V4" | grep -cxF -- "-d $range -j DROP")" 1
done
assert_eq "every valid fixture at once: the DROPs and the final ACCEPT come last" \
	"$(printf '%s\n' "$FW_V4" | tail -n 6)" "$(printf '%s\n' "$DEFAULT_V4" | tail -n 6)"
assert_eq "every valid fixture at once: IPv6 DROPs and final ACCEPT come last" \
	"$(printf '%s\n' "$FW_V6" | tail -n 3)" "$(printf '%s\n' "$DEFAULT_V6" | tail -n 3)"

echo "Test: a line break in the value, a failed read or a missing library means no exceptions"
fw_run "$(environ_file env-newline "POWBOX_EGRESS_ALLOW=tcp,10.0.0.5/32,22
tcp,10.0.0.6/32,22")"
assert_eq "line break: IPv4 chain is the default" "$FW_V4" "$DEFAULT_V4"
assert_contains "line break: warns" "$FW_ERR" "holds a line break"
fw_run "$WORK_ROOT/does-not-exist"
assert_eq "unreadable environ: IPv4 chain is the default" "$FW_V4" "$DEFAULT_V4"
assert_eq "unreadable environ: IPv6 chain is the default" "$FW_V6" "$DEFAULT_V6"
assert_contains "unreadable environ: warns" "$FW_ERR" "cannot read the launch-time environment"
FW_LIB_OVERRIDE="$WORK_ROOT/no-such-lib.sh" fw_run "$(environ_file env-lib "POWBOX_EGRESS_ALLOW=tcp,10.0.0.5/32,22")"
assert_eq "missing library: IPv4 chain is the default" "$FW_V4" "$DEFAULT_V4"
assert_contains "missing library: warns" "$FW_ERR" "cannot load"
assert_eq "missing library: banner unchanged" "$FW_OUT" "$BANNER"

echo "Test: a failing iptables insert leaves the destination blocked, not the chain open"
SIM_FAIL_INSERT=1 fw_run "$(environ_file env-fail "POWBOX_EGRESS_ALLOW=tcp,10.0.0.5/32,22;tcp,fd00::1/128,22")"
assert_eq "exit status" "$FW_RC" 0
assert_eq "IPv4 chain is the default" "$FW_V4" "$DEFAULT_V4"
assert_eq "IPv6 chain is the default" "$FW_V6" "$DEFAULT_V6"
assert_contains "warns" "$FW_ERR" "could not apply egress exception 'tcp,10.0.0.5/32,22'; it stays blocked"
assert_eq "banner lists nothing" "$FW_OUT" "$BANNER"

echo "Test: the firewall ignores its own arguments and environment"
POWBOX_EGRESS_ALLOW="tcp,10.0.0.9/32,22" fw_run "$env_none" "tcp,10.0.0.8/32,22"
assert_eq "IPv4 chain is the default" "$FW_V4" "$DEFAULT_V4"
assert_contains "arguments draw a note" "$FW_ERR" "arguments are ignored"
# Executed as a process (as sudo runs it), not sourced: the real reader runs,
# and whatever it finds in this host's PID 1, the caller's variable and
# arguments must not appear.
: >"$WORK_ROOT/sim.log"
set +e
exec_out="$(SIM_LOG="$WORK_ROOT/sim.log" PATH="$STUB_BIN:$PATH" POWBOX_EGRESS_ALLOW="tcp,10.0.0.9/32,22" \
	bash "$FW" "tcp,10.0.0.8/32,22" 2>/dev/null)"
exec_rc=$?
set -e
assert_eq "executed: exit status" "$exec_rc" 0
assert_not_contains "executed: the caller's variable is not applied" "$(cat "$WORK_ROOT/sim.log")" "10.0.0.9"
assert_not_contains "executed: the argument is not applied" "$(cat "$WORK_ROOT/sim.log")" "10.0.0.8"
assert_contains "executed: the banner prints" "$exec_out" "$BANNER"

echo "Test: PID 1's environ is read under PID 1's own uid and gid"
status="$WORK_ROOT/status"
setpriv_log="$WORK_ROOT/setpriv.log"
cat >"$STUB_BIN/setpriv" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >"$SETPRIV_LOG"
shift 4
exec "$@"
SH
chmod +x "$STUB_BIN/setpriv"
reader() {
	(
		export PATH="$STUB_BIN:$PATH" SETPRIV_LOG="$setpriv_log"
		# shellcheck source=docker/shared/init-firewall.sh
		. "$FW"
		# shellcheck disable=SC2034 # Read by the sourced init-firewall.sh.
		POWBOX_FW_STATUS="$status"
		POWBOX_FW_ENVIRON="$env_none"
		fw_pid1_environ | tr '\0' '\n'
	)
}
printf 'Name:\tdocker-init\nUid:\t1000\t1000\t1000\t1000\nGid:\t1001\t1001\t1001\t1001\n' >"$status"
: >"$setpriv_log"
reader_out="$(reader 2>&1)" || true
assert_eq "setpriv switches to uid 1000 and gid 1001" "$(cat "$setpriv_log")" "--reuid=1000 --regid=1001 --clear-groups -- cat $env_none"
assert_contains "the environ is returned" "$reader_out" "HOSTNAME=x"
printf 'Uid:\t1000\t0\t1000\t1000\nGid:\t1000\t1000\t1000\t1000\n' >"$status"
: >"$setpriv_log"
if reader >/dev/null 2>&1; then
	ko "mixed uids are refused, not read as root"
else
	ok "mixed uids are refused, not read as root"
fi
assert_eq "mixed uids: setpriv is not run" "$(cat "$setpriv_log")" ""
rm -f "$STUB_BIN/setpriv"

# ---------------------------------------------------------------------------
# The launchers' file handling, through POWBOX_PRINT_EGRESS=1 on copies of the
# launchers in a fixture checkout, so the checkout's own .powbox-egress (if
# any) never leaks in.
# ---------------------------------------------------------------------------
CHECKOUT="$WORK_ROOT/checkout"
mkdir -p "$CHECKOUT/scripts" "$CHECKOUT/docker/shared" "$WORK_ROOT/ws"
cp "$LAUNCH_SH" "$LAUNCH_PS" "$CHECKOUT/scripts/"
cp "$LIB" "$CHECKOUT/docker/shared/"
cp "${ROOT_DIR}"/compose*.yml "$CHECKOUT/"
EGRESS_FILE="$CHECKOUT/.powbox-egress"
WS="$(cd "$WORK_ROOT/ws" && pwd -P)"

print_sh() {
	POWBOX_PRINT_EGRESS=1 bash "$CHECKOUT/scripts/launch-agent.sh" codex "$@" 2>&1
}
print_ps() {
	POWBOX_PRINT_EGRESS=1 pwsh -NoProfile -NonInteractive -File "$CHECKOUT/scripts/launch-agent.ps1" codex "$@" 2>&1 | norm
}
value_of() {
	printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

# check_print <label> <want-rules> [<want-warning>...]: both launchers, in both
# launch modes, print <want-rules> and its hash (empty for no rules).
check_print() {
	local label="$1" want="$2" hash="" out mode
	shift 2
	[ -z "$want" ] || hash="$(sha256_of "$want")"
	for mode in dir isolated; do
		if [ "$mode" = dir ]; then
			out="$(print_sh "$WS")" || true
		else
			out="$(print_sh --isolated --repo example/repo)" || true
		fi
		assert_eq "[sh/$mode] $label: rules" "$(value_of "$(printf '%s' "$out" | tr '\n' ' ')" EGRESS_RULES)" "$want"
		assert_eq "[sh/$mode] $label: hash" "$(value_of "$(printf '%s' "$out" | tr '\n' ' ')" EGRESS_HASH)" "$hash"
		for w in "$@"; do assert_contains "[sh/$mode] $label: warns" "$out" "$w"; done
		if $HAVE_PWSH; then
			if [ "$mode" = dir ]; then
				out="$(print_ps "$WS")" || true
			else
				out="$(print_ps -Isolated -Repo example/repo)" || true
			fi
			assert_eq "[ps1/$mode] $label: rules" "$(value_of "$out" EGRESS_RULES)" "$want"
			assert_eq "[ps1/$mode] $label: hash" "$(value_of "$out" EGRESS_HASH)" "$hash"
			for w in "$@"; do assert_contains "[ps1/$mode] $label: warns" "$out" "$w"; done
		fi
	done
}

# check_error <label> <line> <fragment>: both launchers stop with an error that
# names the file and line.
check_error() {
	local label="$1" line="$2" frag="$3" out rc
	set +e
	out="$(print_sh "$WS")"
	rc=$?
	set -e
	assert_eq "[sh] $label: exit status" "$rc" 1
	assert_contains "[sh] $label: names the file and line" "$out" "${EGRESS_FILE} line ${line}: "
	assert_contains "[sh] $label: says why" "$out" "$frag"
	assert_not_contains "[sh] $label: prints no rules" "$out" "EGRESS_RULES="
	if $HAVE_PWSH; then
		set +e
		out="$(POWBOX_PRINT_EGRESS=1 pwsh -NoProfile -NonInteractive -File "$CHECKOUT/scripts/launch-agent.ps1" codex "$WS" 2>&1)"
		rc=$?
		set -e
		out="$(printf '%s' "$out" | norm)"
		assert_eq "[ps1] $label: exit status" "$rc" 1
		assert_contains "[ps1] $label: names the file and line" "$out" "${EGRESS_FILE} line ${line}: "
		assert_contains "[ps1] $label: says why" "$out" "$frag"
		assert_not_contains "[ps1] $label: prints no rules" "$out" "EGRESS_RULES="
	fi
}

echo "Test: no file, or a file with no rules, means no rules and no hash"
rm -f "$EGRESS_FILE"
check_print "no file" ""
printf '\xef\xbb\xbf# only comments\r\n\r\n   \t\n# tcp 10.0.0.1 22\n' >"$EGRESS_FILE"
check_print "comments only" ""
: >"$EGRESS_FILE"
check_print "empty file" ""

echo "Test: BOM, CRLF, comments, case, tabs and duplicates normalize to one canonical form"
printf '\xef\xbb\xbf# Proxy on the tailnet\r\ntcp 100.64.1.2 3128 # proxy\r\n\r\n  UDP\tFD7A:115C:A1E0::1   53\nudp fd7a:115c:a1e0::1/128 53\ntcp 192.168.1.20 5432\ntcp 100.64.1.2/32 3128' >"$EGRESS_FILE"
canonical="tcp,100.64.1.2/32,3128;tcp,192.168.1.20/32,5432;udp,fd7a:115c:a1e0::1/128,53"
check_print "messy file" "$canonical"
printf 'tcp 192.168.1.20 5432 # db, moved up\n# a new comment\nudp fd7a:115c:a1e0::1 53\ntcp 100.64.1.2 3128\n' >"$EGRESS_FILE"
check_print "reordered, recommented" "$canonical"

echo "Test: a rule that looks like a mistake warns but is kept"
printf 'tcp 8.8.8.8 53\ntcp 10.0.0.0/8 any\n' >"$EGRESS_FILE"
check_print "public and broad" "tcp,10.0.0.0/8,any;tcp,8.8.8.8/32,53" \
	"line 1: 8.8.8.8 is outside every blocked range" \
	"line 2: 10.0.0.0/8 reopens at least half of the blocked range 10.0.0.0/8"

echo "Test: a malformed line stops the launch, naming the file and line"
printf '# ok\ntcp 10.0.0.1 22\ntcp 10.0.0.2\n' >"$EGRESS_FILE"
check_error "two fields" 3 "expected '<proto> <destination> <port>'"
printf 'tcp 10.0.0.1 22 23\n' >"$EGRESS_FILE"
check_error "four fields" 1 "expected '<proto> <destination> <port>'"
printf '\n\ntcp 0.0.0.0/0 any # everything\n' >"$EGRESS_FILE"
check_error "IPv4 /0" 3 "is a /0"
printf 'udp ::/0 53\n' >"$EGRESS_FILE"
check_error "IPv6 /0" 1 "is a /0"
printf 'tcp 10.0.0.1 22\r\nicmp 10.0.0.1 any\r\n' >"$EGRESS_FILE"
check_error "unknown protocol" 2 "protocol 'icmp' is not tcp or udp"
printf 'tcp nas.lan 445\n' >"$EGRESS_FILE"
check_error "hostname" 1 "is not an IPv4 address or CIDR"
printf 'tcp 10.1.2.3/8 22\n' >"$EGRESS_FILE"
check_error "host bits" 1 "has host bits set beyond /8"
printf 'tcp 10.0.0.1 22-25\n' >"$EGRESS_FILE"
check_error "port range" 1 "port '22-25' is not"
rm -f "$EGRESS_FILE"
mkdir "$EGRESS_FILE"
check_error_dir() {
	local out rc
	set +e
	out="$(print_sh "$WS")"
	rc=$?
	set -e
	assert_eq "[sh] a directory: exit status" "$rc" 1
	assert_contains "[sh] a directory: error" "$out" "is not a regular file"
	if $HAVE_PWSH; then
		set +e
		out="$(POWBOX_PRINT_EGRESS=1 pwsh -NoProfile -NonInteractive -File "$CHECKOUT/scripts/launch-agent.ps1" codex "$WS" 2>&1 | norm)"
		rc=${PIPESTATUS[0]}
		set -e
		assert_eq "[ps1] a directory: exit status" "$rc" 1
		assert_contains "[ps1] a directory: error" "$out" "is not a regular file"
	fi
}
check_error_dir
rmdir "$EGRESS_FILE"

# ---------------------------------------------------------------------------
# The launchers' create and reuse paths, end to end against a fake docker.
# FAKE_EXISTS / FAKE_RUNNING describe the existing container, FAKE_EGRESS_LABEL
# its powbox.egress-hash label; the other reuse checks are answered so they
# keep the container. Every call is logged.
# ---------------------------------------------------------------------------
FAKE_BIN="$WORK_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/docker" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$1 $2" in
"container inspect")
	case "$*" in
	*State.Running*) echo "${FAKE_RUNNING:-false}" ;;
	*powbox.egress-hash*) printf '%s\n' "${FAKE_EGRESS_LABEL:-}" ;;
	*) [ "${FAKE_EXISTS:-0}" = 1 ] || exit 1 ;;
	esac
	;;
"inspect --format")
	case "$*" in
	*powbox.continue*) echo false ;;
	*/home/node/.local/share/containers*) echo yes ;;
	esac
	;;
"image inspect")
	case "$*" in
	*powbox.base.selfhosted*) echo 1 ;;
	esac
	;;
esac
exit 0
SH
chmod +x "$FAKE_BIN/docker"
FAKE_LOG="$WORK_ROOT/docker.log"

# launch <sh|ps1> <args...>: run the fixture checkout's launcher against the
# fake docker; leaves L_RC, L_OUT (normalized output) and L_LOG (docker calls).
launch() {
	local which="$1"
	shift
	: >"$FAKE_LOG"
	set +e
	if [ "$which" = sh ]; then
		L_OUT="$(FAKE_LOG="$FAKE_LOG" PATH="$FAKE_BIN:$PATH" GIT_CONFIG_PATH="$WORK_ROOT/no-gitconfig" GH_HOST_CONFIG_DIR="$WORK_ROOT/no-gh" \
			bash "$CHECKOUT/scripts/launch-agent.sh" codex "$@" </dev/null 2>&1)"
		L_RC=$?
	else
		L_OUT="$(FAKE_LOG="$FAKE_LOG" PATH="$FAKE_BIN:$PATH" GIT_CONFIG_PATH="$WORK_ROOT/no-gitconfig" GH_HOST_CONFIG_DIR="$WORK_ROOT/no-gh" \
			pwsh -NoProfile -NonInteractive -File "$CHECKOUT/scripts/launch-agent.ps1" codex "$@" </dev/null 2>&1)"
		L_RC=$?
	fi
	set -e
	L_OUT="$(printf '%s' "$L_OUT" | norm)"
	L_LOG="$(cat "$FAKE_LOG")"
}

# log_has <command>: whether the fake docker was called as `docker <command> ...`.
log_has() {
	printf '%s\n' "$L_LOG" | grep -q "^$1 "
}

# The agent's own `compose ... run --name` call (not the volume-prep run).
agent_run() {
	printf '%s\n' "$L_LOG" | grep -E '^compose .* run --name ' || true
}

RULES_A="tcp,100.64.1.2/32,3128"
HASH_A="$(sha256_of "$RULES_A")"

# reuse_case <label> <file-rules|-> <exists> <running> <label-value> <expect> [launch args...]
# <expect>: create-with / create-without (a new container, with or without the
# egress label and variable), recreate-with / recreate-without (removed first),
# start (reused as is), attach, refuse-running, refuse-resume.
reuse_case() {
	local label="$1" rules="$2" exists="$3" running="$4" existing="$5" expect="$6" which run
	shift 6
	if [ "$rules" = - ]; then
		rm -f "$EGRESS_FILE"
	else
		printf '%s\n' "$rules" >"$EGRESS_FILE"
	fi
	for which in sh ps1; do
		if [ "$which" = ps1 ] && ! $HAVE_PWSH; then
			continue
		fi
		local -a args=("$@")
		if [ "$which" = ps1 ]; then
			args=("${args[@]/#--resume/-Resume}")
			args=("${args[@]/#--isolated/-Isolated}")
			args=("${args[@]/#--repo/-Repo}")
		fi
		FAKE_EXISTS="$exists" FAKE_RUNNING="$running" FAKE_EGRESS_LABEL="$existing" launch "$which" "${args[@]}"
		run="$(agent_run)"
		local what="[$which] $label"
		case "$expect" in
		create-with | recreate-with | create-without | recreate-without)
			assert_eq "$what: exit status" "$L_RC" 0
			if [ "${expect#recreate}" != "$expect" ]; then
				if log_has rm; then ok "$what: removes the old container"; else ko "$what: removes the old container" "$L_LOG"; fi
				assert_contains "$what: says why" "$L_OUT" "Egress exceptions changed"
			else
				if log_has rm; then ko "$what: removes nothing" "$L_LOG"; else ok "$what: removes nothing"; fi
			fi
			if [ -n "$run" ]; then ok "$what: creates the container"; else ko "$what: creates the container" "$L_LOG"; fi
			if [ "${expect%with}" != "$expect" ] && [ "${expect%without}" = "$expect" ]; then
				assert_contains "$what: labels the hash" "$run" " --label powbox.egress-hash=${HASH_A} "
				assert_contains "$what: passes the rules" "$run" " -e POWBOX_EGRESS_ALLOW=${RULES_A} "
			else
				assert_not_contains "$what: no egress label" "$run" "powbox.egress-hash"
				assert_not_contains "$what: no egress variable" "$run" "POWBOX_EGRESS_ALLOW"
			fi
			;;
		start | attach)
			assert_eq "$what: exit status" "$L_RC" 0
			if log_has rm; then ko "$what: removes nothing" "$L_LOG"; else ok "$what: removes nothing"; fi
			assert_eq "$what: creates nothing" "$run" ""
			if log_has "$expect"; then ok "$what: reuses the container ($expect)"; else ko "$what: reuses the container ($expect)" "$L_LOG"; fi
			;;
		refuse-running | refuse-resume)
			if [ "$L_RC" -ne 0 ]; then ok "$what: refuses"; else ko "$what: refuses" "$L_OUT"; fi
			if [ "$expect" = refuse-running ]; then
				assert_contains "$what: says to stop it first" "$L_OUT" "is running with different egress exceptions than .powbox-egress now lists. Stop the container first"
			else
				assert_contains "$what: says to drop resume" "$L_OUT" "Relaunch without"
			fi
			if log_has rm; then ko "$what: removes nothing" "$L_LOG"; else ok "$what: removes nothing"; fi
			if log_has attach || log_has start; then ko "$what: neither attaches nor starts" "$L_LOG"; else ok "$what: neither attaches nor starts"; fi
			assert_eq "$what: creates nothing" "$run" ""
			;;
		esac
	done
}

echo "Test: a new container carries the label and variable only when there are rules"
reuse_case "no file, new container" - 0 false "" create-without "$WS"
reuse_case "rules, new container" "tcp 100.64.1.2 3128" 0 false "" create-with "$WS"

echo "Test: reuse follows the egress hash"
reuse_case "no file, unlabelled container" - 1 false "" start "$WS"
reuse_case "same rules" "tcp 100.64.1.2 3128 # edited comment" 1 false "$HASH_A" start "$WS"
reuse_case "same rules, running" "tcp 100.64.1.2 3128" 1 true "$HASH_A" attach "$WS"
reuse_case "no file, running unlabelled" - 1 true "" attach "$WS"
reuse_case "rules added, stopped" "tcp 100.64.1.2 3128" 1 false "" recreate-with "$WS"
reuse_case "rules changed, stopped" "tcp 100.64.1.2 3128" 1 false "0123abcd" recreate-with "$WS"
reuse_case "file deleted, stopped" - 1 false "$HASH_A" recreate-without "$WS"
reuse_case "file emptied, stopped" "# nothing" 1 false "$HASH_A" recreate-without "$WS"
reuse_case "rules changed, running" "tcp 100.64.1.2 3128" 1 true "0123abcd" refuse-running "$WS"
reuse_case "file deleted, running" - 1 true "$HASH_A" refuse-running "$WS"
reuse_case "isolated, file deleted, running" - 1 true "$HASH_A" refuse-running --isolated --repo example/repo

echo "Test: --resume compares too, and never recreates"
reuse_case "resume, same rules" "tcp 100.64.1.2 3128" 1 false "$HASH_A" start --resume "$WS"
reuse_case "resume, file deleted, stopped" - 1 false "$HASH_A" refuse-resume --resume "$WS"
reuse_case "resume, rules changed, running" "tcp 100.64.1.2 3128" 1 true "0123abcd" refuse-running --resume "$WS"
rm -f "$EGRESS_FILE"

if ! $HAVE_PWSH; then
	skipped "pwsh unavailable - launch-agent.ps1 file handling and reuse not run"
fi

echo
echo "egress allow-list tests: ${pass} passed, ${fail} failed, ${skip} skipped"
[ "$fail" -eq 0 ]
