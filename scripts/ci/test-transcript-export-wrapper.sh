#!/usr/bin/env bash
# CI smoke test for scripts/session-end-transcript-export.sh.
#
# Locks down the wrapper's contract — the bash side that holds the
# Python child via `setsid -f` and block-waits on a marker file up to
# VADE_TRANSCRIPT_EXPORT_BUDGET_SEC. Origin: coo-labs/coo-harness#200.
#
# Four asserts:
#
#   1. Cold-start gate (#208): with $HOME/.claude/projects absent the
#      wrapper exits 0 instantly without invoking the Python child.
#      Catches removal of the gate and the cosmetic
#      unknown.export-error.txt drops it prevents.
#
#   2. Fast child → marker detected: stub Python with `exit 0`. Wrapper
#      exits within ~3s; marker file (`*.done`) is removed by the
#      wrapper after detection. Catches removal of the marker poll
#      and removal of the post-detect `rm -f "$MARKER"`.
#
#   3. Slow child → wrapper times out at budget; child survives:
#      stub Python with `sleep $((BUDGET + 5))` while
#      VADE_TRANSCRIPT_EXPORT_BUDGET_SEC=2. Wrapper exits at ~2s + slack;
#      detached child PID still in `kill -0` range after wrapper
#      returns. Catches removal of `setsid -f` (child would die with
#      the wrapper instead) and budget off-by-one regressions.
#
#   4. Marker cleanup symmetry: after the fast-child run, no `*.done`
#      file remains in $HOME/.vade/transcript-export-logs/. The
#      timestamped `*.log` is allowed to remain (per-invocation log
#      retention is by design). The slow-child test eventually drops
#      a marker post-budget; that's acceptable noise — assertion is
#      "fast path is clean", not "every path is clean".
#
# The test does NOT exercise:
#   - The Python redact + encrypt + R2 PutObject + auto-PR flow
#     (covered by test-transcript-export.py + live E6/E7/E8).
#   - Hook-chain triggering by the Claude Code harness (Layer-2,
#     coo-harness#85).
#   - Real container teardown timing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER_SRC="$REPO_ROOT/scripts/session-end-transcript-export.sh"

if [ ! -x "$WRAPPER_SRC" ]; then
  echo "FAIL: $WRAPPER_SRC not executable" >&2
  exit 1
fi

# Require setsid + timeout + python3-or-bash for the stubs.
for cmd in setsid timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "FAIL: required command '$cmd' not in PATH" >&2
    exit 1
  fi
done

WORKDIR="$(mktemp -d -t transcript-export-wrapper-test-XXXXXX)"
SLOW_CHILD_PID=""
cleanup() {
  rc=$?
  # Reap any lingering slow-child setsid'd descendant to avoid zombies
  # outliving the test run.
  if [ -n "${SLOW_CHILD_PID:-}" ] && kill -0 "$SLOW_CHILD_PID" 2>/dev/null; then
    kill -9 "$SLOW_CHILD_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Stage: copy wrapper + sibling-stub into a tempdir so $SCRIPT_DIR
# resolves to the staged copy. Each subtest re-stages the stub it wants.
# ---------------------------------------------------------------------------
STAGE="$WORKDIR/stage"
mkdir -p "$STAGE"
cp "$WRAPPER_SRC" "$STAGE/session-end-transcript-export.sh"
chmod +x "$STAGE/session-end-transcript-export.sh"

WRAPPER="$STAGE/session-end-transcript-export.sh"
STUB="$STAGE/session-end-transcript-export.py"

stage_stub() {
  # Replace the sibling stub. First arg is the stub's body (shell);
  # shebang is added automatically.
  local body="$1"
  cat > "$STUB" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$STUB"
}

# Each test runs with a fresh isolated $HOME so log dirs don't collide.
fresh_home() {
  local home_dir="$WORKDIR/home-$1"
  rm -rf "$home_dir"
  mkdir -p "$home_dir"
  printf '%s' "$home_dir"
}

# ---------------------------------------------------------------------------
# Test 1: cold-start gate. No $HOME/.claude/projects → wrapper exits 0
# instantly without invoking the stub.
# ---------------------------------------------------------------------------
T1_HOME="$(fresh_home t1)"

# Stub that would write a "ran" marker if invoked. If the cold-start
# gate works, this file should never appear.
RAN_MARKER="$T1_HOME/.stub-ran"
stage_stub "touch \"$RAN_MARKER\""

t1_start=$(date +%s)
env -i HOME="$T1_HOME" PATH="$PATH" \
  bash "$WRAPPER" >/dev/null 2>&1
t1_end=$(date +%s)
t1_elapsed=$((t1_end - t1_start))

if [ -e "$RAN_MARKER" ]; then
  echo "FAIL: cold-start gate breached — stub ran despite missing ~/.claude/projects" >&2
  exit 1
fi
if [ "$t1_elapsed" -gt 2 ]; then
  echo "FAIL: cold-start path took ${t1_elapsed}s — should be near-instant" >&2
  exit 1
fi
echo "ok: cold-start gate exits 0 instantly without invoking child (${t1_elapsed}s)"

# ---------------------------------------------------------------------------
# Test 2: fast child → marker detected, wrapper exits cleanly.
# ---------------------------------------------------------------------------
T2_HOME="$(fresh_home t2)"
mkdir -p "$T2_HOME/.claude/projects"

# Stub completes immediately (exit 0). The setsid'd subshell should
# touch the marker and the wrapper should detect within the 1s poll.
stage_stub "exit 0"

t2_start=$(date +%s)
env -i HOME="$T2_HOME" PATH="$PATH" \
  VADE_TRANSCRIPT_EXPORT_BUDGET_SEC=10 \
  bash "$WRAPPER" >/dev/null 2>&1
t2_end=$(date +%s)
t2_elapsed=$((t2_end - t2_start))

if [ "$t2_elapsed" -gt 3 ]; then
  echo "FAIL: fast-child wrapper took ${t2_elapsed}s — marker poll regressed (budget was 10, expected ~1s)" >&2
  exit 1
fi
echo "ok: fast child detected via marker (${t2_elapsed}s, budget=10s)"

# ---------------------------------------------------------------------------
# Test 4 (interleaved with 2 since they share fast-path state):
# After a fast-child run no `*.done` marker remains in the log dir
# (the wrapper rm -f's it on detection).
# ---------------------------------------------------------------------------
T2_LOG_DIR="$T2_HOME/.vade/transcript-export-logs"
if compgen -G "$T2_LOG_DIR/*.done" >/dev/null 2>&1; then
  echo "FAIL: orphan *.done marker remains after fast-child run:" >&2
  ls -la "$T2_LOG_DIR" >&2
  exit 1
fi
echo "ok: no orphan *.done marker after fast-child run"

# ---------------------------------------------------------------------------
# Test 3: slow child → wrapper exits at budget; detached child survives.
# Stub writes its PID before sleeping so we can probe it after the
# wrapper returns.
# ---------------------------------------------------------------------------
T3_HOME="$(fresh_home t3)"
mkdir -p "$T3_HOME/.claude/projects"

PID_FILE="$T3_HOME/stub.pid"
# Sleep budget + 5 so the wrapper's 2s budget definitely runs out.
stage_stub "echo \$\$ > \"$PID_FILE\"; sleep 7; exit 0"

t3_start=$(date +%s)
env -i HOME="$T3_HOME" PATH="$PATH" \
  VADE_TRANSCRIPT_EXPORT_BUDGET_SEC=2 \
  bash "$WRAPPER" >/dev/null 2>&1
t3_end=$(date +%s)
t3_elapsed=$((t3_end - t3_start))

# Wrapper should exit at ~budget (2s), with up to ~1s slack on the
# poll loop. Allow up to 4s to give CI runners breathing room.
if [ "$t3_elapsed" -lt 2 ]; then
  echo "FAIL: slow-child wrapper exited in ${t3_elapsed}s — budget gate regressed (expected ~2s)" >&2
  exit 1
fi
if [ "$t3_elapsed" -gt 5 ]; then
  echo "FAIL: slow-child wrapper took ${t3_elapsed}s — budget regression or marker-poll bug (expected ~2s)" >&2
  exit 1
fi
echo "ok: slow child held wrapper at budget (${t3_elapsed}s, budget=2s)"

# Verify the detached child PID is still alive — if `setsid -f` were
# removed the child would have died with the wrapper's PG.
if [ ! -f "$PID_FILE" ]; then
  echo "FAIL: slow-child PID file never written — stub didn't run" >&2
  exit 1
fi
SLOW_CHILD_PID="$(cat "$PID_FILE")"
if ! kill -0 "$SLOW_CHILD_PID" 2>/dev/null; then
  echo "FAIL: detached child PID $SLOW_CHILD_PID died with the wrapper — setsid -f detach regressed" >&2
  exit 1
fi
echo "ok: detached child PID $SLOW_CHILD_PID survives wrapper exit (setsid -f intact)"

# Cleanup of the slow child happens in the EXIT trap.

echo "PASS: scripts/session-end-transcript-export.sh wrapper contract holds (4/4)"
