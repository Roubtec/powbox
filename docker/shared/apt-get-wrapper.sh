#!/bin/bash
# The apt-get that `sudo apt-get` reaches for the node user.
#
# Baked as /usr/local/libexec/powbox-sudo/apt-get. The sudoers entry grants that
# path only, and a node-only secure_path puts its directory first, so `sudo
# apt-get ...` resolves here while root's own PATH (every image build's
# `RUN apt-get`, including a layer set's local .deb install) still reaches
# /usr/bin/apt-get unrestricted. That directory must stay off every PATH.
#
# Unrestricted apt-get as root is a root shell in one command: hook options
# (-o APT::Update::Pre-Invoke::=...), a local .deb's maintainer scripts, a pager.
# This script parses an untrusted caller's arguments as root, so it admits an
# allowlist and nothing else, and hands the real binary only what it approved,
# in a scrubbed environment with no terminal on stdin (dpkg's conffile prompt
# offers a shell). Packages from the configured repositories stay installable;
# their maintainer scripts run as root by design and those repositories are
# trusted. The policy is pinned by scripts/test-apt-get-wrapper.sh.
set -euo pipefail
export LC_ALL=C

readonly APT_GET=/usr/bin/apt-get

VERBS=(update upgrade install remove purge autoremove clean)
PACKAGE_VERBS=(install remove purge)
# Short flags may be bundled (-qy, -qq); none of these letters takes a value.
SHORT_FLAG_RE='^-[yqfs]+$'
LONG_FLAGS=(
	--yes --assume-yes --quiet --simulate --dry-run --fix-broken
	--no-install-recommends --install-recommends --no-install-suggests
	--reinstall --only-upgrade --no-upgrade --purge --auto-remove --autoremove
)
# A Debian package name, optionally :arch, then =version or /release. It must
# start with a letter or digit: apt reads an argument starting with `/` or `.`
# as a local file, and one starting with `?` or `~` as a search pattern.
PACKAGE_RE='^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?(=[A-Za-z0-9][A-Za-z0-9.+~:-]*|/[a-z0-9][A-Za-z0-9.+_-]*)?$'
MAX_ARG_LEN=200

usage() {
	cat <<EOF
sudo apt-get is limited to managing packages from the configured repositories:

  sudo apt-get [flag ...] <verb> [package ...]

  verbs     ${VERBS[*]}
            (only ${PACKAGE_VERBS[*]} take packages)
  flags     -y -q -f -s, also bundled (-qy, -qq), and
            ${LONG_FLAGS[*]}
  packages  a name from the configured repositories, optionally with :arch,
            =version or /release (dotnet-sdk-8.0, foo:amd64, foo/trixie-backports)

Refused: config options (-o, -c), local .deb files, paths and URLs, flags that
weaken signature checks, and every other verb (changelog, source, build-dep,
download, ...). It always runs non-interactively, as if -y were given, and
keeps existing config files. Anything else belongs in the image build (a
layer set) - ask the user.
EOF
}

refuse() {
	printf 'apt-get: refused %s.\n\n' "$1" >&2
	usage >&2
	exit 2
}

member() {
	local needle=$1 item
	shift
	for item in "$@"; do
		[ "$needle" = "$item" ] && return 0
	done
	return 1
}

if [ "$#" -eq 0 ]; then
	usage >&2
	exit 2
fi

flags=()
verb=""
packages=()
for arg in "$@"; do
	if [ "${#arg}" -gt "$MAX_ARG_LEN" ]; then
		refuse "an argument longer than $MAX_ARG_LEN characters"
	fi
	# %q keeps a hostile argument's control characters off the terminal.
	shown="$(printf '%q' "$arg")"
	case "$arg" in
	-h | --help)
		usage
		exit 0
		;;
	--*)
		member "$arg" "${LONG_FLAGS[@]}" || refuse "$shown: not an allowed flag"
		flags+=("$arg")
		;;
	-*)
		[[ $arg =~ $SHORT_FLAG_RE ]] || refuse "$shown: not an allowed flag"
		flags+=("$arg")
		;;
	*)
		if [ -z "$verb" ]; then
			member "$arg" "${VERBS[@]}" || refuse "$shown: not an allowed verb"
			verb=$arg
		elif [[ $arg =~ $PACKAGE_RE ]] && [[ $arg != *.deb && $arg != *.dsc && $arg != *.changes ]]; then
			packages+=("$arg")
		else
			refuse "$shown: not a package name (local files, paths and URLs are not installable this way)"
		fi
		;;
	esac
done

[ -n "$verb" ] || refuse "a command with no verb"
if [ "${#packages[@]}" -gt 0 ] && ! member "$verb" "${PACKAGE_VERBS[@]}"; then
	refuse "$(printf '%q' "${packages[0]}"): $verb takes no packages"
fi

cd /
exec /usr/bin/env -i \
	PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root \
	DEBIAN_FRONTEND=noninteractive \
	PAGER=cat \
	LESSSECURE=1 \
	"$APT_GET" -y \
	-o Dpkg::Options::=--force-confdef \
	-o Dpkg::Options::=--force-confold \
	"${flags[@]}" "$verb" -- "${packages[@]}" </dev/null
