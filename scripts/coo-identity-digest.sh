#!/usr/bin/env bash
# COO identity digest for cloud Claude Code sessions.
#
# Prints the vade-coo-memory boot instructions (CLAUDE.md) and the
# latest memo header(s) so the identity reading order lands in the
# session's context on startup, rather than requiring a manual read
# pass. Called from the SessionStart: startup hook after
# coo-bootstrap.sh.
#
# No-op if vade-coo-memory is not checked out at the expected path.
# Output is reminder-only — it does not load Mem0, does not commit
# files, does not fail the session if the repo is missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

boot_log_record coo-identity-digest start
trap '_rc=$?; boot_log_record coo-identity-digest end $([ $_rc -eq 0 ] && echo ok || echo fail) rc=$_rc' EXIT

# Resolve workspace root: parent of vade-runtime. /home/user on cloud,
# $WORKSPACE_ROOT on local.
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -n "${COO_MEMORY_DIR:-}" ]; then
  MEM_REPO="$COO_MEMORY_DIR"
elif [ -d "$WORKSPACE_ROOT/vade-coo-memory" ]; then
  MEM_REPO="$WORKSPACE_ROOT/vade-coo-memory"
elif [ -d "$HOME/GitHub/coo-labs/vade-coo-memory" ]; then
  MEM_REPO="$HOME/GitHub/coo-labs/vade-coo-memory"
else
  MEM_REPO="/home/user/vade-coo-memory"
fi
CLAUDE_MD="$MEM_REPO/CLAUDE.md"
MEMO_INDEX="$MEM_REPO/coo/memo_index.json"
BOOTSTRAP_LOG="${HOME}/.vade/coo-bootstrap.log"
SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json"
WORKSPACE_IDENTITY_LINK="$WORKSPACE_ROOT/CLAUDE.md"
WORKSPACE_MCP_LINK="$WORKSPACE_ROOT/.mcp.json"
WORKSPACE_MCP_SRC="$WORKSPACE_ROOT/vade-runtime/.mcp.json"
# common.sh seeds VADE_CLOUD_STATE_DIR with a cloud-host default; on Mac
# local-setup.sh writes the receipt under ~/.vade/local-state/ and hook
# subprocesses don't inherit its env exports. Redirect when the cloud
# path is absent and the local path exists.
if [ ! -d "$VADE_CLOUD_STATE_DIR" ] && [ -d "$HOME/.vade/local-state" ]; then
  VADE_CLOUD_STATE_DIR="$HOME/.vade/local-state"
fi
SETUP_RECEIPT="${VADE_CLOUD_STATE_DIR}/setup-receipt.json"
INTEGRITY_CHECK="${VADE_CLOUD_STATE_DIR}/integrity-check.json"
SKIP_SENTINEL="${HOME}/.vade/.coo-bootstrap-skip-reason"

# ── INTEGRITY-CHECK BANNER (TOP OF DIGEST) ───────────────────────────
#
# Phase A of vade-coo-memory#762: the integrity-check posture and any
# loud-skip sentinel from coo-bootstrap surface BEFORE any identity
# content. The 2026-05-13 boot-skip incident showed that integrity-check
# at the BOTTOM of the digest (and at step 14 of CLAUDE.md reading
# order) is a post-hoc verifier — the failing session never reached it.
# Hoisting both to the top of the first screen makes degradation
# unmissable; combined with CLAUDE.md step 1 reading the JSON file,
# the agent's first action on a degraded boot is surface-to-BDFL.
#
# Run integrity-check FIRST so the file we read below reflects this
# session. Original position (after Mem0 banner) eliminated to avoid
# duplication.
bash "$SCRIPT_DIR/integrity-check.sh" 2>/dev/null || true

_integrity_ok="unknown"
_integrity_passed="?"
_integrity_total="?"
_integrity_degraded=""
if [ -f "$INTEGRITY_CHECK" ] && check_cmd node; then
  _integrity_summary="$(node -e '
    try {
      const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const s = r.summary || {};
      const ok = s.ok === true ? "true" : (s.ok === false ? "false" : "unknown");
      const passed = s.passed ?? "?";
      const total = s.total ?? "?";
      const degraded = (Array.isArray(s.degraded) ? s.degraded : []).join(",");
      console.log(ok + "|" + passed + "|" + total + "|" + degraded);
    } catch { console.log("unknown|?|?|"); }
  ' "$INTEGRITY_CHECK" 2>/dev/null || echo "unknown|?|?|")"
  IFS='|' read -r _integrity_ok _integrity_passed _integrity_total _integrity_degraded <<<"$_integrity_summary"
fi

if [ "$_integrity_ok" = "false" ] || [ -f "$SKIP_SENTINEL" ]; then
  # DEGRADED BOOT — print loudly at the very top. The 4-line recovery
  # sequence below is the proven fix from the 2026-05-13 audit
  # (vade-coo-memory/coo/audits/2026-05-13_boot-skip-failure/recovery-transcript.txt).
  echo "═══════════════════════════════════════════════════════════════"
  echo "⚠️  BOOT DEGRADED — DO NOT START SUBSTANTIVE WORK"
  echo "═══════════════════════════════════════════════════════════════"
  if [ -f "$SKIP_SENTINEL" ]; then
    _skip_reason="$(sed -n '1p' "$SKIP_SENTINEL" 2>/dev/null || true)"
    _skip_hint="$(sed -n '2p' "$SKIP_SENTINEL" 2>/dev/null || true)"
    echo "  Skip reason:  $_skip_reason"
    echo "  Recovery:     $_skip_hint"
    echo ""
  fi
  if [ "$_integrity_ok" = "false" ]; then
    echo "  integrity-check: summary.ok=false  ($_integrity_passed/$_integrity_total)"
    if [ -n "$_integrity_degraded" ]; then
      echo "  degraded:        $_integrity_degraded"
    fi
    echo ""
    # Inline failing-invariant details.
    if check_cmd node && [ -f "$INTEGRITY_CHECK" ]; then
      node -e '
        try {
          const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
          const degraded = Array.isArray(r.summary && r.summary.degraded) ? r.summary.degraded : [];
          if (degraded.length > 0) {
            console.log("  Failing invariants:");
            for (const id of degraded) {
              const grp = id[0];
              const entry = (r.groups || {})[grp] && (r.groups || {})[grp][id];
              const detail = (entry && entry.detail) || "(no detail)";
              console.log("    " + id + ": " + detail);
            }
            console.log("");
          }
        } catch (_) {}
      ' "$INTEGRITY_CHECK" 2>/dev/null || true
    fi
  fi
  echo "  Proven recovery (from 2026-05-13 audit recovery-transcript.txt):"
  echo "    1) git config --file \$HOME/.gitconfig --remove-section user  # clear non-COO gitconfig"
  echo "    2) VADE_COO_MODE=1 bash /home/user/vade-runtime/scripts/coo-bootstrap.sh"
  echo "    3) set -a; source \$HOME/.vade/coo-env; set +a"
  echo "    4) bash /home/user/vade-runtime/scripts/integrity-check.sh"
  echo ""
  echo "  CLAUDE.md step 1 (conditional gate): surface to BDFL, do no other work."
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
elif [ "$_integrity_ok" = "true" ]; then
  # OK boot — one-line green banner. Detailed integrity table follows
  # later in the digest (the original "Integrity check" block was
  # eliminated by this hoist; keep a terse top-line so green sessions
  # still see the result at first screen).
  echo "───────────────────────────────────────────────────────────────"
  echo "Boot integrity: summary.ok=true  ($_integrity_passed/$_integrity_total)  — full report: $INTEGRITY_CHECK"
  echo "───────────────────────────────────────────────────────────────"
  echo ""
fi

if [ ! -f "$CLAUDE_MD" ]; then
  echo "[vade-setup] coo-identity-digest: $CLAUDE_MD not found; skipping."
  exit 0
fi

# Check whether Claude Code's built-in memory loader already picked up
# the identity file via /home/user/CLAUDE.md → vade-coo-memory/CLAUDE.md.
# When the symlink is present, the file is in context from turn one
# and re-echoing would just duplicate content. When it's missing,
# echo as a fallback so identity still lands (same behavior as before
# C6a).
identity_link_live=false
if [ -L "$WORKSPACE_IDENTITY_LINK" ] && \
   [ "$(readlink -f "$WORKSPACE_IDENTITY_LINK" 2>/dev/null)" = "$(readlink -f "$CLAUDE_MD" 2>/dev/null)" ]; then
  identity_link_live=true
fi

if [ "$identity_link_live" = "true" ]; then
  echo "───────────────────────────────────────────────────────────────"
  echo "COO identity: /home/user/CLAUDE.md → vade-coo-memory/CLAUDE.md"
  echo "(loaded by harness memory; skipping echo to avoid duplicate context)"
  echo "───────────────────────────────────────────────────────────────"
else
  echo "───────────────────────────────────────────────────────────────"
  echo "COO identity boot (vade-coo-memory/CLAUDE.md)"
  echo "───────────────────────────────────────────────────────────────"
  cat "$CLAUDE_MD"
fi

# Identity layer (CB-* / OG-*) — inlined so the load-bearing identity
# content lands at boot regardless of whether the agent performs the
# CLAUDE.md §Session-start reading pass. When the first user message is
# task-shaped, default LLM task-focus wins over procedure-first and the
# reading pass is silently skipped; without this block the session runs
# on operational metadata only. Per vade-runtime#226.
IDENTITY_LAYER="$MEM_REPO/coo/identity_layer.md"
if [ -f "$IDENTITY_LAYER" ]; then
  echo ""
  echo "───────────────────────────────────────────────────────────────"
  echo "Identity layer (CB-* / OG-*) — inlined from coo/identity_layer.md"
  echo "───────────────────────────────────────────────────────────────"
  cat "$IDENTITY_LAYER"
  echo "───────────────────────────────────────────────────────────────"
fi

# Lineage events — one-line stamps from each coo/lineage/<event>/README.md.
# Full READMEs stay Read-on-demand per CLAUDE.md §6b; this surface gives
# the agent a stable pointer to active events without requiring the read,
# and is filesystem-driven so new events surface without a CLAUDE.md edit.
# Dirs starting with `_` are meta-folders, not events; skipped.
LINEAGE_DIR="$MEM_REPO/coo/lineage"
if [ -d "$LINEAGE_DIR" ]; then
  echo ""
  echo "───────────────────────────────────────────────────────────────"
  echo "Active lineage events (full READMEs in coo/lineage/<event>/)"
  echo "───────────────────────────────────────────────────────────────"
  for event_dir in "$LINEAGE_DIR"/*/; do
    [ -d "$event_dir" ] || continue
    event_name="$(basename "$event_dir")"
    case "$event_name" in _*) continue ;; esac
    readme="${event_dir}README.md"
    [ -f "$readme" ] || continue
    title="$(grep -m1 '^# ' "$readme" 2>/dev/null | sed 's/^# //')"
    stamp="$(grep -m1 -E '^\*.*lineage' "$readme" 2>/dev/null | sed 's/^\*//;s/\*$//')"
    [ -n "$title" ] || continue
    printf "  %-18s %s\n" "$event_name:" "$title"
    [ -n "$stamp" ] && printf "  %-18s %s\n" "" "$stamp"
  done
  echo "───────────────────────────────────────────────────────────────"
fi

if [ -f "$MEMO_INDEX" ] && check_cmd jq; then
  echo ""
  echo "───────────────────────────────────────────────────────────────"
  echo "Latest memos (10 most recent; full text in coo/memos/<id>.md)"
  echo "───────────────────────────────────────────────────────────────"
  # Read straight from the structured index that the memo-index hook
  # regenerated earlier in the SessionStart chain. Flat array, sorted
  # newest-first by id. Print oldest-of-top-10 first so the most-recent
  # memo lands closest to the user prompt.
  #
  # Prints only id + status + title. Full schema is documented in
  # coo/operations/memo-access.md. The index uses ~19K tokens at ~95
  # memos post-vade-coo-memory#351 — agents needing other slices
  # should jq the file rather than Read it.
  if digest_out=$(jq -r '
    sort_by(.id) | reverse |
    .[0:10] | reverse |
    .[] |
    "  " + .id + " [" + (.status // "—") + "] " + .title
  ' "$MEMO_INDEX" 2>/dev/null) && [ -n "$digest_out" ]; then
    printf '%s\n' "$digest_out"
  else
    echo "  (memo_index.json present but unparseable; skipping digest)"
  fi
  echo ""
  echo "Deeper slices: jq '...' coo/memo_index.json (flat array — schema in coo/operations/memo-access.md)"
fi

echo "───────────────────────────────────────────────────────────────"

# Bootstrap posture — loud surface of whether this session boots with
# a full identity. Three signals:
#   (a) last coo-bootstrap outcome (from the log)
#   (b) env vars actually present in this hook's process
#   (c) env vars present in ~/.claude/settings.json (what MCP servers got)
# When (b) diverges from (c), the current session's MCP tools are
# stale — a restart will pick up the populated env block.
#
# SessionStart hooks run in parallel. Without the wait below, we'd
# sample env and settings.json mid-bootstrap and falsely report
# degraded even when coo-bootstrap eventually completes cleanly (the
# first user-visible regression after PR #20 landed: verification
# run reported "degraded" despite OK-step=complete in the log).
# Shared helper in lib/common.sh; exposes
# VADE_BOOTSTRAP_WAIT_{SAW_FRESH,ELAPSED,TIMEOUT}.
wait_for_coo_bootstrap 60
_digest_saw_fresh="${VADE_BOOTSTRAP_WAIT_SAW_FRESH:-0}"
_digest_wait_elapsed="${VADE_BOOTSTRAP_WAIT_ELAPSED:-0}"
_digest_wait_timeout="${VADE_BOOTSTRAP_WAIT_TIMEOUT:-60}"

echo ""
echo "───────────────────────────────────────────────────────────────"
echo "Bootstrap posture"
echo "───────────────────────────────────────────────────────────────"

if [ -f "$BOOTSTRAP_LOG" ]; then
  last_line="$(tail -n 1 "$BOOTSTRAP_LOG" 2>/dev/null || true)"
  [ -n "$last_line" ] && echo "  Last bootstrap: $last_line"
else
  echo "  Last bootstrap: (no log at $BOOTSTRAP_LOG)"
fi

if [ "$_digest_saw_fresh" -eq 0 ]; then
  if [ "$_digest_wait_elapsed" -ge "$_digest_wait_timeout" ]; then
    echo "  WARN: timed out after ${_digest_wait_timeout}s waiting for a fresh bootstrap terminal state."
  else
    echo "  Note: no fresh bootstrap state this session (hook didn't fire, or finished before digest started)."
  fi
fi

env_has_pat="no"; env_has_mail="no"; env_has_cf="no"
[ -n "${GITHUB_MCP_PAT:-}" ]      && env_has_pat="yes"
[ -n "${AGENTMAIL_API_KEY:-}" ]   && env_has_mail="yes"
# CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID move as a pair (the
# account-scoped verify + wrangler --account-id both need both).
# Surface as a single yes/no so the boot line stays one-screen-wide.
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] && env_has_cf="yes"

settings_pat="unknown"; settings_mail="unknown"; settings_cf="unknown"
if [ -f "$SETTINGS_FILE" ] && check_cmd node; then
  probe="$(node -e '
    const fs = require("fs");
    try {
      const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const e = cfg.env || {};
      console.log(
        (e.GITHUB_MCP_PAT ? "yes" : "no") + " " +
        (e.AGENTMAIL_API_KEY ? "yes" : "no") + " " +
        ((e.CLOUDFLARE_API_TOKEN && e.CLOUDFLARE_ACCOUNT_ID) ? "yes" : "no")
      );
    } catch (_) { console.log("unknown unknown unknown"); }
  ' "$SETTINGS_FILE" 2>/dev/null || echo "unknown unknown unknown")"
  read -r settings_pat settings_mail settings_cf <<<"$probe"
fi

echo "  Process env:       GITHUB_MCP_PAT=$env_has_pat  AGENTMAIL_API_KEY=$env_has_mail  CLOUDFLARE=$env_has_cf"
echo "  settings.json env: GITHUB_MCP_PAT=$settings_pat  AGENTMAIL_API_KEY=$settings_mail  CLOUDFLARE=$settings_cf"

if [ "$env_has_pat" = "yes" ] && [ "$env_has_mail" = "yes" ]; then
  echo "  Full identity loaded; MCP tools (github, agentmail) should have env."
elif [ "$settings_pat" = "yes" ] && [ "$settings_mail" = "yes" ]; then
  echo ""
  echo "  WARN: env populated in settings.json but not in this process."
  echo "  MCP servers were spawned before the env block was written."
  echo "  Next session in this container will boot fully loaded."
else
  echo ""
  echo "  WARN: identity is degraded — required env vars are missing."
  echo "  Inspect $BOOTSTRAP_LOG for the failing step, then re-run:"
  echo "    VADE_FORCE_COO_BOOTSTRAP=1 bash \"${SCRIPT_DIR}/coo-bootstrap.sh\""
fi

# Classify OP_SERVICE_ACCOUNT_TOKEN visibility across build/session. The
# build receipt records whether the token was in env when cloud-setup.sh
# ran at snapshot-build time; session env tells us where it is now.
# Four labeled outcomes:
#   ok           — token at build: first-session MCPs authenticate from turn 0
#   session-only — token only at session boot: first session of every fresh
#                  container boots with empty ${GITHUB_MCP_PAT}, github-coo
#                  MCP hits HTTP 400, /resume recovers it. Platform-level fix
#                  is to declare OP_SERVICE_ACCOUNT_TOKEN in the Anthropic
#                  cloud "Setup script" environment, not just the session env.
#   missing      — absent at both: COO identity dark until env is provisioned
#   unknown      — no receipt to compare against (build-time setup didn't run)
_op_build_seen="unknown"
_op_installed_at_build="unknown"
if [ -f "$SETUP_RECEIPT" ] && check_cmd node; then
  _op_receipt_probe="$(node -e '
    try {
      const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const tok = r.op_token_visible === true ? "yes" : "no";
      let inst;
      if (r.op_installed_at_build === true) inst = "yes";
      else if (r.op_installed_at_build === false) inst = "no";
      else inst = "unknown";
      console.log(tok + " " + inst);
    } catch (_) { console.log("unknown unknown"); }
  ' "$SETUP_RECEIPT" 2>/dev/null || echo "unknown unknown")"
  _op_build_seen="${_op_receipt_probe%% *}"
  _op_installed_at_build="${_op_receipt_probe##* }"
fi
_op_session_seen="no"
[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && _op_session_seen="yes"

case "$_op_build_seen/$_op_session_seen" in
  yes/*)
    ;;
  no/yes)
    echo ""
    echo "  ⚠ OP_SERVICE_ACCOUNT_TOKEN is injected at session-boot only, not build."
    echo "    Every fresh container's FIRST session has github-coo MCP unauthenticated"
    echo "    (empty \${GITHUB_MCP_PAT} substitution → HTTP 400). /resume recovers it."
    echo "    Platform fix: add OP_SERVICE_ACCOUNT_TOKEN to the Anthropic cloud"
    echo "    'Setup script' environment — then coo-bootstrap runs at build and"
    echo "    MCPs authenticate from turn zero."
    ;;
  no/no)
    echo ""
    echo "  ⚠ OP_SERVICE_ACCOUNT_TOKEN absent at build AND session. COO identity is dark."
    ;;
  unknown/*)
    ;;
esac

# Snapshot is degraded when build-time op-install failed (#77): the
# whole point of cloud-setup.sh:ensure_op_cli is to take egress flake
# off the SessionStart critical path. When it failed at build, the
# binary is missing from /home/user/.local/bin and SessionStart's
# bootstrap fallback has to re-fetch from cache.agilebits.com, which
# is exposed to the same flake the build-time install was supposed
# to absorb. Surface this loudly so the operator (or a future agent)
# knows to expect the flake-on-resume failure mode and can /resume
# rather than wedge.
if [ "$_op_installed_at_build" = "no" ]; then
  echo ""
  echo "  ⚠ op CLI failed to install at build time (op_installed_at_build=false)."
  echo "    Snapshot is degraded — SessionStart's bootstrap fallback will re-fetch"
  echo "    op from cache.agilebits.com mid-session, which is exposed to the same"
  echo "    egress flake the build-time install was supposed to absorb. If bootstrap"
  echo "    dies at step=ensure_op_cli, /resume rather than wedge — the second"
  echo "    attempt usually clears."
fi

echo "───────────────────────────────────────────────────────────────"

# MCP surface probe — prerequisites that Claude Code needed at process
# start for project-scope MCP servers (agentmail, github-coo, mem0) to
# register. We can't see the live tool list from a Bash hook, but if
# any prerequisite is missing the tools cannot have been loaded.
# Surface these loudly so the agent knows to avoid attributable writes
# until a /resume picks up the fix we've just applied.
#
# Cloud-only: the /home/user/.mcp.json and /home/user/CLAUDE.md symlinks
# exist because the cloud container's cwd is /home/user, not the project
# dir. On local Mac, Claude Code's cwd is the project dir itself, so it
# loads .mcp.json and CLAUDE.md natively without the workspace bridge.
if [ "$HOME" = "/home/user" ]; then
  echo ""
  echo "───────────────────────────────────────────────────────────────"
  echo "MCP surface probe"
  echo "───────────────────────────────────────────────────────────────"

  mcp_link_ok=false
  mcp_link_state="missing"
  if [ -L "$WORKSPACE_MCP_LINK" ]; then
    if [ "$(readlink -f "$WORKSPACE_MCP_LINK" 2>/dev/null)" = "$(readlink -f "$WORKSPACE_MCP_SRC" 2>/dev/null)" ]; then
      mcp_link_ok=true
      mcp_link_state="ok (→ $(readlink "$WORKSPACE_MCP_LINK" 2>/dev/null))"
    else
      mcp_link_state="wrong target (→ $(readlink "$WORKSPACE_MCP_LINK" 2>/dev/null))"
    fi
  elif [ -e "$WORKSPACE_MCP_LINK" ]; then
    mcp_link_state="present but not a symlink"
  fi
  echo "  /home/user/.mcp.json:     $mcp_link_state"

  id_link_state="missing"
  if [ -L "$WORKSPACE_IDENTITY_LINK" ]; then
    if [ "$identity_link_live" = "true" ]; then
      id_link_state="ok (→ $(readlink "$WORKSPACE_IDENTITY_LINK" 2>/dev/null))"
    else
      id_link_state="wrong target (→ $(readlink "$WORKSPACE_IDENTITY_LINK" 2>/dev/null))"
    fi
  elif [ -e "$WORKSPACE_IDENTITY_LINK" ]; then
    id_link_state="present but not a symlink"
  fi
  echo "  /home/user/CLAUDE.md:     $id_link_state"

  # Any failure = session started without the workspace-scope overrides.
  # Surface the fix path instead of letting the agent guess.
  if [ "$mcp_link_ok" != "true" ] || [ "$identity_link_live" != "true" ]; then
    echo ""
    echo "  ⚠ Workspace-scope overrides were NOT in place at Claude Code startup."
    echo "    Project-scope MCPs (agentmail, github-coo, mem0) did not load this session,"
    echo "    and COO identity was not auto-loaded by the harness memory system."
    echo "    session-start-sync.sh has re-applied the symlinks in this hook pass."
    echo "    Resume the session (/resume) to pick up the full MCP + identity surface."
  fi

  echo "───────────────────────────────────────────────────────────────"
fi

# GitHub write surface — per MEMO 2026-04-23-02, the vade-coo
# attribution invariant (MEMO -22-04) rides on the github-coo MCP when
# healthy and on the gh CLI when the MCP streamable-HTTP transport
# fails with a DNS-cache overflow (issue #36). This block reports
# fallback readiness at turn zero so a new session doesn't have to
# re-derive the protocol from memos when an MCP call hits the failure
# mode mid-task. We deliberately don't probe MCP liveness from a bash
# hook (same reason the MCP surface probe above sticks to filesystem
# prerequisites).
echo ""
echo "───────────────────────────────────────────────────────────────"
echo "GitHub write surface"
echo "───────────────────────────────────────────────────────────────"
if check_cmd gh; then
  gh_ver="$(gh --version 2>/dev/null | head -1)"
  printf "  %-25s %s\n" "gh CLI:" "${gh_ver:-present}"
else
  printf "  %-25s %s\n" "gh CLI:" "not found (expected /home/user/.local/bin/gh; run ensure_gh_cli)"
fi
if [ -n "${GITHUB_MCP_PAT:-}" ]; then
  printf "  %-25s %s\n" "gh auth token:" "GITHUB_MCP_PAT present (gh will attribute as vade-coo)"
else
  printf "  %-25s %s\n" "gh auth token:" "GITHUB_MCP_PAT unset — /resume or check coo-bootstrap"
fi
echo "  gh write path:            GH_TOKEN=\$GITHUB_MCP_PAT gh <cmd>  (attributes as vade-coo)."
echo "                            Sole GitHub write path. github-coo MCP retired by"
echo "                            Epic #112 Stream 1; harness github MCP writes deny-listed."
echo "───────────────────────────────────────────────────────────────"

# Note: integrity-check.sh runs at the TOP of the digest now (see
# the INTEGRITY-CHECK BANNER block above), so the integrity-check.json
# file is already current by the time this section reads it. Original
# placement here (after Mem0 banner) was removed by Phase A of
# vade-coo-memory#762; the integrity-check fires after session-start-sync
# anyway because this whole script runs after session-start-sync in the
# SessionStart hook chain.

# Mem0 read/write surface — same banner pattern as "GitHub write surface"
# above. Per vade-runtime#109, the hosted Mem0 MCP at mcp.mem0.ai hits
# the same Node `undici` DNS-cache-overflow class that kills github-coo,
# so we run the official stdio server (`mem0-mcp-server`) as a local
# subprocess instead. This block always prints — green when healthy,
# loud ⚠ when degraded — so the agent sees Mem0 posture at turn zero
# rather than only when integrity-check enumerates degraded invariants.
# E5 in integrity-check.json is the canonical pass/fail signal.

echo ""
echo "───────────────────────────────────────────────────────────────"
echo "Mem0 read/write surface"
echo "───────────────────────────────────────────────────────────────"
mem0_bin=""
for cand in "/home/user/.local/bin/mem0-mcp-server" "$HOME/.local/bin/mem0-mcp-server"; do
  if [ -x "$cand" ]; then mem0_bin="$cand"; break; fi
done
mem0_key="no"
if [ -f "$SETTINGS_FILE" ] && check_cmd node; then
  mem0_key="$(node -e '
    try {
      const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      console.log((cfg.env && cfg.env.MEM0_API_KEY) ? "yes" : "no");
    } catch { console.log("no"); }
  ' "$SETTINGS_FILE" 2>/dev/null || echo "no")"
fi
e5_status="unknown"
e5_detail=""
if [ -f "$INTEGRITY_CHECK" ] && check_cmd node; then
  read -r e5_status e5_detail < <(node -e '
    try {
      const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const e = (r.groups && r.groups.E && r.groups.E.E5) || {};
      let s = "unknown";
      if (e.ok === true) s = "ok";
      else if (e.ok === false) s = "degraded";
      else if (e.skipped === true) s = "skip";
      console.log(s + " " + (e.detail || "").replace(/\n/g, " "));
    } catch { console.log("unknown"); }
  ' "$INTEGRITY_CHECK" 2>/dev/null || echo "unknown")
fi
if [ -n "$mem0_bin" ]; then
  printf "  %-25s %s\n" "stdio MCP binary:" "$mem0_bin"
else
  printf "  %-25s %s\n" "stdio MCP binary:" "MISSING (run ensure_mem0_mcp_server; cloud-setup.sh installs at build)"
fi
printf "  %-25s %s\n" "MEM0_API_KEY:" "settings.json env=$mem0_key"
printf "  %-25s %s\n" "integrity-check E5:" "$e5_status"
echo "  REST fallback (writes):   bin/mem0-rest.sh; canonical for memo_pointer (MEMO 2026-04-24-07)"
case "$e5_status" in
  degraded)
    echo ""
    echo "  ⚠ Mem0 MCP is degraded. CLAUDE.md §4 + §12 boot rituals (CB-* / OG-* identity"
    echo "    load, recent-episodic handoff) cannot run via MCP this session. Fall back to"
    echo "    durable file layer (coo/episodic_memory.md + memo_index.json) per CLAUDE.md §6"
    echo "    graceful-degradation clause; for writes route through bin/mem0-rest.sh."
    echo "    Detail: $e5_detail"
    ;;
  skip)
    echo ""
    echo "  Note: E5 probe was skipped — see detail above. Most common cause: MEM0_API_KEY"
    echo "  not in this hook's process env even though settings.json carries it (MCP server"
    echo "  spawn picks it up; the probe subprocess does not). Not a degradation; verify"
    echo "  by listing mcp__mem0__* tools in your first agent turn."
    ;;
esac
echo "───────────────────────────────────────────────────────────────"

# Note: detailed integrity-check summary was hoisted to the TOP of the
# digest in Phase A of vade-coo-memory#762. See the INTEGRITY-CHECK
# BANNER block near the top of this script. Original block deleted here
# to avoid duplication.

# Cloud build-time receipt — what did cloud-setup.sh actually do at
# snapshot build? Present = build ran; missing = build skipped or the
# setup script field in the Anthropic cloud UI is not wired.
echo ""
echo "───────────────────────────────────────────────────────────────"
echo "Cloud build-time receipt"
echo "───────────────────────────────────────────────────────────────"
if [ -f "$SETUP_RECEIPT" ]; then
  if check_cmd node; then
    node -e '
      const fs = require("fs");
      try {
        const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        for (const k of Object.keys(r)) {
          const v = r[k];
          console.log("  " + (k + ":").padEnd(25) + " " + v);
        }
      } catch (e) { console.log("  (unreadable: " + e.message + ")"); }
    ' "$SETUP_RECEIPT" 2>/dev/null || cat "$SETUP_RECEIPT"
  else
    cat "$SETUP_RECEIPT"
  fi
else
  echo "  (no receipt at $SETUP_RECEIPT)"
  echo "  cloud-setup.sh did not run at snapshot build, or ran but aborted before writing the receipt."
  echo "  Check the Anthropic cloud env 'Setup script' field —"
  echo "    expected: bash /home/user/vade-runtime/scripts/cloud-setup.sh"
fi
echo "───────────────────────────────────────────────────────────────"
