#!/usr/bin/env bash
# test-auto-subscribe-pr: smoke-test scripts/hooks/auto-subscribe-pr.sh.
#
# Regression guard for the 2026-05-25 → 2026-05-31 hook outage: the
# original matcher only caught the literal substring "gh pr create"
# (raw form) and silently no-op'd on the canonical
# `coo-harness/scripts/gh-pr-create.sh` wrapper that
# coo-memory/CLAUDE.md §"GitHub writes" names as the preferred path.
# PR-watch subscriptions failed on the wrapper path, which was ~half
# of PRs. The hook is invisible-when-broken (always exits 0), so a
# test is the only durable guard.
#
# Run: bash scripts/ci/test-auto-subscribe-pr.sh
# Exit: 0 on all pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/auto-subscribe-pr.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }

PASS=0
FAIL=0
declare -a FAILURES=()

# run_hook <command> <stdout>
run_hook() {
  jq -n --arg c "$1" --arg s "$2" \
    '{tool_input: {command: $c}, tool_response: {stdout: $s}}' \
    | "$HOOK" 2>/dev/null
}

assert_fires() {
  local name="$1" out="$2"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("subscribe_pr_activity")' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  FIRES: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("FIRES: $name")
    printf '  FAIL  FIRES: %s\n' "$name"
    printf '         hook output: %s\n' "${out:-<empty>}"
  fi
}

assert_mentions() {
  local name="$1" pattern="$2" out="$3"
  if printf '%s' "$out" | jq -e --arg p "$pattern" '.hookSpecificOutput.additionalContext | test($p)' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  MENTIONS %s: %s\n' "$pattern" "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("MENTIONS $pattern: $name")
    printf '  FAIL  MENTIONS %s: %s\n' "$pattern" "$name"
    printf '         hook output: %s\n' "${out:-<empty>}"
  fi
}

assert_noop() {
  local name="$1" out="$2"
  if [ -z "$out" ]; then
    PASS=$((PASS+1))
    printf '  PASS  NOOP:  %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("NOOP: $name")
    printf '  FAIL  NOOP:  %s\n' "$name"
    printf '         hook output: %s\n' "$out"
  fi
}

URL='https://github.com/coo-labs/coo-memory/pull/1234'

printf 'Fires on canonical and raw forms:\n'

assert_fires "raw gh pr create" \
  "$(run_hook "gh pr create --title foo --body 'bar'" "$URL")"

assert_fires "wrapper bare path" \
  "$(run_hook "coo-harness/scripts/gh-pr-create.sh --title foo --body 'bar'" "$URL")"

assert_fires "wrapper via bash" \
  "$(run_hook "bash /home/user/coo-harness/scripts/gh-pr-create.sh --title foo --body 'bar'" "$URL")"

assert_fires "wrapper via VADE_RUNTIME_DIR" \
  "$(run_hook "bash \$VADE_RUNTIME_DIR/scripts/gh-pr-create.sh --title foo --body 'bar'" "$URL")"

printf '\nMentions both subscriptions (subscribe_pr_activity + subscribe-pr-watch.sh):\n'

assert_mentions "canonical wrapper case" "subscribe-pr-watch" \
  "$(run_hook "coo-harness/scripts/gh-pr-create.sh --title foo --body 'bar'" "$URL")"

printf '\nNo-ops on unrelated commands:\n'

assert_noop "gh pr list" \
  "$(run_hook "gh pr list" "")"

assert_noop "gh pr view" \
  "$(run_hook "gh pr view 42" "https://github.com/coo-labs/coo-memory/pull/42")"

assert_noop "unrelated bash" \
  "$(run_hook "echo hello" "world")"

assert_noop "empty command" \
  "$(run_hook "" "")"

printf '\nGuards against malformed input:\n'

# Matcher fires, but URL extraction fails → exit 0, no output.
assert_noop "wrapper with no URL in stdout" \
  "$(run_hook "coo-harness/scripts/gh-pr-create.sh --title foo" "Error: something went wrong")"

printf '\nSummary: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
