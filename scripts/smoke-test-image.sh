#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: smoke-test-image.sh <image> <primary-command> [extra command ...]}"
shift

if [ "$#" -eq 0 ]; then
	echo "At least one command must be provided for smoke testing." >&2
	exit 1
fi

SCRIPT=$'set -e\n'
for cmd in "$@"; do
	SCRIPT+="${cmd}"$'\n'
done

echo "Smoke testing image: $IMAGE"
docker run --rm --entrypoint /bin/sh "$IMAGE" -lc "$SCRIPT"
echo "Smoke test passed: all expected CLI tools were found."
