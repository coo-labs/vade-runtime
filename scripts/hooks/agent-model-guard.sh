#!/usr/bin/env bash
# PreToolUse Agent hook: refuse dispatch of built-in subagents that
# default to Haiku unless the caller passes an explicit `model:`
# argument. Forces the dispatcher to make a calibrated model choice
# rather than silently inheriting Haiku.
#
# Why: Per https://code.claude.com/docs/en/sub-agents.md the built-in
# `Explore` and `claude-code-guide` subagents are pinned to Haiku. The
# Agent tool's `model:` parameter, when omitted, falls back to that
# pin — so an unannotated `Agent({subagent_type: "Explore", ...})`
# call silently runs on Haiku. Across multiple sessions Ven observed
# the failure profile this produces: high-confidence shallow
# heuristics, uncalibrated assertions, plausible hallucinations that
# fail under verification. The motivating audit is
# coo-labs/coo-logs#347 (Phase-1 orientation pass: two Explore
# sub-agents made confident attribution errors based on branch-name
# heuristics; both required active disambiguation in parent context).
#
# Block rule:
#   tool_input.subagent_type ∈ {"Explore", "claude-code-guide"}
#   AND (tool_input.model is missing OR empty string)
#
# Allow rules:
#   - tool_input.model is any non-empty string. Even `"haiku"` is
#     allowed — the act of typing it IS the calibrated choice. Silent
#     omission is what we refuse.
#   - subagent_type is any other value (Plan and general-purpose
#     inherit the parent's model; statusline-setup is Sonnet by
#     default; all custom `.claude/agents/*.md` agents in this
#     substrate pin `model:` in frontmatter).
#
# Bypass: none. The intervention is exactly to force the choice. If
# you genuinely want silent-Haiku behavior on a per-call basis, pass
# `model: "haiku"` — that satisfies the rule and documents your intent
# in the call site.
#
# Reference: MEMO-2026-05-25-<suffix>; coo-memory#781;
# coo/parallel_instance_protocol.md §8.6.

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

subagent_type="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || true)"

case "$subagent_type" in
  Explore|claude-code-guide) ;;
  *) exit 0 ;;
esac

model="$(printf '%s' "$input" | jq -r '.tool_input.model // ""' 2>/dev/null || true)"

if [ -n "$model" ]; then
  exit 0
fi

reason="[agent-model-guard] Built-in subagent '${subagent_type}' defaults to Haiku per code.claude.com/docs/en/sub-agents.md. Pass an explicit \`model:\` argument so the choice is calibrated: \`\"sonnet\"\` (or higher) for any result the parent will act on; \`\"haiku\"\` only when the result will be independently verified by the caller (e.g. a narrow file-existence check, a one-line lookup). Silent omission is refused because the failure profile of Haiku on load-bearing work — high-confidence shallow heuristics, uncalibrated assertions, plausible hallucinations — propagates errors that the parent then has to disambiguate. See coo/parallel_instance_protocol.md §8.6 and MEMO references in coo-memory#781."

jq -n --arg reason "$reason" '{
  decision: "block",
  reason: $reason
}'
exit 0
