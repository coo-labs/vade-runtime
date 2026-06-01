#!/usr/bin/env bash
# PreToolUse Write|Edit hook: when the agent is about to Write/Edit a
# `.github/workflows/*.yml|yaml` file, inject the App-token contents-API
# recipe as system-reminder context. This closes the gap where the
# agent has read CLAUDE.md's "GitHub writes" section at boot but
# doesn't recall the workflow-scope workaround under tool-call pressure
# and burns ~5 cycles re-discovering it after `git push` is rejected.
#
# Why proactive (PreToolUse on Edit/Write) rather than reactive: the
# reactive layer is in git-push-workflow-scope-guard.sh (PostToolUse on
# Bash). Surfacing the recipe at edit time means the agent knows the
# commit-and-push path from the moment they start the change, not
# after the wasted push.
#
# Contract: reads PreToolUse JSON on stdin; emits
#   { hookSpecificOutput: { hookEventName: "PreToolUse",
#                           additionalContext: "..." } }
# on stdout when the file_path matches. Always exits 0. Non-matching
# tool_name / file_path → no output, no block.
#
# Path match: any path containing `.github/workflows/` and ending in
# `.yml` or `.yaml`. Matches both the canonical repo-root location
# (`.github/workflows/foo.yml`) and per-repo checkout layouts under
# `$VADE_RUNTIME_DIR/.github/workflows/`, etc.
#
# Bypass: VADE_WORKFLOW_AUTH_GUARD_BYPASS=1 → unconditionally allow
# (no context injection). Set when intentionally drafting workflow
# content that won't be committed.
#
# Reference: coo-memory/CLAUDE.md §"GitHub writes" (canonical recipe),
# coo-harness post-#407 design discussion.

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

if [ "${VADE_WORKFLOW_AUTH_GUARD_BYPASS:-}" = "1" ]; then
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || true)"
case "$tool_name" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)"
case "$file_path" in
  *.github/workflows/*.yml|*.github/workflows/*.yaml) ;;
  *) exit 0 ;;
esac

guidance="[workflow-file-auth-guard] About to ${tool_name} a workflow file. \`git push\` will be rejected (OAuth lacks \`workflow\` scope). Use the App-token contents API:

  GH_USE_APP_TOKEN=1 gh api -X PUT repos/<o>/<r>/contents/<path> \\
    -f branch=<branch> -f message=<msg> \\
    -f content=\$(base64 -w0 <local>) \\
    -f sha=\$(GH_USE_APP_TOKEN=1 gh api repos/<o>/<r>/contents/<path>?ref=<base> --jq .sha)

If branch doesn't exist: POST repos/<o>/<r>/git/refs first. Resulting commit: vade-coo-app[bot]. Bypass: VADE_WORKFLOW_AUTH_GUARD_BYPASS=1. Full mechanics: coo-memory/CLAUDE.md §\"GitHub writes\"."

jq -n --arg msg "$guidance" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $msg
  }
}'
