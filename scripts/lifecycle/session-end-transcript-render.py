#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
session-end-transcript-render.py — coo-labs/coo-console#12 sub-task 1.

Renders a Claude Code session jsonl to a self-contained HTML viewer and
uploads it to R2 at `rendered/<sessionId>.html`. The Worker proxies
that key under `GET /transcripts/<sessionId>` on console.vade-app.dev.

Standalone for now — invoke manually or from a script. Wiring into the
Stop-hook chain (alongside session-end-transcript-export) is a separate
PR once the renderer's output stabilizes on real sessions.

Usage:
  # Render the most-recent local jsonl, upload to R2.
  session-end-transcript-render.py

  # Render a specific session.
  session-end-transcript-render.py --session-id <uuid>

  # Render an arbitrary jsonl path (does not require it under ~/.claude/projects).
  session-end-transcript-render.py --input /path/to/transcript.jsonl

  # Skip upload — write HTML to stdout (or --output PATH).
  session-end-transcript-render.py --no-upload --output /tmp/preview.html

Env:
  R2_TRANSCRIPTS_ACCESS_KEY_ID      — R2 access key (32 hex)
  R2_TRANSCRIPTS_SECRET_ACCESS_KEY  — R2 secret key (64 hex)
Read at run time via `op`:
  op://COO/r2-transcripts/endpoint  — R2 S3 URL
  op://COO/r2-transcripts/bucket    — bucket name

R2 layout:
  rendered/<sessionId>.html         — flat key, served by the Worker

Exits 0 on success or skip-without-error; 1 on argument or input error;
2 on R2 upload error (when not in --no-upload mode).
"""

from __future__ import annotations

import argparse
import datetime
import html
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PARSER_VERSION = 2
SCRIPT_DIR = Path(__file__).resolve().parent


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[session-end-transcript-render] {msg}\n")


def _resolve_session_id_and_jsonl(
    session_id_override: str | None,
    input_override: Path | None,
) -> tuple[str, Path]:
    if input_override is not None:
        if not input_override.is_file():
            raise FileNotFoundError(f"--input {input_override} not found")
        sid = session_id_override or input_override.stem
        return sid, input_override

    projects = Path.home() / ".claude" / "projects"
    if not projects.is_dir():
        raise FileNotFoundError(f"~/.claude/projects not found at {projects}")

    sid = session_id_override or os.environ.get("CLAUDE_SESSION_ID", "").strip()
    if sid:
        candidates = list(projects.glob(f"*/{sid}.jsonl"))
        if not candidates:
            raise FileNotFoundError(
                f"session-id={sid} but no matching jsonl under {projects}"
            )
        return sid, candidates[0]

    all_jsonl = sorted(
        projects.glob("*/*.jsonl"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not all_jsonl:
        raise FileNotFoundError(f"no .jsonl found under {projects}")
    chosen = all_jsonl[0]
    return chosen.stem, chosen


def _read_entries(jsonl_path: Path) -> list[dict]:
    entries = []
    with open(jsonl_path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError as e:
                _stderr(f"skipping malformed line {lineno}: {e}")
    return entries


# ---------------------------------------------------------------------------
# Classification + rendering
# ---------------------------------------------------------------------------

SYSTEM_REMINDER_RE = re.compile(
    r"<system-reminder>(.*?)</system-reminder>", re.DOTALL
)
# Envelopes Claude Code injects into the user-message slot that aren't
# typed by the operator: webhook events from MCP subscriptions, background
# task completions, etc. When the user message contains only these and no
# remaining text, it's an auto-notification, not a real user turn.
AUTO_NOTIFICATION_RES = [
    re.compile(r"<github-webhook-activity>.*?</github-webhook-activity>", re.DOTALL),
    re.compile(r"<task-notification>.*?</task-notification>", re.DOTALL),
]


def _strip_auto_notifications(text: str) -> str:
    """Strip system-reminders and known auto-notification envelopes.
    Returns the residue (what the user actually typed, if anything)."""
    out = SYSTEM_REMINDER_RE.sub("", text)
    for r in AUTO_NOTIFICATION_RES:
        out = r.sub("", out)
    return out


def _is_auto_notification_user_entry(entry: dict) -> bool:
    """True iff a user-typed message slot carries only auto-notifications
    (webhook activity, task completion) and no real operator content."""
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    if isinstance(content, str):
        return not _strip_auto_notifications(content).strip()
    if isinstance(content, list):
        any_text = False
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                any_text = True
                if _strip_auto_notifications(block.get("text", "")).strip():
                    return False
        # All-text-blocks were auto-only → True; no text blocks at all → False
        # (must be a tool_result message, which we classify elsewhere).
        return any_text
    return False


def _classify(entry: dict) -> str:
    """Bucket a raw jsonl entry into a rendering kind."""
    t = entry.get("type")
    if t == "attachment":
        return "attachment"
    if t in ("queue-operation", "last-prompt", "mode", "summary"):
        return "meta"
    if t == "user":
        msg = entry.get("message", {}) or {}
        content = msg.get("content")
        if isinstance(content, list):
            kinds = {b.get("type") for b in content if isinstance(b, dict)}
            if "tool_result" in kinds:
                return "tool_result"
            return "user"
        if isinstance(content, str):
            return "user"
        return "user"
    if t == "assistant":
        msg = entry.get("message", {}) or {}
        content = msg.get("content")
        if isinstance(content, list):
            kinds = [b.get("type") for b in content if isinstance(b, dict)]
            if all(k == "thinking" for k in kinds) and kinds:
                return "thinking"
            if all(k == "tool_use" for k in kinds) and kinds:
                return "tool_use"
            return "assistant"
        return "assistant"
    return "other"


def _format_ts(ts: str | None) -> str:
    if not ts:
        return ""
    try:
        dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d %H:%M:%S UTC")
    except (ValueError, TypeError):
        return ts or ""


def _ts_to_dt(ts: str | None) -> datetime.datetime | None:
    if not ts:
        return None
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def _format_elapsed(prev: datetime.datetime | None, now: datetime.datetime | None) -> str:
    if prev is None or now is None:
        return ""
    delta = (now - prev).total_seconds()
    if delta < 0:
        return ""
    if delta < 1:
        return "<1s"
    if delta < 60:
        return f"{int(delta)}s"
    if delta < 3600:
        return f"{int(delta // 60)}m{int(delta % 60):02d}s"
    return f"{int(delta // 3600)}h{int((delta % 3600) // 60):02d}m"


def _truncate(s: str, n: int) -> tuple[str, bool]:
    """Return (head, was_truncated). Head has no trailing whitespace."""
    if len(s) <= n:
        return s, False
    return s[:n].rstrip(), True


def _first_line(s, max_len: int = 80) -> str:
    if not isinstance(s, str):
        s = "" if s is None else _json_pretty(s)
    first = s.lstrip().splitlines()[0] if s.strip() else ""
    head, _ = _truncate(first, max_len)
    return head


def _esc(s) -> str:
    if s is None:
        return ""
    if not isinstance(s, str):
        s = str(s)
    return html.escape(s, quote=True)


def _json_pretty(obj) -> str:
    try:
        return json.dumps(obj, indent=2, ensure_ascii=False)
    except (TypeError, ValueError):
        return repr(obj)


def _tool_args_summary(input_obj: dict | None) -> str:
    if not isinstance(input_obj, dict) or not input_obj:
        return ""
    parts = []
    for k, v in input_obj.items():
        if isinstance(v, str):
            head, trunc = _truncate(v.replace("\n", " "), 60)
            parts.append(f"{k}={head}" + ("…" if trunc else ""))
        elif isinstance(v, (int, float, bool)) or v is None:
            parts.append(f"{k}={v}")
        else:
            parts.append(f"{k}=…")
    out, _ = _truncate(" ".join(parts), 160)
    return out


def _tool_result_text(content) -> str:
    """Tool result content can be a string, list of content blocks, or dict."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        chunks = []
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "text":
                    chunks.append(block.get("text", ""))
                elif block.get("type") == "image":
                    chunks.append("[image]")
                else:
                    chunks.append(_json_pretty(block))
            else:
                chunks.append(str(block))
        return "\n".join(chunks)
    return _json_pretty(content)


def _render_raw(entry: dict) -> str:
    raw = _esc(_json_pretty(entry))
    return (
        '<details class="raw"><summary>Show raw JSON</summary>'
        f'<pre class="raw-json">{raw}</pre></details>'
    )


def _render_text_with_reminders(text: str) -> str:
    """Split text into normal segments and folded system-reminder blocks."""
    parts: list[str] = []
    cursor = 0
    for m in SYSTEM_REMINDER_RE.finditer(text):
        prefix = text[cursor : m.start()]
        if prefix.strip():
            parts.append(f'<div class="text">{_esc(prefix)}</div>')
        body = m.group(1).strip()
        head = _first_line(body, 80)
        parts.append(
            '<details class="sysrem">'
            f'<summary><span class="badge">system-reminder</span> '
            f'<span class="preview">{_esc(head)}</span></summary>'
            f'<pre class="content">{_esc(body)}</pre>'
            "</details>"
        )
        cursor = m.end()
    tail = text[cursor:]
    if tail.strip():
        parts.append(f'<div class="text">{_esc(tail)}</div>')
    if not parts:
        return ""
    return "\n".join(parts)


def _render_user(idx: int, entry: dict, elapsed: str) -> str:
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    if isinstance(content, list):
        body_parts = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text":
                body_parts.append(_render_text_with_reminders(block.get("text", "")))
            else:
                body_parts.append(
                    f'<pre class="content">{_esc(_json_pretty(block))}</pre>'
                )
        body = "\n".join(p for p in body_parts if p)
    elif isinstance(content, str):
        body = _render_text_with_reminders(content)
    else:
        body = f'<pre class="content">{_esc(_json_pretty(content))}</pre>'

    ts = _format_ts(entry.get("timestamp"))
    return (
        f'<article class="entry user" id="entry-{idx}" data-role="user">'
        f'<header><a class="anchor" href="#entry-{idx}">#{idx}</a>'
        f'<span class="role-badge">user</span>'
        f'<span class="ts">{_esc(ts)}</span>'
        f'<span class="elapsed">{_esc(elapsed)}</span></header>'
        f'<div class="body">{body}</div>'
        f"{_render_raw(entry)}"
        "</article>"
    )


def _render_assistant(idx: int, entry: dict, elapsed: str) -> str:
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    usage = msg.get("usage") or {}
    parts: list[str] = []
    has_error = False

    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                parts.append(f'<div class="text">{_esc(block.get("text", ""))}</div>')
            elif btype == "thinking":
                thinking = block.get("thinking", "") or ""
                head = _first_line(thinking, 80)
                parts.append(
                    '<details class="thinking">'
                    f'<summary><span class="badge">thinking</span> '
                    f'<span class="preview">{_esc(head)}</span></summary>'
                    f'<pre class="content">{_esc(thinking)}</pre>'
                    "</details>"
                )
            elif btype == "tool_use":
                name = block.get("name", "?")
                input_obj = block.get("input", {})
                summary = _tool_args_summary(input_obj)
                args_pretty = _json_pretty(input_obj)
                parts.append(
                    '<div class="tool-use">'
                    f'<span class="badge tool">⚒ {_esc(name)}</span>'
                    f'<span class="tool-summary">{_esc(summary)}</span>'
                    '<details class="tool-args">'
                    "<summary>args</summary>"
                    f'<pre class="content">{_esc(args_pretty)}</pre>'
                    "</details>"
                    "</div>"
                )
            else:
                parts.append(f'<pre class="content">{_esc(_json_pretty(block))}</pre>')
    elif isinstance(content, str):
        parts.append(f'<div class="text">{_esc(content)}</div>')

    in_tok = usage.get("input_tokens")
    out_tok = usage.get("output_tokens")
    cache_read = usage.get("cache_read_input_tokens")
    token_bits = []
    if in_tok is not None:
        token_bits.append(f"in {in_tok}")
    if out_tok is not None:
        token_bits.append(f"out {out_tok}")
    if cache_read:
        token_bits.append(f"cache {cache_read}")
    token_badge = " · ".join(token_bits)

    ts = _format_ts(entry.get("timestamp"))
    role_cls = "assistant"
    return (
        f'<article class="entry {role_cls}{" error" if has_error else ""}" '
        f'id="entry-{idx}" data-role="assistant">'
        f'<header><a class="anchor" href="#entry-{idx}">#{idx}</a>'
        f'<span class="role-badge">assistant</span>'
        f'<span class="ts">{_esc(ts)}</span>'
        f'<span class="elapsed">{_esc(elapsed)}</span>'
        f'<span class="tokens">{_esc(token_badge)}</span></header>'
        f'<div class="body">{"".join(parts)}</div>'
        f"{_render_raw(entry)}"
        "</article>"
    )


def _render_tool_result(idx: int, entry: dict, elapsed: str) -> str:
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    if not isinstance(content, list):
        content = []

    body_parts = []
    has_error = False
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") != "tool_result":
            continue
        is_err = bool(block.get("is_error"))
        has_error = has_error or is_err
        text = _tool_result_text(block.get("content"))
        line_count = text.count("\n") + 1 if text else 0
        first = _first_line(text, 80)
        tool_use_id = block.get("tool_use_id", "")
        body_parts.append(
            '<div class="tool-result-block">'
            f'<span class="badge result{" err" if is_err else ""}">'
            f'{"ERROR" if is_err else "result"}</span>'
            f'<span class="preview">{_esc(first)}</span>'
            f'<span class="lines">{line_count} line{"s" if line_count != 1 else ""}</span>'
            f'<span class="tuid">{_esc(tool_use_id[:8])}</span>'
            '<details class="tool-result-full">'
            "<summary>full</summary>"
            f'<pre class="content">{_esc(text)}</pre>'
            "</details>"
            "</div>"
        )

    ts = _format_ts(entry.get("timestamp"))
    return (
        f'<article class="entry tool-result{" error" if has_error else ""}" '
        f'id="entry-{idx}" data-role="tool_result">'
        f'<header><a class="anchor" href="#entry-{idx}">#{idx}</a>'
        f'<span class="role-badge">tool result</span>'
        f'<span class="ts">{_esc(ts)}</span>'
        f'<span class="elapsed">{_esc(elapsed)}</span></header>'
        f'<div class="body">{"".join(body_parts)}</div>'
        f"{_render_raw(entry)}"
        "</article>"
    )


def _render_attachment(idx: int, entry: dict, elapsed: str) -> str:
    att = entry.get("attachment", {}) or {}
    hook_name = att.get("hookName") or att.get("hookEvent") or att.get("type") or "attachment"
    stdout = att.get("stdout") if isinstance(att.get("stdout"), str) else ""
    stderr = att.get("stderr") if isinstance(att.get("stderr"), str) else ""
    content = att.get("content")
    content_str = content if isinstance(content, str) else (_json_pretty(content) if content else "")
    exit_code = att.get("exitCode")
    has_error = isinstance(exit_code, int) and exit_code != 0

    preview = _first_line(stdout or content_str or stderr, 80)
    body = stdout + (("\nSTDERR:\n" + stderr) if stderr else "")
    if content_str and content_str != stdout:
        body = body + (("\n---\n" + content_str) if body else content_str)

    ts = _format_ts(entry.get("timestamp"))
    return (
        '<details class="entry attachment'
        f'{" error" if has_error else ""}" id="entry-{idx}" data-role="attachment">'
        '<summary><a class="anchor" href="#entry-{idx}">'.format(idx=idx)
        + f'#{idx}</a>'
        f'<span class="role-badge">attachment</span>'
        f'<span class="hook-name">{_esc(hook_name)}</span>'
        f'<span class="preview">{_esc(preview)}</span>'
        f'<span class="ts">{_esc(ts)}</span>'
        f'<span class="elapsed">{_esc(elapsed)}</span></summary>'
        f'<pre class="content">{_esc(body)}</pre>'
        f"{_render_raw(entry)}"
        "</details>"
    )


def _render_thinking_entry(idx: int, entry: dict, elapsed: str) -> str:
    """Assistant entry whose only content is thinking — render compact."""
    return _render_assistant(idx, entry, elapsed)


def _render_meta(idx: int, entry: dict, elapsed: str) -> str:
    t = entry.get("type") or "meta"
    body = _json_pretty(entry)
    ts = _format_ts(entry.get("timestamp"))
    return (
        f'<details class="entry meta" id="entry-{idx}" data-role="meta">'
        f'<summary><a class="anchor" href="#entry-{idx}">#{idx}</a>'
        f'<span class="role-badge">{_esc(t)}</span>'
        f'<span class="ts">{_esc(ts)}</span>'
        f'<span class="elapsed">{_esc(elapsed)}</span></summary>'
        f'<pre class="content">{_esc(body)}</pre>'
        "</details>"
    )


def _render_other(idx: int, entry: dict, elapsed: str) -> str:
    return _render_meta(idx, entry, elapsed)


# ---------------------------------------------------------------------------
# Document assembly
# ---------------------------------------------------------------------------

CSS = """
:root {
  --bg: #0d1117; --panel: #161b22; --border: #30363d; --fg: #e6edf3;
  --muted: #8b949e; --accent: #58a6ff; --user: #79c0ff; --assistant: #d2a8ff;
  --tool: #7ee787; --system: #8b949e; --error: #ff7b72;
  --warning: #d29922;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg: #ffffff; --panel: #f6f8fa; --border: #d0d7de; --fg: #1f2328;
    --muted: #656d76; --accent: #0969da; --user: #0969da; --assistant: #8250df;
    --tool: #1a7f37; --system: #656d76; --error: #cf222e;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui,
    sans-serif; font-size: 14px; line-height: 1.5; }
body { display: grid; grid-template-columns: minmax(220px, 280px) 1fr;
  min-height: 100vh; }
nav.toc { position: sticky; top: 0; align-self: start; max-height: 100vh;
  overflow-y: auto; padding: 16px; border-right: 1px solid var(--border);
  background: var(--panel); font-size: 12px; }
nav.toc h2 { font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em;
  margin: 0 0 12px 0; color: var(--muted); }
nav.toc ol { list-style: none; margin: 0; padding: 0; }
nav.toc li { margin: 0 0 6px 0; }
nav.toc a { color: var(--fg); text-decoration: none; display: block;
  padding: 4px 6px; border-radius: 4px; }
nav.toc a:hover { background: var(--bg); }
main { padding: 16px 24px; min-width: 0; max-width: 100%; }
p.back { margin: 0 0 8px 0; font-size: 12px; }
p.back a { color: var(--muted); text-decoration: none; }
p.back a:hover { color: var(--accent); }
header.session { padding-bottom: 16px; border-bottom: 1px solid var(--border);
  margin-bottom: 16px; }
header.session h1 { margin: 0 0 4px 0; font-size: 18px; font-family: ui-monospace,
  SFMono-Regular, Menlo, monospace; }
header.session .meta { color: var(--muted); font-size: 12px; }
.controls { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0 24px;
  align-items: center; }
.controls input[type=search] { flex: 1 1 200px; background: var(--panel);
  border: 1px solid var(--border); color: var(--fg); padding: 6px 10px;
  border-radius: 6px; font: inherit; }
.controls button { background: var(--panel); border: 1px solid var(--border);
  color: var(--fg); padding: 6px 10px; border-radius: 6px; font: inherit;
  cursor: pointer; }
.controls button.active { background: var(--accent); color: var(--bg);
  border-color: var(--accent); }
.entry { margin: 0 0 14px 0; padding: 10px 12px; border: 1px solid var(--border);
  border-left: 3px solid var(--system); border-radius: 6px; background: var(--panel); }
.entry.user { border-left-color: var(--user); }
.entry.assistant { border-left-color: var(--assistant); }
.entry.tool-result { border-left-color: var(--tool); }
.entry.attachment { border-left-color: var(--system); }
.entry.meta { border-left-color: var(--system); opacity: 0.85; }
.entry.error { border-left-color: var(--error); }
.entry > header, .entry > summary { display: flex; flex-wrap: wrap; gap: 10px;
  align-items: center; font-size: 12px; color: var(--muted); cursor: default; }
.entry > summary { cursor: pointer; list-style: none; }
.entry > summary::-webkit-details-marker { display: none; }
.entry > summary::before { content: "▸"; color: var(--muted); width: 8px;
  display: inline-block; transition: transform 0.1s; }
.entry[open] > summary::before { transform: rotate(90deg); }
.anchor { color: var(--muted); text-decoration: none; font-family: ui-monospace,
  monospace; min-width: 32px; }
.anchor:hover { color: var(--accent); }
.role-badge { background: var(--bg); padding: 2px 6px; border-radius: 3px;
  font-weight: 600; font-size: 11px; text-transform: uppercase;
  letter-spacing: 0.03em; }
.ts, .elapsed, .tokens, .hook-name, .tuid, .lines { font-family: ui-monospace,
  monospace; font-size: 11px; color: var(--muted); }
.elapsed::before { content: "+"; }
.body { margin-top: 8px; }
.text { white-space: pre-wrap; word-wrap: break-word; margin: 6px 0; }
.entry pre.content, pre.raw-json { background: var(--bg); border: 1px solid var(--border);
  border-radius: 4px; padding: 8px 10px; overflow-x: auto; font-family: ui-monospace,
  monospace; font-size: 12px; white-space: pre-wrap; word-wrap: break-word;
  max-width: 100%; margin: 6px 0; }
details.sysrem, details.thinking, details.tool-args, details.tool-result-full,
details.raw { margin: 6px 0; }
details.sysrem > summary, details.thinking > summary, details.tool-args > summary,
details.tool-result-full > summary, details.raw > summary {
  cursor: pointer; color: var(--muted); font-size: 12px; list-style: none;
  display: flex; gap: 8px; align-items: center; }
details > summary::-webkit-details-marker { display: none; }
details > summary::before { content: "▸"; width: 8px; display: inline-block;
  color: var(--muted); transition: transform 0.1s; }
details[open] > summary::before { transform: rotate(90deg); }
.badge { background: var(--bg); padding: 2px 6px; border-radius: 3px;
  font-size: 11px; font-weight: 600; }
.badge.tool { color: var(--tool); }
.badge.result { color: var(--tool); }
.badge.result.err { color: var(--error); }
.preview { color: var(--muted); font-family: ui-monospace, monospace;
  font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  max-width: 60ch; }
.tool-use { display: flex; flex-wrap: wrap; gap: 8px; align-items: baseline;
  margin: 4px 0; }
.tool-summary { color: var(--fg); font-family: ui-monospace, monospace;
  font-size: 12px; overflow-wrap: anywhere; }
.tool-result-block { margin: 6px 0; padding: 6px 8px; background: var(--bg);
  border-radius: 4px; }
.tool-result-block > * { display: inline-block; vertical-align: middle;
  margin-right: 8px; }
.hide-attachment .entry.attachment { display: none; }
.hide-tool-result .entry.tool-result { display: none; }
.hide-meta .entry.meta { display: none; }
.only-conversation .entry:not(.user):not(.assistant) { display: none; }
mark.search-hit { background: var(--warning); color: var(--bg); }
@media (max-width: 768px) {
  body { grid-template-columns: 1fr; }
  nav.toc { position: static; max-height: 280px; border-right: none;
    border-bottom: 1px solid var(--border); }
}
"""

JS = """
(function(){
  const main = document.querySelector('main');
  const search = document.getElementById('search-box');
  const buttons = document.querySelectorAll('.controls button[data-toggle]');
  buttons.forEach(b => b.addEventListener('click', () => {
    b.classList.toggle('active');
    document.body.classList.toggle(b.dataset.toggle, b.classList.contains('active'));
  }));
  let timer;
  search.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(() => runSearch(search.value.trim()), 150);
  });
  function runSearch(q) {
    // Clear previous highlights.
    document.querySelectorAll('mark.search-hit').forEach(m => {
      const t = document.createTextNode(m.textContent);
      m.parentNode.replaceChild(t, m);
    });
    document.querySelectorAll('.entry').forEach(e => e.style.display = '');
    if (!q) return;
    const ql = q.toLowerCase();
    const entries = document.querySelectorAll('.entry');
    entries.forEach(e => {
      const text = e.textContent.toLowerCase();
      if (text.indexOf(ql) === -1) {
        e.style.display = 'none';
      } else {
        // expand any closed <details> inside so the match is visible
        e.querySelectorAll('details').forEach(d => d.open = true);
        if (e.tagName === 'DETAILS') e.open = true;
        highlight(e, q);
      }
    });
  }
  function highlight(root, q) {
    const ql = q.toLowerCase();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: n => n.parentElement.closest('script,style,mark') ? NodeFilter.FILTER_REJECT
        : n.nodeValue.toLowerCase().indexOf(ql) !== -1 ? NodeFilter.FILTER_ACCEPT
        : NodeFilter.FILTER_SKIP
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(n => {
      const v = n.nodeValue, lv = v.toLowerCase();
      const frag = document.createDocumentFragment();
      let i = 0;
      while (i < v.length) {
        const j = lv.indexOf(ql, i);
        if (j === -1) { frag.appendChild(document.createTextNode(v.slice(i))); break; }
        if (j > i) frag.appendChild(document.createTextNode(v.slice(i, j)));
        const mark = document.createElement('mark');
        mark.className = 'search-hit';
        mark.textContent = v.slice(j, j + q.length);
        frag.appendChild(mark);
        i = j + q.length;
      }
      n.parentNode.replaceChild(frag, n);
    });
  }
  const jumpErr = document.getElementById('jump-error');
  if (jumpErr) jumpErr.addEventListener('click', () => {
    const e = document.querySelector('.entry.error');
    if (e) { e.scrollIntoView({block:'start'}); if (e.tagName==='DETAILS') e.open = true; }
  });
})();
"""


def _build_toc(rendered_entries: list[tuple[int, str, str]]) -> str:
    """Build the table-of-contents nav.

    Each tuple is (idx, kind, preview). Only user turns get numbered list
    entries; assistant turns appear underneath their preceding user turn
    as sub-entries (visual hierarchy is the user-turn anchor).
    """
    items = []
    user_n = 0
    for idx, kind, preview in rendered_entries:
        if kind == "user":
            user_n += 1
            label = f"{user_n}. {preview or '(empty)'}"
            label_short, _ = _truncate(label, 60)
            items.append(f'<li><a href="#entry-{idx}">{_esc(label_short)}</a></li>')
    if not items:
        items.append('<li><em class="muted">no user turns</em></li>')
    return f'<nav class="toc"><h2>User turns</h2><ol>{"".join(items)}</ol></nav>'


def _format_session_url(remote_sid: str) -> str:
    remote_sid = remote_sid.strip()
    if not remote_sid:
        return ""
    if remote_sid.startswith("cse_"):
        remote_sid = remote_sid[4:]
    return f"https://claude.ai/code/session_{remote_sid}"


def _fetch_remote_sid_from_export_meta(session_id: str) -> str:
    """Best-effort lookup of CLAUDE_CODE_REMOTE_SESSION_ID from the
    export pipeline's meta.json at transcripts/meta/<sid>.meta.json.
    Returns "" on any failure or absence. Schema version 3 added the
    field; older sidecars return "" silently."""
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        return ""
    try:
        endpoint, bucket = _r2_endpoint_bucket()
    except RuntimeError:
        return ""
    try:
        import boto3
        from botocore.config import Config
        from botocore.exceptions import ClientError
    except ImportError:
        return ""
    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="auto",
        config=Config(signature_version="s3v4", retries={"max_attempts": 2, "mode": "standard"}),
    )
    try:
        resp = s3.get_object(Bucket=bucket, Key=f"transcripts/meta/{session_id}.meta.json")
        body = resp["Body"].read()
        meta = json.loads(body)
        return str(meta.get("claude_code_remote_session_id") or "")
    except (ClientError, KeyError, ValueError):
        return ""


def _compute_session_url(session_id: str) -> str:
    """Derive the claude.ai/code session URL for `session_id`.

    Lookup order:
      1. Env (CLAUDE_CODE_SESSION_ID matches target → use
         CLAUDE_CODE_REMOTE_SESSION_ID). Stop-hook path is here.
      2. Export meta.json sidecar in R2 (schema v3+ carries the
         remote-session-id). Backfill path is here.
    Returns "" when neither source has it."""
    env_sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if env_sid and env_sid == session_id:
        remote = os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID", "").strip()
        url = _format_session_url(remote)
        if url:
            return url
    return _format_session_url(_fetch_remote_sid_from_export_meta(session_id))


def compute_metadata(session_id: str, entries: list[dict]) -> dict:
    """Walk entries once; return the metadata blob for the list-page sidecar.

    Schema (renderer_version=1):
      session_id, started_at, ended_at, duration_seconds,
      entry_count, user_turn_count, assistant_turn_count,
      tool_call_count, error_count, first_user_preview,
      renderer_version.
    """
    first_ts: datetime.datetime | None = None
    last_ts: datetime.datetime | None = None
    user_count = 0
    assistant_count = 0
    tool_call_count = 0
    error_count = 0
    first_user_preview = ""
    first_user_uuid: str | None = None

    for entry in entries:
        kind = _classify(entry)
        ts = _ts_to_dt(entry.get("timestamp"))
        if ts is not None:
            if first_ts is None:
                first_ts = ts
            last_ts = ts

        if kind == "user":
            if _is_auto_notification_user_entry(entry):
                # Webhook events / task notifications injected into the user
                # slot aren't operator turns; don't count them.
                pass
            else:
                user_count += 1
                if not first_user_preview:
                    msg = entry.get("message", {}) or {}
                    content = msg.get("content")
                    text = ""
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "text":
                                text = block.get("text", "")
                                break
                    text = _strip_auto_notifications(text).strip()
                    if text:
                        first_user_preview = _first_line(text, 140)
                        # Capture the UUID of the FIRST real user message.
                        # Invariant across jsonl rotations — Claude Code
                        # preserves message UUIDs in the replayed history,
                        # verified empirically on 4 known rotations of the
                        # same conversation. Perfect group key when present.
                        uid = entry.get("uuid")
                        if isinstance(uid, str):
                            first_user_uuid = uid
        elif kind in ("assistant", "tool_use", "thinking"):
            assistant_count += 1
            msg = entry.get("message", {}) or {}
            content = msg.get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_call_count += 1
        elif kind == "tool_result":
            msg = entry.get("message", {}) or {}
            content = msg.get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        if block.get("is_error"):
                            error_count += 1
        elif kind == "attachment":
            att = entry.get("attachment", {}) or {}
            exit_code = att.get("exitCode")
            if isinstance(exit_code, int) and exit_code != 0:
                error_count += 1

    duration_seconds = 0
    if first_ts is not None and last_ts is not None:
        duration_seconds = max(0, int((last_ts - first_ts).total_seconds()))

    return {
        "session_id": session_id,
        "started_at": first_ts.isoformat() if first_ts else None,
        "ended_at": last_ts.isoformat() if last_ts else None,
        "duration_seconds": duration_seconds,
        "entry_count": len(entries),
        "user_turn_count": user_count,
        "assistant_turn_count": assistant_count,
        "tool_call_count": tool_call_count,
        "error_count": error_count,
        "first_user_preview": first_user_preview,
        "first_user_uuid": first_user_uuid,
        "session_url": _compute_session_url(session_id),
        "renderer_version": PARSER_VERSION,
    }


def render_html(session_id: str, entries: list[dict]) -> str:
    session_url = _compute_session_url(session_id)
    rendered: list[str] = []
    toc_entries: list[tuple[int, str, str]] = []
    prev_ts: datetime.datetime | None = None
    first_ts: datetime.datetime | None = None
    last_ts: datetime.datetime | None = None
    error_count = 0

    for i, entry in enumerate(entries):
        kind = _classify(entry)
        now_ts = _ts_to_dt(entry.get("timestamp"))
        if now_ts is not None:
            if first_ts is None:
                first_ts = now_ts
            last_ts = now_ts
        elapsed = _format_elapsed(prev_ts, now_ts)
        if now_ts is not None:
            prev_ts = now_ts

        preview = ""
        is_auto_user = kind == "user" and _is_auto_notification_user_entry(entry)
        if kind == "user" and not is_auto_user:
            msg = entry.get("message", {}) or {}
            content = msg.get("content")
            if isinstance(content, str):
                preview = _first_line(_strip_auto_notifications(content), 60)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        preview = _first_line(_strip_auto_notifications(block.get("text", "")), 60)
                        break

        if kind == "user":
            html_chunk = _render_user(i, entry, elapsed)
        elif kind == "assistant":
            html_chunk = _render_assistant(i, entry, elapsed)
        elif kind == "thinking":
            html_chunk = _render_thinking_entry(i, entry, elapsed)
        elif kind == "tool_use":
            html_chunk = _render_assistant(i, entry, elapsed)
        elif kind == "tool_result":
            html_chunk = _render_tool_result(i, entry, elapsed)
        elif kind == "attachment":
            html_chunk = _render_attachment(i, entry, elapsed)
        elif kind == "meta":
            html_chunk = _render_meta(i, entry, elapsed)
        else:
            html_chunk = _render_other(i, entry, elapsed)

        if 'class="entry' in html_chunk and " error" in html_chunk.split(">", 1)[0]:
            error_count += 1

        rendered.append(html_chunk)
        # Auto-notification user entries don't get a TOC slot — but they
        # still render as entries (raw form remains scrollable / Find-able).
        toc_entries.append((i, "auto_user" if is_auto_user else kind, preview))

    toc = _build_toc(toc_entries)
    duration = _format_elapsed(first_ts, last_ts) or "—"
    started = _format_ts(first_ts.isoformat() if first_ts else None) or "—"
    entry_count = len(entries)
    user_count = sum(1 for _, k, _ in toc_entries if k == "user")
    assistant_count = sum(1 for _, k, _ in toc_entries if k == "assistant")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Transcript {_esc(session_id)}</title>
<style>{CSS}</style>
</head>
<body>
{toc}
<main>
  <p class="back"><a href="/transcripts/">← All transcripts</a>{(' &nbsp;·&nbsp; <a href="' + _esc(session_url) + '" target="_blank" rel="noopener">Open in Claude Code ↗</a>') if session_url else ''}</p>
  <header class="session">
    <h1>{_esc(session_id)}</h1>
    <div class="meta">
      started {_esc(started)} · duration {_esc(duration)} ·
      {entry_count} entries ({user_count} user, {assistant_count} assistant) ·
      {error_count} error{"" if error_count == 1 else "s"}
    </div>
  </header>
  <div class="controls">
    <input type="search" id="search-box" placeholder="Search transcript..." autocomplete="off">
    <button data-toggle="hide-attachment">Hide attachments</button>
    <button data-toggle="hide-tool-result">Hide tool results</button>
    <button data-toggle="hide-meta">Hide meta</button>
    <button data-toggle="only-conversation">Only user + assistant</button>
    <button id="jump-error">Jump to first error</button>
  </div>
  <div class="entries">
    {"".join(rendered)}
  </div>
</main>
<script>{JS}</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# R2 upload (duplicated minimal helpers from session-end-transcript-export.py;
# factor into scripts/lib/r2.py when a third caller emerges)
# ---------------------------------------------------------------------------


def _op_read(ref: str) -> str:
    if not shutil.which("op"):
        return ""
    try:
        out = subprocess.run(
            ["op", "read", ref],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return out.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def _r2_endpoint_bucket() -> tuple[str, str]:
    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not endpoint or not bucket:
        raise RuntimeError(
            "R2 endpoint or bucket not readable from op://COO/r2-transcripts/{endpoint,bucket}"
        )
    return endpoint, bucket


def _r2_put_bytes(
    body: bytes,
    key: str,
    *,
    overwrite: bool,
    content_type: str,
    cache_control: str = "private, max-age=0, must-revalidate",
) -> dict:
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        raise RuntimeError(
            "R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY missing"
        )
    endpoint, bucket = _r2_endpoint_bucket()

    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="auto",
        config=Config(signature_version="s3v4", retries={"max_attempts": 3, "mode": "standard"}),
    )

    put_kwargs = {
        "Bucket": bucket,
        "Key": key,
        "Body": body,
        "ContentType": content_type,
        "CacheControl": cache_control,
    }
    if not overwrite:
        put_kwargs["IfNoneMatch"] = "*"

    try:
        s3.put_object(**put_kwargs)
        return {"bucket": bucket, "key": key, "endpoint": endpoint, "ceded": False}
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if code == "PreconditionFailed" or status == 412:
            _stderr(f"R2 PUT ceded (key exists, no-overwrite): {key}")
            return {"bucket": bucket, "key": key, "endpoint": endpoint, "ceded": True}
        raise


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    p.add_argument("--session-id", help="explicit session uuid (overrides $CLAUDE_SESSION_ID)")
    p.add_argument("--input", type=Path, help="path to .jsonl (overrides session-id resolution)")
    p.add_argument("--output", type=Path, help="write HTML to PATH instead of stdout")
    p.add_argument("--no-upload", action="store_true",
                   help="skip R2 upload (default if --output is set)")
    p.add_argument("--overwrite", action="store_true",
                   help="overwrite an existing key in R2 (default: first-write-wins)")
    p.add_argument("--key-prefix", default="rendered",
                   help="R2 key prefix (default: rendered)")
    args = p.parse_args(argv)

    try:
        session_id, jsonl_path = _resolve_session_id_and_jsonl(
            args.session_id, args.input
        )
    except FileNotFoundError as e:
        _stderr(str(e))
        return 1

    _stderr(f"rendering {session_id} from {jsonl_path}")
    entries = _read_entries(jsonl_path)
    if not entries:
        _stderr(f"no entries in {jsonl_path}")
        return 1
    html_doc = render_html(session_id, entries)
    html_bytes = html_doc.encode("utf-8")
    _stderr(f"rendered {len(entries)} entries → {len(html_bytes)} bytes")

    if args.output is not None:
        args.output.write_bytes(html_bytes)
        _stderr(f"wrote {args.output}")

    skip_upload = args.no_upload or args.output is not None
    if skip_upload:
        if args.output is None:
            sys.stdout.write(html_doc)
        return 0

    key_prefix = args.key_prefix.rstrip("/")
    html_key = f"{key_prefix}/{session_id}.html"
    meta_key = f"{key_prefix}/{session_id}.meta.json"
    try:
        html_result = _r2_put_bytes(
            html_bytes, html_key,
            overwrite=args.overwrite,
            content_type="text/html; charset=utf-8",
        )
    except Exception as e:
        _stderr(f"R2 upload (html) failed: {e}")
        return 2
    _stderr(f"uploaded → {html_result['endpoint']}/{html_result['bucket']}/{html_result['key']}"
            + (" (ceded)" if html_result.get("ceded") else ""))

    metadata = compute_metadata(session_id, entries)
    meta_bytes = json.dumps(metadata, separators=(",", ":")).encode("utf-8")
    try:
        meta_result = _r2_put_bytes(
            meta_bytes, meta_key,
            overwrite=args.overwrite,
            content_type="application/json; charset=utf-8",
        )
    except Exception as e:
        # HTML already landed; sidecar miss is non-fatal — list page tolerates absence.
        _stderr(f"R2 upload (meta sidecar) failed: {e}")
        return 0
    _stderr(f"uploaded → {meta_result['endpoint']}/{meta_result['bucket']}/{meta_result['key']}"
            + (" (ceded)" if meta_result.get("ceded") else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
