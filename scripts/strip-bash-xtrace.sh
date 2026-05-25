#!/usr/bin/env bash
# PreToolUse Bash hook: prepend `set +x;` to suppress in-eval xtrace
# noise when the bootstrap trace harness is on
# (VADE_BOOTSTRAP_TRACE_MODE=1).
#
# Background: with the trace harness active, every Bash tool call
# returns tool output polluted by `set -x` lines (`+ export BUN_OPTIONS=
# --smol`, `+ shopt -u extglob`, `+ eval '...'`, `++ <my command
# tokens>`, `+ pwd -P`). The xtrace fires on Claude Code's bash
# subprocess; the exact origin is uncertain (possibly Anthropic
# harness; possibly our trace-init via BASH_ENV). What's certain is
# that the noise reaches Claude's context as part of the tool result,
# wasting cache-creation tokens with no debugging value (verified:
# nothing in this content is read by the model for any decision; the
# real trace lives in ~/.vade/traces/<run-id>/xtrace.log).
#
# This hook rewrites the Bash tool command to prefix `set +x;`. Once
# evaluated, set -x is disabled for the rest of the bash session:
#
#   - In-eval xtrace from the user command: suppressed
#   - Trailing harness `+ pwd -P`: suppressed (set +x persists past
#     eval — the eval body runs in the current shell)
#   - Pre-eval harness lines (`+ export BUN_OPTIONS=--smol` etc.):
#     unaffected. Those fire before the eval runs, before our prefix
#     can take effect. Unsuppressable via PreToolUse — they would
#     require a different injection point (BASH_ENV with early
#     BASH_XTRACEFD redirect, or container-level configuration).
#
# Net effect: ~50-75% reduction in xtrace noise per Bash tool call.
# The captured trace at ~/.vade/traces/ is unaffected (the xtrace fd
# the trace-init opens is separate from the bash session's default
# xtrace stream).
#
# Contract: reads PreToolUse JSON on stdin
# (`{"tool_input": {"command": "..."}}`). Emits JSON with
# `hookSpecificOutput.updatedInput.command` to rewrite the command,
# or nothing to leave it untouched. Always exits 0 — never blocks
# the tool call.
#
# References: coo-harness#273 (trace harness), coo-harness#274
# (two-mechanism env model + this cleanup as a flagged implication).

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

# No-op when the trace harness is off — no xtrace noise to suppress.
if [ "${VADE_BOOTSTRAP_TRACE_MODE:-0}" != "1" ]; then
    exit 0
fi

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# Preserve user intent: skip rewrite if the command begins with a `set`
# call. The author may be intentionally manipulating shell options.
case "$cmd" in
    set\ *) exit 0 ;;
esac

# Idempotence: don't re-prefix if the rewrite already landed.
case "$cmd" in
    "set +x; "*) exit 0 ;;
esac

# Rewrite with the prefix; return via PreToolUse updatedInput.
jq -n --arg new_cmd "set +x; $cmd" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: { command: $new_cmd }
  }
}'
