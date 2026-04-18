# Task: Add auto-resume for Codex sessions (mirror of Claude's --continue)

## Context

Commit `8a0c01b` on branch `fix-resume` added an auto-resume mechanism for Claude: the launcher passes `--continue` by default, but only when a prior session exists for the current working directory. The check is a `sh -c` pre-flight inside the container that inspects `~/.claude/projects/<slug>/*.jsonl`, where `<slug>` is `$PWD` with every non-alphanumeric, non-dash character replaced by `-` (verified empirically). Without that check, `claude --continue` exits with "No conversation found" in a never-before-touched workspace.

The goal here is the equivalent feature for Codex.

## What we know from Codex docs

- `codex resume --last` resumes the most recent session from the current working directory ([ref](https://developers.openai.com/codex/cli/reference)).
- `codex resume` without args launches an interactive picker (not what we want as a default).
- Transcripts are JSONL, keyed by working directory, but the on-disk path and slug format are **not documented**.

## What we don't know (must verify empirically in a Codex container)

1. **Does `codex resume --last` fail hard** in a workspace with no history (like `claude --continue` does), or does it fall back to a fresh session gracefully? If it falls back gracefully, a pre-flight check is unnecessary and we can just pass `--last` unconditionally.
2. **Where does Codex store session transcripts on disk?** Likely under `~/.codex/` somewhere — inspect the directory tree after starting one session, and diff after starting another in a different cwd.
3. **What is Codex's slug/encoding rule** for mapping a cwd to a transcript directory? Test with cwds containing `.`, `_`, space, `+`, `--`, uppercase — the same matrix used for Claude. Document the rule in a comment next to the check.

## How to verify (inside a Codex container)

The technique that worked for Claude was to run the CLI in non-interactive mode from throwaway directories and diff the transcript directory listing before/after. Adapt for Codex — something like:

```sh
mkdir -p /tmp/test-specials && cd /tmp/test-specials
for d in "has spaces" "has.dot" "has_underscore" "has+plus" "UPPER" "with--dashes"; do
  mkdir -p "$d" && cd "$d"
  # capture transcript dir listing before
  find ~/.codex -type d > /tmp/before    # adjust path once you know where it is
  # whatever the Codex equivalent of `claude --print "hi"` is — codex exec? a one-shot flag?
  codex exec "hi" >/dev/null 2>&1
  find ~/.codex -type d > /tmp/after
  diff /tmp/before /tmp/after
  cd /tmp/test-specials
done
rm -rf /tmp/test-specials
# don't forget to delete the test entries from ~/.codex afterwards
```

Keep the prompts trivial ("hi") — each run should cost near-zero tokens. The goal is to observe the *directory name Codex chooses*, not to get a useful response.

Then test the no-history failure mode: `cd /tmp/fresh-empty-dir && codex resume --last` and see what happens (clean exit? fall-through? error message? non-zero exit code?).

## What to implement

In both `scripts/launch-agent.sh` and `scripts/launch-agent.ps1`, the Codex branch currently launches with:

```
codex --dangerously-bypass-approvals-and-sandbox
```

If `codex resume --last` gracefully falls back to a fresh session when no history exists, replace it with:

```
codex resume --last --dangerously-bypass-approvals-and-sandbox
```

…and you're done — no pre-flight check needed.

If it fails hard (like Claude), add a pre-flight check structurally identical to the Claude branch in `launch-agent.sh:270-278` / `launch-agent.ps1:196-207`. Use the same `sh -c` wrapper pattern so the check runs inside the container where the `codex-config` volume is mounted. Document the slug rule in a comment, with an empirical-verification note like we did for Claude.

Beware: `codex --exec <task>` (the `--exec` flag handled earlier in the launcher) takes a different code path and should not get `resume --last` — only the interactive default branch should auto-resume. The existing `if ... elif ... elif` structure already separates those.

Also update the "Resuming Claude Sessions" section in `README.md` (around line 199) — either expand it to cover both agents, or add a parallel "Resuming Codex Sessions" section.

## Acceptance criteria

- Launching a Codex container in a brand-new workspace starts a fresh session cleanly (no error, no crash).
- Launching a Codex container in a workspace with prior history auto-resumes the most recent session.
- The slug rule (if a pre-flight check is needed) is documented in a code comment with the verified character set.
- README reflects the new behavior.
- No regression in Codex's `--exec` flow.

## Out of scope

- Changing Claude's behavior.
- Adding new CLI flags to the launcher (the auto-resume should just be the default for the interactive Codex path, matching how Claude's `--continue` is now).
