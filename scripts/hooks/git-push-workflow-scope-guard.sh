#!/usr/bin/env bash
# PostToolUse Bash hook: detect the OAuth-without-workflow-scope
# rejection on `git push` and inject the App-token contents-API
# recovery recipe as system-reminder context. Reactive complement to
# workflow-file-auth-guard.sh (proactive PreToolUse on Edit/Write).
#
# Trigger: bash command contains `git push` AND the tool response
# (stdout+stderr combined) contains the rejection signature
# `without \`workflow\` scope`. Both conditions must match — we only
# fire on the actual failure, not on every `git push`.
#
# Contract: reads PostToolUse JSON on stdin; emits
#   { hookSpecificOutput: { hookEventName: "PostToolUse",
#                           additionalContext: "..." } }
# on stdout when the rejection signature matches. Always exits 0.
#
# Why this exists even with workflow-file-auth-guard.sh: the proactive
# hook fires before the edit, but if the agent dispatched a sub-agent
# to edit, or rebased from another branch, the proactive context may
# not have reached the model that's running the push. The reactive
# layer catches the failure at the actual point of pain.
#
# Reference: coo-memory/CLAUDE.md §"GitHub writes", same design as
# workflow-file-auth-guard.sh.

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
case "$cmd" in
  *"git push"*) ;;
  *) exit 0 ;;
esac

response="$(printf '%s' "$input" | jq -r '
  if (.tool_response | type) == "object"
  then ((.tool_response.stdout // "") + "\n" + (.tool_response.stderr // ""))
  else (.tool_response | tostring) end' 2>/dev/null || true)"

case "$response" in
  *"without \`workflow\` scope"*) ;;
  *"without 'workflow' scope"*) ;;
  *"workflow scope"*) ;;
  *) exit 0 ;;
esac

guidance="[git-push-workflow-scope-guard] Push rejected — OAuth lacks \`workflow\` scope. Don't retry. Use the App-token contents API:

  GH_USE_APP_TOKEN=1 gh api -X PUT repos/<o>/<r>/contents/<path> \\
    -f branch=<branch> -f message=<msg> \\
    -f content=\$(base64 -w0 <local>) \\
    -f sha=\$(GH_USE_APP_TOKEN=1 gh api repos/<o>/<r>/contents/<path>?ref=<base> --jq .sha)

If branch doesn't exist: POST repos/<o>/<r>/git/refs -f ref=refs/heads/<branch> -f sha=<base-sha> first. Then \`git fetch origin <branch>\` to resync local. Full mechanics: coo-memory/CLAUDE.md §\"GitHub writes\"."

jq -n --arg msg "$guidance" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $msg
  }
}'
