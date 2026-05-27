#!/usr/bin/env bash
# CI smoke test for scripts/lifecycle/session-idle-watchdog.sh.
#
# Three asserts:
#
#   1. cmd_close drops a coo-idle-close-<id>.md stub at the expected
#      coo-logs sessions path with the documented header shape
#      (Status / Started / Ended / Idle minutes / Event count).
#   2. The stub references the meta.json sidecar when one is present.
#   3. The bootstrap-mode --start path is a clean no-op when
#      VADE_SESSION_IDLE_DISABLE=1 is set (so CI doesn't fork a
#      background worker that outlives the test).
#
# The test does NOT exercise:
#   - Real Mem0 writes (no MEM0_API_KEY in the test env).
#   - Real git commits (no .git in the staged agent-logs dir).
#   - The transcript-export hook (covered by test-transcript-export.py).
#
# coo-labs/coo-logs#67.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WATCHDOG="$REPO_ROOT/scripts/lifecycle/session-idle-watchdog.sh"

if [ ! -x "$WATCHDOG" ]; then
  echo "FAIL: $WATCHDOG not executable" >&2
  exit 1
fi

WORKDIR="$(mktemp -d -t idle-watchdog-test-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_HOME="$WORKDIR/home"
FAKE_AGENT_LOGS="$WORKDIR/coo-logs"
FAKE_PROJECTS="$FAKE_HOME/.claude/projects/-home-user"
mkdir -p "$FAKE_HOME/.vade/agent-state" "$FAKE_HOME/.vade/idle-watchdog-logs" \
  "$FAKE_AGENT_LOGS/sessions" "$FAKE_AGENT_LOGS/transcripts/2026/04/28" \
  "$FAKE_PROJECTS"

SESSION_ID="testsession-aaaaaaaaaaaaaaaaaaaa"
JSONL="$FAKE_PROJECTS/${SESSION_ID}.jsonl"

# Synthetic jsonl with two parseable timestamps. Construct via printf
# to keep the shape clean. No secret-shaped tokens (scanner-clean).
printf '{"type":"user","timestamp":"2026-04-28T01:00:00.000Z","content":"hello"}\n' > "$JSONL"
printf '{"type":"assistant","timestamp":"2026-04-28T01:30:42.123Z","content":"world"}\n' >> "$JSONL"

# Synthetic meta.json sidecar (so the stub references it).
META_PATH="$FAKE_AGENT_LOGS/transcripts/2026/04/28/${SESSION_ID}.meta.json"
cat > "$META_PATH" <<EOF
{
  "schema_version": 1,
  "parser_version": 1,
  "session_id": "$SESSION_ID",
  "exported_at": "2026-04-28T01:30:55Z",
  "events_processed": 2,
  "redaction_hits": {}
}
EOF

# ---------------------------------------------------------------------------
# Test 1: --start with VADE_SESSION_IDLE_DISABLE=1 is a clean no-op.
# ---------------------------------------------------------------------------

env -i HOME="$FAKE_HOME" PATH="$PATH" \
  VADE_SESSION_IDLE_DISABLE=1 \
  bash "$WATCHDOG" --start

# No worker should have been forked; no PID file should exist.
if compgen -G "$FAKE_HOME/.vade/agent-state/idle-watchdog.*.pid" >/dev/null 2>&1; then
  echo "FAIL: VADE_SESSION_IDLE_DISABLE=1 still forked a worker (pid-file present)" >&2
  ls -la "$FAKE_HOME/.vade/agent-state/" >&2
  exit 1
fi
echo "ok: --start respects VADE_SESSION_IDLE_DISABLE=1"

# ---------------------------------------------------------------------------
# Test 2: cmd_close drops the stub log with expected shape and references.
# ---------------------------------------------------------------------------

# No MEM0_API_KEY in env → mem0 step is a no-op (logged as skipped).
# No .git in $FAKE_AGENT_LOGS → git step is a no-op (logged as skipped).
env -i HOME="$FAKE_HOME" PATH="$PATH" \
  VADE_AGENT_LOGS_DIR="$FAKE_AGENT_LOGS" \
  bash "$WATCHDOG" --close "$SESSION_ID" "$JSONL"

STUB="$FAKE_AGENT_LOGS/sessions/2026/04/28/coo-idle-close-${SESSION_ID}.md"
if [ ! -f "$STUB" ]; then
  echo "FAIL: stub not written at $STUB" >&2
  echo "tree of $FAKE_AGENT_LOGS:" >&2
  find "$FAKE_AGENT_LOGS" >&2
  exit 1
fi
echo "ok: stub written at $STUB"

assert_contains() {
  local needle="$1"
  if ! grep -qF -- "$needle" "$STUB"; then
    echo "FAIL: stub missing expected text: $needle" >&2
    echo "--- stub contents ---" >&2
    cat "$STUB" >&2
    exit 1
  fi
}

assert_contains 'Status:** incomplete'
assert_contains "Session ID:** \`${SESSION_ID}\`"
assert_contains 'Started:** 2026-04-28T01:00:00.000Z'
assert_contains 'Ended:**   2026-04-28T01:30:42.123Z'
assert_contains 'Event count:** 2'
assert_contains "Transcript sidecar:** \`transcripts/2026/04/28/${SESSION_ID}.meta.json\`"
assert_contains 'coo-labs/coo-logs#67'

echo "ok: stub shape matches expected schema"

# ---------------------------------------------------------------------------
# Test 3: cmd_close on a session_id without a sidecar still drops a stub
#         (no Transcript-sidecar line; no crash).
# ---------------------------------------------------------------------------

NO_SIDECAR_ID="testsession-bbbbbbbbbbbbbbbbbbbb"
NO_SIDECAR_JSONL="$FAKE_PROJECTS/${NO_SIDECAR_ID}.jsonl"
printf '{"type":"user","timestamp":"2026-04-28T02:00:00.000Z","content":"x"}\n' > "$NO_SIDECAR_JSONL"

env -i HOME="$FAKE_HOME" PATH="$PATH" \
  VADE_AGENT_LOGS_DIR="$FAKE_AGENT_LOGS" \
  bash "$WATCHDOG" --close "$NO_SIDECAR_ID" "$NO_SIDECAR_JSONL"

STUB2="$FAKE_AGENT_LOGS/sessions/2026/04/28/coo-idle-close-${NO_SIDECAR_ID}.md"
if [ ! -f "$STUB2" ]; then
  echo "FAIL: stub not written for no-sidecar case at $STUB2" >&2
  exit 1
fi
if grep -qF "Transcript sidecar:" "$STUB2"; then
  echo "FAIL: stub claims a sidecar that doesn't exist" >&2
  cat "$STUB2" >&2
  exit 1
fi
echo "ok: no-sidecar close case skips the sidecar reference cleanly"

# ---------------------------------------------------------------------------
# Test 4: --stop is idempotent (no-op when no PID files).
# ---------------------------------------------------------------------------

env -i HOME="$FAKE_HOME" PATH="$PATH" bash "$WATCHDOG" --stop
echo "ok: --stop is a clean no-op when nothing is live"

echo
echo "PASS: scripts/ci/test-session-idle-watchdog.sh"
