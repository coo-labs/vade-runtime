#!/usr/bin/env bash
# PreToolUse Bash hook: refuse direct HTTP client subprocess calls to
# `api.github.com`. Forces the agent down the `gh` path, where the
# `gh-coo-wrap.sh` shim auto-routes the correct PAT by repo owner.
#
# Why: When the agent reaches for `curl https://api.github.com/...` it
# bypasses every layer that exists to make GitHub interactions
# anti-fragile: PAT routing, session-URL injection, body-shape lint.
# The 2026-05-11 cross-fork fork failure was the direct cause —
# `gh repo fork venpopov/X` would have routed correctly; `curl ...
# /repos/venpopov/X/forks` did not. This hook converts the wrong
# reflex into a hard refusal at the substrate.
#
# Contract: reads Claude Code's PreToolUse JSON on stdin,
# `{"tool_input": {"command": "..."}}`. Always exits 0. To block, emits
# `{"decision": "block", "reason": "..."}` on stdout. To allow, emits
# nothing.
#
# Block rules (any pipeline stage):
#   - First command word is one of the HTTP-client family:
#       curl, wget, http, https, httpie
#     AND any argument contains `api.github.com`.
#   - First command word is `python`/`python3`/`python2`/`node`/`bun`/
#     `deno`/`ruby`/`perl` AND the next arg is `-c` / `-e` AND the
#     script body contains `api.github.com`.
#
# Allow rules (allowed shapes that mention api.github.com):
#   - `gh ...` (auto-routes via gh-coo-wrap.sh)
#   - File-read / file-edit / grep / sed of a file that happens to
#     contain `api.github.com` (cat, head, tail, less, grep, rg, sed,
#     awk, jq, vim, etc.) — first command word not in the blocked set.
#   - Pipeline whose ONLY mention is in a non-network stage.
#
# Bypass:
#   - VADE_GITHUB_API_GUARD_BYPASS=1 → unconditionally allow. Set this
#     for a deliberate diagnostic; flag in commit / PR if persisted.
#
# Reference: MEMO-2026-05-12-22m9, coo-harness#TBD.

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# Bypass shortcut: env var set on the agent's shell.
case "$cmd" in
  *VADE_GITHUB_API_GUARD_BYPASS=1*) exit 0 ;;
esac
if [ "${VADE_GITHUB_API_GUARD_BYPASS:-}" = "1" ]; then
  exit 0
fi

# Fast pre-filter: if api.github.com is not in the command at all,
# allow immediately. Keep the hook's hot-path cheap.
case "$cmd" in
  *api.github.com*) ;;
  *) exit 0 ;;
esac

# Delegate the structural analysis to python3 (already a dependency
# for bash-token-guard.sh). Bash heredoc parsing inside $() is fragile
# across macOS bash 3.2 and Linux bash 5.x; the python sub-process
# sidesteps quoting issues.
leak_reason="$(python3 - "$cmd" <<'PY' 2>/dev/null || true
import re, sys
cmd = sys.argv[1]

# HTTP-client command words that block on api.github.com mention.
HTTP_CLIENTS = {"curl", "wget", "http", "https", "httpie"}
# Interpreter command words that block when -c/-e arg contains
# api.github.com in the inline script.
INTERPRETERS = {"python", "python3", "python2", "node", "nodejs",
                "bun", "deno", "ruby", "perl"}
INLINE_FLAGS = {"-c", "-e", "--command", "--eval"}

def split_pipelines(s):
    """Split on `|` (pipe) but not `||`. Respect quotes."""
    out, cur = [], []
    in_s = in_d = False
    i = 0
    while i < len(s):
        ch = s[i]
        nxt = s[i+1] if i+1 < len(s) else ''
        if ch == '\\' and not in_s:
            cur.append(ch)
            if nxt:
                cur.append(nxt); i += 2; continue
        if ch == "'" and not in_d:
            in_s = not in_s; cur.append(ch); i += 1; continue
        if ch == '"' and not in_s:
            in_d = not in_d; cur.append(ch); i += 1; continue
        if (not in_s and not in_d and ch == '|'
                and nxt != '|' and (i == 0 or s[i-1] != '|')):
            out.append(''.join(cur)); cur = []; i += 1; continue
        cur.append(ch); i += 1
    out.append(''.join(cur))
    return out

def split_logical(s):
    """Split on `&&` / `||` / `;` / newline, respecting quotes."""
    out, cur = [], []
    in_s = in_d = False
    i = 0
    while i < len(s):
        ch = s[i]
        nxt = s[i+1] if i+1 < len(s) else ''
        if ch == '\\' and not in_s:
            cur.append(ch)
            if nxt:
                cur.append(nxt); i += 2; continue
        if ch == "'" and not in_d:
            in_s = not in_s; cur.append(ch); i += 1; continue
        if ch == '"' and not in_s:
            in_d = not in_d; cur.append(ch); i += 1; continue
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

# Tokenize a segment into rough command words. We don't need perfect
# shell tokenization — just the first command word + a flag scan.
def first_cmd_word(seg):
    # Strip leading env-var assignments (VAR=val cmd ...).
    s = seg.lstrip()
    # Skip leading env-var assignments.
    while True:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*=\S*)\s+', s)
        if m:
            s = s[m.end():]
        else:
            break
    # Strip leading `&` / redirects.
    s = re.sub(r'^[\s\d&<>]+', '', s)
    m = re.match(r'(\S+)', s)
    return (m.group(1) if m else ''), s

def args_contain_target(s):
    """Return True if 'api.github.com' appears anywhere in the
    segment (after the command word)."""
    return 'api.github.com' in s

def check_segment(seg):
    """Return a block reason if this segment violates, else ''."""
    if 'api.github.com' not in seg:
        return ''
    cmd_word, rest = first_cmd_word(seg)
    if not cmd_word:
        return ''
    # Strip a leading absolute path so /usr/bin/curl resolves to curl.
    base = cmd_word.rsplit('/', 1)[-1]
    # Strip a trailing semicolon if any leaked through tokenization.
    base = base.rstrip(';')
    # Allow `gh ...` — that's the desired path.
    if base == 'gh':
        return ''
    if base in HTTP_CLIENTS:
        return (f"direct {base} call to api.github.com "
                "bypasses gh's auto-routing (PAT selection by repo owner)")
    if base in INTERPRETERS:
        # Only flag if the inline script (-c / -e arg) references
        # api.github.com. Walk args after the command word.
        toks = re.split(r'\s+', rest.strip())
        # toks[0] is base again; scan from toks[1:].
        i = 1
        while i < len(toks):
            t = toks[i]
            if t in INLINE_FLAGS:
                # Next token is the inline script — but quoted scripts
                # span multiple tokens. Easier: rejoin from after the
                # flag and check the rest of `rest` for api.github.com.
                tail = rest.split(t, 1)[1] if t in rest else ''
                if 'api.github.com' in tail:
                    return (f"inline {base} {t} script references "
                            "api.github.com; bypasses gh's auto-routing")
                break
            i += 1
        return ''
    return ''

reasons = []
# Logical splits — each statement is independent.
for stmt in split_logical(cmd):
    # Pipeline splits — each stage is a separate command.
    for stage in split_pipelines(stmt):
        r = check_segment(stage)
        if r:
            reasons.append(r)
            break  # one reason per statement is enough

if reasons:
    print(reasons[0])
    sys.exit(0)
PY
)"

if [ -n "$leak_reason" ]; then
  jq -n --arg reason "$leak_reason" '{
    decision: "block",
    reason: ("[bash-github-api-guard] " + $reason + ". Use `gh api PATH` (auto-routes credentials by repo owner) or a `gh` subcommand. Examples: `gh api repos/OWNER/REPO`, `gh repo fork OWNER/REPO`, `gh pr create --repo OWNER/REPO ...`. Bypass for a deliberate diagnostic: prefix `VADE_GITHUB_API_GUARD_BYPASS=1`. See MEMO-2026-05-12-22m9.")
  }'
  exit 0
fi

exit 0
