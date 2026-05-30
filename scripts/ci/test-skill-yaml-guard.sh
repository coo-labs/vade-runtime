#!/usr/bin/env bash
# test-skill-yaml-guard: smoke-test scripts/hooks/skill-yaml-guard.sh.
#
# Mirrors test-bash-github-api-guard.sh: pipe PreToolUse JSON
# envelopes into the hook, assert block / allow per case.
#
# Run: bash scripts/ci/test-skill-yaml-guard.sh
# Exit: 0 on all pass, 1 otherwise.
#
# Reference: coo-labs/coo-memory#1088, coo-labs/skills#26.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/skill-yaml-guard.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "FAIL: python3-yaml required"; exit 1; }

TMP="$(mktemp -d -t skill-yaml-guard-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
declare -a FAILURES=()

# run_hook_write <file_path> <content>
run_hook_write() {
  jq -n --arg fp "$1" --arg c "$2" \
    '{tool_name: "Write", tool_input: {file_path: $fp, content: $c}}' \
    | "$HOOK" 2>/dev/null
}

# run_hook_edit <file_path> <old_string> <new_string> [replace_all]
run_hook_edit() {
  local fp="$1" old="$2" new="$3" all="${4:-false}"
  jq -n --arg fp "$fp" --arg o "$old" --arg n "$new" --argjson all "$all" \
    '{tool_name: "Edit", tool_input: {file_path: $fp, old_string: $o, new_string: $n, replace_all: $all}}' \
    | "$HOOK" 2>/dev/null
}

# run_hook_raw <stdin-json>
run_hook_raw() {
  printf '%s' "$1" | "$HOOK" 2>/dev/null
}

assert_block() {
  local name="$1" out="$2"
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  BLOCK: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("BLOCK: $name")
    printf '  FAIL  BLOCK: %s\n' "$name"
    printf '         hook output: %s\n' "${out:-<empty>}"
  fi
}

assert_allow() {
  local name="$1" out="$2"
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  ALLOW: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("ALLOW: $name")
    printf '  FAIL  ALLOW: %s\n' "$name"
    printf '         hook output: %s\n' "$out"
  fi
}

# --- fixtures ---

# Frontmatter that violates strict YAML: unquoted colon-space in
# description value (the 2026-05-30 batch root cause).
BAD_FM_COLON='---
name: example
description: Use when X. Dont invoke for: case Y.
---
body
'

# Frontmatter with unquoted bracket flow-sequence in argument-hint
# (the day-overview class of bug).
BAD_FM_FLOW='---
name: example
description: a single short sentence.
argument-hint: [--date YYYY-MM-DD] [--end YYYY-MM-DD]
---
body
'

# Same descriptions, but properly double-quoted — must pass.
GOOD_FM_COLON='---
name: example
description: "Use when X. Dont invoke for: case Y."
---
body
'
GOOD_FM_FLOW='---
name: example
description: a single short sentence.
argument-hint: "[--date YYYY-MM-DD] [--end YYYY-MM-DD]"
---
body
'

NO_FM='# just a markdown file, no frontmatter
some prose.
'

# --- Write fixtures ---

printf 'Write cases:\n'

assert_allow "valid frontmatter (quoted)" \
  "$(run_hook_write /tmp/x/SKILL.md "$GOOD_FM_COLON")"

assert_allow "valid frontmatter (quoted flow)" \
  "$(run_hook_write /tmp/x/SKILL.md "$GOOD_FM_FLOW")"

assert_block "invalid frontmatter — unquoted colon-space" \
  "$(run_hook_write /tmp/x/SKILL.md "$BAD_FM_COLON")"

assert_block "invalid frontmatter — unquoted flow sequence in argument-hint" \
  "$(run_hook_write /tmp/x/SKILL.md "$BAD_FM_FLOW")"

assert_allow "no frontmatter at all" \
  "$(run_hook_write /tmp/x/SKILL.md "$NO_FM")"

assert_allow "non-SKILL.md path (would be invalid YAML, but path doesn't match)" \
  "$(run_hook_write /tmp/notes.md "$BAD_FM_COLON")"

assert_allow "non-SKILL.md path, deep nested" \
  "$(run_hook_write /tmp/.claude/skills/x/README.md "$BAD_FM_COLON")"

# --- Edit fixtures (need on-disk files) ---

printf '\nEdit cases:\n'

EDIT_DIR="$TMP/edit"
mkdir -p "$EDIT_DIR"

# Valid file, edit introduces invalid YAML in frontmatter -> BLOCK.
printf '%s' "$GOOD_FM_COLON" > "$EDIT_DIR/SKILL.md"
assert_block "edit a valid file introducing colon-space" \
  "$(run_hook_edit "$EDIT_DIR/SKILL.md" \
      'description: "Use when X. Dont invoke for: case Y."' \
      'description: Use when X. Dont invoke for: case Y.')"

# Valid file, edit touches body only -> still valid -> ALLOW.
printf '%s' "$GOOD_FM_COLON" > "$EDIT_DIR/SKILL.md"
assert_allow "edit a valid file, body only, still valid" \
  "$(run_hook_edit "$EDIT_DIR/SKILL.md" 'body' 'new body content')"

# Already-broken file, edit touches body only -> ALLOW (pre-existing rule).
printf '%s' "$BAD_FM_COLON" > "$EDIT_DIR/SKILL.md"
assert_allow "edit a pre-existing-broken file, body only — pre-existing rule" \
  "$(run_hook_edit "$EDIT_DIR/SKILL.md" 'body' 'new body content')"

# Already-broken file, edit FIXES the frontmatter -> post is valid -> ALLOW.
printf '%s' "$BAD_FM_COLON" > "$EDIT_DIR/SKILL.md"
assert_allow "edit fixes a broken frontmatter (post-state valid)" \
  "$(run_hook_edit "$EDIT_DIR/SKILL.md" \
      'description: Use when X. Dont invoke for: case Y.' \
      'description: "Use when X. Dont invoke for: case Y."')"

# Edit whose old_string doesn't match -> Edit will error itself; don't block.
printf '%s' "$GOOD_FM_COLON" > "$EDIT_DIR/SKILL.md"
assert_allow "edit with non-matching old_string" \
  "$(run_hook_edit "$EDIT_DIR/SKILL.md" 'this-string-is-not-in-the-file' 'whatever')"

# Edit on a non-existent file -> Edit will error itself; don't block.
assert_allow "edit on non-existent file" \
  "$(run_hook_edit "$EDIT_DIR/does-not-exist/SKILL.md" 'old' 'new')"

# replace_all: introduce invalidity at multiple sites.
printf -- '---\nname: x\ndescription: "ok"\nfoo: "ok"\n---\nbody\n' > "$EDIT_DIR/SKILL.md"
assert_block "replace_all introduces invalidity (foo: -> foo: bad: pair)" \
  "$(run_hook_edit "$EDIT_DIR/SKILL.md" '"ok"' 'use for: bad' true)"

# --- Wrong-matcher and bypass ---

printf '\nMatcher + bypass cases:\n'

assert_allow "Bash tool envelope is inert" \
  "$(run_hook_raw '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}')"

assert_allow "MultiEdit tool envelope is inert (not currently in matcher)" \
  "$(run_hook_raw '{"tool_name":"MultiEdit","tool_input":{"file_path":"/tmp/SKILL.md"}}')"

assert_allow "Read tool envelope is inert" \
  "$(run_hook_raw '{"tool_name":"Read","tool_input":{"file_path":"/tmp/SKILL.md"}}')"

bypass_out="$(VADE_SKILL_YAML_GUARD_BYPASS=1 run_hook_write /tmp/x/SKILL.md "$BAD_FM_COLON")"
assert_allow "VADE_SKILL_YAML_GUARD_BYPASS=1 allows invalid frontmatter" \
  "$bypass_out"

# --- Block reason content sanity check ---

printf '\nBlock-reason content:\n'
bad_out="$(run_hook_write /tmp/x/SKILL.md "$BAD_FM_COLON")"
if printf '%s' "$bad_out" | jq -e '.reason | contains("skill-yaml-guard") and contains("mapping values") and contains("VADE_SKILL_YAML_GUARD_BYPASS")' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  reason names hook, parser error, and bypass\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("REASON content")
  printf '  FAIL  reason content missing expected fragments\n'
  printf '         reason: %s\n' "$(printf '%s' "$bad_out" | jq -r '.reason')"
fi

# --- Summary ---

printf '\nTotal: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
