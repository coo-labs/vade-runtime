#!/usr/bin/env bash
# memo-index (thin wrapper).
#
# The real memo-index logic lives at
# coo-memory/.claude/_lib/memo-index.sh — it travels with the
# data it operates on (per the data-ownership rule from the 2026-04-25
# emancipation refactor; see MEMO 2026-04-25-02).
#
# This thin wrapper exists so the SessionStart hook chain (which dispatches
# `bash "$HOME/.claude/vade-hooks/dispatch.sh" memo-index` and resolves
# scripts under coo-harness/scripts/) continues to find a `memo-index.sh`
# entry point. It walks up to find vade-coo-memory adjacent and re-invokes
# the canonical script there.
#
# Graceful: if vade-coo-memory is not adjacent (peer-agent surface, fresh
# vade-runtime clone with no companion), log and exit 0. The hook chain
# does not fail because the index is missing.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd -P)"

# Candidate roots, first that resolves wins.
CANDIDATES=(
  "${COO_MEMORY_DIR:-}"
  "$SELF_DIR/../../vade-coo-memory"     # runtime/scripts → workspace → vade-coo-memory
  "${CLAUDE_PROJECT_DIR:-}/../vade-coo-memory"
  "${CLAUDE_PROJECT_DIR:-}/vade-coo-memory"
  "$HOME/GitHub/coo-labs/coo-memory"
  "/home/user/coo-memory"
)

COO=""
for c in "${CANDIDATES[@]}"; do
  [ -z "$c" ] && continue
  if [ -f "$c/.claude/_lib/memo-index.sh" ]; then
    COO="$(cd "$c" && pwd -P)"
    break
  fi
done

if [ -z "$COO" ]; then
  echo "[memo-index wrapper] vade-coo-memory not adjacent; skipping (peer-agent surface or pre-refactor clone)."
  exit 0
fi

exec bash "$COO/.claude/_lib/memo-index.sh" "$@"
