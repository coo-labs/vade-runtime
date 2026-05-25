#!/usr/bin/env bash
# SessionStart/SessionEnd hook dispatcher.
#
# Installed as $HOME/.claude/vade-hooks/dispatch.sh (symlink, maintained
# by sync_claude_config → ensure_hooks_dispatch_shim). Every hook command
# in .claude/settings.json invokes this script with a hook name as $1
# and any additional flags as $2+, e.g.:
#
#   bash "$HOME/.claude/vade-hooks/dispatch.sh" session-lifecycle --end
#
# The shim's job is to find the real script in coo-harness/scripts/
# without settings.json baking in a repo-specific path. Portability is
# concentrated here — settings.json references only $HOME-relative
# paths, which are defined on every platform Claude Code runs on.
#
# Resolver rules, first match wins:
#   1. $VADE_RUNTIME_DIR env var (explicit override)
#   2. $CLAUDE_PROJECT_DIR (Mac single-root case, where cwd=repo)
#   3. Parent of this shim's real path — i.e. vade-runtime/ itself when
#      the shim was installed via symlink by sync_claude_config
#   4. readlink of /home/user/.mcp.json — the MCP-config symlink target's
#      parent is vade-runtime (cloud case, layout-agnostic)
#   5. $HOME/GitHub/coo-labs/coo-harness (local Mac default)
#
# Every invocation appends one line to ~/.vade/boot.log recording which
# rule won + whether the target script was found. Non-fatal on every
# path: exit 0 even when nothing resolves, so a missing runtime doesn't
# cascade a hook chain failure. The integrity-check probe catches
# failures loudly on the next read.
#
# Contract: MEMO pairing this fix, vade-runtime PR closing the
# CLAUDE_PROJECT_DIR regression from #28.
set -euo pipefail

HOOK_NAME="${1:-}"
shift || true
HOOK_ARGS=("$@")

if [ -z "$HOOK_NAME" ]; then
  echo "hooks-dispatch: no hook name supplied" >&2
  exit 0
fi

BOOT_LOG="${HOME}/.vade/boot.log"
# Inline JSON-string escape (handles \, ", and the four control chars
# bash callers might pass). Duplicated from common.sh::_json_escape
# because the dispatch shim deliberately does not source common.sh —
# this script is the bootstrap entry point and must not depend on
# anything that could itself be missing or stale.
_je() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"; s="${s//$'\b'/\\b}"
  printf '%s' "$s"
}

_log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$BOOT_LOG")" 2>/dev/null || return 0
  printf '{"ts":"%s","script":"hooks-dispatch","hook":"%s","rule":"%s","runtime":"%s","ok":%s,"detail":"%s"}\n' \
    "$ts" "$(_je "$HOOK_NAME")" "$(_je "$1")" "$(_je "${2:-}")" "$3" "$(_je "${4:-}")" \
    >> "$BOOT_LOG" 2>/dev/null || return 0
}

_script_for() {
  local base="$1" name="$2"
  local candidate="$base/scripts/$name.sh"
  [ -f "$candidate" ] && printf '%s' "$candidate"
}

RESOLVED_RUNTIME=""
RESOLVED_RULE=""
RESOLVED_SCRIPT=""

# Rule 1: explicit override
if [ -n "${VADE_RUNTIME_DIR:-}" ] && target="$(_script_for "$VADE_RUNTIME_DIR" "$HOOK_NAME")" && [ -n "$target" ]; then
  RESOLVED_RUNTIME="$VADE_RUNTIME_DIR"
  RESOLVED_RULE="env_VADE_RUNTIME_DIR"
  RESOLVED_SCRIPT="$target"
fi

# Rule 2: CLAUDE_PROJECT_DIR (when cwd is the repo itself)
if [ -z "$RESOLVED_SCRIPT" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  if target="$(_script_for "$CLAUDE_PROJECT_DIR" "$HOOK_NAME")" && [ -n "$target" ]; then
    RESOLVED_RUNTIME="$CLAUDE_PROJECT_DIR"
    RESOLVED_RULE="CLAUDE_PROJECT_DIR"
    RESOLVED_SCRIPT="$target"
  fi
fi

# Rule 3: self-referential via shim's install path
if [ -z "$RESOLVED_SCRIPT" ]; then
  self_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  if [ -n "$self_path" ]; then
    self_runtime="$(cd "$(dirname "$self_path")/.." 2>/dev/null && pwd)"
    if [ -n "$self_runtime" ] && target="$(_script_for "$self_runtime" "$HOOK_NAME")" && [ -n "$target" ]; then
      RESOLVED_RUNTIME="$self_runtime"
      RESOLVED_RULE="self_path"
      RESOLVED_SCRIPT="$target"
    fi
  fi
fi

# Rule 4: derive from MCP-config symlink (cloud case, layout-agnostic)
if [ -z "$RESOLVED_SCRIPT" ] && [ -L /home/user/.mcp.json ]; then
  mcp_target="$(readlink -f /home/user/.mcp.json 2>/dev/null || true)"
  if [ -n "$mcp_target" ]; then
    mcp_runtime="$(dirname "$mcp_target")"
    if target="$(_script_for "$mcp_runtime" "$HOOK_NAME")" && [ -n "$target" ]; then
      RESOLVED_RUNTIME="$mcp_runtime"
      RESOLVED_RULE="mcp_symlink"
      RESOLVED_SCRIPT="$target"
    fi
  fi
fi

# Rule 5: local Mac default
if [ -z "$RESOLVED_SCRIPT" ] && [ -d "$HOME/GitHub/coo-labs/coo-harness" ]; then
  if target="$(_script_for "$HOME/GitHub/coo-labs/coo-harness" "$HOOK_NAME")" && [ -n "$target" ]; then
    RESOLVED_RUNTIME="$HOME/GitHub/coo-labs/coo-harness"
    RESOLVED_RULE="mac_default"
    RESOLVED_SCRIPT="$target"
  fi
fi

if [ -z "$RESOLVED_SCRIPT" ]; then
  _log "none" "" "false" "no resolver rule matched; hook skipped"
  echo "hooks-dispatch: could not locate $HOOK_NAME.sh in any known runtime location" >&2
  exit 0
fi

_log "$RESOLVED_RULE" "$RESOLVED_RUNTIME" "true" "dispatching to $RESOLVED_SCRIPT"

# Forward. Use `bash` explicitly (matches settings.json convention) and
# pass through additional args. Don't use exec — we want the logged
# dispatch line even if the hook crashes.
bash "$RESOLVED_SCRIPT" ${HOOK_ARGS[@]+"${HOOK_ARGS[@]}"}
