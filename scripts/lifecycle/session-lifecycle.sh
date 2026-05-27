#!/usr/bin/env bash
# Session lifecycle hook — end-mode prints an end-of-session reminder
# (Stop hook); start-mode just tags a run_id for the session.
#
# Reminder-only. The script does not call Mem0, does not read Mem0,
# does not commit files.
#
# Graceful no-op if sourced libraries are missing; never breaks
# session start or stop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

MODE="start"
if [ "${1:-}" = "--end" ]; then
  MODE="end"
fi

boot_log_record "session-lifecycle-$MODE" start
trap '_rc=$?; boot_log_record "session-lifecycle-'"$MODE"'" end $([ $_rc -eq 0 ] && echo ok || echo fail) rc=$_rc' EXIT

# Claude Code's Write tool resolves ~/ to /home/user in the cloud
# container while bash $HOME is /root. Plans authored through
# Claude's tools therefore land at a different path than the hook
# would see. Search both so the candidate list is complete
# regardless of which home a writer used.
PLANS_DIR="$HOME/.claude/plans"
CLAUDE_PLANS_DIR="/home/user/.claude/plans"

STATE_DIR="$HOME/.vade/agent-state"
RUN_ID_FILE="$STATE_DIR/current-run-id"
mkdir -p "$STATE_DIR" 2>/dev/null || true

list_plans() {
  {
    [ -d "$PLANS_DIR" ]        && find "$PLANS_DIR"        -maxdepth 1 -type f -name '*.md' 2>/dev/null
    [ "$PLANS_DIR" != "$CLAUDE_PLANS_DIR" ] && [ -d "$CLAUDE_PLANS_DIR" ] \
                               && find "$CLAUDE_PLANS_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null
  } | sort -u
}

if [ "$MODE" = "start" ]; then
  RUN_ID="run-$(date -u +%Y-%m-%dT%H%M%S)"
  echo "$RUN_ID" > "$RUN_ID_FILE" 2>/dev/null || true

  # Surface in-flight plan files from prior sessions and unpaired
  # idle-close stubs. Both are concrete handoffs the agent can act on;
  # the broader Mem0 SOP reminder was removed (Coo only uses Mem0 at
  # boot/end, not on every SessionStart resume).
  header_printed=0
  plans="$(list_plans || true)"
  if [ -n "$plans" ]; then
    [ "$header_printed" -eq 0 ] && echo "─── session-start surface ───" && header_printed=1
    echo "  • Plan files present:"
    while IFS= read -r p; do
      [ -n "$p" ] && echo "      - $p"
    done <<< "$plans"
  fi

  agent_logs_dir=""
  for _cand in "$HOME/GitHub/coo-labs/coo-logs" "/home/user/coo-logs"; do
    if [ -d "$_cand" ]; then agent_logs_dir="$_cand"; break; fi
  done
  if [ -n "$agent_logs_dir" ] && [ -d "$agent_logs_dir/sessions" ]; then
    pending_stubs="$(find "$agent_logs_dir/sessions" -type f \
      -name 'coo-idle-close-*.md' -mtime -3 2>/dev/null | sort)"
    if [ -n "$pending_stubs" ]; then
      while IFS= read -r stub; do
        [ -z "$stub" ] && continue
        sid="$(basename "$stub" .md)"
        sid="${sid#coo-idle-close-}"
        stub_dir="$(dirname "$stub")"
        if [ -f "$stub_dir/coo-summary-on-${sid}.md" ]; then continue; fi
        if [ -z "${idle_close_header_printed:-}" ]; then
          [ "$header_printed" -eq 0 ] && echo "─── session-start surface ───" && header_printed=1
          echo "  • Prior session(s) ended on idle (coo-labs/coo-logs#67):"
          idle_close_header_printed=1
        fi
        echo "      - ${stub#"$agent_logs_dir/"}"
      done <<< "$pending_stubs"
      if [ -n "${idle_close_header_printed:-}" ]; then
        echo "    Each owes a paired coo-summary-on-<sessionId>.md."
      fi
    fi
  fi
  exit 0
fi

# --- end mode ---

# Gate on marker written by the /end-session skill (vade-coo-memory).
# The skill runs the full session-end checklist and touches this file
# as its last step. When the marker is present, cleanup is done —
# consume it and exit silently rather than injecting a 50-line reminder
# into the next turn's context. When absent, emit a one-line nudge.
# Fixes coo-labs/coo-harness#245 (Stop hook fires every turn, causing
# per-turn context pollution).
END_MARKER="$HOME/.vade/.end-session-done"
if [ -f "$END_MARKER" ]; then
  rm -f "$END_MARKER"
  exit 0
fi

# /end-session was not run. Emit a minimal one-line systemMessage so
# the agent is reminded on the next turn without flooding the context.
if check_cmd node; then
  node -e 'process.stdout.write(JSON.stringify({systemMessage: "Session stopping. If this is the actual end of the session and /end-session was not run, run it now to commit plans, write the Mem0 entry, and persist the session log."}) + "\n");'
fi
