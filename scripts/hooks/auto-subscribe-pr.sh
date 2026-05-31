#!/usr/bin/env bash
# PostToolUse Bash hook: auto-subscribe to PR activity after `gh pr create`.
#
# Reads hook input JSON on stdin, detects whether the bash command was a
# `gh pr create`, parses the PR URL from the tool response, and emits an
# additionalContext system reminder instructing the next turn to call
# mcp__github__subscribe_pr_activity. PR subscriptions are session-scoped
# to the model, so a shell-side call cannot register one — the model must
# issue the MCP call itself, hence the context-injection design.
#
# Always exits 0; no-ops cleanly on non-matching commands or unparsable
# output so a misclassification can never block tool execution.

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
# Match both invocation forms: raw `gh pr create` AND the canonical
# `gh-pr-create.sh` wrapper (coo-memory/CLAUDE.md §"GitHub writes").
# PostToolUse sees the OUTER bash command, not the wrapper's exec'd
# child, so the wrapper invocation must be detected by its own name.
case "$cmd" in
  *"gh pr create"*|*"gh-pr-create"*) ;;
  *) exit 0 ;;
esac

blob="$(printf '%s' "$input" | jq -r '
  if (.tool_response | type) == "object"
  then (.tool_response.stdout // "")
  else (.tool_response | tostring) end' 2>/dev/null || true)"
url="$(printf '%s' "$blob" | grep -oE 'https://github\.com/[^/[:space:]"\\]+/[^/[:space:]"\\]+/pull/[0-9]+' | head -1 || true)"
[ -z "$url" ] && exit 0

owner="$(printf '%s' "$url" | sed -E 's|.*github\.com/([^/]+)/.*|\1|')"
repo="$(printf '%s' "$url" | sed -E 's|.*github\.com/[^/]+/([^/]+)/pull/[0-9]+.*|\1|')"
pn="$(printf '%s' "$url" | sed -E 's|.*/pull/([0-9]+).*|\1|')"

if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$pn" ]; then
  exit 0
fi
case "$pn" in *[!0-9]*|'') exit 0 ;; esac

jq -n --arg owner "$owner" --arg repo "$repo" --argjson pn "$pn" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: (
      "[auto-subscribe-pr] A pull request was just created at " + $owner + "/" + $repo + "#" + ($pn|tostring) + ". In your next tool batch, set up two parallel subscriptions:\n" +
      "  1. Call mcp__github__subscribe_pr_activity with owner=\"" + $owner + "\", repo=\"" + $repo + "\", pullNumber=" + ($pn|tostring) + " — streams CI failures, comments, and reviews into this session as github-webhook-activity events.\n" +
      "  2. Start a Monitor on $VADE_RUNTIME_DIR/scripts/subscribe-pr-mergeable.sh " + $owner + "/" + $repo + " " + ($pn|tostring) + " — emits one stdout line per mergeable-state transition (clean to conflict and back) and a terminal line on merge/close. Closes the conflict-notification gap that subscribe_pr_activity does not cover (coo-harness#254)."
    )
  }
}'
