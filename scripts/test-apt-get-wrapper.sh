#!/usr/bin/env bash
# Unit tests for docker/shared/apt-get-wrapper.sh, the apt-get that `sudo
# apt-get` reaches for the node user, and for its sudoers wiring in
# docker/base/Dockerfile.
#
# The wrapper is copied to a tmpdir with its `readonly APT_GET=/usr/bin/apt-get`
# line pointed at a stub that records its argv, environment, working directory
# and stdin, so the accept/reject policy and exactly what reaches the real
# binary are asserted without root, sudo or apt. The rewrite is verified: a
# renamed assignment makes this suite FATAL rather than run the real apt-get.
# The built image's end of it (sudo -l, a real `sudo apt-get update`, a refused
# -o) is Stage 1 of commands/smoke-test.sh.
#
# Needs only bash + coreutils. No image, no Docker, no root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT_DIR/docker/shared/apt-get-wrapper.sh"
DOCKERFILE="$ROOT_DIR/docker/base/Dockerfile"
WRAPPER_PATH=/usr/local/libexec/powbox-sudo/apt-get

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}
ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
	[ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/       /'
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-apt-get-wrapper.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

LOG="$TMP/stub.log"
STUB="$TMP/apt-get-stub"
# The wrapper runs the stub under `env -i`, so the log path is baked into it.
{
	printf '#!/bin/sh\n'
	printf 'log=%q\n' "$LOG"
	cat <<'EOF'
{
	echo "cwd=$(pwd)"
	echo "stdin=$(readlink /proc/self/fd/0)"
	for a in "$@"; do echo "arg=$a"; done
	env | sort | sed 's/^/env=/'
} >"$log"
EOF
} >"$STUB"
chmod +x "$STUB"

WRAPPER="$TMP/apt-get"
sed "s#^readonly APT_GET=/usr/bin/apt-get\$#readonly APT_GET=$STUB#" "$SRC" >"$WRAPPER"
if [ "$(grep -c "^readonly APT_GET=$STUB\$" "$WRAPPER")" != 1 ] || grep -v '^[[:space:]]*#' "$WRAPPER" | grep -q /usr/bin/apt-get; then
	echo "FATAL: could not point the wrapper's APT_GET at the stub; refusing to run it." >&2
	exit 1
fi
chmod +x "$WRAPPER"

OUT="$TMP/out"
# run <args...>: run the wrapper, leaving its exit status in $rc, its combined
# output in $OUT and, when it exec'd the stub, the stub's record in $LOG.
run() {
	rm -f "$LOG"
	rc=0
	"$WRAPPER" "$@" >"$OUT" 2>&1 </dev/null || rc=$?
}

# The argv the stub received, one argument per line.
stub_args() {
	sed -n 's/^arg=//p' "$LOG"
}

FIXED_PREFIX=$'-y\n-o\nDpkg::Options::=--force-confdef\n-o\nDpkg::Options::=--force-confold'

expect_accept() {
	local want=$1 desc=$2
	shift 2
	run "$@"
	if [ "$rc" -ne 0 ] || [ ! -f "$LOG" ]; then
		ko "$desc: accepted" "rc=$rc; $(cat "$OUT")"
		return
	fi
	local got
	got="$(stub_args)"
	if [ "$got" = "$FIXED_PREFIX"$'\n'"$want" ]; then
		ok "$desc"
	else
		ko "$desc: argv" "$(diff <(printf '%s\n' "$FIXED_PREFIX" "$want") <(printf '%s\n' "$got") || true)"
	fi
}

expect_refuse() {
	local desc=$1
	shift
	run "$@"
	if [ -f "$LOG" ]; then
		ko "$desc: refused" "the stub ran with: $(stub_args | tr '\n' ' ')"
	elif [ "$rc" -ne 2 ]; then
		ko "$desc: exit 2" "rc=$rc; $(cat "$OUT")"
	elif ! grep -q '^apt-get: refused ' "$OUT" || ! grep -q '^  verbs ' "$OUT"; then
		ko "$desc: names the refusal and what is allowed" "$(cat "$OUT")"
	else
		ok "$desc"
	fi
}

printf 'A. the documented and common invocations reach apt-get, with only what was approved\n'
expect_accept $'update\n--' "sudo apt-get update" update
expect_accept $'-y\ninstall\n--\njq' "sudo apt-get install -y <package>" install -y jq
expect_accept $'-y\ninstall\n--\ndotnet-sdk-8.0' "the .NET side-by-side SDK install from the full notes" install -y dotnet-sdk-8.0
expect_accept $'-qy\n--no-install-recommends\ninstall\n--\nfoo\nbar' "flags before the verb, bundled short flags, several packages" -qy --no-install-recommends install foo bar
expect_accept $'-qq\nupdate\n--' "-qq update" -qq update
expect_accept $'install\n--\nfoo:amd64\nfoo=1:2.3~rc1-4+b1\nfoo/trixie-backports\ng++\nlibstdc++6' \
	"arch, version and release qualifiers, and + in names" install foo:amd64 'foo=1:2.3~rc1-4+b1' foo/trixie-backports 'g++' 'libstdc++6'
expect_accept $'remove\n--\nfoo' "remove" remove foo
expect_accept $'--purge\nremove\n--\nfoo' "remove --purge" remove --purge foo
expect_accept $'purge\n--\nfoo' "purge" purge foo
expect_accept $'autoremove\n--' "autoremove" autoremove
expect_accept $'upgrade\n--' "upgrade" upgrade
expect_accept $'clean\n--' "clean" clean
expect_accept $'-f\ninstall\n--' "-f install with no packages" -f install
expect_accept $'--simulate\ninstall\n--\nfoo' "--simulate" install --simulate foo

printf 'B. what reaches apt-get runs from /, with no terminal and a scrubbed environment\n'
rm -f "$LOG"
rc=0
(cd "$TMP" && APT_CONFIG=/tmp/evil.conf PAGER=/bin/sh DPKG_PAGER=/bin/sh SHELL=/bin/sh \
	DEBIAN_FRONTEND=readline DPKG_ROOT=/tmp/root TMPDIR=/tmp/x http_proxy=http://x \
	"$WRAPPER" install foo >"$OUT" 2>&1) || rc=$?
if [ "$rc" -ne 0 ] || [ ! -f "$LOG" ]; then
	ko "install under a hostile environment ran" "rc=$rc; $(cat "$OUT")"
else
	if grep -qx 'cwd=/' "$LOG"; then ok "working directory is /"; else ko "working directory is /" "$(grep '^cwd=' "$LOG")"; fi
	if grep -qx 'stdin=/dev/null' "$LOG"; then ok "stdin is /dev/null"; else ko "stdin is /dev/null" "$(grep '^stdin=' "$LOG")"; fi
	want_env=$'env=DEBIAN_FRONTEND=noninteractive\nenv=HOME=/root\nenv=LESSSECURE=1\nenv=PAGER=cat\nenv=PATH=/usr/sbin:/usr/bin:/sbin:/bin'
	# The stub's own shell may export PWD/SHLVL/_; anything else is a leak.
	got_env="$(grep '^env=' "$LOG" | grep -Ev '^env=(PWD|OLDPWD|SHLVL|_)=')"
	if [ "$got_env" = "$want_env" ]; then
		ok "only the wrapper's fixed environment reaches apt-get"
	else
		ko "only the wrapper's fixed environment reaches apt-get" "$got_env"
	fi
fi

printf 'C. config and hook options are refused, however they are spelled\n'
expect_refuse "-o APT::Update::Pre-Invoke::=id" -o 'APT::Update::Pre-Invoke::=id' update
expect_refuse "-o joined to its value" '-oAPT::Update::Pre-Invoke::=id' update
expect_refuse "-o bundled after an allowed flag" -yo 'APT::Update::Pre-Invoke::=id' update
expect_refuse "--option=" '--option=APT::Update::Pre-Invoke::=id' update
expect_refuse "--option <value>" --option 'APT::Update::Pre-Invoke::=id' update
expect_refuse "-c <file>" -c /tmp/evil.conf update
expect_refuse "-c joined to its value" -c/tmp/evil.conf update
expect_refuse "--config-file=" --config-file=/tmp/evil.conf update
expect_refuse "-o placed after the verb" update -o 'APT::Update::Pre-Invoke::=id'
expect_refuse "an option smuggled after --" install -- -o 'APT::Update::Pre-Invoke::=id'
expect_refuse "a value joined to an allowed long flag" --yes=no install foo
expect_refuse "-q with a value" -q=2 update
expect_refuse "-t <release> (takes a value)" -t trixie-backports install foo
expect_refuse "a bare -" - install foo
expect_refuse "two allowed flags in one argument" '--yes --quiet' install foo

printf 'D. local files, paths and URLs are refused as packages\n'
expect_refuse "./local.deb" install ./local.deb
expect_refuse "an absolute .deb path" install /tmp/x.deb
expect_refuse "../x.deb" install ../x.deb
expect_refuse "." install .
expect_refuse "a directory path" install ./build/
expect_refuse "a name that ends in .deb" install foo.deb
expect_refuse "an http URL" install http://example.com/x.deb
expect_refuse "a file: URL" install file:/tmp/x.deb
expect_refuse "a version that is a path" install 'foo=../../tmp/x'
expect_refuse "a release that is a path" install foo/../../tmp/x
expect_refuse "a .dsc file" install ./foo.dsc

printf 'E. flags that weaken authentication are refused\n'
expect_refuse "--allow-unauthenticated" --allow-unauthenticated install foo
expect_refuse "--allow-insecure-repositories" --allow-insecure-repositories update
expect_refuse "--allow-releaseinfo-change" --allow-releaseinfo-change update
expect_refuse "--allow-downgrades" --allow-downgrades install foo
expect_refuse "--force-yes" --force-yes install foo

printf 'F. verbs that page, build from source or are otherwise unlisted are refused\n'
for v in changelog source build-dep download dist-upgrade full-upgrade satisfy check autoclean moo; do
	expect_refuse "$v" "$v" foo
done
expect_refuse "an uppercase verb" INSTALL foo

printf 'G. odd package arguments are refused\n'
expect_refuse "an apt search pattern" install '?name(foo)'
expect_refuse "a ~ pattern" install '~nfoo'
expect_refuse "a glob" install 'foo*'
expect_refuse "an empty argument" install ''
expect_refuse "an uppercase name" install Foo
expect_refuse "a name with a newline" install $'foo\nbar'
expect_refuse "a name with a space" install 'foo bar'
expect_refuse "a name with shell metacharacters" install 'foo;id'
expect_refuse "an overlong argument" install "a$(printf '%0300d' 0)"
expect_refuse "packages after a verb that takes none" update foo
expect_refuse "packages after autoremove" autoremove foo

printf 'H. usage\n'
expect_refuse "no verb at all" -y
run
if [ "$rc" -eq 2 ] && [ ! -f "$LOG" ] && grep -q '^  verbs ' "$OUT"; then ok "no arguments prints the policy and exits 2"; else ko "no arguments" "rc=$rc; $(cat "$OUT")"; fi
run --help
if [ "$rc" -eq 0 ] && [ ! -f "$LOG" ] && grep -q '^  verbs ' "$OUT"; then ok "--help prints the policy and exits 0"; else ko "--help" "rc=$rc; $(cat "$OUT")"; fi
run install $'foo\033[2Jbar'
if grep -q $'\033' "$OUT"; then ko "a refused argument's control characters are not echoed raw"; else ok "a refused argument's control characters are not echoed raw"; fi

printf 'I. the Dockerfile wires sudo to the wrapper, and only through sudo\n'
sudoers_cmds="node ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/shadow-mounts.sh, /usr/local/bin/fix-workspace-perms.sh, $WRAPPER_PATH"
if grep -qF "'$sudoers_cmds'" "$DOCKERFILE"; then
	ok "the sudoers grant names the helpers and the wrapper, not /usr/bin/apt-get"
else
	ko "the sudoers grant names the helpers and the wrapper, not /usr/bin/apt-get" "$(grep -n 'NOPASSWD' "$DOCKERFILE")"
fi
if grep -qF "'Defaults:node secure_path=\"${WRAPPER_PATH%/apt-get}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"'" "$DOCKERFILE"; then
	ok "a node-only secure_path puts the wrapper's directory first"
else
	ko "a node-only secure_path puts the wrapper's directory first" "$(grep -n 'secure_path' "$DOCKERFILE")"
fi
if grep -Eq "^COPY --chmod=755 docker/shared/apt-get-wrapper\.sh $WRAPPER_PATH\$" "$DOCKERFILE"; then
	ok "the wrapper is baked at the granted path"
else
	ko "the wrapper is baked at the granted path" "$(grep -n 'apt-get-wrapper' "$DOCKERFILE")"
fi
if grep -qx 'docker/shared/apt-get-wrapper.sh' "$ROOT_DIR/scripts/base-source-files.txt"; then
	ok "base-source-files.txt lists the wrapper"
else
	ko "base-source-files.txt lists the wrapper"
fi
# Root's PATH must never reach the wrapper, or every build-time `RUN apt-get`
# (including full's local .deb install) would be refused.
leaks="$(grep -rn 'powbox-sudo' "$ROOT_DIR/docker" --include=Dockerfile | grep -Ev 'secure_path=|NOPASSWD|^[^:]*:[0-9]+:COPY ' | grep -v ':[0-9]*:#' || true)"
if [ -z "$leaks" ]; then
	ok "no Dockerfile puts the wrapper's directory anywhere else (PATH, symlinks)"
else
	ko "no Dockerfile puts the wrapper's directory anywhere else (PATH, symlinks)" "$leaks"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
