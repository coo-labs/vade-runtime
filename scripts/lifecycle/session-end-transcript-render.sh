#!/usr/bin/env bash
# Bash wrapper for session-end-transcript-render.py. Mirrors the
# detach/wait shape of session-end-transcript-export.sh — render runs
# in a setsid-forked child so the harness PG-kill at SessionEnd
# doesn't cut it short, and the wrapper block-waits up to BUDGET_SEC
# so the container teardown grace window covers the render PUT.
#
# Independent from the export hook: if export fails for any reason
# (missing creds, redact engine non-zero, container teardown), render
# is unaffected — it reads the LIVE jsonl from ~/.claude/projects/
# directly, not the encrypted archive. Conversely, render failure
# does not impact export (no cross-hook signal). Both are best-effort
# session-end work.
#
# Refs coo-labs/coo-console#12 sub-task 1b.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cold-start precondition: on a fresh hosted container the SessionEnd
# hook can fire before ~/.claude/projects exists. Bail silently — there
# is no live transcript to render.
if [ ! -d "${HOME}/.claude/projects" ]; then
  exit 0
fi

# Source coo-env if present (provides R2 secrets). Fail-open: missing
# env is handled inside the Python script (it logs and exits non-zero
# rather than corrupting state).
if [ -f "${HOME}/.vade/coo-env" ]; then
  # shellcheck disable=SC1090,SC1091
  . "${HOME}/.vade/coo-env" 2>/dev/null || true
fi

LOG_DIR="${HOME}/.vade/transcript-render-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/${TS}-$$.log"
MARKER="$LOG_DIR/${TS}-$$.done"

# Detach via setsid -f so the render survives the harness PG-kill at
# SessionEnd. Marker file touched after the Python exits so the parent
# can detect completion without holding a child PID.
setsid -f bash -c \
  "\"$SCRIPT_DIR/session-end-transcript-render.py\" \"\$@\"; touch \"$MARKER\"" \
  -- "$@" \
  </dev/null >"$LOG_FILE" 2>&1

# Render budget — much smaller than export (no redact, encrypt, gzip,
# auto-PR; just read-parse-template-PUT). ~1-3s typical, ~5-8s cold.
# 20s covers cold-start + R2 PUT with margin.
BUDGET_SEC="${VADE_TRANSCRIPT_RENDER_BUDGET_SEC:-20}"
i=0
while [ "$i" -lt "$BUDGET_SEC" ]; do
  if [ -f "$MARKER" ]; then
    rm -f "$MARKER"
    break
  fi
  sleep 1
  i=$((i + 1))
done

exit 0
