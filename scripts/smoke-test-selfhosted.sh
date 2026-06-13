#!/usr/bin/env bash
set -euo pipefail

# Smoke-test the self-hosted ("--isolated") launch mode. Two stages:
#
#   Stage A — launcher identity. Drives scripts/launch-agent.sh with the
#   POWBOX_PRINT_IDENTITY hook (which resolves names and exits before any Docker
#   call), so it runs ANYWHERE — no image, no daemon, no network. It asserts the
#   naming contract: dir-mounted is byte-for-byte unchanged; a --name is
#   deterministic (so a relaunch re-attaches the same workspace path → same Claude
#   session slug); an unnamed launch is fresh each time; the repo-slug strips .git
#   and lowercases; and the per-mode volume set is correct.
#
#   Stage B — entrypoint clone behavior, exercised against the agent IMAGE
#   (default powbox-agent:latest). It runs the baked seed-workspace.sh directly
#   (--entrypoint, bypassing the firewall/podman setup) to check clone-on-first-run,
#   reuse-skips-clone, --reclone, and the loud unauthenticated-clone announcement,
#   plus the single-mount hardlink invariant the one-volume layout relies on. It
#   needs the image and network, so it SELF-SKIPS when the image is absent (e.g. a
#   launcher-only checkout) rather than failing. Skip it explicitly with
#   POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="${ROOT_DIR}/scripts/launch-agent.sh"
IMAGE="${1:-powbox-agent:latest}"
# A tiny, stable public repo — no gh auth needed to clone it.
PUBLIC_REPO="${POWBOX_SMOKE_PUBLIC_REPO:-https://github.com/octocat/Hello-World.git}"

pass=0
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
ok() {
	pass=$((pass + 1))
	echo "  ok: $*"
}

# Read one key=value field out of a POWBOX_PRINT_IDENTITY block.
id_field() {
	# $1 = full identity output, $2 = key
	printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# SHA256(input)[:12] using the SAME command-fallback chain as launch-agent.sh's
# project_hash, so the expected hash is computed identically to the launcher's on
# every supported host — including macOS (shasum, no sha256sum) and any host that
# only ships openssl. Mirrors the launcher rather than hard-requiring sha256sum,
# which made Stage A die under `set -euo pipefail` before it could run.
project_hash() {
	local input="${1:-}"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum | cut -c1-12
	elif command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 | cut -c1-12
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s' "$input" | openssl dgst -sha256 | sed 's/^.* //' | cut -c1-12
	else
		fail "no hashing command found (need sha256sum, shasum, or openssl)"
	fi
}

echo "Self-hosted smoke test (launcher: $LAUNCHER)"
echo "Stage A — launcher identity (no image/daemon needed)"

# --- dir-mounted is unchanged: hash == SHA256(canonical path)[:12] -------------
DM="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude "$ROOT_DIR" 2>/dev/null)"
[ "$(id_field "$DM" mode)" = "dir-mounted" ] || fail "default mode is not dir-mounted"
# Mirror the launcher's dir-mounted hash input exactly: it lowercases the path
# before hashing on Windows (MSYS/Cygwin), where the FS is case-insensitive, and
# preserves it as-is elsewhere. Without this the expected hash would diverge from
# the launcher's on Git Bash/MSYS and the contract check would falsely fail.
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) hash_input="$(printf '%s' "$ROOT_DIR" | tr '[:upper:]' '[:lower:]')" ;;
*) hash_input="$ROOT_DIR" ;;
esac
want_hash="$(project_hash "$hash_input")"
case "$(id_field "$DM" CONTAINER_NAME)" in
*"-$want_hash") ok "dir-mounted hash matches SHA256(path)[:12]" ;;
*) fail "dir-mounted hash changed (want suffix -$want_hash): $(id_field "$DM" CONTAINER_NAME)" ;;
esac
[ -n "$(id_field "$DM" NM_VOLUME)" ] || fail "dir-mounted is missing NM_VOLUME"
[ -n "$(id_field "$DM" WT_VOLUME)" ] || fail "dir-mounted is missing WT_VOLUME"
[ -z "$(id_field "$DM" WS_VOLUME)" ] || fail "dir-mounted must not have a WS_VOLUME"
ok "dir-mounted has nm/wt volumes and no ws volume"

# --- named → deterministic (same identity twice) ------------------------------
N1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/Repo.git --name foo 2>/dev/null)"
N2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/Repo.git --name foo 2>/dev/null)"
[ "$(id_field "$N1" mode)" = "isolated" ] || fail "--isolated did not select isolated mode"
[ "$(id_field "$N1" CONTAINER_NAME)" = "$(id_field "$N2" CONTAINER_NAME)" ] ||
	fail "named instance is not deterministic across launches"
[ "$(id_field "$N1" WORKSPACE_MOUNT)" = "$(id_field "$N2" WORKSPACE_MOUNT)" ] ||
	fail "named instance workspace path (→ Claude session slug) is not stable"
ok "named instance is deterministic (same workspace path / session slug on relaunch)"

# --- named identity is PER-REPO: same --name on a different repo must not collide
# Two remotes that share a basename (owner1/app, owner2/app) launched with the same
# --name must resolve to DISTINCT identities; otherwise the second launch would
# attach to (or --reclone wipe) the first repo's container/workspace.
P1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner1/app --name shared 2>/dev/null)"
P2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner2/app --name shared 2>/dev/null)"
[ "$(id_field "$P1" CONTAINER_NAME)" != "$(id_field "$P2" CONTAINER_NAME)" ] ||
	fail "two repos sharing a basename collide under the same --name"
[ "$(id_field "$P1" WORKSPACE_MOUNT)" != "$(id_field "$P2" WORKSPACE_MOUNT)" ] ||
	fail "two repos sharing a basename share a workspace path under the same --name"
ok "named identity is per-repo (owner1/app vs owner2/app, same --name, differ)"

# ... while the SAME repo expressed different ways (slug vs full https URL) under
# the same --name stays stable, so reuse is not broken by spec form.
S1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/app --name stable 2>/dev/null)"
S2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo https://github.com/owner/app.git --name stable 2>/dev/null)"
[ "$(id_field "$S1" CONTAINER_NAME)" = "$(id_field "$S2" CONTAINER_NAME)" ] ||
	fail "same repo via slug vs https URL produced different identities under the same --name"
ok "named identity is spec-form stable (owner/app == https://github.com/owner/app.git)"

# repo-slug: .git stripped, lowercased.
case "$(id_field "$N1" PROJECT_NAME)" in
repo-*) ok "repo-slug strips .git and lowercases (Repo.git → repo)" ;;
*) fail "repo-slug derivation wrong: $(id_field "$N1" PROJECT_NAME)" ;;
esac
[ "$(id_field "$N1" WS_VOLUME)" = "agent-ws-$(id_field "$N1" CONTAINER_NAME)" ] ||
	fail "WS_VOLUME is not agent-ws-<container>"
if [ -n "$(id_field "$N1" NM_VOLUME)" ] || [ -n "$(id_field "$N1" WT_VOLUME)" ]; then
	fail "isolated mode must not create nm/wt volumes"
fi
ok "isolated has agent-ws-<container> and no nm/wt volumes"

# --- unnamed → fresh every launch ---------------------------------------------
U1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/repo 2>/dev/null)"
U2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/repo 2>/dev/null)"
[ "$(id_field "$U1" CONTAINER_NAME)" != "$(id_field "$U2" CONTAINER_NAME)" ] ||
	fail "unnamed instances collided (should be fresh each launch)"
ok "unnamed instances are fresh each launch"

# --- self-hosted-only flags require --isolated --------------------------------
if POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --name foo >/dev/null 2>&1; then
	fail "--name without --isolated should error"
fi
ok "self-hosted-only flags are rejected without --isolated"

echo "Stage A passed ($pass checks)."

# --- Stage B — clone behavior against the image -------------------------------
if [ -n "${POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE:-}" ]; then
	echo "Stage B skipped (POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE is set)."
	echo "Self-hosted smoke test passed (Stage A only)."
	exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Stage B skipped: image '$IMAGE' not found (build it to exercise the clone path)."
	echo "Self-hosted smoke test passed (Stage A only)."
	exit 0
fi

echo "Stage B — entrypoint clone behavior against $IMAGE"
WSVOL="powbox-smoke-ws-$$"
HV1="powbox-smoke-hl-a-$$"
HV2="powbox-smoke-hl-b-$$"
cleanup() {
	docker volume rm -f "$WSVOL" "$HV1" "$HV2" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker volume create "$WSVOL" >/dev/null

run_seed() { # extra docker env... -> runs seed-workspace.sh as root over $WSVOL
	docker run --rm --user root \
		-e POWBOX_SELF_HOSTED=1 \
		-e POWBOX_WORKSPACE_DIR=/ws \
		-e GH_TOKEN= -e GITHUB_TOKEN= \
		"$@" \
		-v "${WSVOL}:/ws" \
		--entrypoint /usr/local/bin/seed-workspace.sh \
		"$IMAGE"
}

# clone-on-first-run
run_seed -e "POWBOX_CLONE_REPO=${PUBLIC_REPO}" >/dev/null 2>&1 ||
	fail "clone-on-first-run failed for $PUBLIC_REPO"
docker run --rm -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" -c '[ -e /ws/.git ]' ||
	fail "clone-on-first-run did not produce a .git"
ok "clone-on-first-run produced a checkout"

# reuse-skips-clone: a marker dropped in the tree must survive a second run
docker run --rm --user root -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" -c 'touch /ws/SMOKE_MARKER'
reuse_out="$(run_seed -e "POWBOX_CLONE_REPO=${PUBLIC_REPO}" 2>&1 || true)"
printf '%s' "$reuse_out" | grep -q "skipping clone" || fail "reuse did not skip the clone"
docker run --rm -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" -c '[ -e /ws/SMOKE_MARKER ]' ||
	fail "reuse re-cloned (marker was wiped)"
ok "reuse skips the clone and preserves the working tree"

# --reclone is a one-shot launcher action: it empties the (kept) volume, then the
# entrypoint clones fresh. Simulate the launcher's prep wipe, then re-seed; the
# marker must be gone and a new .git present.
docker run --rm --user root -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" \
	-c 'find /ws -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; true'
run_seed -e "POWBOX_CLONE_REPO=${PUBLIC_REPO}" >/dev/null 2>&1 ||
	fail "re-clone after a --reclone wipe failed"
docker run --rm -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" -c '[ ! -e /ws/SMOKE_MARKER ] && [ -e /ws/.git ]' ||
	fail "--reclone wipe + re-clone did not produce a clean checkout"
ok "--reclone (launcher empties the volume) yields a fresh clone"

# unauthenticated/failed clone → loud announcement + non-zero exit
docker volume create "${WSVOL}-fail" >/dev/null
set +e
fail_out="$(docker run --rm --user root \
	-e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws \
	-e GH_TOKEN= -e GITHUB_TOKEN= \
	-e "POWBOX_CLONE_REPO=this-org-does-not-exist-zzz/nope-9999" \
	-v "${WSVOL}-fail:/ws" \
	--entrypoint /usr/local/bin/seed-workspace.sh "$IMAGE" 2>&1)"
fail_rc=$?
set -e
docker volume rm -f "${WSVOL}-fail" >/dev/null 2>&1 || true
[ "$fail_rc" -ne 0 ] || fail "a failed clone should exit non-zero"
printf '%s' "$fail_out" | grep -q "POWBOX SELF-HOSTED CLONE FAILED" ||
	fail "a failed clone did not print the loud announcement"
printf '%s' "$fail_out" | grep -q "gh auth login" ||
	fail "the announcement is missing the gh-auth remedy"
ok "a failed clone announces loudly and exits non-zero"

# Single-mount hardlink invariant: within ONE volume (store + node_modules as
# subdirs, the self-hosted layout) link(2) succeeds; ACROSS two volumes it EXDEVs
# (the dir-mounted root-node_modules case the one-volume layout fixes).
docker volume create "$HV1" >/dev/null
docker volume create "$HV2" >/dev/null
docker run --rm -v "${HV1}:/ws" --entrypoint /bin/sh "$IMAGE" -c '
set -e
mkdir -p /ws/.worktrees/.pnpm-store /ws/node_modules /ws/.worktrees/task/node_modules
echo pkg > /ws/.worktrees/.pnpm-store/f
ln /ws/.worktrees/.pnpm-store/f /ws/node_modules/f
ln /ws/.worktrees/.pnpm-store/f /ws/.worktrees/task/node_modules/f
[ "$(stat -c %h /ws/.worktrees/.pnpm-store/f)" -ge 3 ]' ||
	fail "hardlink within one workspace volume failed (root + worktree node_modules)"
ok "store hardlinks into BOTH the root and a worktree node_modules (one mount)"
docker run --rm -v "${HV1}:/store" -v "${HV2}:/nm" --entrypoint /bin/sh "$IMAGE" -c '
echo x > /store/g
if ln /store/g /nm/g 2>/dev/null; then exit 1; fi
exit 0' ||
	fail "cross-volume hardlink unexpectedly succeeded (EXDEV invariant broken)"
ok "cross-mount hardlink EXDEVs (confirms why dir-mounted root node_modules copies)"

echo "Stage B passed."
echo "Self-hosted smoke test passed."
