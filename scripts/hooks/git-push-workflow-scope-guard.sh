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

guidance="[git-push-workflow-scope-guard] \`git push\` was rejected because the session OAuth lacks \`workflow\` scope. This is structural; do NOT retry with --no-verify, --force, or by re-attempting the same push. The scope is fundamentally missing from the OAuth that authenticates git over HTTP in this environment.

Use the \`vade-coo\` App install token via the REST contents API instead:

  # 1. Identify the workflow files in your pending commits:
  git diff --name-only origin/main..HEAD | grep '^\\.github/workflows/'

  # 2. If the remote branch doesn't exist yet, create it at the
  #    parent commit (the one that doesn't touch workflows):
  GH_USE_APP_TOKEN=1 gh api -X POST repos/<owner>/<repo>/git/refs \\
    -f ref=\"refs/heads/<branch>\" \\
    -f sha=\"<base-sha>\"

  # 3. For each workflow file, PUT contents via App-attributed commit:
  CONTENT=\$(base64 -w0 <local-file>)
  SHA=\$(GH_USE_APP_TOKEN=1 gh api repos/<owner>/<repo>/contents/<path>?ref=<base-ref> --jq .sha)
  GH_USE_APP_TOKEN=1 gh api -X PUT repos/<owner>/<repo>/contents/<path> \\
    -f branch=\"<branch>\" \\
    -f message=\"<commit message>\" \\
    -f content=\"\$CONTENT\" \\
    -f sha=\"\$SHA\"

The App installation has \`workflows: write\`; the OAuth does not. After the API commit lands, \`git fetch origin <branch>\` to resync local. For any future commit on this branch that also touches a workflow file, repeat the API path — do not retry \`git push\`.

If your branch has BOTH workflow and non-workflow commits, split the work: \`git push\` the non-workflow commits first (they will succeed), then PUT each workflow file via the API on top. Full mechanics: coo-memory/CLAUDE.md §\"GitHub writes\"."

jq -n --arg msg "$guidance" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $msg
  }
}'
