#!/usr/bin/env bash
# PreToolUse Bash hook: refuse bare-echo / bare-printf / cat-EOF of
# token-bearing env vars to stdout/stderr/files.
#
# Why: Claude has at least twice leaked PAT bytes via
# `echo $GITHUB_MCP_PAT`-style commands and self-corrected after the
# fact. The discipline lives in CLAUDE.md but was followed
# inconsistently. This hook refuses the class of command outright,
# converting a soft norm into a hard guard.
#
# Contract: reads Claude Code's PreToolUse JSON on stdin,
# `{"tool_input": {"command": "..."}}`. Always exits 0. To block, emits
# `{"decision": "block", "reason": "..."}` on stdout (per Claude Code
# hook contract). To allow, emits nothing.
#
# Pattern:
#   - Variables guarded: GITHUB_MCP_PAT, GITHUB_TOKEN, MEM0_API_KEY,
#     OP_SERVICE_ACCOUNT_TOKEN, AGENTMAIL_API_KEY.
#   - BLOCK if a token-var reference appears as the operand of `echo`,
#     `printf`, or in a here-doc body, AND the redirection (or default
#     stdout) is NOT `/dev/null` AND the output is NOT piped into
#     another command (where the var is the *input* to that command,
#     not its stdout — e.g. `echo "$X" | gh auth login --with-token`
#     is allowed because `gh` consumes it, not the terminal).
#   - ALLOW: existence checks (`[ -n "$VAR" ]`, `[ -z "$VAR" ]`),
#     length checks (`${#VAR}`), redirect to /dev/null, pipe into
#     another command.
#
# Reference: coo-harness#165, MEMO-2026-04-22-04 (PAT discipline).

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# Token vars to guard. Keep regex-anchored (\b on both sides) so
# substrings like `GITHUB_TOKEN_BACKUP` don't accidentally match.
TOKEN_VAR_RE='(GITHUB_MCP_PAT|GITHUB_TOKEN|MEM0_API_KEY|OP_SERVICE_ACCOUNT_TOKEN|AGENTMAIL_API_KEY)'

# Quick pre-filter: if the command doesn't reference any guarded var
# at all, allow immediately. This keeps the hook's hot-path cheap.
if ! printf '%s' "$cmd" | grep -qE "\\\$\{?${TOKEN_VAR_RE}\b"; then
  exit 0
fi

# Decompose the command into pipeline stages and per-stage logical
# segments split by `&&`, `||`, `;`. We evaluate each segment in
# isolation: a leak in stage 1 is independent of stage 2's behavior.
#
# We work line-by-line on the rewritten command (newlines inserted at
# operator boundaries) so a single `grep -E` per pattern can scan all
# segments. The transformation:
#   1. `|` → newline (pipeline boundary; first stage's stdout is
#      consumed by next stage's stdin, so an `echo $X | gh ...`
#      first-stage emission is not a leak)
#   2. `&&`, `||`, `;`, `\n` → newline (logical boundary)
#
# Then for each segment we test:
#   - If segment matches an `echo`/`printf` of a guarded var AND does
#     NOT redirect to /dev/null AND is NOT followed by a pipe into
#     another command (since pipe was already split out above, the
#     remaining segment is the *terminal* stdout, which IS a leak).
#   - If the segment is a here-doc opener whose body references a
#     guarded var.
#
# Pipe-into-command is handled implicitly: after splitting on `|`,
# only the LAST stage's stdout is "real" stdout. But every preceding
# stage's stdout becomes the next stage's stdin, so an echo-of-var
# in any non-terminal stage is consumed, not leaked. We mark
# non-terminal stages with a sentinel so the check skips them.

# Build a normalized form. We don't try to be a full shell parser —
# we do enough to catch the documented bad cases without false
# positives on the documented good cases.

leak_reason=""

# Step 1: detect here-doc bodies. Pattern:
#   cat <<EOF\n...$VAR...\nEOF
# The here-doc body is delimited by the first occurrence of the
# tag (EOF in the canonical case) on its own line, until the next
# occurrence of that tag on its own line.
#
# We extract here-doc bodies and check each for a guarded var.
heredoc_check() {
  local c="$1"
  # Find lines like `<<TAG` or `<<-TAG` or `<<'TAG'` or `<<"TAG"`.
  # Capture TAG, then scan from that point forward for body up to
  # next ^TAG$.
  python3 - "$c" <<'PY' 2>/dev/null || true
import re, sys
cmd = sys.argv[1]
# Match here-doc openers; tag may be quoted.
pat = re.compile(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')
token_re = re.compile(r'\$\{?(GITHUB_MCP_PAT|GITHUB_TOKEN|MEM0_API_KEY|OP_SERVICE_ACCOUNT_TOKEN|AGENTMAIL_API_KEY)\b')
lines = cmd.split('\n')
i = 0
while i < len(lines):
    m = pat.search(lines[i])
    if m:
        tag = m.group(1)
        # Body starts on next line, ends at line equal to tag (possibly
        # tab-indented if `<<-`).
        j = i + 1
        body = []
        while j < len(lines):
            stripped = lines[j].lstrip('\t')
            if stripped == tag:
                break
            body.append(lines[j])
            j += 1
        body_text = '\n'.join(body)
        if token_re.search(body_text):
            # Heredoc body references a guarded var. Now check the
            # opener's redirection target. If the opener's tail
            # (after `<<TAG`) is `>/dev/null` or pipes into another
            # command, allow. Otherwise block.
            tail = lines[i][m.end():]
            if '/dev/null' in tail:
                pass
            elif '|' in tail:
                # Piped into a consumer; allowed.
                pass
            else:
                print("here-doc body emits a guarded token var to stdout/file")
                sys.exit(0)
        i = j + 1
    else:
        i += 1
PY
}

heredoc_reason="$(heredoc_check "$cmd")"
if [ -n "$heredoc_reason" ]; then
  leak_reason="$heredoc_reason"
fi

# Step 2: detect echo/printf of guarded vars. Split on pipeline
# boundaries first, then on logical boundaries. Only the LAST stage
# of each pipeline is treated as a terminal-output context.
#
# Note: heredoc in a function (not inline in $()) — bash 3.2 (macOS)
# misparses <<'DELIM' inside $() when the delimiter is single-quoted.
echo_check() {
  local c="$1"
  python3 - "$c" <<'PY' 2>/dev/null || true
import re, sys
cmd = sys.argv[1]

# Strip here-doc bodies so they don't confuse the pipeline splitter
# (here-doc detection ran above).
def strip_heredocs(c):
    pat = re.compile(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')
    lines = c.split('\n')
    out = []
    i = 0
    while i < len(lines):
        m = pat.search(lines[i])
        if m:
            tag = m.group(1)
            out.append(lines[i])
            j = i + 1
            while j < len(lines):
                stripped = lines[j].lstrip('\t')
                if stripped == tag:
                    out.append(lines[j])
                    break
                j += 1
            i = j + 1
        else:
            out.append(lines[i])
            i += 1
    return '\n'.join(out)

cmd = strip_heredocs(cmd)

token_re = re.compile(r'\$\{?(GITHUB_MCP_PAT|GITHUB_TOKEN|MEM0_API_KEY|OP_SERVICE_ACCOUNT_TOKEN|AGENTMAIL_API_KEY)\b')

# Split on `|` (pipeline boundaries) but NOT `||`. Walk char-by-char
# tracking quotes.
def split_pipelines(s):
    out = []
    cur = []
    i = 0
    in_s = False  # inside single quotes
    in_d = False  # inside double quotes
    while i < len(s):
        ch = s[i]
        nxt = s[i+1] if i+1 < len(s) else ''
        if ch == '\\' and not in_s:
            cur.append(ch)
            if nxt:
                cur.append(nxt)
                i += 2
                continue
        if ch == "'" and not in_d:
            in_s = not in_s
            cur.append(ch)
            i += 1
            continue
        if ch == '"' and not in_s:
            in_d = not in_d
            cur.append(ch)
            i += 1
            continue
        if not in_s and not in_d and ch == '|' and nxt != '|' and (i == 0 or s[i-1] != '|'):
            out.append(''.join(cur))
            cur = []
            i += 1
            continue
        cur.append(ch)
        i += 1
    out.append(''.join(cur))
    return out

# Split on logical boundaries `&&`, `||`, `;`, newline.
def split_logical(s):
    # Easier: replace operators with newline, then split.
    # Walk char-by-char to respect quotes.
    out = []
    cur = []
    i = 0
    in_s = False
    in_d = False
    while i < len(s):
        ch = s[i]
        nxt = s[i+1] if i+1 < len(s) else ''
        if ch == '\\' and not in_s:
            cur.append(ch)
            if nxt:
                cur.append(nxt)
                i += 2
                continue
        if ch == "'" and not in_d:
            in_s = not in_s
            cur.append(ch); i += 1; continue
        if ch == '"' and not in_s:
            in_d = not in_d
            cur.append(ch); i += 1; continue
        if not in_s and not in_d:
            if ch == '&' and nxt == '&':
                out.append(''.join(cur)); cur = []; i += 2; continue
            if ch == '|' and nxt == '|':
                out.append(''.join(cur)); cur = []; i += 2; continue
            if ch == ';':
                out.append(''.join(cur)); cur = []; i += 1; continue
            if ch == '\n':
                out.append(''.join(cur)); cur = []; i += 1; continue
        cur.append(ch); i += 1
    out.append(''.join(cur))
    return out

# A segment "leaks" if:
#   - It's the LAST stage of its pipeline (i.e. its stdout is real
#     stdout or a file), AND
#   - It contains `echo` or `printf` whose argument list references
#     a guarded var, AND
#   - It does NOT redirect to /dev/null.
#
# A segment is "safe" if:
#   - The var only appears inside `${#VAR}` (length expansion)
#   - The var only appears inside a `[ -n "$VAR" ]` / `[ -z "$VAR" ]`
#     test
#   - The reference is in a non-terminal pipeline stage

# Patterns for safe contexts. We check these BEFORE the leak test
# and remove safe-context substrings from the segment so the leak
# test sees only the dangerous remainder.
def scrub_safe(seg):
    # ${#VAR} length expansion
    seg = re.sub(r'\$\{#(GITHUB_MCP_PAT|GITHUB_TOKEN|MEM0_API_KEY|OP_SERVICE_ACCOUNT_TOKEN|AGENTMAIL_API_KEY)\}', 'SAFE_LEN', seg)
    # [ -n "$VAR" ] / [ -z "$VAR" ] / [[ -n "$VAR" ]] / test -n "$VAR"
    seg = re.sub(r'\[\[?\s*-[nz]\s+"?\$\{?(GITHUB_MCP_PAT|GITHUB_TOKEN|MEM0_API_KEY|OP_SERVICE_ACCOUNT_TOKEN|AGENTMAIL_API_KEY)\}?"?\s*\]?\]?', 'SAFE_TEST', seg)
    seg = re.sub(r'\btest\s+-[nz]\s+"?\$\{?(GITHUB_MCP_PAT|GITHUB_TOKEN|MEM0_API_KEY|OP_SERVICE_ACCOUNT_TOKEN|AGENTMAIL_API_KEY)\}?"?', 'SAFE_TEST', seg)
    return seg

def has_redirect_to_devnull(seg):
    # `> /dev/null`, `>/dev/null`, `&> /dev/null`, `2>/dev/null`,
    # `>>/dev/null`, `1>/dev/null`, etc.
    return re.search(r'(?:^|\s|&)(?:[12]?>>?|&>>?)\s*/dev/null\b', seg) is not None

# echo/printf with a guarded var as one of its args. Match echo or
# printf as a command word (start of segment or after `;`/`&&`/`||`/
# ` ` etc.; since we already split on those, just anchor to start
# of segment after leading whitespace).
def echo_printf_leaks_var(seg):
    # Strip leading whitespace.
    s = seg.lstrip()
    # Match echo / printf at the start.
    m = re.match(r'(echo|printf)\b(.*)$', s, re.DOTALL)
    if not m:
        return False
    args = m.group(2)
    return token_re.search(args) is not None

pipelines = split_pipelines(cmd)
n = len(pipelines)
for idx, stage in enumerate(pipelines):
    is_last_stage = (idx == n - 1)
    if not is_last_stage:
        # Non-terminal stage: stdout is consumed by the next stage's
        # stdin. Even an `echo $TOKEN` here is fine because the next
        # command is the one reading it (e.g. `gh auth login
        # --with-token`).
        continue
    # Logical-split the terminal stage and check each segment.
    for seg in split_logical(stage):
        scrubbed = scrub_safe(seg)
        if not token_re.search(scrubbed):
            continue  # var only appeared in safe contexts
        if has_redirect_to_devnull(scrubbed):
            continue
        if echo_printf_leaks_var(scrubbed):
            print("bare echo/printf of a guarded token env var to stdout/file")
            sys.exit(0)
PY
}

if [ -z "$leak_reason" ]; then
  reason="$(echo_check "$cmd")"
  if [ -n "$reason" ]; then
    leak_reason="$reason"
  fi
fi

if [ -n "$leak_reason" ]; then
  jq -n --arg reason "$leak_reason" '{
    decision: "block",
    reason: ("[bash-token-guard] " + $reason + ". Refusing to print PAT/API-key bytes to a terminal or file. Use: existence check `[ -n \"$VAR\" ] && echo set`, length check `echo \"${#VAR}\"`, or pipe into a consumer like `gh auth login --with-token`. See coo-harness#165, MEMO-2026-04-22-04.")
  }'
  exit 0
fi

exit 0
