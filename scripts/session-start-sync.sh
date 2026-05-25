#!/usr/bin/env bash
# Defensive re-sync on every SessionStart.
#
# Snapshots go stale: the committed repo advances, but the
# baked-in <workspace>/.claude/settings.json and workspace-scope symlinks
# reflect whatever was in vade-runtime at build time. This script closes
# that gap by re-running the idempotent pieces of cloud-setup.sh /
# local-setup.sh that don't need 1Password access:
#
#   1. sync_claude_config  — mirror coo-harness/.claude into the
#      workspace .claude (preserves the env block populated by
#      coo-bootstrap so MCPs still pick up credentials).
#   2. ensure_workspace_mcp_config — workspace .mcp.json symlink.
#   3. ensure_workspace_identity_link — workspace CLAUDE.md symlink so
#      the harness memory loader auto-reads vade-coo-memory's identity.
#
# Target is $WORKSPACE_ROOT/.claude (the parent of vade-runtime). On
# cloud that resolves to $HOME (/home/user); on local it resolves to
# $DEV_DIR/vade-app, leaving the user's personal $HOME/.claude alone.
#
# Runs first in the SessionStart:startup hook chain (before
# coo-bootstrap) so all later hooks see the freshest hook list and
# symlinks. The sync itself still runs after MCP resolution, so new
# MCPs from a repo update only become visible from session N+1. That's
# the fundamental Phase-B constraint, not something we can close here.
#
# Safe to re-run any number of times; exits 0 on every path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

WORKSPACE_ROOT_DERIVED="$(cd "$SCRIPT_DIR/../.." && pwd)"

# common.sh seeds VADE_CLOUD_STATE_DIR with a cloud-host default (/home/user/.vade-cloud-state);
# on Mac local-setup.sh exports ~/.vade/local-state but hook subprocesses don't inherit its env.
# Redirect when the cloud path is absent and the local path exists so integrity-check.sh (and
# other hooks) write to the correct location. coo-harness#171.
if [ ! -d "$VADE_CLOUD_STATE_DIR" ] && [ -d "$HOME/.vade/local-state" ]; then
  VADE_CLOUD_STATE_DIR="$HOME/.vade/local-state"
fi

boot_log_record session-start-sync start
sync_claude_config "$SCRIPT_DIR/../.claude" "$WORKSPACE_ROOT_DERIVED/.claude"
# Aggregate per-repo primitives from data-owning repos. Per the
# data-ownership rule (MEMO 2026-04-25-02), slash commands and skills
# live in the repo whose data they manipulate; the aggregator surfaces
# them at the workspace .claude/ so they're invokable from any cwd
# under the workspace. Repo list is loaded from
# scripts/aggregator.yml so future joins are a config edit, not a
# script change (coo-memory#952).
mapfile -t _AGGREGATOR_REPOS < <(load_aggregator_repos)
aggregate_workspace_claude_config "$WORKSPACE_ROOT_DERIVED" "$WORKSPACE_ROOT_DERIVED/.claude" \
  "${_AGGREGATOR_REPOS[@]}"
ensure_workspace_mcp_config "$SCRIPT_DIR/../.mcp.json" "$WORKSPACE_ROOT_DERIVED/.mcp.json"
ensure_workspace_identity_link "$WORKSPACE_ROOT_DERIVED/coo-memory/CLAUDE.md" "$WORKSPACE_ROOT_DERIVED/CLAUDE.md"
# Stale-snapshot fallback for the mem0 stdio MCP (coo-harness#109).
# cloud-setup.sh is the canonical installer; this catches snapshots
# built before that change, or local dev environments where build-time
# setup doesn't run. Idempotent — short-circuits when the binary is
# already present. Failure is non-fatal: integrity-check E5 will
# surface the gap loudly via the coo-identity-digest banner so the
# next session triggers a /resume rather than wedging silently.
ensure_mem0_mcp_server || true
# Bridge /home/user/.local/bin/gh (persistent install target) onto
# /root/.local/bin (already on PATH for Claude's Bash tool) so the
# MEMO 2026-04-23-02 gh-CLI fallback is callable without the agent
# having to rediscover the install path every session.
ensure_gh_symlink_on_path
# Install the gh-coo-wrap wrapper so every attributable `gh` write
# auto-carries the Claude Code session URL. MEMO 2026-04-26-02
# (issue #150). Idempotent via marker grep.
ensure_gh_coo_wrap "$SCRIPT_DIR/gh-coo-wrap.sh"
# Persist VADE_CLOUD_STATE_DIR into ~/.claude/settings.json env so hook subprocesses
# (integrity-check.sh, coo-identity-digest.sh, etc.) inherit the correct path. Must run
# before integrity-check.sh so the JSON lands at the right location. State-dir-only
# variant: must NOT call merge_coo_settings_paths here, because that helper also
# rewrites the PATH key from the live shell PATH. On macOS the SessionStart hook
# subprocess inherits a thin non-login PATH (no Homebrew), and rewriting from that
# would clobber the well-formed PATH coo-bootstrap captured at install time.
# coo-harness#171.
merge_coo_settings_state_dir
# Persist VADE_RUNTIME_DIR into ~/.claude/settings.json env so subprocesses
# (hooks, scheduled-runtime invocations, agents) inherit it and any
# script call form `"$VADE_RUNTIME_DIR/..."` resolves at hook time
# without an explicit-path fallback. Same state-dir-only rationale as
# the call above (no PATH rewrite). coo-harness#228 carries the
# specific evidence (the Night's Watch standing-order call form).
merge_coo_settings_runtime_dir
# Persist VADE_COO_MEMORY_DIR into ~/.claude/settings.json env. Sibling
# parity with VADE_RUNTIME_DIR — gh-coo-wrap.sh and various skills/hooks
# resolve the memory-repo path via $VADE_COO_MEMORY_DIR, and without
# this merge it doesn't survive into subprocess env across resume.
# coo-harness#265.
merge_coo_settings_memory_dir
# Refresh the external-touch (F6) cache when it's older than 24h.
# Build-time prewarm in cloud-setup.sh handles the fresh-snapshot case;
# this catches snapshots resumed after the cache has gone stale and
# session-resume environments where the build skipped the prewarm
# (no PAT at build time, etc.). Fail-open: if gh/PAT missing or refresh
# fails, F6 falls back to its own "cache absent" skip path.
prewarm_external_touch_cache "$WORKSPACE_ROOT_DERIVED" 24
# integrity-check.sh runs in coo-identity-digest.sh instead of here,
# so the check fires after the platform's repo-sync has settled
# (coo-harness#XXX; moved from here to eliminate boot-time false alarms).
boot_log_record session-start-sync end ok
