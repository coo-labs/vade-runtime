#!/usr/bin/env bash
# Print a session-lifecycle reminder for Claude Code agents working in
# any coo-labs repo. Two modes:
#
#   session-lifecycle.sh         → boot reminder (SessionStart hook)
#   session-lifecycle.sh --end   → end-of-session reminder (Stop hook)
#
# Reminder-only. The script does not call Mem0, does not read Mem0,
# does not commit files. Its output tells Claude what to do; Claude
# does the work via MCP tools.
#
# See vade-coo-memory/coo/mem0_sop.md for the full SOP.
# See vade-coo-memory/coo/briefings/003-claude-code-cross-session-state.md
# for the design rationale (relocated from vade-core/docs/briefings/
# per MEMO-2026-04-27-02).
#
# Graceful no-op if sourced libraries or node are missing; never
# breaks session start or stop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

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

  echo "───────────────────────────────────────────────────────────────"
  echo "Session lifecycle (SOP-MEM-001 §5)"
  echo ""
  echo "Runtime identity: agent_id=\"claude-code\""
  echo "Suggested run_id: $RUN_ID"
  echo ""
  echo "On start (SOP-MEM-001 v1.1 §5):"
  echo "  • Identity load — get_memories with filter"
  echo "      {AND: [{user_id: \"coo\"}]}"
  echo "    Pulls every core_belief (CB-*) and overarching_goal (OG-*)."
  echo "  • Recent-episodic handoff — search_memories with filter"
  echo "      {AND: [{user_id: \"ven\"},"
  echo "             {metadata: {created_by: \"coo\"}},"
  echo "             {created_at: {gte: \"<now - 24h>\"}}]}"
  echo "    Pulls the prior session's session_summary and any other"
  echo "    recent episodic entries. Check artifact_refs for in-flight"
  echo "    plan files from prior sessions."
  echo ""

  plans="$(list_plans || true)"
  if [ -n "$plans" ]; then
    echo "  • Plan files already present:"
    while IFS= read -r p; do
      [ -n "$p" ] && echo "      - $p"
    done <<< "$plans"
    echo "    These may be stale from a prior session or pre-committed"
    echo "    work. Cross-reference with the Mem0 hand-off above."
    echo ""
  fi

  # Prior idle-close stub logs: if the watchdog
  # (coo-labs/vade-agent-logs#67) fired a mechanical close on a recent
  # session, the next interactive COO owes a real summary. Surface
  # any unpaired stubs from the last 3 days so the agent doesn't have
  # to discover them.
  agent_logs_dir=""
  for _cand in "$HOME/GitHub/coo-labs/vade-agent-logs" "/home/user/vade-agent-logs"; do
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
        # Skip stubs that already have a paired summary file in the same dir.
        stub_dir="$(dirname "$stub")"
        if [ -f "$stub_dir/coo-summary-on-${sid}.md" ]; then continue; fi
        if [ -z "${idle_close_header_printed:-}" ]; then
          echo "  • Prior session(s) ended on idle (coo-labs/vade-agent-logs#67):"
          idle_close_header_printed=1
        fi
        echo "      - ${stub#"$agent_logs_dir/"}"
      done <<< "$pending_stubs"
      if [ -n "${idle_close_header_printed:-}" ]; then
        echo "    These owe a real session summary. Append a sibling"
        echo "    coo-summary-on-<sessionId>.md in the same dir, or amend"
        echo "    the stub in place with what was worked on."
        echo ""
      fi
    fi
  fi

  echo "Full SOP: vade-coo-memory/coo/mem0_sop.md"
  echo "───────────────────────────────────────────────────────────────"
  exit 0
fi

# --- end mode ---

# Gate on marker written by the /end-session skill (vade-coo-memory).
# The skill runs the full session-end checklist and touches this file
# as its last step. When the marker is present, cleanup is done —
# consume it and exit silently rather than injecting a 50-line reminder
# into the next turn's context. When absent, emit a one-line nudge.
# Fixes coo-labs/vade-runtime#245 (Stop hook fires every turn, causing
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
