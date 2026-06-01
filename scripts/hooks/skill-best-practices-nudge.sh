#!/usr/bin/env bash
# PreToolUse Write|Edit hook: surface the agent-skills best-practices
# guide URL when the agent is about to write or edit a file inside any
# skill folder. Non-blocking; fires once per skill-folder per container.
#
# Why: the skills we author repeatedly hit the same anti-patterns from
# the official guide (verbose description, second-person voice, inline
# bash in SKILL.md instead of a script, no progressive disclosure,
# embedded markdown links in the description). Surfacing the URL at
# edit-time means the next turn has the guide in context without the
# operator having to dig up the link.
#
# Contract: reads Claude Code's PreToolUse JSON on stdin,
#   { "tool_name": "Write" | "Edit",
#     "tool_input": { "file_path": "...", ... } }
# Always exits 0. To emit the nudge, prints
#   { "hookSpecificOutput": { "hookEventName": "PreToolUse",
#                             "additionalContext": "..." } }
# on stdout. To skip, prints nothing.
#
# Path scope: any path inside a skill folder. Detected by either
#   (a) the file being SKILL.md itself (covers new-skill bootstrap), OR
#   (b) walking up the path until we find a SKILL.md sibling at any
#       ancestor directory (covers reference.md, template.md, scripts/,
#       and any nested companion file).
#
# De-dup: per-container marker at /tmp/.skill-best-practices-nudge.<hash>
# keyed on the skill folder's normalized path. Container's ephemeral
# /tmp makes this naturally session-scoped — next container starts
# fresh. Operator nudges N times per N skill folders, not N edits.
#
# Bypass: VADE_SKILL_BEST_PRACTICES_NUDGE_BYPASS=1 → unconditionally skip.
#
# Reference: authored 2026-06-01 alongside MEMO-2026-06-01-z4ty after
# revising .claude/skills/commission-audit/SKILL.md against the guide.

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

if [ "${VADE_SKILL_BEST_PRACTICES_NUDGE_BYPASS:-}" = "1" ]; then
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || true)"
case "$tool_name" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)"
[ -z "$file_path" ] && exit 0

# Locate the skill folder, if any.
skill_root=""
case "$file_path" in
  */SKILL.md)
    # The file being written IS the SKILL.md; the folder is its parent.
    skill_root="$(dirname "$file_path")"
    ;;
  *)
    # Walk up looking for a SKILL.md sibling at any ancestor.
    dir="$(dirname "$file_path")"
    for _ in 1 2 3 4 5 6 7 8; do
      [ "$dir" = "/" ] || [ "$dir" = "." ] || [ -z "$dir" ] && break
      if [ -f "$dir/SKILL.md" ]; then
        skill_root="$dir"
        break
      fi
      parent="$(dirname "$dir")"
      [ "$parent" = "$dir" ] && break
      dir="$parent"
    done
    ;;
esac

[ -z "$skill_root" ] && exit 0

# Per-container de-dup on the skill folder.
hash="$(printf '%s' "$skill_root" | sha1sum | cut -c1-12)"
marker="/tmp/.skill-best-practices-nudge.${hash}"
[ -f "$marker" ] && exit 0
touch "$marker"

context="[skill-best-practices] About to ${tool_name,,} a file inside skill folder \`${skill_root}\`. Before substantive authoring, fetch and read https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices.md — the guide covers description length (≤1024 chars, ~400 ideal, what + when + trigger terms, third-person, no embedded markdown links), progressive disclosure (SKILL.md body ≤500 lines, references one level deep), preferring scripts for deterministic mechanics over inline bash, and the anti-patterns we keep hitting (verbose descriptions, second-person voice, embedded narrative for forthcoming features, author-concern sections like 'Pass/fail criteria').

Fires once per skill folder per container; won't repeat on subsequent edits in this folder this session. Bypass: VADE_SKILL_BEST_PRACTICES_NUDGE_BYPASS=1."

jq -n --arg ctx "$context" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $ctx
  }
}'
exit 0
