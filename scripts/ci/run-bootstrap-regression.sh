#!/usr/bin/env bash
# CI runner for the bootstrap regression suite (coo-harness#86).
#
# Drives the full snapshot-build → session-resume cycle in fake-env mode:
#
#   1. Stage a cloud-style workspace at $VADE_CI_WORKSPACE_ROOT/{vade-runtime,
#      vade-coo-memory,vade-core} from the PR checkout.
#   2. Generate fixture SSH keys + their fingerprints; export them so
#      install_coo_ssh_keys' fingerprint check passes.
#   3. Install PATH-shadowed mocks for `op` and `curl` (latter only
#      intercepts api.github.com/user, forwards everything else).
#   4. Provision an isolated $HOME so the runner's gitconfig / ~/.claude
#      stay untouched, then plant the Anthropic-baseline gitconfig
#      fixture (user.email=noreply@anthropic.com) the cloud snapshot
#      ships by default. Mirrors the cloud baseline state coo-bootstrap
#      must overwrite-safely accept (vrt#266 allowlist; vrt#267 / Phase
#      B of vcm#762 — the persistence-round-trip fixture).
#   5. Run scripts/cloud-setup.sh (writes setup-receipt.json + invokes
#      coo-bootstrap.sh under the mocks).
#   6. Unset VADE_COO_MODE, re-source the env block persisted to
#      $TMP_HOME/.claude/settings.json (mirroring Claude Code's
#      resume-time injection — the durable carrier on cloud), then
#      run scripts/session-start-sync.sh + integrity-check.sh explicitly
#      (in live sessions integrity-check.sh runs inside coo-identity-digest;
#      CI only runs session-start-sync, so we call it directly here).
#      The re-source step is the structural fix that displaces a prior
#      `export VADE_COO_MODE=1` here: it tests the full persistence
#      round-trip rather than masking failures in
#      _write_claude_settings_env with a runtime pre-export.
#   7. Read integrity-check.json, subtract VADE_CI_ALLOWLIST, fail if any
#      degraded invariants remain.
#   8. Render a markdown summary (groups + per-invariant table) to
#      $VADE_CI_SUMMARY_OUT for the PR-comment step in the workflow.
#
# Invariants the suite covers correspond 1:1 to integrity-check.sh
# Groups A–F. E1–E4 (live MCP probes) skip in CI by design; F1–F4 skip
# cleanly because the staged vade-coo-memory is a stub without .git.
#
# Locally invokable: `bash scripts/ci/run-bootstrap-regression.sh .`
# from a vade-runtime checkout. Set VADE_CI_WORKSPACE_ROOT to a
# scratch path (e.g. /tmp/vade-ci-workspace) when running locally to
# avoid clobbering production /home/user/ working trees. SOURCE_DIR
# must NOT be the same as $VADE_CI_WORKSPACE_ROOT/vade-runtime — the
# stage step `rm -rf`s the destination first.
set -euo pipefail

SOURCE_DIR="${1:-$PWD}"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

WORKSPACE_ROOT="${VADE_CI_WORKSPACE_ROOT:-/home/user}"
RUNTIME_DST="$WORKSPACE_ROOT/coo-harness"
COO_MEM_DST="$WORKSPACE_ROOT/vade-coo-memory"
CORE_DST="$WORKSPACE_ROOT/vade-canvas"

TEST_HOME="${VADE_CI_TEST_HOME:-/tmp/vade-ci-home}"
MOCK_DIR="${VADE_CI_MOCK_DIR:-/tmp/vade-ci-mocks}"
SUMMARY_OUT="${VADE_CI_SUMMARY_OUT:-/tmp/bootstrap-regression-summary.md}"
RESULT_OUT="${VADE_CI_RESULT_OUT:-/tmp/bootstrap-regression-result.json}"
ALLOWLIST="${VADE_CI_ALLOWLIST:-}"
export SUMMARY_OUT RESULT_OUT ALLOWLIST

log() { printf '[ci-bootstrap-regression] %s\n' "$*"; }

# Self-clobber guard: SOURCE_DIR must not equal the destination, or the
# rm -rf in the stage step will delete the source mid-run.
if [ "$SOURCE_DIR" = "$RUNTIME_DST" ]; then
  log "FATAL: SOURCE_DIR equals RUNTIME_DST ($SOURCE_DIR); set VADE_CI_WORKSPACE_ROOT to a scratch path."
  exit 2
fi

# ── 1. Stage workspace ───────────────────────────────────────────
if [ ! -d "$WORKSPACE_ROOT" ] || [ ! -w "$WORKSPACE_ROOT" ]; then
  if command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$WORKSPACE_ROOT"
    sudo chown -R "$(id -u):$(id -g)" "$WORKSPACE_ROOT"
  else
    mkdir -p "$WORKSPACE_ROOT"
  fi
fi

log "Staging $SOURCE_DIR → $RUNTIME_DST"
rm -rf "$RUNTIME_DST"
mkdir -p "$RUNTIME_DST"
# tar-pipe preserves .git so cloud-setup's `git rev-parse --short HEAD`
# resolves a real sha into the receipt.
( cd "$SOURCE_DIR" && tar c . ) | ( cd "$RUNTIME_DST" && tar x )
git config --global --add safe.directory "$RUNTIME_DST" 2>/dev/null || true

log "Stubbing sibling repos at $WORKSPACE_ROOT"
rm -rf "$COO_MEM_DST" "$CORE_DST"
# Wipe workspace-scope leftovers from prior runs so a regression in
# cloud-setup or session-start-sync (e.g. a missing
# ensure_workspace_identity_link call) actually fails C1/C2 instead of
# being masked by a stale symlink. Production CI on ubuntu-latest gets
# a fresh runner per job; local re-runs need the explicit clean.
rm -rf "$WORKSPACE_ROOT/CLAUDE.md" "$WORKSPACE_ROOT/.mcp.json" \
       "$WORKSPACE_ROOT/.vade-cloud-state"
mkdir -p "$COO_MEM_DST/coo" "$COO_MEM_DST/identity"
cat > "$COO_MEM_DST/CLAUDE.md" <<'EOF'
# vade-coo-memory CLAUDE.md (CI bootstrap-regression stub)

Placeholder file so ensure_workspace_identity_link has a target and
integrity-check C1 passes. The real CLAUDE.md lives at
https://github.com/coo-labs/coo-memory/blob/main/CLAUDE.md.
EOF
mkdir -p "$CORE_DST/.claude"

# ── 2. Fixture SSH keys + fingerprints ───────────────────────────
log "Generating fixture SSH keys at $MOCK_DIR/keys"
rm -rf "$MOCK_DIR"
mkdir -p "$MOCK_DIR/keys" "$MOCK_DIR/bin"
ssh-keygen -t ed25519 -N '' -q -f "$MOCK_DIR/keys/vade-coo-auth" -C "ci-mock-auth"
ssh-keygen -t ed25519 -N '' -q -f "$MOCK_DIR/keys/vade-coo-sign" -C "ci-mock-sign"
COO_AUTH_FP_EXPECTED="$(ssh-keygen -lf "$MOCK_DIR/keys/vade-coo-auth.pub" | awk '{print $2}')"
COO_SIGN_FP_EXPECTED="$(ssh-keygen -lf "$MOCK_DIR/keys/vade-coo-sign.pub" | awk '{print $2}')"
export COO_AUTH_FP_EXPECTED COO_SIGN_FP_EXPECTED
log "  auth fp: $COO_AUTH_FP_EXPECTED"
log "  sign fp: $COO_SIGN_FP_EXPECTED"

# ── 3. PATH-shadowed mocks ───────────────────────────────────────
install -m 0755 "$RUNTIME_DST/scripts/ci/mocks/op"   "$MOCK_DIR/bin/op"
install -m 0755 "$RUNTIME_DST/scripts/ci/mocks/curl" "$MOCK_DIR/bin/curl"
export VADE_CI_MOCK_KEYDIR="$MOCK_DIR/keys"
# Capture the real curl path before our mock shadows it on PATH.
REAL_CURL="$(command -v curl || echo /usr/bin/curl)"
export VADE_CI_REAL_CURL="$REAL_CURL"
export PATH="$MOCK_DIR/bin:$PATH"
# Force ensure_op_cli / ensure_gh_cli to short-circuit on our mocks
# instead of trying to install the real binaries into a system bindir.
# Without this the snapshot-bindir resolver would prepend
# /home/user/.local/bin (when running as root with that dir present),
# shadowing our mock op with a real one.
export VADE_BINDIR_OVERRIDE="$MOCK_DIR/bin"
# Skip the binary-vendor fetch path in CI — it would try to hit
# api.github.com/repos/.../releases/... with a $GITHUB_MCP_PAT we don't
# have here, and even with one, the release-asset endpoint isn't
# mocked. ensure_*_cli's per-binary mocks handle the install side.
export VADE_BINARY_VENDOR_DISABLE=1
log "Mocks on PATH: op=$(command -v op) curl=$(command -v curl) (real curl: $REAL_CURL)"
log "VADE_BINDIR_OVERRIDE=$VADE_BINDIR_OVERRIDE"
log "VADE_BINARY_VENDOR_DISABLE=$VADE_BINARY_VENDOR_DISABLE"

# ── 4. Isolated HOME ─────────────────────────────────────────────
log "Provisioning isolated HOME at $TEST_HOME"
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME"
export HOME="$TEST_HOME"
unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME

# ── 5. Fake credentials + run cloud-setup ────────────────────────
export OP_SERVICE_ACCOUNT_TOKEN="ops_FAKE_CI_TOKEN_DO_NOT_USE_FOR_REAL_CALLS"

# Pin cloud-state under WORKSPACE_ROOT so the runner reads the same
# integrity-check.json that cloud-setup wrote. Without this override the
# common.sh default (/home/user/.vade-cloud-state) wins when the
# inherited env doesn't already point there, and a non-/home/user
# WORKSPACE_ROOT in CI yields a path mismatch (cloud-setup writes to
# /home/user/, runner reads from /tmp/...).
export VADE_CLOUD_STATE_DIR="$WORKSPACE_ROOT/.vade-cloud-state"

# Anthropic-baseline gitconfig fixture (Phase B of vcm#762 / vrt#267).
# Anthropic cloud snapshots ship a baseline user.email=noreply@anthropic.com
# from the harness base image, which the gitconfig-overwrite guard in
# coo-bootstrap.sh has to explicitly allowlist. vrt#262 introduced the
# guard without that allowlist; cloud sessions silently skipped the
# bootstrap (the 2026-05-13 incident); vrt#266 added the allowlist. The
# CI fixture must mirror the cloud baseline state so a regression in the
# allowlist surfaces as test failure, not as masked-green CI. Without
# this line, the CI was running against an empty $TMP_HOME/.gitconfig
# — a state that does not exist in production cloud.
git config --file "$TEST_HOME/.gitconfig" user.email noreply@anthropic.com

log "Running scripts/cloud-setup.sh"
bash "$RUNTIME_DST/scripts/cloud-setup.sh"

# ── 6. Re-source persisted settings.json env, then session-start-sync ─
log "Running scripts/session-start-sync.sh"
# Tag the integrity-check report with a CI-flavored session id so any
# operator triaging the artifact can tell it's not a real session.
export CLAUDE_CODE_SESSION_ID="ci-bootstrap-regression-${GITHUB_RUN_ID:-local}"
# Simulate Claude Code's resume behavior: at session-start, Claude Code
# reads settings.json.env and exports those keys into its own process
# env, where hook subprocesses (session-start-sync, coo-bootstrap, etc.)
# inherit them. cloud-setup.sh runs in a separate shell whose runtime
# export of VADE_COO_MODE=1 does not survive into this stage; the
# persisted settings.json.env is the durable carrier.
#
# Phase B (vcm#762 / vrt#267) replaces a hard `export VADE_COO_MODE=1`
# here with the real persistence round-trip: unset the runtime carrier,
# then re-source whatever cloud-setup actually persisted to
# settings.json.env. If _write_claude_settings_env was broken (e.g. by
# a regression in the COO-mode gate, the gitconfig-overwrite guard
# tripping before persistence, etc.), VADE_COO_MODE will be absent from
# settings.json.env, the writers in session-start-sync.sh / common.sh
# will early-exit on `[ "${VADE_COO_MODE:-0}" = "1" ]`, and the D4
# invariant (and others) will degrade — surfacing the regression as CI
# failure. This is the structural fix for the "fix-local-broke-cloud"
# class the pre-export was masking.
unset VADE_COO_MODE
SETTINGS_JSON_PATH="$TEST_HOME/.claude/settings.json"
if [ ! -f "$SETTINGS_JSON_PATH" ]; then
  log "FATAL: $SETTINGS_JSON_PATH absent after cloud-setup.sh — cannot re-source env."
  exit 2
fi
# Process substitution (source <(...)) — not the |source-/dev/stdin
# variant which dies on a subshell boundary unless `shopt -s lastpipe`
# is set with job control off. Both forms encode the same intent:
# re-export every key in settings.json.env into the current shell so
# the next-stage subprocess inherits the persisted view, not the
# pre-cloud-setup view.
log "Re-sourcing env from $SETTINGS_JSON_PATH (persistence round-trip)"
source <(jq -r '.env // {} | to_entries[] | "export \(.key)=\(.value | @sh)"' "$SETTINGS_JSON_PATH")
log "  VADE_COO_MODE after re-source: ${VADE_COO_MODE:-<unset>}"
bash "$RUNTIME_DST/scripts/session-start-sync.sh"

# Run integrity-check.sh explicitly. In live sessions this is called by
# coo-identity-digest.sh (hook position 4, after the platform repo-sync
# settles). CI only runs session-start-sync, so we invoke it directly.
log "Running scripts/integrity-check.sh"
bash "$RUNTIME_DST/scripts/integrity-check.sh" 2>/dev/null || true

# ── 7. Read integrity-check + apply allowlist ────────────────────
INTEGRITY="${VADE_CLOUD_STATE_DIR:-$WORKSPACE_ROOT/.vade-cloud-state}/integrity-check.json"
if [ ! -f "$INTEGRITY" ]; then
  log "FATAL: integrity-check.json not produced at $INTEGRITY"
  exit 2
fi

log "integrity-check.json contents:"
cat "$INTEGRITY"
echo

set +e
node -e '
  const fs = require("fs");
  const [path, allowlistRaw] = process.argv.slice(1);
  const allow = new Set((allowlistRaw || "").split(",").map(s => s.trim()).filter(Boolean));
  const data = JSON.parse(fs.readFileSync(path, "utf8"));
  const allDegraded = (data.summary && data.summary.degraded) || [];
  const degraded = allDegraded.filter(k => !allow.has(k));
  const allowed  = allDegraded.filter(k =>  allow.has(k));
  const ok = degraded.length === 0;
  fs.writeFileSync(process.env.RESULT_OUT, JSON.stringify({
    ok, degraded, allowed,
    passed: data.summary && data.summary.passed,
    total:  data.summary && data.summary.total,
  }) + "\n");
  process.exit(ok ? 0 : 1);
' "$INTEGRITY" "$ALLOWLIST"
RC=$?
set -e

# ── 8. Render summary regardless of pass/fail ────────────────────
bash "$RUNTIME_DST/scripts/ci/render-integrity-summary.sh" \
  "$INTEGRITY" "$RESULT_OUT" "$SUMMARY_OUT" "$ALLOWLIST"

if [ "$RC" -ne 0 ]; then
  log "FAIL — degraded invariants (excluding allowlist '$ALLOWLIST')"
  exit 1
fi
log "PASS — all integrity-check invariants ok (allowlist: '$ALLOWLIST')"
