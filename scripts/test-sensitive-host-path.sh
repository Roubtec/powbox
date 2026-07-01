#!/usr/bin/env bash
set -euo pipefail

# Unit test for docker/shared/sensitive-host-path.sh — the shared predicate that stops
# the workspace-perms heal from recursively chowning a mount whose HOST source is a
# system or home directory (the VPS-lockout incident: a `cc`/`cx` run from ~ re-owning
# the whole home tree to node and breaking sshd's StrictModes chain on ~/.ssh).
#
# Hermetic and host-independent: it sources the library and drives both functions
# directly (powbox_mountinfo_host_src is pointed at a synthetic mountinfo file via its
# 2nd arg), so it needs no Docker, no root, and no native-Linux host. Wired into
# commands/smoke-test.sh as an early stage and runnable on its own.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB="${ROOT_DIR}/docker/shared/sensitive-host-path.sh"

# shellcheck source=docker/shared/sensitive-host-path.sh
. "$LIB"

fails=0
checks=0

# expect_sensitive <0|1> <path> [home] — assert the predicate's classification.
expect_sensitive() {
	local want="$1" path="$2" home="${3:-}"
	checks=$((checks + 1))
	if powbox_is_sensitive_host_path "$path" "$home"; then
		local got=0
	else
		local got=1
	fi
	if [ "$got" != "$want" ]; then
		printf 'FAIL: powbox_is_sensitive_host_path %q %q -> %s, expected %s\n' \
			"$path" "$home" \
			"$([ "$got" = 0 ] && echo sensitive || echo ok)" \
			"$([ "$want" = 0 ] && echo sensitive || echo ok)" >&2
		fails=$((fails + 1))
	fi
}

# 0 = sensitive (must NOT be chowned); 1 = ok (a genuine project, heal normally).

# --- the filesystem root + bare system/home roots (sensitive) -----------------
for p in / /root /home /Users /etc /usr /var /opt /srv /boot /bin /sbin \
	/lib /lib32 /lib64 /libx32 /dev /proc /sys /run /mnt /media /tmp /lost+found; do
	expect_sensitive 0 "$p"
done
# Trailing slash must normalise to the same classification.
expect_sensitive 0 /root/
expect_sensitive 0 /home/
expect_sensitive 0 /etc/

# --- user home directories: exactly one level under /home or /Users (sensitive)
expect_sensitive 0 /home/alice
expect_sensitive 0 /home/alice/
expect_sensitive 0 /Users/bob
expect_sensitive 0 "/home/john.doe"
expect_sensitive 0 "/home/has space" # one component even with a space → still a home

# --- genuine project checkouts NESTED under those roots (ok) ------------------
expect_sensitive 1 /home/alice/code/app
expect_sensitive 1 /home/alice/myrepo
expect_sensitive 1 /Users/bob/dev/site
expect_sensitive 1 /opt/app
expect_sensitive 1 /srv/www/site
expect_sensitive 1 /var/www/html
expect_sensitive 1 /mnt/data/repo
expect_sensitive 1 /workspace/proj-1234
expect_sensitive 1 /tmp/powbox-dirmount-XXXXXX # the dir-mount smoke's own fixture path
expect_sensitive 1 /code/myrepo                # a depth-1 NON-system dir is fine
expect_sensitive 1 /projects

# --- SSH config directories are sensitive at ANY depth: chowning just ~/.ssh (and its
#     authorized_keys) to node trips sshd StrictModes and locks the user out even while the
#     home dir stays root-owned. Matched on every mount layout — /root/.ssh, /home/alice/.ssh,
#     and the shallow /alice/.ssh a separate-/home bind reads field 4 back as. --------------
expect_sensitive 0 /root/.ssh
expect_sensitive 0 /home/alice/.ssh
expect_sensitive 0 /home/alice/.ssh/ # trailing slash normalises the same
expect_sensitive 0 /alice/.ssh       # separate-/home layout: field 4 reads back shallow
expect_sensitive 0 /.ssh
# ... but a sibling/lookalike that is not itself a .ssh dir stays ok.
expect_sensitive 1 /home/alice/.sshfoo
expect_sensitive 1 /home/alice/code/.ssh-notes

# --- empty / unknown path is not classified sensitive (caller treats as unknown)
expect_sensitive 1 ""

# --- caller-supplied home dir (launcher forwards $HOME): a home at a non-standard
#     location is caught even though it is not under /home or /Users ---------------
expect_sensitive 0 /var/services/homes/bob /var/services/homes/bob
expect_sensitive 0 /srv/users/jo/ /srv/users/jo
# ... but a project NESTED under that home is still ok.
expect_sensitive 1 /var/services/homes/bob/app /var/services/homes/bob
# An empty/"/" home must not turn every path sensitive.
expect_sensitive 1 /home/alice/app ""
expect_sensitive 1 /code/myrepo /

# --- powbox_mountinfo_host_src: field-4 lookup keyed on the field-5 mountpoint ----
mi="$(mktemp "${TMPDIR:-/tmp}/powbox-mi.XXXXXX")"
trap 'rm -f "$mi"' EXIT
cat >"$mi" <<'EOF'
889 879 0:81 /root /workspace/root-abc rw,noatime - 9p host rw
896 889 8:48 /data/docker/volumes/agent-nm/_data /workspace/root-abc/node_modules rw - ext4 /dev/sdd rw
900 889 8:48 /home/alice/app /workspace/app-def rw - ext4 /dev/sdd rw
901 889 8:48 /home/has\040space /workspace/space-ghi rw - ext4 /dev/sdd rw
902 889 8:48 /opt/we\134ird /workspace/bs-jkl rw - ext4 /dev/sdd rw
EOF

assert_eq() {
	checks=$((checks + 1))
	if [ "$2" != "$3" ]; then
		printf 'FAIL: %s -> %q, expected %q\n' "$1" "$2" "$3" >&2
		fails=$((fails + 1))
	fi
}

assert_eq "host_src(/workspace/root-abc)" \
	"$(powbox_mountinfo_host_src /workspace/root-abc "$mi")" "/root"
assert_eq "host_src(/workspace/app-def)" \
	"$(powbox_mountinfo_host_src /workspace/app-def "$mi")" "/home/alice/app"
assert_eq "host_src(nested node_modules)" \
	"$(powbox_mountinfo_host_src /workspace/root-abc/node_modules "$mi")" "/data/docker/volumes/agent-nm/_data"
assert_eq "host_src(no such mountpoint)" \
	"$(powbox_mountinfo_host_src /workspace/missing "$mi")" ""
assert_eq "host_src(empty arg)" \
	"$(powbox_mountinfo_host_src "" "$mi")" ""
# The kernel octal-escapes space/tab/newline/backslash in mountinfo's source field; the
# lookup must DECODE them back to the real host path, else a sensitive home/system dir
# whose name carries one of those bytes slips past the predicate (and the warnings print
# gibberish). \040 → space; \134 → backslash, consumed as one escape (not re-expanded
# together with the trailing "ird").
assert_eq "host_src(escaped space decodes)" \
	"$(powbox_mountinfo_host_src /workspace/space-ghi "$mi")" "/home/has space"
assert_eq "host_src(escaped backslash decodes)" \
	"$(powbox_mountinfo_host_src /workspace/bs-jkl "$mi")" '/opt/we\ird'

# End-to-end: the source resolved from mountinfo feeds the sensitivity predicate.
expect_sensitive 0 "$(powbox_mountinfo_host_src /workspace/root-abc "$mi")"  # /root → sensitive
expect_sensitive 1 "$(powbox_mountinfo_host_src /workspace/app-def "$mi")"   # /home/alice/app → nested project, ok
expect_sensitive 0 "$(powbox_mountinfo_host_src /workspace/space-ghi "$mi")" # /home/has space → home dir (decoded), sensitive
expect_sensitive 1 "$(powbox_mountinfo_host_src /workspace/bs-jkl "$mi")"    # /opt/we\ird → nested under /opt, ok

if [ "$fails" -ne 0 ]; then
	echo "sensitive-host-path unit test: $fails/$checks checks FAILED." >&2
	exit 1
fi
echo "sensitive-host-path unit test passed ($checks checks)."
