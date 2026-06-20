#!/usr/bin/env bash
set -euo pipefail

# The agent image is unified: both claude and codex (and codex's bwrap sandbox)
# are baked into the same image alongside the shared toolchain, so one smoke
# test validates everything in a single pass.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE="${1:-powbox-agent:latest}"

# The image-gated checks in stages 1–3 (and Stage 4's clone behavior) need the
# agent image; Stage 4's self-hosted identity contract runs without it. Detect
# the image once up front so a missing one is reported clearly here rather than
# as a raw docker error at Stage 1. POWBOX_SMOKE_REQUIRE_IMAGE=1 (used by CI)
# turns an absent image into a hard error before any stage runs; it is also
# exported so a sub-script invoked directly (e.g. the self-hosted clone stage)
# fails instead of self-skipping its image-gated checks into a false "all green".
# Track every stage we skip so the end-of-run banner can report a partial run.
skipped=()
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	if [ -n "${POWBOX_SMOKE_REQUIRE_IMAGE:-}" ]; then
		echo "ERROR: image '$IMAGE' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set — refusing to run a partial (image-skipping) smoke test." >&2
		echo "       Build it first (./build.sh agent) or unset POWBOX_SMOKE_REQUIRE_IMAGE." >&2
		exit 1
	fi
	echo "WARNING: image '$IMAGE' not found — the image-gated stages need it. Stage 1 will fail and abort the run before any later stage (Stages 2–5) runs, so you get no partial coverage."
	echo "         Build it (./build.sh agent), or set POWBOX_SMOKE_REQUIRE_IMAGE=1 to fail fast here with a clear message instead of a raw docker error at Stage 1."
fi
export POWBOX_SMOKE_REQUIRE_IMAGE

# Stage 1 — tool presence + key image config: every expected CLI resolves and
# runs, and pnpm ships package-import-method=auto (not the old forced copy) so
# worktree installs can hardlink from a co-located store.
"${ROOT_DIR}/scripts/smoke-test-image.sh" "$IMAGE" \
	"claude --version >/dev/null" \
	"codex --version >/dev/null" \
	"bwrap --version >/dev/null" \
	"gh --version >/dev/null" \
	"node --version >/dev/null" \
	"npm --version >/dev/null" \
	"pnpm --version >/dev/null" \
	"pnpm config get package-import-method | grep -qx auto" \
	"pip3 --version >/dev/null" \
	"python3 --version >/dev/null" \
	"sqlcmd -? >/dev/null" \
	"sqlite3 --version >/dev/null" \
	"psql --version >/dev/null" \
	"pg-dev-up check >/dev/null" \
	"command -v wt-bootstrap >/dev/null" \
	"command -v wt-enter >/dev/null" \
	"command -v wt-remove >/dev/null" \
	"shellcheck --version >/dev/null" \
	"ping -V >/dev/null" \
	"nc -h >/dev/null 2>&1" \
	"bc --version >/dev/null" \
	"less --version >/dev/null" \
	"lsof -v >/dev/null 2>&1" \
	"tree --version >/dev/null" \
	"fd --version >/dev/null" \
	"fzf --version >/dev/null" \
	"bat --version >/dev/null" \
	"ssh -V >/dev/null 2>&1" \
	"rsync --version >/dev/null" \
	"strace -V >/dev/null" \
	"gpg --version >/dev/null" \
	"gcc --version >/dev/null" \
	"file --version >/dev/null" \
	"printf test | xxd >/dev/null" \
	"envsubst --version >/dev/null" \
	"yq --version >/dev/null" \
	"shfmt --version >/dev/null" \
	"unzip -v >/dev/null" \
	"zip -v >/dev/null" \
	"wget --version >/dev/null" \
	"htop --version >/dev/null"

# Stage 2 — pg-dev-up functional test: stand up a real throwaway cluster and
# connect through the emitted DATABASE_URL. Unlike `pg-dev-up check` (binary
# presence only) this exercises role/db creation, URL percent-encoding, the
# 127.0.0.1 host binding, and the eval round-trip. Deliberately nasty
# credentials prove the SQL-quoting and URL-encoding paths. Skip the daemon
# bring-up with POWBOX_SMOKE_SKIP_DB=1 (Stage 3 below still runs unless
# POWBOX_SMOKE_SKIP_PODMAN is also set; set both for a Stage 1 presence-only run).
if [ -n "${POWBOX_SMOKE_SKIP_DB:-}" ]; then
	echo "Skipping pg-dev-up functional test (POWBOX_SMOKE_SKIP_DB is set)."
	skipped+=("Stage 2: pg-dev-up functional (POWBOX_SMOKE_SKIP_DB)")
else
	echo "Running pg-dev-up functional test against $IMAGE ..."
	docker run --rm \
		-e POSTGRES_USER=t \
		-e POSTGRES_PASSWORD='p@s/s&w#d' \
		-e POSTGRES_DB=app \
		--entrypoint /bin/sh "$IMAGE" -lc '
set -e
pg-dev-up up >/dev/null
url=$(pg-dev-up url)
echo "DATABASE_URL=$url"
printf %s "$url" | grep -qF "p%40s%2Fs%26w%23d" || { echo "FAIL: password not percent-encoded in URL" >&2; exit 1; }
printf %s "$url" | grep -qF "@127.0.0.1:" || { echo "FAIL: URL host is not 127.0.0.1" >&2; exit 1; }
eval "$(pg-dev-up url --export)"
out=$(psql "$DATABASE_URL" -tAc "SELECT current_user, current_database()")
echo "psql SELECT -> $out"
printf %s "$out" | grep -qxF "t|app" || { echo "FAIL: unexpected psql result: $out" >&2; exit 1; }
pg-dev-up down >/dev/null
'
	echo "pg-dev-up functional test passed."
fi

# Stage 3 — rootless Podman engine: the agent image bakes podman + a docker shim
# (docs/rootless-podman.md). This is the automated guard that follow-up asked for —
# a base/Podman bump that regresses the engine (a dropped containers.conf drop-in,
# a Podman without the `compose` subcommand, a nested run that no longer starts) is
# caught here. The helper runs the image with the launch-time device + security
# wiring the launcher normally supplies via the compose overlays. On a host that
# cannot expose /dev/net/tun it still validates the static engine wiring and skips
# only the nested-run checks; a genuinely broken image fails on any host. Skip the
# whole stage explicitly with POWBOX_SMOKE_SKIP_PODMAN=1; see
# scripts/smoke-test-podman.sh for what it covers.
if [ -n "${POWBOX_SMOKE_SKIP_PODMAN:-}" ]; then
	echo "Skipping Podman smoke test (POWBOX_SMOKE_SKIP_PODMAN is set)."
	skipped+=("Stage 3: rootless Podman engine (POWBOX_SMOKE_SKIP_PODMAN)")
else
	# smoke-test-podman.sh also treats POWBOX_PODMAN=off (deprecated alias
	# POWBOX_FUSE=off) as a whole-stage skip and exits 0 with its own notice; and
	# under auto (the default) on a host without /dev/net/tun it runs the static
	# engine checks but exits 0 after self-skipping the nested-run + published-port
	# checks (e.g. Docker Desktop / a hosted runner with no tun device). Mirror both
	# gates so the banner records the partial run instead of claiming all stages ran
	# — the child evaluates the same host /dev/net/tun condition before its docker
	# run, so the two agree. The child still prints the skip message; we track it here.
	podman_gate="${POWBOX_PODMAN:-${POWBOX_FUSE:-auto}}"
	"${ROOT_DIR}/scripts/smoke-test-podman.sh" "$IMAGE"
	if [ "$podman_gate" = "off" ]; then
		skipped+=("Stage 3: rootless Podman engine (POWBOX_PODMAN=off)")
	elif [ "$podman_gate" != "on" ] && [ ! -e /dev/net/tun ]; then
		skipped+=("Stage 3: rootless Podman nested-run checks (no /dev/net/tun)")
	fi
fi

# Stage 4 - self-hosted ("--isolated") launch mode. Validates the launcher's
# self-hosted identity contract (always, no image needed) and the baked
# seed-workspace.sh clone/reuse/reclone/failure + single-mount hardlink behavior
# against the image (self-skips when the image is absent). Skip the whole stage
# with POWBOX_SMOKE_SKIP_SELFHOSTED=1; see scripts/smoke-test-selfhosted.sh.
if [ -n "${POWBOX_SMOKE_SKIP_SELFHOSTED:-}" ]; then
	echo "Skipping self-hosted smoke test (POWBOX_SMOKE_SKIP_SELFHOSTED is set)."
	skipped+=("Stage 4: self-hosted launch mode (POWBOX_SMOKE_SKIP_SELFHOSTED)")
else
	"${ROOT_DIR}/scripts/smoke-test-selfhosted.sh" "$IMAGE"
	# POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1 runs Stage A (launcher identity) but skips
	# Stage B (clone behavior) inside the child, which still exits 0. Record that
	# partial coverage so the banner does not claim all stages ran.
	if [ -n "${POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE:-}" ]; then
		skipped+=("Stage 4: self-hosted clone behavior (POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE)")
	fi
fi

# Stage 5 - native-Linux dir-mount ownership. A bind-mounted root-owned repo is
# root:root inside the container, which the node agent (uid 1000) cannot write;
# entrypoint-core.sh's write probe + the sudo-allowlisted fix-workspace-perms.sh
# helper (PR #55) chown it to node so git/edits work. This stage runs two cases: the
# all-root-owned mount (PR #55) and a mixed-ownership mount (task 007) — a node-owned
# root that hides nested root-owned files from a host `sudo git pull` that the helper's
# uid-0 re-own heals. The all-root case (task 005a) drives the GENUINE extracted entrypoint
# decision unit heal-workspace-perms.sh — the byte-for-byte probe-and-call code
# entrypoint-core.sh runs — so it guards the probe/decision path (does the probe still detect
# the unwritable mount and hand it to the helper?), not only the helper; that unit still
# ultimately invokes fix-workspace-perms.sh by the same allowlisted path/sudo mechanism, so
# the in-isolation helper + sudoers coverage is preserved. The mixed case still invokes
# fix-workspace-perms.sh DIRECTLY in isolation; converting it to the same decision unit is
# tracked in tasks/007a. Neither case boots the full entrypoint chain (firewall/gh/shadow need
# the launcher's compose wiring, out of scope here). It asserts node can
# write + git-commit each after the fix. It self-skips (exit 0) when the image is absent (honouring
# POWBOX_SMOKE_REQUIRE_IMAGE), when it cannot create a root-owned fixture (no root /
# passwordless sudo — the local-dev case; it runs for real on a CI runner), or when
# the host masks the native-Linux uid bug. Skip the whole stage with
# POWBOX_SMOKE_SKIP_DIRMOUNT=1; see scripts/smoke-test-dirmount.sh.
if [ -n "${POWBOX_SMOKE_SKIP_DIRMOUNT:-}" ]; then
	echo "Skipping dir-mount ownership smoke test (POWBOX_SMOKE_SKIP_DIRMOUNT is set)."
	skipped+=("Stage 5: dir-mount ownership (POWBOX_SMOKE_SKIP_DIRMOUNT)")
else
	# The child still exits 0 when it self-skips at runtime (non-Linux host, no
	# root/passwordless sudo, or a host that masks the uid bug), so its exit code
	# alone cannot distinguish a real pass from a skip. Hand it a marker file: it
	# records the skip reason there and we surface it in the banner below, so a
	# partial run is not reported as "all stages ran". An empty marker means the
	# stage actually ran.
	dirmount_marker="$(mktemp "${TMPDIR:-/tmp}/powbox-smoke-dirmount-skip.XXXXXX")"
	POWBOX_SMOKE_SKIP_MARKER="$dirmount_marker" "${ROOT_DIR}/scripts/smoke-test-dirmount.sh" "$IMAGE"
	if [ -s "$dirmount_marker" ]; then
		skipped+=("Stage 5: dir-mount ownership ($(cat "$dirmount_marker"))")
	fi
	rm -f "$dirmount_marker"
fi

if [ "${#skipped[@]}" -gt 0 ]; then
	echo
	echo "================ SMOKE TEST: STAGES SKIPPED ================"
	for s in "${skipped[@]}"; do
		echo "  - $s"
	done
	echo "This was a PARTIAL smoke test — the stages above did not run."
	echo "For a full run (e.g. in CI) unset the POWBOX_SMOKE_SKIP_* vars; set"
	echo "POWBOX_SMOKE_REQUIRE_IMAGE=1 to also fail on a missing image."
	echo "==========================================================="
else
	echo "Smoke test complete (all stages ran)."
fi
