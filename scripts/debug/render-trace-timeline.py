#!/usr/bin/env python3
"""Render an interactive HTML timeline from a bootstrap-trace run.

Usage: render-trace-timeline.py [<trace-dir>] [<output-html>]
Default trace-dir: ~/.vade/traces/$(cat ~/.vade/traces/CURRENT_RUN_ID)
Default output:    /tmp/trace-timeline.html
"""
import datetime
import json
import os
import re
import sys
from html import escape


def find_default_trace_dir():
    cur = os.path.expanduser("~/.vade/traces/CURRENT_RUN_ID")
    if os.path.exists(cur):
        run_id = open(cur).read().strip()
        return os.path.expanduser(f"~/.vade/traces/{run_id}")
    raise SystemExit("no trace dir given and CURRENT_RUN_ID not found")


TRACE_DIR = sys.argv[1] if len(sys.argv) > 1 else find_default_trace_dir()
OUTPUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/trace-timeline.html"

meta_path = os.path.join(TRACE_DIR, "meta.json")
meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}

xtrace_path = os.path.join(TRACE_DIR, "xtrace.log")
xtrace_re = re.compile(
    r"^\++ \[(?P<ts>[0-9.]+)\] \[pid=(?P<pid>\d+) bp=(?P<bp>\d+)\] "
    r"\[(?P<script>[^:\]]+?)(?::(?P<line>\d+))? fn=(?P<fn>[^\]]+)\] "
    r"(?P<cmd>.*)$"
)

PID_FIRST = {}
PID_LAST = {}
PID_SCRIPT = {}
PID_CMD_COUNT = {}
EVENTS = []
boot_start = None

print(f"Parsing {xtrace_path} ...", file=sys.stderr)

with open(xtrace_path) as f:
    for line in f:
        m = xtrace_re.match(line)
        if not m:
            continue
        ts = float(m["ts"])
        pid = int(m["pid"])
        script = m["script"]
        srcline = m.group("line") or ""
        fn = m["fn"]
        cmd = m["cmd"].strip()

        if boot_start is None or ts < boot_start:
            boot_start = ts

        if pid not in PID_FIRST:
            PID_FIRST[pid] = ts
            PID_SCRIPT[pid] = script
            PID_CMD_COUNT[pid] = 0
        PID_LAST[pid] = ts
        PID_CMD_COUNT[pid] += 1

        # Only honor the FIRST _VTRACE_INVOCATION_TAG per PID. A long-lived
        # script (e.g. coo-identity-digest.sh that sticks around as a monitor)
        # may re-source bootstrap-trace-init later with a different tag for a
        # subshell action — we keep the first-seen script identity.
        if cmd.startswith("_VTRACE_INVOCATION_TAG=") and not PID_SCRIPT.get(f"_tag_seen_{pid}"):
            tag = cmd.split("=", 1)[1].split()[0]
            PID_SCRIPT[pid] = tag
            PID_SCRIPT[f"_tag_seen_{pid}"] = True

        # Promote script: stop reporting bootstrap-trace-init/dispatch when
        # we've already locked a real user script via TAG
        if not PID_SCRIPT.get(f"_tag_seen_{pid}"):
            if PID_SCRIPT[pid] in ("bootstrap-trace-init.sh", "common.sh", "dispatch.sh") and script not in (
                "bootstrap-trace-init.sh",
                "common.sh",
                "dispatch.sh",
            ):
                PID_SCRIPT[pid] = script

        # Capture events
        ev = None
        if fn.startswith("_write_claude_settings_"):
            ev = {"type": "write", "label": fn.replace("_write_claude_settings_", "write:")}
        elif fn.startswith("merge_coo_settings_"):
            ev = {"type": "merge", "label": fn.replace("merge_coo_settings_", "merge:")}
        elif cmd.startswith("_add "):
            parts = cmd.split(" ", 3)
            if len(parts) >= 3:
                key, ok = parts[1], parts[2]
                detail = parts[3] if len(parts) > 3 else ""
                ev = {
                    "type": "invariant-fail" if ok == "false" else ("invariant-skip" if ok == "skip" else "invariant-pass"),
                    "label": f"{key}={ok}",
                    "detail": detail,
                }
        elif fn == "ensure_gh_coo_wrap" and "0755" in cmd and "install" in cmd:
            ev = {"type": "note", "label": "gh-coo-wrap installed"}
        elif fn == "ensure_hooks_dispatch_shim" and cmd.startswith("mkdir -p"):
            ev = {"type": "note", "label": "dispatch shim setup"}
        elif fn == "MAIN" and (cmd.startswith("set -euo") or cmd.startswith("set -uo")):
            # script-entry marker
            ev = {"type": "enter", "label": f"enter {script}"}
        elif fn == "_log" and cmd.startswith("echo '[") and "BOOT DEGRADED" in cmd:
            ev = {"type": "alert", "label": "BOOT DEGRADED banner"}
        elif fn == "log" and cmd.startswith("echo '[vade-setup]"):
            # surface key vade-setup log lines
            if any(k in cmd for k in ("merged ", "marker present", "SKIP", "fresh bootstrap", "coo-bootstrap: already")):
                ev = {"type": "note", "label": cmd[5:].strip("'\"")[:80]}

        if ev is not None:
            # dedup repeated writes/merges (same pid+label keep first only)
            if ev["type"] in ("write", "merge"):
                key = (pid, ev["label"])
                if any(e.get("_key") == key for e in EVENTS):
                    continue
                ev["_key"] = key
            ev["ts"] = ts
            ev["pid"] = pid
            ev["script"] = script
            ev["line"] = srcline
            ev["fn"] = fn
            ev["cmd"] = cmd[:240]
            EVENTS.append(ev)

# Parse snapshots
SNAPSHOTS = []
snapshots_dir = os.path.join(TRACE_DIR, "snapshots")
if os.path.isdir(snapshots_dir):
    snap_re = re.compile(
        r"^(?P<ymd>\d{8})T(?P<hms>\d{6})(?P<micros>\d+)-(?P<script>.+?)-enter-(?P<pid>\d+)$"
    )
    for d in sorted(os.listdir(snapshots_dir)):
        m = snap_re.match(d)
        if not m:
            continue
        try:
            dt = datetime.datetime.strptime(
                f"{m['ymd']}{m['hms']}", "%Y%m%d%H%M%S"
            ).replace(tzinfo=datetime.timezone.utc)
            ts = dt.timestamp() + int(m["micros"]) * 1e-6
        except Exception:
            continue

        env_state = None
        try:
            s = json.load(open(os.path.join(snapshots_dir, d, "content/settings.json")))
            env = s.get("env", {}) or {}
            env_state = {
                "has_VADE_RUNTIME_DIR": "VADE_RUNTIME_DIR" in env,
                "has_VADE_COO_MEMORY_DIR": "VADE_COO_MEMORY_DIR" in env,
                "has_VADE_CLOUD_STATE_DIR": "VADE_CLOUD_STATE_DIR" in env,
                "env_keys_count": len(env),
            }
        except Exception:
            pass

        SNAPSHOTS.append(
            {"ts": ts, "script": m["script"], "pid": int(m["pid"]), "env": env_state, "dir": d}
        )

# strip sentinel keys we used internally
for k in [k for k in PID_SCRIPT if isinstance(k, str) and k.startswith("_tag_seen_")]:
    del PID_SCRIPT[k]

PIDS = sorted(PID_FIRST.keys(), key=lambda p: PID_FIRST[p])


def to_ms(ts):
    return (ts - boot_start) * 1000


data = {
    "meta": meta,
    "boot_start_epoch": boot_start,
    "duration_ms": (max(PID_LAST.values()) - boot_start) * 1000 if PID_LAST else 0,
    "pids": [
        {
            "pid": p,
            "script": PID_SCRIPT[p],
            "first_ms": to_ms(PID_FIRST[p]),
            "last_ms": to_ms(PID_LAST[p]),
            "count": PID_CMD_COUNT[p],
        }
        for p in PIDS
    ],
    "events": [
        {
            "pid": e["pid"],
            "ts_ms": to_ms(e["ts"]),
            "type": e["type"],
            "label": e["label"],
            "script": e["script"],
            "line": e["line"],
            "fn": e["fn"],
            "cmd": e["cmd"],
            "detail": e.get("detail", ""),
        }
        for e in EVENTS
    ],
    "snapshots": [
        {
            "ts_ms": to_ms(s["ts"]),
            "script": s["script"],
            "pid": s["pid"],
            "env": s["env"],
            "dir": s["dir"],
        }
        for s in SNAPSHOTS
    ],
}

print(
    f"PIDs={len(PIDS)}  events={len(EVENTS)}  snapshots={len(SNAPSHOTS)}  "
    f"duration={data['duration_ms']:.0f}ms",
    file=sys.stderr,
)

run_id = escape(meta.get("run_id", "?"))
started_at = escape(meta.get("started_at", "?"))

HTML = (
    """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Bootstrap trace timeline — """ + run_id + """</title>
<style>
  :root {
    --bg: #1a1a1a;
    --panel: #232323;
    --row-alt: #1e1e1e;
    --text: #d8d8d8;
    --muted: #888;
    --border: #3a3a3a;
    --span: rgba(120,150,200,0.25);
    --span-border: rgba(180,200,240,0.5);
    --hl: #ffd35a;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; height: 100%; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, sans-serif;
    background: var(--bg);
    color: var(--text);
    font-size: 12px;
    overflow: hidden;
  }
  #header {
    padding: 8px 12px;
    border-bottom: 1px solid var(--border);
    display: flex;
    gap: 16px;
    align-items: baseline;
    background: var(--panel);
    flex-shrink: 0;
  }
  #header strong { color: #fff; font-weight: 600; }
  #header .meta { color: var(--muted); font-size: 11px; }
  #header .meta b { color: var(--text); font-weight: 600; }

  #legend {
    padding: 6px 12px;
    font-size: 11px;
    color: var(--muted);
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    display: flex;
    gap: 14px;
    flex-wrap: wrap;
    flex-shrink: 0;
  }
  .leg { display: inline-flex; align-items: center; gap: 4px; }
  .swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px; }

  #main {
    display: flex;
    height: calc(100vh - 70px);
    overflow: hidden;
  }
  #chart-area {
    flex-grow: 1;
    overflow: hidden;
    position: relative;
    background: var(--bg);
  }
  #detail-area {
    width: 340px;
    flex-shrink: 0;
    border-left: 1px solid var(--border);
    overflow-y: auto;
    padding: 12px;
    background: var(--panel);
  }
  #detail-area h3 { margin: 0 0 8px 0; font-size: 12px; color: var(--hl); }
  #detail-area dl { margin: 0; }
  #detail-area dt { color: var(--muted); font-size: 10px; margin-top: 6px; }
  #detail-area dd { margin: 2px 0 0 0; font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 11px; word-break: break-all; }
  #detail-area .hint { color: var(--muted); font-size: 11px; }

  #chart-scroll {
    position: absolute;
    inset: 0;
    overflow-x: auto;
    overflow-y: auto;
  }
  #chart-inner {
    position: relative;
    height: 100%;
    min-height: 100%;
  }

  #axis {
    position: sticky;
    top: 0;
    height: 26px;
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    z-index: 10;
  }
  .axis-tick {
    position: absolute;
    top: 0;
    bottom: 0;
    padding-left: 4px;
    font-size: 10px;
    color: var(--muted);
    border-left: 1px solid var(--border);
  }

  .labels {
    position: sticky;
    left: 0;
    z-index: 9;
    width: 260px;
    background: var(--panel);
    border-right: 1px solid var(--border);
  }

  .row {
    position: relative;
    height: 22px;
    border-bottom: 1px solid rgba(255,255,255,0.04);
    white-space: nowrap;
  }
  .row.alt { background: var(--row-alt); }
  .row .label {
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: 260px;
    padding: 3px 8px;
    background: var(--panel);
    border-right: 1px solid var(--border);
    overflow: hidden;
    text-overflow: ellipsis;
    z-index: 5;
  }
  .row .label .pid { color: var(--muted); margin-right: 6px; }
  .row .lane {
    position: absolute;
    left: 260px;
    top: 0;
    bottom: 0;
  }
  .span {
    position: absolute;
    top: 4px;
    bottom: 4px;
    background: var(--span);
    border: 1px solid var(--span-border);
    border-radius: 2px;
    pointer-events: auto;
  }
  .span:hover { background: rgba(120,150,200,0.4); }
  .event {
    position: absolute;
    top: 3px;
    width: 5px;
    height: 16px;
    border-radius: 1px;
    cursor: pointer;
    transform: translateX(-2px);
  }
  .event:hover { outline: 2px solid var(--hl); z-index: 6; }
  .event.write { background: #ff9c2a; width: 6px; }
  .event.merge { background: #4aa8ff; }
  .event.invariant-pass { background: #4ad06a; }
  .event.invariant-fail { background: #ff4a4a; width: 7px; box-shadow: 0 0 6px rgba(255,74,74,0.6); }
  .event.invariant-skip { background: #888; }
  .event.note { background: #c0c0c0; opacity: 0.65; width: 3px; }
  .event.enter { background: #c084fc; width: 2px; }
  .event.alert { background: #ff4a4a; width: 8px; }

  .snap-line {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 0;
    border-left: 1px dashed rgba(200,200,200,0.25);
    pointer-events: none;
    z-index: 2;
  }
  .snap-line.has-rt { border-color: rgba(74,208,106,0.55); }
  .snap-line.no-rt { border-color: rgba(255,74,74,0.5); }
  .snap-line .marker {
    position: absolute;
    top: -2px;
    left: -4px;
    width: 8px;
    height: 8px;
    background: inherit;
    pointer-events: auto;
    cursor: pointer;
  }
  .snap-line.has-rt .marker { background: #4ad06a; border-radius: 50%; }
  .snap-line.no-rt .marker { background: #ff4a4a; border-radius: 50%; }

  #tooltip {
    position: fixed;
    background: #0b0b0b;
    border: 1px solid #555;
    padding: 6px 9px;
    font-size: 11px;
    pointer-events: none;
    max-width: 380px;
    z-index: 100;
    border-radius: 4px;
    display: none;
    box-shadow: 0 6px 24px rgba(0,0,0,0.6);
    line-height: 1.4;
  }

  #controls {
    position: absolute;
    right: 10px;
    bottom: 10px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 6px 8px;
    display: flex;
    gap: 8px;
    z-index: 50;
    align-items: center;
    font-size: 11px;
  }
  #controls button {
    background: #333;
    color: var(--text);
    border: 1px solid #555;
    padding: 3px 8px;
    cursor: pointer;
    border-radius: 3px;
    font-size: 11px;
  }
  #controls button:hover { background: #444; }
  #controls input[type=range] { width: 140px; }
  #controls input[type=text] { background: #1a1a1a; color: var(--text); border: 1px solid #555; padding: 3px 6px; font-size: 11px; border-radius: 3px; width: 140px; }
  #controls label { display: inline-flex; align-items: center; gap: 3px; cursor: pointer; }

  #stage-bg {
    position: absolute;
    left: 260px;
    top: 26px;
    bottom: 0;
    z-index: 1;
    pointer-events: none;
  }
</style>
</head>
<body>
<div id="header">
  <strong>Bootstrap trace timeline</strong>
  <span class="meta">
    <b>""" + run_id + """</b> &middot;
    started <b>""" + started_at + """</b> &middot;
    duration <b id="meta-duration">…</b> &middot;
    <b id="meta-procs">…</b> processes &middot;
    <b id="meta-events">…</b> events &middot;
    <b id="meta-snaps">…</b> snapshots
  </span>
</div>
<div id="legend">
  <span class="leg"><span class="swatch" style="background:#ff9c2a"></span> file write</span>
  <span class="leg"><span class="swatch" style="background:#4aa8ff"></span> merge wrapper</span>
  <span class="leg"><span class="swatch" style="background:#4ad06a"></span> invariant pass</span>
  <span class="leg"><span class="swatch" style="background:#ff4a4a"></span> invariant fail</span>
  <span class="leg"><span class="swatch" style="background:#888"></span> invariant skip</span>
  <span class="leg"><span class="swatch" style="background:#c084fc"></span> script entry</span>
  <span class="leg"><span class="swatch" style="background:#c0c0c0"></span> log/note</span>
  <span class="leg"><span class="swatch" style="background:#4ad06a;border-radius:50%"></span> snapshot (VADE_RUNTIME_DIR present)</span>
  <span class="leg"><span class="swatch" style="background:#ff4a4a;border-radius:50%"></span> snapshot (missing)</span>
  <span class="leg" style="margin-left:auto">scroll = pan · ⌘/Ctrl+scroll = zoom · click event/snapshot for detail</span>
</div>
<div id="main">
  <div id="chart-area">
    <div id="chart-scroll">
      <div id="chart-inner">
        <div id="axis"></div>
        <div id="rows"></div>
      </div>
    </div>
    <div id="controls">
      <span>zoom</span>
      <input type="range" id="zoom" min="0.05" max="30" step="0.05" value="1">
      <button id="fit">fit window</button>
      <button id="boot-zoom">boot (0–5s)</button>
      <span style="margin-left:8px">filter</span>
      <input type="text" id="filter" placeholder="script name…">
      <label><input type="checkbox" id="hide-noise" checked> hide wrappers</label>
      <label><input type="checkbox" id="boot-only" checked> boot window only</label>
    </div>
  </div>
  <div id="detail-area">
    <h3 id="detail-title">Detail</h3>
    <div id="detail-body" class="hint">
      Click an event or snapshot to inspect it. Scroll the chart with the trackpad/wheel. Hold ⌘ or Ctrl + scroll to zoom.
    </div>
  </div>
</div>
<div id="tooltip"></div>
<script>
const DATA = """ + json.dumps(data) + """;
"""
    + r"""
const TARGETS = {
  ROW_HEIGHT: 22,
  AXIS_HEIGHT: 26,
  LABEL_WIDTH: 260,
  MIN_PX_PER_MS: 0.05,
  MAX_PX_PER_MS: 30,
};

let pxPerMs = 0.5;
const chartInner = document.getElementById("chart-inner");
const rowsHost = document.getElementById("rows");
const axisHost = document.getElementById("axis");
const scroll = document.getElementById("chart-scroll");
const tooltip = document.getElementById("tooltip");

// resolve a script color by name
function scriptColor(script) {
  const key = (script || "").toLowerCase();
  if (key.includes("session-start-sync")) return "#4aa8ff";
  if (key.includes("integrity-check")) return "#ff4a4a";
  if (key.includes("coo-bootstrap")) return "#4ad06a";
  if (key.includes("coo-identity-digest")) return "#ff9c2a";
  if (key.includes("memo-index")) return "#c084fc";
  if (key.includes("session-lifecycle")) return "#ffd35a";
  if (key.includes("session-idle")) return "#aaa";
  if (key.includes("discussions-digest")) return "#22d3ee";
  if (key.includes("bash-")) return "#7f8c8d";
  if (key.includes("dispatch")) return "#677";
  return "#999";
}

function setMeta() {
  document.getElementById("meta-duration").textContent = `${DATA.duration_ms.toFixed(0)} ms`;
  document.getElementById("meta-procs").textContent = DATA.pids.length;
  document.getElementById("meta-events").textContent = DATA.events.length;
  document.getElementById("meta-snaps").textContent = DATA.snapshots.length;
}

const BOOT_WINDOW_MS = 22000;
const NOISE_SCRIPTS = new Set(["dispatch.sh", "bootstrap-trace-init.sh"]);
function isNoisePid(p) {
  if (NOISE_SCRIPTS.has(p.script)) return true;
  // brief git subprocesses are integrity-check children; skip when many
  if (p.script === "git" && p.count < 100) return true;
  if (p.script === "bash-github-api-guard.sh") return true;
  if (p.script === "bash-token-guard.sh") return true;
  return false;
}

function visiblePids() {
  const filterTxt = (document.getElementById("filter").value || "").toLowerCase();
  const hideNoise = document.getElementById("hide-noise").checked;
  const bootOnly = document.getElementById("boot-only").checked;
  return DATA.pids.filter(p => {
    if (bootOnly && p.first_ms >= BOOT_WINDOW_MS) return false;
    if (hideNoise && isNoisePid(p)) return false;
    if (filterTxt && !(`${p.pid} ${p.script}`.toLowerCase().includes(filterTxt))) return false;
    return true;
  });
}

function effectiveDurationMs() {
  if (document.getElementById("boot-only").checked) return BOOT_WINDOW_MS;
  return DATA.duration_ms;
}

function render() {
  rowsHost.innerHTML = "";
  axisHost.innerHTML = "";
  // also clear any old snap-lines
  chartInner.querySelectorAll(".snap-line").forEach(n => n.remove());

  const pids = visiblePids();
  const totalMs = effectiveDurationMs();
  const chartWidth = TARGETS.LABEL_WIDTH + totalMs * pxPerMs + 60;
  chartInner.style.width = `${chartWidth}px`;
  chartInner.style.height = `${TARGETS.AXIS_HEIGHT + pids.length * TARGETS.ROW_HEIGHT + 40}px`;

  // axis
  const tickStep = pickTickStep(pxPerMs);
  axisHost.style.width = `${chartWidth}px`;
  for (let t = 0; t <= totalMs; t += tickStep) {
    const tick = document.createElement("div");
    tick.className = "axis-tick";
    tick.style.left = `${TARGETS.LABEL_WIDTH + t * pxPerMs}px`;
    tick.textContent = formatMs(t);
    axisHost.appendChild(tick);
  }

  // rows
  const eventsByPid = new Map();
  for (const ev of DATA.events) {
    if (!eventsByPid.has(ev.pid)) eventsByPid.set(ev.pid, []);
    eventsByPid.get(ev.pid).push(ev);
  }

  pids.forEach((p, idx) => {
    const row = document.createElement("div");
    row.className = "row" + (idx % 2 ? " alt" : "");
    row.style.top = `${idx * TARGETS.ROW_HEIGHT}px`;
    row.style.position = "absolute";
    row.style.left = "0";
    row.style.width = `${chartWidth}px`;

    const label = document.createElement("div");
    label.className = "label";
    label.title = `${p.script} (PID ${p.pid}) — ${p.count} commands`;
    label.innerHTML = `<span class="pid">${p.pid}</span><span style="color:${scriptColor(p.script)}">${escapeHtml(p.script)}</span>`;
    row.appendChild(label);

    const lane = document.createElement("div");
    lane.className = "lane";
    lane.style.left = `${TARGETS.LABEL_WIDTH}px`;
    lane.style.width = `${DATA.duration_ms * pxPerMs + 60}px`;

    const span = document.createElement("div");
    span.className = "span";
    const startX = p.first_ms * pxPerMs;
    const widthX = Math.max(2, (p.last_ms - p.first_ms) * pxPerMs);
    span.style.left = `${startX}px`;
    span.style.width = `${widthX}px`;
    span.style.borderColor = scriptColor(p.script);
    span.title = `${p.script} (PID ${p.pid}) — ${formatMs(p.first_ms)} → ${formatMs(p.last_ms)} (${(p.last_ms - p.first_ms).toFixed(1)} ms, ${p.count} commands)`;
    span.addEventListener("click", () => showProcDetail(p));
    span.addEventListener("mouseenter", e => showTooltip(e, `PID ${p.pid} · ${p.script}<br>${formatMs(p.first_ms)} → ${formatMs(p.last_ms)} (${(p.last_ms - p.first_ms).toFixed(1)} ms)<br>${p.count} commands`));
    span.addEventListener("mousemove", moveTooltip);
    span.addEventListener("mouseleave", hideTooltip);
    lane.appendChild(span);

    const evs = eventsByPid.get(p.pid) || [];
    for (const ev of evs) {
      const dot = document.createElement("div");
      dot.className = `event ${ev.type}`;
      dot.style.left = `${ev.ts_ms * pxPerMs}px`;
      dot.title = `${ev.label} @ ${formatMs(ev.ts_ms)}`;
      dot.addEventListener("click", e => { e.stopPropagation(); showEventDetail(ev, p); });
      dot.addEventListener("mouseenter", e =>
        showTooltip(e, `<b>${escapeHtml(ev.label)}</b><br>${formatMs(ev.ts_ms)} · PID ${ev.pid}<br>${escapeHtml(ev.script)}:${ev.line || "?"} fn=${escapeHtml(ev.fn)}` + (ev.detail ? `<br><i>${escapeHtml(ev.detail.slice(0,160))}</i>` : ""))
      );
      dot.addEventListener("mousemove", moveTooltip);
      dot.addEventListener("mouseleave", hideTooltip);
      lane.appendChild(dot);
    }

    row.appendChild(lane);
    rowsHost.appendChild(row);
  });

  // overlay snapshots as vertical lines
  rowsHost.style.position = "absolute";
  rowsHost.style.top = `${TARGETS.AXIS_HEIGHT}px`;
  rowsHost.style.left = "0";
  rowsHost.style.right = "0";
  rowsHost.style.height = `${pids.length * TARGETS.ROW_HEIGHT}px`;

  const bootOnly = document.getElementById("boot-only").checked;
  for (const snap of DATA.snapshots) {
    if (bootOnly && snap.ts_ms >= BOOT_WINDOW_MS) continue;
    const line = document.createElement("div");
    const present = snap.env && snap.env.has_VADE_RUNTIME_DIR;
    line.className = "snap-line " + (snap.env ? (present ? "has-rt" : "no-rt") : "");
    line.style.left = `${TARGETS.LABEL_WIDTH + snap.ts_ms * pxPerMs}px`;
    line.style.top = `${TARGETS.AXIS_HEIGHT}px`;
    line.style.height = `${pids.length * TARGETS.ROW_HEIGHT}px`;
    const marker = document.createElement("div");
    marker.className = "marker";
    marker.addEventListener("click", e => { e.stopPropagation(); showSnapDetail(snap); });
    marker.addEventListener("mouseenter", e => showTooltip(e, snapTooltip(snap)));
    marker.addEventListener("mousemove", moveTooltip);
    marker.addEventListener("mouseleave", hideTooltip);
    line.appendChild(marker);
    chartInner.appendChild(line);
  }
}

function snapTooltip(s) {
  const e = s.env || {};
  return `<b>snapshot</b> @ ${formatMs(s.ts_ms)}<br>${escapeHtml(s.script)}-enter (BASHPID ${s.pid})<br>settings.json env keys: ${e.env_keys_count ?? "?"}<br>VADE_RUNTIME_DIR: <b style="color:${e.has_VADE_RUNTIME_DIR ? '#4ad06a' : '#ff4a4a'}">${e.has_VADE_RUNTIME_DIR ? "present" : "missing"}</b><br>VADE_COO_MEMORY_DIR: ${e.has_VADE_COO_MEMORY_DIR ? "present" : "missing"}<br>VADE_CLOUD_STATE_DIR: ${e.has_VADE_CLOUD_STATE_DIR ? "present" : "missing"}`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
}

function formatMs(ms) {
  if (ms < 1000) return ms.toFixed(0) + " ms";
  return (ms / 1000).toFixed(2) + " s";
}

function pickTickStep(pxPerMs) {
  // pick tick spacing so labels are ~80px apart
  const targetPx = 80;
  const stepMs = targetPx / pxPerMs;
  const candidates = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 30000, 60000];
  for (const c of candidates) if (c >= stepMs) return c;
  return candidates[candidates.length - 1];
}

function showTooltip(e, html) {
  tooltip.innerHTML = html;
  tooltip.style.display = "block";
  moveTooltip(e);
}
function moveTooltip(e) {
  const padding = 12;
  let x = e.clientX + padding;
  let y = e.clientY + padding;
  const tw = tooltip.offsetWidth;
  const th = tooltip.offsetHeight;
  if (x + tw > window.innerWidth) x = e.clientX - padding - tw;
  if (y + th > window.innerHeight) y = e.clientY - padding - th;
  tooltip.style.left = `${x}px`;
  tooltip.style.top = `${y}px`;
}
function hideTooltip() { tooltip.style.display = "none"; }

function showProcDetail(p) {
  const title = document.getElementById("detail-title");
  const body = document.getElementById("detail-body");
  title.textContent = `Process · PID ${p.pid}`;
  body.classList.remove("hint");
  body.innerHTML = `<dl>
    <dt>script</dt><dd style="color:${scriptColor(p.script)}">${escapeHtml(p.script)}</dd>
    <dt>first seen</dt><dd>${formatMs(p.first_ms)}</dd>
    <dt>last seen</dt><dd>${formatMs(p.last_ms)}</dd>
    <dt>lifespan</dt><dd>${(p.last_ms - p.first_ms).toFixed(1)} ms</dd>
    <dt>commands in xtrace</dt><dd>${p.count}</dd>
  </dl>`;
}

function showEventDetail(ev, p) {
  const title = document.getElementById("detail-title");
  const body = document.getElementById("detail-body");
  title.innerHTML = `<span style="color:${typeColor(ev.type)}">${escapeHtml(ev.label)}</span>`;
  body.classList.remove("hint");
  body.innerHTML = `<dl>
    <dt>type</dt><dd>${ev.type}</dd>
    <dt>timestamp</dt><dd>${formatMs(ev.ts_ms)} (epoch+${ev.ts_ms.toFixed(3)} ms)</dd>
    <dt>process</dt><dd>PID ${ev.pid} — <span style="color:${scriptColor(p.script)}">${escapeHtml(p.script)}</span></dd>
    <dt>source line</dt><dd>${escapeHtml(ev.script)}:${ev.line || "?"}</dd>
    <dt>function</dt><dd>${escapeHtml(ev.fn)}</dd>
    ${ev.detail ? `<dt>detail</dt><dd>${escapeHtml(ev.detail)}</dd>` : ""}
    <dt>raw command</dt><dd style="white-space:pre-wrap">${escapeHtml(ev.cmd)}</dd>
  </dl>`;
}

function showSnapDetail(snap) {
  const e = snap.env || {};
  const title = document.getElementById("detail-title");
  const body = document.getElementById("detail-body");
  title.textContent = `Snapshot · ${snap.script}`;
  body.classList.remove("hint");
  body.innerHTML = `<dl>
    <dt>timestamp</dt><dd>${formatMs(snap.ts_ms)}</dd>
    <dt>trigger</dt><dd>${escapeHtml(snap.script)}-enter (BASHPID ${snap.pid})</dd>
    <dt>settings.json env keys</dt><dd>${e.env_keys_count ?? "?"}</dd>
    <dt>VADE_RUNTIME_DIR</dt><dd style="color:${e.has_VADE_RUNTIME_DIR ? '#4ad06a' : '#ff4a4a'}">${e.has_VADE_RUNTIME_DIR ? "present" : "missing"}</dd>
    <dt>VADE_COO_MEMORY_DIR</dt><dd style="color:${e.has_VADE_COO_MEMORY_DIR ? '#4ad06a' : '#ff4a4a'}">${e.has_VADE_COO_MEMORY_DIR ? "present" : "missing"}</dd>
    <dt>VADE_CLOUD_STATE_DIR</dt><dd style="color:${e.has_VADE_CLOUD_STATE_DIR ? '#4ad06a' : '#ff4a4a'}">${e.has_VADE_CLOUD_STATE_DIR ? "present" : "missing"}</dd>
    <dt>snapshot dir</dt><dd>${escapeHtml(snap.dir)}</dd>
  </dl>`;
}

function typeColor(t) {
  return {
    "write": "#ff9c2a", "merge": "#4aa8ff",
    "invariant-pass": "#4ad06a", "invariant-fail": "#ff4a4a", "invariant-skip": "#888",
    "note": "#c0c0c0", "enter": "#c084fc", "alert": "#ff4a4a",
  }[t] || "#fff";
}

// Zoom controls
const zoomInput = document.getElementById("zoom");
zoomInput.addEventListener("input", () => { pxPerMs = parseFloat(zoomInput.value); render(); });
document.getElementById("fit").addEventListener("click", () => {
  const usable = scroll.clientWidth - TARGETS.LABEL_WIDTH - 60;
  pxPerMs = Math.max(TARGETS.MIN_PX_PER_MS, Math.min(TARGETS.MAX_PX_PER_MS, usable / effectiveDurationMs()));
  zoomInput.value = pxPerMs;
  render();
  scroll.scrollLeft = 0;
});
document.getElementById("boot-zoom").addEventListener("click", () => {
  const usable = scroll.clientWidth - TARGETS.LABEL_WIDTH - 60;
  pxPerMs = Math.max(TARGETS.MIN_PX_PER_MS, Math.min(TARGETS.MAX_PX_PER_MS, usable / 5000));
  zoomInput.value = pxPerMs;
  render();
  scroll.scrollLeft = 0;
});
document.getElementById("filter").addEventListener("input", render);
document.getElementById("hide-noise").addEventListener("change", render);
document.getElementById("boot-only").addEventListener("change", render);

// wheel zoom (ctrl/cmd)
scroll.addEventListener("wheel", (e) => {
  if (!(e.ctrlKey || e.metaKey)) return;
  e.preventDefault();
  const rect = scroll.getBoundingClientRect();
  const xInChart = scroll.scrollLeft + (e.clientX - rect.left) - TARGETS.LABEL_WIDTH;
  const msAtPointer = xInChart / pxPerMs;
  const factor = e.deltaY < 0 ? 1.2 : 1 / 1.2;
  const next = Math.max(TARGETS.MIN_PX_PER_MS, Math.min(TARGETS.MAX_PX_PER_MS, pxPerMs * factor));
  if (next === pxPerMs) return;
  pxPerMs = next;
  zoomInput.value = pxPerMs;
  render();
  scroll.scrollLeft = msAtPointer * pxPerMs + (e.clientX - rect.left - TARGETS.LABEL_WIDTH) * 0 + TARGETS.LABEL_WIDTH - (e.clientX - rect.left);
  scroll.scrollLeft = msAtPointer * pxPerMs - (e.clientX - rect.left - TARGETS.LABEL_WIDTH);
}, { passive: false });

setMeta();
// initial fit
window.addEventListener("load", () => {
  const usable = scroll.clientWidth - TARGETS.LABEL_WIDTH - 60;
  pxPerMs = Math.max(TARGETS.MIN_PX_PER_MS, Math.min(TARGETS.MAX_PX_PER_MS, usable / Math.min(5000, BOOT_WINDOW_MS)));
  zoomInput.value = pxPerMs;
  render();
});
</script>
</body>
</html>
"""
)

with open(OUTPUT, "w") as f:
    f.write(HTML)
print(f"Wrote {OUTPUT}", file=sys.stderr)
