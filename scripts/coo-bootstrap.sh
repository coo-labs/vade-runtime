#!/usr/bin/env bash
# COO identity bootstrap for cloud Claude Code sessions.
#
# Called by cloud-setup.sh when OP_SERVICE_ACCOUNT_TOKEN is present.
# Pulls COO credentials from 1Password (vault "COO") via the op CLI,
# writes SSH keys + gitconfig + env file, validates GitHub identity.
#
# Contract: vade-coo-memory/coo/cloud-env-bootstrap.md.
# Architecture rationale: MEMO 2026-04-22-03 (supersedes -22-01 §2).
#
# Fail modes are loud (exit non-zero) so the caller can decide whether
# to continue the VADE setup without COO identity.
#
# Path-trigger anchor: this script is one of the boot-impacting paths
# the Layer-2 full-harness workflow watches
# (.github/workflows/full-harness-layer2.yml). The blank line above
# this comment is the trivial-touch fixture from Phase C of the boot-
# architecture audit (vade-app/vade-coo-memory#762) used to validate
# that path filter on the workflow's own introduction PR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

boot_log_record coo-bootstrap start

# Record every exit path in ~/.vade/coo-bootstrap.log so silent failures
# still leave a trail. The identity-digest hook surfaces the tail of
# this file on each session start.
COO_BOOTSTRAP_STEP="init"
_on_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    bootstrap_log_record OK "step=${COO_BOOTSTRAP_STEP} rc=0"
    boot_log_record coo-bootstrap end ok "step=${COO_BOOTSTRAP_STEP}"
  else
    bootstrap_log_record FAIL "step=${COO_BOOTSTRAP_STEP} rc=${rc}"
    boot_log_record coo-bootstrap end fail "step=${COO_BOOTSTRAP_STEP}" "rc=${rc}"
  fi
  return $rc
}
trap _on_exit EXIT

# Defense-in-depth: coo-bootstrap is a no-op outside an explicit COO
# session. cloud-setup.sh exports VADE_COO_MODE=1 once for the lifetime
# of the cloud snapshot; the local `claude-coo` zsh wrapper exports it
# on Ven's Mac only when explicitly invoked. Outside those contexts —
# bare `claude` from any cwd, including from inside the vade-app
# workspace where project-scope hooks would otherwise fire this chain —
# the entire bootstrap pipeline (gitconfig write, secret fetch,
# settings.json merge) early-exits without touching the user's state.
if [ "${VADE_COO_MODE:-0}" != "1" ]; then
  log "coo-bootstrap: VADE_COO_MODE!=1; skipping COO bootstrap entirely."
  COO_BOOTSTRAP_STEP="skip-no-coo-mode"
  bootstrap_log_record SKIP "VADE_COO_MODE!=1"
  # Cloud-aware loud-skip: write a sentinel the identity-digest hook
  # surfaces at the TOP of its banner. Mac silent-skips remain silent
  # (helper no-ops outside cloud context). 2026-05-13 root cause:
  # this exact gate fired silently when the gitconfig-overwrite guard
  # blocked the persistence write, leaving every subsequent boot to
  # hit this skip with no surface. Phase A of vade-coo-memory#762.
  _write_skip_reason \
    "VADE_COO_MODE!=1 — coo-bootstrap exited before identity load" \
    "Fix: VADE_FORCE_COO_BOOTSTRAP=1 VADE_COO_MODE=1 bash /home/user/vade-runtime/scripts/coo-bootstrap.sh; set -a; source ~/.vade/coo-env; set +a; bash /home/user/vade-runtime/scripts/integrity-check.sh"
  trap - EXIT
  exit 0
fi

# Ensure baseline COO identity in gitconfig BEFORE any early-exit gate.
# Signing keys and full-fidelity gitconfig still gated behind
# write_coo_gitconfig (which needs OP_SERVICE_ACCOUNT_TOKEN). This minimal
# write only sets attribution name/email so commits survive no-op-token
# boots without falling back to the container default ("Test <test@test.com>").
# Closes vade-coo-memory#287.
COO_BOOTSTRAP_STEP="ensure_coo_identity_minimal"
GC="${VADE_COO_GITCONFIG:-${HOME}/.gitconfig}"
mkdir -p "$(dirname "$GC")"
# Belt-and-suspenders guard: refuse to overwrite a gitconfig owned by
# someone other than COO. Catches the case where VADE_COO_MODE=1 leaks
# into a context (manual debugging, future regression in the wrapper)
# where VADE_COO_GITCONFIG is unset and GC defaults to a personal
# $HOME/.gitconfig. Anthropic cloud snapshots ship a baseline
# user.email=noreply@anthropic.com from the harness base image — that
# is overwrite-safe (harness-default, not a real user identity) and
# was the regression that broke 2026-05-13 cloud sessions when the
# original "fresh snapshot has empty gitconfig" assumption failed.
existing_email="$(git config --file "$GC" --get user.email 2>/dev/null || true)"
if [ -n "$existing_email" ] \
   && [ "$existing_email" != "coo@vade-app.dev" ] \
   && [ "$existing_email" != "noreply@anthropic.com" ]; then
  log "coo-bootstrap: refusing to overwrite $GC (existing user.email=$existing_email is not COO)"
  bootstrap_log_record SKIP "refused to overwrite non-COO gitconfig $GC"
  # Cloud-aware loud-skip sentinel. This branch fires when an
  # unexpected user.email squats in $GC — the 2026-05-13 class but
  # for a non-Anthropic baseline. Mac silent-skips remain silent.
  _write_skip_reason \
    "coo-bootstrap refused to overwrite $GC (existing user.email=$existing_email)" \
    "Fix: inspect $GC, remove the non-COO user section (git config --file $GC --remove-section user), then VADE_FORCE_COO_BOOTSTRAP=1 bash /home/user/vade-runtime/scripts/coo-bootstrap.sh"
  trap - EXIT
  exit 0
fi
git config --file "$GC" user.name "COO"
git config --file "$GC" user.email "coo@vade-app.dev"

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  log "coo-bootstrap: OP_SERVICE_ACCOUNT_TOKEN unset; skipping COO identity setup."
  COO_BOOTSTRAP_STEP="skip-no-op-token"
  bootstrap_log_record SKIP "OP_SERVICE_ACCOUNT_TOKEN unset"
  # Cloud-aware loud-skip sentinel. Without OP_SERVICE_ACCOUNT_TOKEN
  # there's no 1Password access and the secret-fetch chain cannot
  # complete. Surface this loudly on cloud so the operator knows to
  # provision the env (Anthropic cloud "Setup script" env var).
  _write_skip_reason \
    "OP_SERVICE_ACCOUNT_TOKEN unset — coo-bootstrap cannot fetch secrets" \
    "Fix: provision OP_SERVICE_ACCOUNT_TOKEN in the Anthropic cloud 'Setup script' env, then resume the container. For ad-hoc recovery, export the token then VADE_FORCE_COO_BOOTSTRAP=1 bash /home/user/vade-runtime/scripts/coo-bootstrap.sh"
  trap - EXIT
  exit 0
fi

# Defense in depth behind the SessionStart matcher: secrets don't
# rotate within a container's lifetime, and every artifact this
# script writes (SSH keys, gitconfig, env file, settings.json env
# block) is durable across resumes. Skip the whole pipeline if it
# already ran in this container. Escape hatch:
# VADE_FORCE_COO_BOOTSTRAP=1.
#
# Also verify the settings.json env block actually contains the keys
# a successful bootstrap would have written. A bare marker is not
# enough: if an earlier bootstrap ran under pre-#18 code it left the
# marker without populating GITHUB_MCP_PAT into ~/.claude/settings.json,
# and the session resume came up with github MCP unauth. If any expected
# key is absent, treat the marker as stale and re-run. run-2026-04-22T073717
# hit exactly this: marker present, settings.json env had only
# AGENTMAIL_API_KEY, GITHUB_MCP_PAT was unset, vade-coo identity dark.
COO_ENV_FILE="${HOME}/.vade/coo-env"
COO_BOOT_MARKER="${HOME}/.vade/.coo-bootstrap-done"
_settings_env_complete() {
  local settings="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json"
  [ -f "$settings" ] || return 1
  check_cmd node || return 0  # node missing: fall back to marker-only trust
  node -e '
    const fs = require("fs");
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) || {}; }
    catch { process.exit(1); }
    const env = cfg.env || {};
    // Bootstrap-blocking required-list: every key here, when missing, force-re-runs
    // the full bootstrap. VADE_AUTH_TOKEN is intentionally NOT in this list — it
    // is passed through merge_coo_settings_env (best-effort) but feature-gated and
    // may be empty in some environments without warranting a full re-run.
    const required = ["GITHUB_MCP_PAT", "GITHUB_TOKEN", "AGENTMAIL_API_KEY", "MEM0_API_KEY",
                      "R2_TRANSCRIPTS_ACCESS_KEY_ID", "R2_TRANSCRIPTS_SECRET_ACCESS_KEY",
                      "TRANSCRIPTS_AGE_IDENTITY",
                      "VADE_CLOUD_STATE_DIR", "PATH"];
    for (const k of required) { if (!env[k]) process.exit(1); }
    // PATH content sanity: Claude Code does not shell-expand env values,
    // so a literal "${PATH}" in this position is the broken-output of an
    // earlier bootstrap (vade-runtime#83 first-cut bug). Force re-run so
    // _write_claude_settings_paths overwrites with the expanded form.
    // No FHS-layout floor (vade-runtime#141): hard-coding /usr/bin
    // overfit to the Debian base image and would re-trigger the
    // bootstrap on every boot if the image family ever changes
    // (Alpine/musl, Nix-style /nix/store, etc.). The literal-${PATH}
    // check above is the load-bearing one.
    if (env.PATH.includes("${PATH}")) {
      process.exit(1);
    }
    process.exit(0);
  ' "$settings" 2>/dev/null
}
if [ "${VADE_FORCE_COO_BOOTSTRAP:-0}" != "1" ] \
   && [ -f "$COO_ENV_FILE" ] && [ -f "$COO_BOOT_MARKER" ] \
   && _settings_env_complete \
   && _cached_pat_still_valid; then
  log "coo-bootstrap: already complete this container; skipping."
  COO_BOOTSTRAP_STEP="skip-marker-present"
  bootstrap_log_record SKIP "marker present at $COO_BOOT_MARKER (cached PAT validated)"
  # Benign skip: identity is already loaded. Clear any stale skip
  # sentinel from a prior failing boot so the digest banner reflects
  # current state.
  _clear_skip_reason
  trap - EXIT
  exit 0
fi
if [ -f "$COO_BOOT_MARKER" ] && [ "${VADE_FORCE_COO_BOOTSTRAP:-0}" != "1" ]; then
  # Marker exists but at least one shortcut precondition failed:
  # settings.json env block is missing a key (pre-#18 bootstrap, see
  # comment above), or the cached PAT no longer authenticates as
  # vade-coo (#72 — revocation/scope-change/expiry between snapshots).
  # Fall through to the full bootstrap to refresh both.
  if [ -f "$COO_ENV_FILE" ] && _settings_env_complete \
     && ! _cached_pat_still_valid; then
    log "coo-bootstrap: marker present but cached GITHUB_MCP_PAT no longer authenticates as vade-coo; re-running"
    bootstrap_log_record START "marker stale (cached PAT failed validation); forcing re-run"
  else
    log "coo-bootstrap: marker present but settings.json env incomplete; re-running"
    bootstrap_log_record START "marker stale (settings.json env missing keys); forcing re-run"
  fi
fi

log "coo-bootstrap: starting"
bootstrap_log_record START "VADE_FORCE_COO_BOOTSTRAP=${VADE_FORCE_COO_BOOTSTRAP:-0}"

COO_BOOTSTRAP_STEP="ensure_op_cli"
ensure_op_cli

# Verify the service-account token before attempting any reads. Retry
# to absorb transient 1Password API errors (503s). 5 attempts
# (~15s tolerance) matches _op_to_file's already-tuned budget
# (lib/common.sh _op_to_file) — same flake mode. #76 propagates the
# proven budget here after run-2026-04-25T182206 exhausted the
# prior 3-attempt budget on a transient api.1password.com hiccup.
COO_BOOTSTRAP_STEP="op_whoami"
if ! retry 5 op whoami >/dev/null; then
  log "FATAL: op whoami failed after retries. Check OP_SERVICE_ACCOUNT_TOKEN and vault access."
  exit 1
fi
log "1Password service account authenticated: $(op whoami 2>/dev/null | head -1)"

COO_BOOTSTRAP_STEP="install_coo_ssh_keys"
install_coo_ssh_keys

COO_BOOTSTRAP_STEP="fetch_coo_secrets"
fetch_coo_secrets

COO_BOOTSTRAP_STEP="write_coo_gitconfig"
write_coo_gitconfig

# Make `git push` route through git-push-with-fallback.sh by default
# (vade-runtime#67 adoption-as-default). Non-fatal: if the install
# refuses (e.g. user already has a custom $bindir/git), the bootstrap
# continues. Pushes still work via system git; they just won't auto-
# fallback when the cloud git-proxy 403s.
COO_BOOTSTRAP_STEP="install_coo_git_shim"
install_coo_git_shim || log "coo-bootstrap: git shim install skipped/failed; continuing"

# Validate BEFORE merging into ~/.claude/settings.json (#66): a
# wrong-identity PAT must never land in the harness's persistent env
# block. fetch_coo_secrets stages secrets in ~/.vade/coo-env and exports
# them to this shell so validate_coo_identity can hit api.github.com;
# only after that succeeds does merge_coo_settings_env write the PAT
# into settings.json. set -e ensures we exit before merge on validate
# failure.
COO_BOOTSTRAP_STEP="validate_coo_identity"
validate_coo_identity

COO_BOOTSTRAP_STEP="merge_coo_settings_env"
merge_coo_settings_env

# Persist non-secret path state (VADE_CLOUD_STATE_DIR + PATH with the
# snapshot user bindir prepended) into ~/.claude/settings.json env so
# fresh shells inherit it on first try. vade-runtime#83.
COO_BOOTSTRAP_STEP="merge_coo_settings_paths"
merge_coo_settings_paths

COO_BOOTSTRAP_STEP="summarize_coo_identity"
summarize_coo_identity

mkdir -p "$(dirname "$COO_BOOT_MARKER")"
touch "$COO_BOOT_MARKER"

# Clear any stale loud-skip sentinel from a prior failing boot now that
# the full bootstrap has completed successfully. Digest banner picks up
# the absence on the next session-start.
_clear_skip_reason

COO_BOOTSTRAP_STEP="complete"
log "coo-bootstrap: complete"
