---
name: trace-timeline
description: Render an interactive HTML timeline from a bootstrap-trace run. Use when the user wants to view, visualize, inspect, or "see" what happened during a traced boot — process spans, write/read interleavings, snapshot states, the D-group invariant decisions. Triggers on phrases like "show me the trace", "visualize the boot", "timeline of the trace", "interactive diagram of the trace", "render the trace", or when investigating a `~/.vade/traces/<run-id>/` directory and a chart would be clearer than text. Reads `xtrace.log` + `snapshots/*/content/settings.json` + `meta.json`, writes a self-contained HTML file that opens in any browser. Read-only over the trace data. Don't invoke for: running a fresh trace (that's the `bootstrap-trace-init.sh` harness via container UI), proposing fixes to the boot pipeline (the audit pause forbids it), or operating on traces from other tools.
allowed-tools: Bash, Read, SendUserFile
---

# trace-timeline — interactive bootstrap-trace viewer

Render an interactive swim-lane timeline (Chrome-DevTools-Network-tab
shape) from a bootstrap-trace run. One row per OS process, lifespan
bars, colored event markers for writes / invariant decisions / merges /
script entries, and vertical lines for each snapshot moment colored by
whether `VADE_RUNTIME_DIR` was present in `settings.json` at that
instant. Pan, zoom, click for raw xtrace context.

Companion to the trace capture harness — see
[`scripts/debug/README.md`](../../scripts/debug/README.md) for the
capture side (`BASH_ENV` + `VADE_BOOTSTRAP_TRACE_MODE=1`).

## When to use this skill

Invoke when the user wants to **look** at a bootstrap trace rather
than read it. Triggers:

- "show me / visualize / render the trace"
- "interactive diagram of the boot"
- "timeline of the / what happened during the / when did X fire"
- "view the race", "see the writes", "see the snapshots"
- The user names a trace directory under `~/.vade/traces/`
  and would benefit from a chart over raw `xtrace.log` lines.

Don't invoke for:

- Running a fresh capture (handled by `bootstrap-trace-init.sh` and the
  container UI env vars per `scripts/debug/README.md`).
- Proposing fixes to the boot pipeline (the
  [vade-app/vade-coo-memory#762](https://github.com/vade-app/vade-coo-memory/issues/762)
  pause forbids it — render-and-document only).
- Traces produced by tools other than the bootstrap-trace harness
  (file layout is specific to this harness).

## Procedure

### 1. Locate the trace

If the user named one, use that. Otherwise default to the current:

```sh
TRACE=~/.vade/traces/$(cat ~/.vade/traces/CURRENT_RUN_ID)
ls "$TRACE" && cat "$TRACE/meta.json"
```

If `CURRENT_RUN_ID` is missing or `xtrace.log` doesn't exist, stop and
report — the harness either hasn't run or its output rolled.

### 2. Render

```sh
python3 /home/user/vade-runtime/scripts/debug/render-trace-timeline.py "$TRACE" /tmp/trace-timeline.html
```

The script:

- Parses `xtrace.log` (PS4-prefixed, one bash command per line) into
  per-PID lifespans and event lists.
- Resolves each PID to its real script name using the
  `_VTRACE_INVOCATION_TAG=` line emitted by `bootstrap-trace-init.sh`
  (first-seen wins — long-lived processes that re-source the init for
  a subshell don't get retagged).
- Walks `snapshots/*/content/settings.json` for each capture and
  records whether `VADE_RUNTIME_DIR` / `VADE_COO_MEMORY_DIR` /
  `VADE_CLOUD_STATE_DIR` were present.
- Captures these event kinds (one marker each on the timeline):
    - `_write_claude_settings_*` — file writes (orange)
    - `merge_coo_settings_*` — wrapper merge calls (blue)
    - `_add D[0-9]+ (true|false|skip)` — D-group invariant decisions
      (green / red / gray)
    - `set -euo pipefail` from a user script — script entry (purple)
    - selected `[vade-setup] …` log lines (gray notes)
- Writes a single self-contained HTML file (~250 KB) with embedded
  JSON. No CDN dependencies; opens offline.

### 3. Deliver

```sh
SendUserFile /tmp/trace-timeline.html with a one-line caption.
```

Orient the user briefly:

- **Default view** is the boot window (0–22 s), noise wrappers
  (`dispatch.sh`, guards, brief `git` subprocesses) hidden.
- **"boot (0–5 s)"** button zooms onto the actual race.
- **Ctrl/⌘ + scroll** zooms anywhere; drag the time slider for fine
  control; the script-name filter input narrows rows.
- Snapshot dots above the timeline are **red** when
  `VADE_RUNTIME_DIR` is missing from `settings.json`, **green** when
  present.
- Click any event marker or snapshot dot for raw xtrace
  context in the right-hand detail panel.

If the trace contains a D4=false event (the canonical reader-vs-writer
race for vade-app/vade-coo-memory#762), name it explicitly — the bright
red glowing dot in the integrity-check row, with the three orange
write markers in the session-start-sync row immediately around it,
**is** the race.

## What the timeline answers

| Question | Where to look |
|---|---|
| Which hooks ran in parallel? | Stacked lifespan bars in the default view. |
| Did writer A and writer B overlap? | Two rows, their orange markers' x-positions. |
| Did integrity-check read before settings.json was complete? | Red snapshot dots to the left of the writer's last orange marker; D4=false event between them. |
| Why did D-group invariant N fail? | Click the red marker on the integrity-check row → detail panel shows `_add` source line, full `cmd` text, and `detail` string. |
| When did each script enter? | Purple "enter" markers at the left edge of each row's lifespan bar. |
| Which subprocess of integrity-check is which `git`? | Toggle off "hide wrappers" and the brief git PIDs appear; click each for its commands count and PID. |

## What the timeline can't answer

- **Sub-millisecond interleave inside `node -e` blocks.** xtrace records
  bash entry/exit, not syscalls inside spawned binaries. Atomic-rename
  vs read inside a node helper is invisible at this resolution.
- **Process parent / child tree.** xtrace shows PID+BASHPID but not
  PPID; use a snapshot's `metadata/processes.txt` (linked in the
  snapshot detail) for the tree at that instant.
- **Anything before the first traced bash invocation.** Anthropic's
  pre-clone phase happens before `BASH_ENV` resolves; the trace begins
  at the first bash after the repo is on disk.

## Re-running on a fresh trace

The renderer is parameterized. Point it at any `~/.vade/traces/<run-id>/`
directory — pass the path positionally:

```sh
python3 /home/user/vade-runtime/scripts/debug/render-trace-timeline.py \
    ~/.vade/traces/bootstrap-trace-XXXX-YYYY \
    /tmp/trace-timeline.html
```

No arguments → defaults to the run named in `~/.vade/traces/CURRENT_RUN_ID`,
output to `/tmp/trace-timeline.html`.
