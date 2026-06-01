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

guidance="[workflow-file-auth-guard] You are about to ${tool_name} a GitHub Actions workflow file (${file_path}). When you commit and push this change, \`git push\` WILL be rejected with:

  refusing to allow an OAuth App to create or update workflow \`.github/workflows/<file>\` without \`workflow\` scope

This is structural — the session's OAuth lacks the workflow scope. Do NOT retry with --no-verify or --force; the scope is fundamentally absent. The canonical workaround uses the \`vade-coo\` App install token via the REST contents API:

  # 1. If the remote branch doesn't exist yet, create it at base HEAD:
  GH_USE_APP_TOKEN=1 gh api -X POST repos/<owner>/<repo>/git/refs \\
    -f ref=\"refs/heads/<branch>\" \\
    -f sha=\"<base-sha>\"

  # 2. PUT the workflow file via App-attributed commit:
  CONTENT=\$(base64 -w0 <local-file>)
  SHA=\$(GH_USE_APP_TOKEN=1 gh api repos/<owner>/<repo>/contents/<path>?ref=<base-ref> --jq .sha)
  GH_USE_APP_TOKEN=1 gh api -X PUT repos/<owner>/<repo>/contents/<path> \\
    -f branch=\"<branch>\" \\
    -f message=\"<commit message>\" \\
    -f content=\"\$CONTENT\" \\
    -f sha=\"\$SHA\"

The App installation has \`workflows: write\`; the OAuth that authenticates \`git push\` does not. The resulting commit is attributed to \`vade-coo-app[bot]\`. If your branch has multiple commits and only some touch workflows, push the non-workflow commits via \`git push\` first, then PUT the workflow file separately.

Full mechanics: coo-memory/CLAUDE.md §\"GitHub writes\". Bypass for a deliberate diagnostic: set VADE_WORKFLOW_AUTH_GUARD_BYPASS=1."

jq -n --arg msg "$guidance" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $msg
  }
}'
