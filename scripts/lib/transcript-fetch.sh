#!/usr/bin/env bash
# Bash wrapper for transcript-fetch.py. Sources ~/.vade/coo-env so
# R2_TRANSCRIPTS_* and TRANSCRIPTS_AGE_IDENTITY are populated, then
# exec's the Python implementation.
#
# Usage:
#   bash scripts/lib/transcript-fetch.sh <session_id> [--meta <path>]
#   bash scripts/lib/transcript-fetch.sh --cleanup <jsonl_path>
#
# Exit codes propagate from the Python script; unlike the export-side
# wrapper, failures here surface to the caller (the Stage-1
# transcript-analyzer agent decides how to handle a fetch failure).
#
# coo-labs/vade-agent-logs#64 Batch 3.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${HOME}/.vade/coo-env" ]; then
  # shellcheck disable=SC1090,SC1091
  . "${HOME}/.vade/coo-env" 2>/dev/null || true
fi

exec "$SCRIPT_DIR/transcript-fetch.py" "$@"
