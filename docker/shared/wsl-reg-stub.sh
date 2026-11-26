#!/bin/sh
# Baked as /mnt/c/Windows/System32/reg.exe, the path Claude Code hard-codes for
# reading Windows admin policy (HKLM/HKCU\SOFTWARE\Policies\ClaudeCode) when it
# believes it runs on WSL, which it concludes from any /proc/version naming
# "microsoft", Docker Desktop's WSL2 kernel included (Claude Code 2.1.332).
# While that read goes unanswered, CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS
# stays inert. A container reaches no Windows registry, so every query gets
# reg.exe's answer for an absent key: this text on stderr and exit 1, which
# Claude Code counts as "no policy". A real mount at /mnt/c hides this file.
#
# POWBOX_WSL_REGISTRY_STUB=0 answers as unreadable instead. Exit 1 without the
# not-found text gets the verdict Claude Code gives a missing reg.exe
# (unanswered, not expected to pass on a later query), and an empty stderr keeps
# it from re-querying the parent keys, so the waiver fails closed as it would
# without the stub.
if [ "${POWBOX_WSL_REGISTRY_STUB-}" = 0 ]; then
	exit 1
fi
echo 'ERROR: The system was unable to find the specified registry key or value.' >&2
exit 1
