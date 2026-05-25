#!/usr/bin/env bash
# First-run setup for the VADE devcontainer.
# Idempotent: safe to run multiple times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

log "VADE devcontainer first-run setup"

ensure_dirs

install_deps /workspace

# gh CLI for COO attribution fallback (see coo-labs/vade-runtime#36 and
# ensure_gh_cli in lib/common.sh). No-op if gh is already present
# (local macOS via brew is common). Non-fatal on failure.
ensure_gh_cli || log "Warning: gh CLI install failed; continuing without the attribution fallback."

ensure_agent_hooks "$SCRIPT_DIR"

# Catch-up digest run: subsequent sessions get fresh output via the
# installed SessionStart hook.
bash "$SCRIPT_DIR/discussions-digest.sh" || true

print_versions

log "Done. Library at $HOME/.vade/library/"
