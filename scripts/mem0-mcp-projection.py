#!/usr/bin/env python3
"""
mem0-mcp-projection.py — stdin/stdout JSON-RPC proxy for the Mem0 MCP server.

coo-labs/vade-runtime#154. Closes the #1 transcript-bloat case from the
2026-04-28 audit (vade-coo-memory#249, epic vade-coo-memory#258).

Wraps the upstream mem0 stdio MCP binary and post-processes
`tools/call` results when the called tool is `search_memories` or
`get_memories`. Each result record is projected to drop ~60% of
structural noise per record:

  - Always dropped: categories, structured_attributes, expiration_date,
    created_at, updated_at.
  - Dropped if null/empty: agent_id, app_id, run_id.
  - Kept: id, memory, user_id, score (search), metadata (full sub-object).

All other JSON-RPC frames pass through verbatim. Frames that fail to
parse pass through verbatim too (never lose data). stdin and stderr
are forwarded verbatim.

Per-record projection is hard-coded; no opt-out. Full data is still
in Mem0 if needed via the REST API.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading

# Real upstream binary. Single config constant.
REAL_BINARY = "/home/user/.local/share/uv-tools/mem0-mcp-server/bin/mem0-mcp-server"

# Tools whose result payload we project.
PROJECTED_TOOLS = ("search_memories", "get_memories")

# Keys to always strip from each record.
ALWAYS_DROP = (
    "categories",
    "structured_attributes",
    "expiration_date",
    "created_at",
    "updated_at",
)

# Keys to drop when their value is null / empty string.
DROP_IF_EMPTY = ("agent_id", "app_id", "run_id")


def project_record(record):
    """Apply the projection to a single result record dict in place-style."""
    if not isinstance(record, dict):
        return record
    out = {k: v for k, v in record.items() if k not in ALWAYS_DROP}
    for k in DROP_IF_EMPTY:
        if k in out and (out[k] is None or out[k] == ""):
            del out[k]
    return out


def project_payload(payload):
    """
    Project the payload returned by search_memories / get_memories.
    The payload may be a list of records, or a dict with a "results" /
    "memories" key wrapping the list. Unrecognized shapes pass through.
    """
    if isinstance(payload, list):
        return [project_record(r) for r in payload]
    if isinstance(payload, dict):
        out = dict(payload)
        for key in ("results", "memories", "data"):
            if key in out and isinstance(out[key], list):
                out[key] = [project_record(r) for r in out[key]]
        return out
    return payload


def project_tools_call_result(result):
    """
    MCP tools/call result envelope is:
      { "content": [ {"type": "text", "text": "<json-string>"} ], ... }
    We rewrite each text item whose payload parses as JSON; non-JSON
    text items pass through.
    """
    if not isinstance(result, dict):
        return result
    content = result.get("content")
    if not isinstance(content, list):
        return result
    new_content = []
    for item in content:
        if (
            isinstance(item, dict)
            and item.get("type") == "text"
            and isinstance(item.get("text"), str)
        ):
            text = item["text"]
            try:
                parsed = json.loads(text)
            except (ValueError, TypeError):
                new_content.append(item)
                continue
            projected = project_payload(parsed)
            new_item = dict(item)
            new_item["text"] = json.dumps(projected, separators=(",", ":"))
            new_content.append(new_item)
        else:
            new_content.append(item)
    new_result = dict(result)
    new_result["content"] = new_content
    return new_result


# Track in-flight tools/call requests by JSON-RPC id so we know whether
# to project the response. This thread mutates the dict; the response
# handler reads + deletes. Single producer (stdin pump), single
# consumer (stdout pump), so a plain dict + lock is enough.
_inflight_lock = threading.Lock()
_inflight: dict = {}


def remember_request(frame: dict) -> None:
    """If frame is a tools/call for a projected tool, remember its id."""
    if frame.get("method") != "tools/call":
        return
    params = frame.get("params") or {}
    name = params.get("name")
    if name in PROJECTED_TOOLS:
        rid = frame.get("id")
        if rid is not None:
            with _inflight_lock:
                _inflight[rid] = name


def take_inflight(rid) -> str | None:
    if rid is None:
        return None
    with _inflight_lock:
        return _inflight.pop(rid, None)


def transform_outgoing(frame: dict) -> dict:
    """Apply projection if this frame is a response to a tracked call."""
    if "result" not in frame:
        return frame
    rid = frame.get("id")
    tool = take_inflight(rid)
    if tool is None:
        return frame
    new_frame = dict(frame)
    new_frame["result"] = project_tools_call_result(frame["result"])
    return new_frame


def pump_stdin(child_stdin) -> None:
    """Read parent stdin → child stdin, sniffing requests for projection state."""
    try:
        for raw in sys.stdin.buffer:
            line = raw.rstrip(b"\r\n")
            if line:
                try:
                    frame = json.loads(line)
                    if isinstance(frame, dict):
                        remember_request(frame)
                except (ValueError, TypeError):
                    pass  # pass through unchanged
            child_stdin.write(raw)
            child_stdin.flush()
    except (BrokenPipeError, ValueError):
        pass
    finally:
        try:
            child_stdin.close()
        except Exception:
            pass


def pump_stdout(child_stdout) -> None:
    """Read child stdout → parent stdout, projecting matched response frames."""
    out = sys.stdout.buffer
    try:
        for raw in child_stdout:
            line = raw.rstrip(b"\r\n")
            if not line:
                out.write(raw)
                out.flush()
                continue
            try:
                frame = json.loads(line)
            except (ValueError, TypeError):
                out.write(raw)
                out.flush()
                continue
            if isinstance(frame, dict):
                frame = transform_outgoing(frame)
            # Re-emit as a single line + newline. Keep compact form so
            # we don't bloat what we just trimmed.
            out.write(json.dumps(frame, separators=(",", ":")).encode("utf-8"))
            out.write(b"\n")
            out.flush()
    except (BrokenPipeError, ValueError):
        pass


def pump_stderr(child_stderr) -> None:
    err = sys.stderr.buffer
    try:
        while True:
            chunk = child_stderr.read(4096)
            if not chunk:
                break
            err.write(chunk)
            err.flush()
    except (BrokenPipeError, ValueError):
        pass


def main() -> int:
    # Inherit the env (so MEM0_API_KEY etc. flow through from the
    # MCP host) and pass through any args verbatim.
    child = subprocess.Popen(
        [REAL_BINARY, *sys.argv[1:]],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=os.environ.copy(),
        bufsize=0,
    )

    t_in = threading.Thread(target=pump_stdin, args=(child.stdin,), daemon=True)
    t_out = threading.Thread(target=pump_stdout, args=(child.stdout,), daemon=True)
    t_err = threading.Thread(target=pump_stderr, args=(child.stderr,), daemon=True)
    t_in.start()
    t_out.start()
    t_err.start()

    rc = child.wait()
    # Drain remaining output threads briefly so the last frame isn't lost.
    t_out.join(timeout=2)
    t_err.join(timeout=2)
    return rc


if __name__ == "__main__":
    sys.exit(main())
