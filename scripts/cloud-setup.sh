#!/usr/bin/env bash
# Claude Code web cloud environment setup.
# Runs once at snapshot build (cached for ~7 days). Subsequent
# session resumes restore the cached snapshot — this script does
# not re-execute on resume.
#
# Entry point: paste this into the cloud env "Setup script" field:
#   #!/bin/bash
#   set -e
#   bash /home/user/vade-runtime/scripts/cloud-setup.sh
#
# The harness clones vade-core, vade-runtime, and vade-coo-memory into
# /home/user/ before this runs, so we just point at /home/user/vade-runtime.
set -euo pipefail

# The cloud snapshot IS the COO session by construction. Export
# VADE_COO_MODE=1 so coo-bootstrap and the merge_coo_settings_* writers
# in lib/common.sh fire normally. On Ven's local Mac the analogous flag
# is set only by the `claude-coo` zsh wrapper, gating COO-mode writes
# to opt-in sessions and leaving bare `claude` launches untouched —
# even when fired from inside the coo-labs workspace where project-
# scope hooks would otherwise re-trigger the COO pipeline.
export VADE_COO_MODE=1

# Derive workspace root from script location so the bootstrap-regression
# CI (.github/workflows/bootstrap-regression.yml) can stage a sandboxed
# /tmp/<root>/vade-runtime tree without colliding with the production
# /home/user/ working trees. In production both resolve to /home/user.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$RUNTIME_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$RUNTIME_DIR/scripts/lib/common.sh"

log "Cloud environment setup starting"
build_log_record START "cloud-setup: begin"
log "Baseline: node=$(node --version 2>/dev/null || echo 'missing') npm=$(npm --version 2>/dev/null || echo 'missing')"

ensure_dirs
sync_claude_config "$RUNTIME_DIR/.claude"
# vade-runtime#157 switched settings.json hook commands from
# $HOME/.claude/vade-hooks/dispatch.sh to
# $CLAUDE_PROJECT_DIR/.claude/vade-hooks/dispatch.sh. On local those paths
# coincide because $CLAUDE_PROJECT_DIR resolves to $WORKSPACE_ROOT and the
# user's personal $HOME is left untouched, but on cloud they diverge:
# $HOME=/root while $CLAUDE_PROJECT_DIR=/home/user (=$WORKSPACE_ROOT) at
# hook-fire time (see integrity-check B5). The sync_claude_config above
# only installs the shim under $HOME/.claude, so without this extra
# install the first SessionStart on a fresh snapshot would fail to
# resolve any of the hook chain. Mirror the shim under the workspace
# .claude as well — session-start-sync's full re-sync to
# $WORKSPACE_ROOT/.claude takes over once the chain bootstraps.
ensure_hooks_dispatch_shim "$RUNTIME_DIR/.claude" "$WORKSPACE_ROOT/.claude"
# Aggregate per-repo primitives from data-owning repos into the
# user-scope .claude/ via per-file symlinks. Per the data-ownership
# rule (MEMO 2026-04-25-02), slash commands and skills live in the
# repo whose data they manipulate; the aggregator surfaces them at
# user-scope so they're invokable from any session cwd.
aggregate_workspace_claude_config "$WORKSPACE_ROOT" "$HOME/.claude" \
  vade-runtime vade-coo-memory vade-core
ensure_workspace_mcp_config "$RUNTIME_DIR/.mcp.json" "$WORKSPACE_ROOT/.mcp.json"
ensure_workspace_identity_link "$WORKSPACE_ROOT/vade-coo-memory/CLAUDE.md" "$WORKSPACE_ROOT/CLAUDE.md"

# Validate the synced settings.json actually parses as JSON and has a
# populated SessionStart:startup hook chain. File-exists alone would
# pass on a truncated or corrupt file. Node is guaranteed present on
# the cloud image; fall back to file-exists only if node is missing.
SETTINGS_SYNC_OK=false
if [ -f "$HOME/.claude/settings.json" ]; then
  if check_cmd node; then
    if node -e '
      const fs = require("fs");
      const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const chains = (cfg.hooks && cfg.hooks.SessionStart) || [];
      for (const c of chains) {
        if (c.matcher === "startup" && Array.isArray(c.hooks) && c.hooks.length > 0) process.exit(0);
      }
      process.exit(1);
    ' "$HOME/.claude/settings.json" 2>/dev/null; then
      SETTINGS_SYNC_OK=true
    fi
  else
    SETTINGS_SYNC_OK=true
  fi
fi

WORKSPACE_MCP_SYMLINKED=false
[ -L "$WORKSPACE_ROOT/.mcp.json" ] && \
  [ "$(readlink -f "$WORKSPACE_ROOT/.mcp.json" 2>/dev/null)" = "$(readlink -f "$RUNTIME_DIR/.mcp.json" 2>/dev/null)" ] && \
  WORKSPACE_MCP_SYMLINKED=true

IDENTITY_LINK_OK=false
[ -L "$WORKSPACE_ROOT/CLAUDE.md" ] && \
  [ "$(readlink -f "$WORKSPACE_ROOT/CLAUDE.md" 2>/dev/null)" = "$(readlink -f "$WORKSPACE_ROOT/vade-coo-memory/CLAUDE.md" 2>/dev/null)" ] && \
  IDENTITY_LINK_OK=true

# Workspace deps (npm install vade-core, install tsx) are opt-in:
# nothing in the SessionStart hook pipeline imports from node_modules,
# and MCP runs remote (mcp.vade-app.dev). Contributors who want the
# full local toolchain set VADE_BOOT_INSTALL=1.
if [ "${VADE_BOOT_INSTALL:-0}" = "1" ]; then
  ensure_tsx
  install_deps "$WORKSPACE_ROOT/vade-core"
fi

print_versions

# Fetch the consolidated binary vendor bundle (op + gh + uv +
# mem0-mcp-server) in one curl from the vade-runtime release asset,
# replacing four per-CDN fetches at snapshot-build time. Best-effort:
# on any failure (missing pin, network, sha mismatch) the per-binary
# ensure_*_cli paths below run as fallback. Briefing 004 / B1 reframe;
# read BINARY_VENDOR_BUNDLE_SHA256 from versions.lock if pinned and
# export so the function can sha256-verify before untar.
BINARY_VENDOR_BUNDLE_SHA256="$(awk '$1 == "binary_vendor_bundle" && $2 != "-" { print $2; exit }' "$RUNTIME_DIR/versions.lock" 2>/dev/null || true)"
export BINARY_VENDOR_BUNDLE_SHA256
if ensure_binaries_from_vendor; then
  build_log_record OK "cloud-setup: binary vendor bundle installed"
else
  build_log_record WARN "cloud-setup: binary vendor bundle unavailable; falling back to per-binary direct fetch"
fi

# Pre-warm uv cache for the boto3-dependent transcript scripts so fresh
# snapshots start with a hot cache. Closes #202. Runs after
# ensure_binaries_from_vendor (provides uv) and before any per-binary
# install path so the cache lives on the snapshot before later steps.
prewarm_uv_cache

# Install the op CLI at snapshot-build time so the SessionStart-hook
# bootstrap fallback never has to fetch it through the egress proxy
# mid-session. The binary lands in /home/user/.local/bin/op which
# survives the snapshot → resume transition. Idempotent: if a prior
# build (or the runtime Dockerfile, per epic #112 Stream 2) already
# installed it, ensure_op_cli's presence-check short-circuits.
#
# FATAL on failure (closes vade-runtime#111). A snapshot without op is
# degraded by definition: every session that resumes from it has to
# re-fetch op from cache.agilebits.com mid-SessionStart, exposed to
# the same egress flake the build-time install was supposed to absorb,
# AND the COO identity load (op read … from the COO vault) cannot
# proceed without it. Failing the build forces an immediate rebuild
# rather than producing a session that's structurally guaranteed to
# fail D-group invariants.
#
# Trade-off: cloud build SLA — if cache.agilebits.com is flapping,
# build-fail-rate goes up. Mitigations: the 5-attempt retry budget in
# ensure_op_cli (vade-runtime#76); the Dockerfile-baked /usr/local/bin/op
# layer (epic #112 Stream 2) which makes ensure_op_cli a no-op when the
# runtime image is in use. If neither is enough, follow-up work is
# vade-runtime#111 option (b) — alternate origin / local mirror.
OP_INSTALLED_AT_BUILD=false
if ensure_op_cli; then
  OP_INSTALLED_AT_BUILD=true
  build_log_record OK "cloud-setup: op CLI installed at build time"
else
  build_log_record WARN "cloud-setup: op CLI install failed at build time; receipt will record op_installed_at_build=false"
  log "Warning: op CLI install failed at build time; snapshot ships degraded."
  log "  coo-identity-digest renders a ⚠ block at SessionStart when the receipt"
  log "  shows op_installed_at_build=false, so the operator sees the degradation"
  log "  loudly instead of mid-task. coo-bootstrap.sh re-runs ensure_op_cli at"
  log "  SessionStart — different egress window than build time, may recover."
  log "  Reverses #116's FATAL flip per BDFL: failing the build was over-strict"
  log "  given that #119 showed the cloud sandbox doesn't actually use the"
  log "  Dockerfile-baked /usr/local/bin/op, so the bake doesn't backstop a"
  log "  cache.agilebits.com flake at snapshot-build time. Bootable-but-degraded"
  log "  is strictly better than unbootable for diagnostic purposes."
fi

# Install the gh CLI for the same reason: snapshot-persistent, no
# per-resume fetch. Per Epic #112 Stream 1 (closing the cloud-boot
# flake chapter), `gh` is now the canonical GitHub write path under
# vade-coo attribution — the github-coo MCP transport was retired
# because its `type: "http"` channel kept hitting Node `undici` DNS-
# cache overflow (see #36, #109, MEMO-2026-04-24-08).
if ensure_gh_cli; then
  build_log_record OK "cloud-setup: gh CLI installed at build time"
else
  build_log_record WARN "cloud-setup: gh CLI install failed at build time; sessions will lack the attribution fallback"
  log "Warning: gh CLI install failed at build time; degraded-MCP sessions will fall through to venpopov attribution."
fi

# Install the mem0-mcp-server stdio binary. Same snapshot-persistence
# rationale as op + gh — paying the install cost at build time means
# the SessionStart hook chain never has to fetch through the egress
# proxy, and Claude Code can spawn the MCP at process start without a
# uvx-on-demand round-trip. Required for mem0 MCP availability per
# vade-runtime#109; without it the .mcp.json stdio entry points at a
# missing binary and Mem0 surface stays dark.
if ensure_mem0_mcp_server; then
  build_log_record OK "cloud-setup: mem0-mcp-server installed at build time"
else
  build_log_record WARN "cloud-setup: mem0-mcp-server install failed at build time; SessionStart hook will retry"
  log "Warning: mem0-mcp-server install failed at build time; first session will boot with Mem0 MCP dark."
fi

# Install Quarto for slide-deck and document rendering. Same
# snapshot-persistence rationale as op + gh + mem0-mcp-server: paying
# the ~131 MB fetch at build time keeps SessionStart off the egress
# proxy. Quarto bundles its own pandoc + deno, so the install also
# brings pandoc onto the bundle without a separate package step.
# Best-effort: on failure the first session that needs Quarto fetches
# on demand. Introduced for the 2026-shiffrin-conference deck under
# vade-coo-memory/coo/_drafts/; kept standing for any future
# markdown-to-{revealjs,pptx,pdf} workflow the chain produces.
if ensure_quarto_cli; then
  build_log_record OK "cloud-setup: quarto installed at build time"
else
  build_log_record WARN "cloud-setup: quarto install failed at build time; first session will need to install on demand"
  log "Warning: quarto install failed at build time; first session that uses it will pay a ~131 MB direct-fetch."
fi

# Pre-fetch the 1Password MCP server (@takescake/1password-mcp) into the
# global npm cache so first-session `npx -y` resolves offline. Same
# snapshot-persistence rationale as op + gh + mem0 — paying the npm
# fetch cost at build time keeps the SessionStart MCP spawn off the
# egress proxy. The MCP exists to close the rotated-PAT → restart
# failure class (vade-runtime#164): when 1Password rotates a credential
# mid-session, an in-process MCP path can re-read the secret without
# the harness restart that the cached `op` CLI bootstrap requires.
# Read-only is enforced by the COO service account's vault permissions
# (1Password's own recommendation per their MCP security guidance);
# .mcp.json scopes credentials to OP_SERVICE_ACCOUNT_TOKEN only.
if npm install -g "@takescake/1password-mcp@2.4.2" --no-audit --no-fund >/dev/null 2>&1; then
  build_log_record OK "cloud-setup: @takescake/1password-mcp installed at build time"
else
  build_log_record WARN "cloud-setup: @takescake/1password-mcp install failed at build time; first-session npx will fetch on demand"
  log "Warning: @takescake/1password-mcp install failed at build time; first session will pay an npx-on-demand fetch."
fi

# COO identity bootstrap runs only when OP_SERVICE_ACCOUNT_TOKEN is set
# in the cloud environment config. Non-fatal on failure — the base VADE
# env should still come up even if 1Password is unreachable.
# See vade-coo-memory/coo/cloud-env-bootstrap.md for the contract.
# Anthropic cloud envs may scope custom env vars to the session process
# only; the SessionStart hook in .claude/settings.json picks up the
# slack in that case.
#
# Probe: record token visibility and settings.json state so the next
# session's identity-digest can tell us whether setup-script time is
# a viable bootstrap site (structurally superior to the hook because
# MCP servers pick up env at Claude Code startup, not post-hook).
OP_TOKEN_VISIBLE=false
COO_BOOTSTRAP_RAN=false
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  OP_TOKEN_VISIBLE=true
  build_log_record PROBE "cloud-setup: OP_SERVICE_ACCOUNT_TOKEN visible at setup time (len=${#OP_SERVICE_ACCOUNT_TOKEN})"
  if bash "$RUNTIME_DIR/scripts/coo-bootstrap.sh"; then
    COO_BOOTSTRAP_RAN=true
    build_log_record OK "cloud-setup: coo-bootstrap completed"
  else
    build_log_record FAIL "cloud-setup: coo-bootstrap failed; continuing without COO identity"
    log "Warning: coo-bootstrap failed; continuing without COO identity."
  fi
else
  build_log_record PROBE "cloud-setup: OP_SERVICE_ACCOUNT_TOKEN unset at setup time; hook fallback required"
  log "OP_SERVICE_ACCOUNT_TOKEN not visible at setup time; SessionStart hook will run coo-bootstrap."
fi

# Pre-warm the external-touch (F6) cache into the snapshot so the first
# session of a fresh container reports F6 ok rather than "cache absent
# — refresh via bin/external-touch.py" (which required a manual handoff
# step on every cold boot). Runs after coo-bootstrap so $GITHUB_MCP_PAT
# is exported; fail-open if either is missing or external-touch.py is
# absent (CI fake-env stages a stub vade-coo-memory without it).
# vade-coo-memory#429 cache-refresh follow-up.
. "$HOME/.vade/coo-env" 2>/dev/null || true
prewarm_external_touch_cache "$WORKSPACE_ROOT"

# Durable receipt so sessions can diagnose build-time state without
# parsing logs. coo-identity-digest surfaces this in the SessionStart
# digest block.
GIT_SHA="$(git -C "$RUNTIME_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
build_receipt_write \
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  op_token_visible="$OP_TOKEN_VISIBLE" \
  op_installed_at_build="$OP_INSTALLED_AT_BUILD" \
  coo_bootstrap_ran="$COO_BOOTSTRAP_RAN" \
  workspace_mcp_symlinked="$WORKSPACE_MCP_SYMLINKED" \
  identity_link_ok="$IDENTITY_LINK_OK" \
  settings_sync_ok="$SETTINGS_SYNC_OK" \
  git_sha="$GIT_SHA"

build_log_record OK "cloud-setup: complete (op_token=$OP_TOKEN_VISIBLE coo_bootstrap=$COO_BOOTSTRAP_RAN mcp_link=$WORKSPACE_MCP_SYMLINKED id_link=$IDENTITY_LINK_OK)"
log "Done."
