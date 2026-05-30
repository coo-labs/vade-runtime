#!/usr/bin/env bash
# PreToolUse Write|Edit hook: refuse a write/edit to any `*/SKILL.md`
# whose post-write YAML frontmatter (the block between the first pair
# of `---` markers) fails strict YAML parse. The motivating bug was
# the 2026-05-30 batch of seven SKILL.md files whose unquoted
# `description` values contained `: ` (colon-space), which strict
# YAML treats as a nested-mapping start. Claude Code's permissive
# loader tolerated them; GitHub's Markdown renderer (and any other
# strict consumer like read.vade-app.dev) surfaces:
#   Error in user YAML: mapping values are not allowed in this context
# Catching this in-session, before the agent commits and pushes, means
# the deny reason is fed straight back into the conversation and the
# agent corrects on the next turn — instead of after the PR renders.
#
# Why PreToolUse, not PostToolUse: PreToolUse can block the write
# entirely. PostToolUse would let the bad file land and only warn.
#
# Contract: reads PreToolUse JSON on stdin:
#   { "tool_name": "Write" | "Edit",
#     "tool_input": { "file_path": "...", "content"|"old_string"|... } }
# Always exits 0. To block, prints
#   { "decision": "block", "reason": "..." }
# on stdout. To allow, prints nothing.
#
# Path scope: any path whose last component is `SKILL.md`
# (case-sensitive). Covers `.claude/skills/<name>/SKILL.md` (live) and
# `skills/skills/{reference,vendored}/<name>/SKILL.md` (vendored).
#
# Pre-existing-invalidity rule (Edit only): if the file's current
# frontmatter is already invalid, exit 0 — don't punish the agent for
# a pre-existing bug; the edit may even be the fix. Only block when
# the edit *introduces* invalidity (current valid → post-edit invalid).
#
# Bypass: VADE_SKILL_YAML_GUARD_BYPASS=1 → unconditionally allow.
#
# Reference: coo-labs/coo-memory#1088 and coo-labs/skills#26
# (2026-05-30 batch fix).

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

if [ "${VADE_SKILL_YAML_GUARD_BYPASS:-}" = "1" ]; then
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || true)"
case "$tool_name" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)"
case "$file_path" in
  */SKILL.md) ;;
  *) exit 0 ;;
esac

# Delegate the YAML parse + edit-application logic to python3 — same
# rationale as bash-github-api-guard.sh: bash quoting on multi-line
# content is fragile, python3 is already in the boot baseline. Pass
# the envelope JSON as argv (not stdin) because `python3 - ...`
# already reserves stdin for the heredoc script body.
result="$(python3 - "$file_path" "$input" <<'PY' 2>/dev/null || true
import json, sys, os

try:
    import yaml
except ImportError:
    # Fail open if yaml isn't installed — don't block on a hook bug.
    sys.exit(0)

file_path = sys.argv[1]
try:
    env = json.loads(sys.argv[2])
except (json.JSONDecodeError, IndexError):
    sys.exit(0)
tool = env.get('tool_name', '')
ti = env.get('tool_input', {}) or {}

def extract_fm(text):
    """Return the frontmatter block between the first pair of ---
    fences, or None if no frontmatter is present."""
    if not text.startswith('---'):
        return None
    nl = text.find('\n')
    if nl < 0:
        return None
    end = text.find('\n---', nl)
    if end < 0:
        return None
    return text[nl + 1:end]

def parse_or_error(fm):
    try:
        yaml.safe_load(fm)
        return True, ''
    except yaml.YAMLError as e:
        return False, str(e)

if tool == 'Write':
    new_content = ti.get('content', '')
    new_fm = extract_fm(new_content)
    if new_fm is None:
        sys.exit(0)
    ok, err = parse_or_error(new_fm)
    if ok:
        sys.exit(0)
    print(json.dumps({'error': err}))
    sys.exit(0)

# Edit branch.
if not os.path.isfile(file_path):
    sys.exit(0)
try:
    with open(file_path, 'r', encoding='utf-8') as f:
        current = f.read()
except (OSError, UnicodeDecodeError):
    sys.exit(0)

old = ti.get('old_string', '')
new = ti.get('new_string', '')
replace_all = bool(ti.get('replace_all', False))

if replace_all:
    post = current.replace(old, new)
else:
    idx = current.find(old)
    if idx < 0:
        # old_string doesn't match — Edit itself will error; not ours.
        sys.exit(0)
    post = current[:idx] + new + current[idx + len(old):]

post_fm = extract_fm(post)
if post_fm is None:
    sys.exit(0)
post_ok, post_err = parse_or_error(post_fm)
if post_ok:
    sys.exit(0)

# Pre-existing-invalidity rule: skip if the current file was already
# broken — the edit isn't the one introducing the bug.
current_fm = extract_fm(current)
if current_fm is not None:
    cur_ok, _ = parse_or_error(current_fm)
    if not cur_ok:
        sys.exit(0)

print(json.dumps({'error': post_err}))
sys.exit(0)
PY
)"

[ -z "$result" ] && exit 0

err="$(printf '%s' "$result" | jq -r '.error // ""' 2>/dev/null)"
[ -z "$err" ] && exit 0

reason="[skill-yaml-guard] SKILL.md frontmatter would not parse as strict YAML after this write. Error from python3-yaml:

${err}

Usual cause: an unquoted \`description\` or \`argument-hint\` value containing \`: \` (colon-space) — strict YAML treats that as a nested mapping — or starting with \`[\` / \`{\` — parsed as a flow sequence/mapping. Fix: wrap the value in double quotes (escape internal \\\" if any). Example:

  description: \"Author a session-handoff briefing per ... Don't invoke for: single-PR handoffs ...\"

GitHub's Markdown renderer and read.vade-app.dev both error on this even though Claude Code's loader tolerates it — see coo-labs/coo-memory#1088 / coo-labs/skills#26 for the prior batch fix.

Bypass for a deliberate exception: prefix \`VADE_SKILL_YAML_GUARD_BYPASS=1\` in the shell, or set it in env."

jq -n --arg reason "$reason" '{
  decision: "block",
  reason: $reason
}'
exit 0
