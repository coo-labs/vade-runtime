#!/usr/bin/env bash
# test-gh-coo-wrap: smoke-test the gh wrapper that auto-injects the
# Claude Code session URL onto --body for covered `gh` subcommands.
#
# Strategy: install a mock `gh-real` that prints its JSON-encoded
# argv (and stdin) to stdout, then run the wrapper with various arg
# shapes and assert the augmented body appears (or doesn't, for
# pass-through cases) where expected.
#
# Run: bash scripts/ci/test-gh-coo-wrap.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../gh-coo-wrap.sh"

[ -x "$WRAPPER" ] || { echo "FAIL: wrapper not executable at $WRAPPER"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Mock gh-real: dump its argv, one per line, to stdout. For
# --body-file we also dump the file contents marked with FILE-CONTENT:.
# Also prints GH_TOKEN so routing-layer tests can assert which PAT
# the wrapper selected for this invocation.
cat > "$WORK/gh-real" <<'EOF'
#!/usr/bin/env bash
printf 'GH_TOKEN=%s\n' "${GH_TOKEN:-<unset>}"
i=0
for a in "$@"; do
  i=$((i+1))
  printf 'ARG[%d]=%s\n' "$i" "$a"
done
# If a body-file path was given, dump its contents too.
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    if [ -f "$a" ]; then
      printf 'FILE-CONTENT-START\n'
      cat "$a"
      printf '\nFILE-CONTENT-END\n'
    fi
  fi
  case "$a" in
    --body-file=*)
      bf="${a#--body-file=}"
      if [ -f "$bf" ]; then
        printf 'FILE-CONTENT-START\n'
        cat "$bf"
        printf '\nFILE-CONTENT-END\n'
      fi
      ;;
  esac
  prev="$a"
done
EOF
chmod 0755 "$WORK/gh-real"

# Synthetic session env for tests.
export CLAUDE_CODE_REMOTE_SESSION_ID="cse_TESTID123"
export COO_GH_REAL="$WORK/gh-real"
EXPECTED_URL="https://claude.ai/code/session_TESTID123"

PASS=0
FAIL=0
declare -a FAILURES=()

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf '  PASS  %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
    printf '         expected to contain: %s\n' "$needle"
    printf '         got:\n'
    printf '%s\n' "$haystack" | sed 's/^/           /'
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
    printf '         expected NOT to contain: %s\n' "$needle"
    printf '         got:\n'
    printf '%s\n' "$haystack" | sed 's/^/           /'
  else
    PASS=$((PASS+1))
    printf '  PASS  %s\n' "$name"
  fi
}

# ---- TEST 1: gh pr create --body "X" augments body ----
out="$("$WRAPPER" pr create --title t --body "hello world")"
assert_contains "pr create --body augments" "$out" "$EXPECTED_URL"
assert_contains "pr create --body preserves original" "$out" "hello world"

# ---- TEST 2: gh pr comment --body "X" augments ----
out="$("$WRAPPER" pr comment 123 --body "ack")"
assert_contains "pr comment --body augments" "$out" "$EXPECTED_URL"

# ---- TEST 3: gh issue create --body "X" augments ----
out="$("$WRAPPER" issue create --title t --body "report")"
assert_contains "issue create --body augments" "$out" "$EXPECTED_URL"

# ---- TEST 4: gh issue comment --body "X" augments ----
out="$("$WRAPPER" issue comment 1 --body "thanks")"
assert_contains "issue comment --body augments" "$out" "$EXPECTED_URL"

# ---- TEST 5: gh pr review --body "X" augments ----
out="$("$WRAPPER" pr review 9 --request-changes --body "needs fix")"
assert_contains "pr review --body augments" "$out" "$EXPECTED_URL"

# ---- TEST 6: --body= form (single token) augments ----
out="$("$WRAPPER" pr create --title t --body="long body text")"
assert_contains "--body= form augments" "$out" "$EXPECTED_URL"

# ---- TEST 7: -b short form augments ----
out="$("$WRAPPER" pr create --title t -b "short")"
assert_contains "-b short form augments" "$out" "$EXPECTED_URL"

# ---- TEST 8: idempotent (body already has URL) ----
existing_url="https://claude.ai/code/session_OLDID"
out="$("$WRAPPER" pr create --title t --body "preexisting $existing_url")"
assert_contains "idempotent: preexisting URL preserved" "$out" "$existing_url"
assert_not_contains "idempotent: new URL not appended" "$out" "$EXPECTED_URL"

# ---- TEST 9: empty body — no augmentation ----
out="$("$WRAPPER" pr create --title t --body "")"
assert_not_contains "empty body: not augmented" "$out" "$EXPECTED_URL"

# ---- TEST 10: pass-through — pr review --approve (no body) ----
out="$("$WRAPPER" pr review 9 --approve)"
assert_not_contains "pr review --approve: pass-through" "$out" "$EXPECTED_URL"

# ---- TEST 11: pass-through — non-covered subcommand (pr list) ----
out="$("$WRAPPER" pr list --state open)"
assert_not_contains "pr list: pass-through" "$out" "$EXPECTED_URL"

# ---- TEST 12: pass-through — gh api (uncovered) ----
out="$("$WRAPPER" api '/repos/foo/bar' -f body="x")"
assert_not_contains "gh api: pass-through" "$out" "$EXPECTED_URL"

# ---- TEST 13: --body-file augments (file contents written augmented) ----
echo "from a file" > "$WORK/body.txt"
out="$("$WRAPPER" pr create --title t --body-file "$WORK/body.txt")"
assert_contains "--body-file augments file content" "$out" "$EXPECTED_URL"
assert_contains "--body-file preserves original content" "$out" "from a file"

# ---- TEST 14: --body-file=- reads stdin and augments ----
out="$(printf 'from stdin' | "$WRAPPER" pr create --title t --body-file -)"
assert_contains "--body-file=stdin augments" "$out" "$EXPECTED_URL"
assert_contains "--body-file=stdin preserves" "$out" "from stdin"

# ---- TEST 15: outside-Claude (no session env) — pass-through ----
out="$(env -u CLAUDE_CODE_REMOTE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
       COO_GH_REAL="$WORK/gh-real" "$WRAPPER" pr create --title t --body "hi")"
assert_not_contains "no session env: not augmented" "$out" "claude.ai/code/session_"

# ---- TEST 16: -R <repo> before subcommand — augments ----
out="$("$WRAPPER" -R coo-labs/coo-memory issue comment 1 --body "with -R")"
assert_contains "-R before subcommand: issue comment augments" "$out" "$EXPECTED_URL"
assert_contains "-R before subcommand: body preserved" "$out" "with -R"

# ---- TEST 17: --repo <repo> before subcommand — augments ----
out="$("$WRAPPER" --repo coo-labs/coo-harness pr comment 2 --body "with --repo")"
assert_contains "--repo before subcommand: pr comment augments" "$out" "$EXPECTED_URL"

# ---- TEST 18: --repo=<repo> (=value form) before subcommand — augments ----
out="$("$WRAPPER" --repo=coo-labs/vade-canvas issue create --title t --body "with --repo=")"
assert_contains "--repo=value before subcommand: issue create augments" "$out" "$EXPECTED_URL"

# ---- TEST 19: -R then pr review --body — augments ----
out="$("$WRAPPER" -R coo-labs/coo-harness pr review 9 --request-changes --body "needs work")"
assert_contains "-R before pr review --body: augments" "$out" "$EXPECTED_URL"

# ---- TEST 20: -R then pr list — pass-through (uncovered subcommand) ----
out="$("$WRAPPER" -R coo-labs/coo-harness pr list --state open)"
assert_not_contains "-R before pr list: pass-through" "$out" "$EXPECTED_URL"

# ---- TEST 21: -R then pr review --approve (no body) — pass-through ----
out="$("$WRAPPER" -R coo-labs/coo-harness pr review 9 --approve)"
assert_not_contains "-R before pr review --approve: no augmentation" "$out" "$EXPECTED_URL"

# ---- TEST 22: -R interleaved (subcommand then -R then action) — augments ----
out="$("$WRAPPER" issue -R coo-labs/coo-harness comment 1 --body "interleaved")"
assert_contains "-R interleaved: issue comment augments" "$out" "$EXPECTED_URL"

# ---- TEST 23: --hostname before subcommand — augments ----
out="$("$WRAPPER" --hostname github.com issue comment 1 --body "with hostname")"
assert_contains "--hostname before subcommand: augments" "$out" "$EXPECTED_URL"

# ---- TEST 24: -R then --body-file — augments file content ----
echo "from a file (with -R)" > "$WORK/body2.txt"
out="$("$WRAPPER" -R coo-labs/coo-memory issue comment 1 --body-file "$WORK/body2.txt")"
assert_contains "-R before --body-file: file content augmented" "$out" "$EXPECTED_URL"
assert_contains "-R before --body-file: original content preserved" "$out" "from a file (with -R)"

# ---- TEST 25: real binary missing AND none on PATH — exit 127 ----
# Set PATH to dirs that don't contain gh so the fallback also fails.
ec=0
err="$(env -i PATH=/usr/bin:/bin HOME="$HOME" COO_GH_REAL=/nonexistent/path \
       "$WRAPPER" pr create --body "x" 2>&1 >/dev/null)" || ec=$?
if [ "$ec" = "127" ]; then
  PASS=$((PASS+1))
  printf '  PASS  missing real binary: exit 127\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("missing real binary exit code")
  printf '  FAIL  missing real binary: exit %s, expected 127\n' "$ec"
  printf '         stderr: %s\n' "$err"
fi

# ============================================================
# PAT routing tests (MEMO-2026-05-11-6xv2 + MEMO-2026-05-12-22m9).
# ============================================================
# These tests assert which PAT the wrapper exports as GH_TOKEN
# based on the target repo owner. The mock prints GH_TOKEN as its
# first output line; tests assert that prefix.

export GITHUB_MCP_PAT="MCP_PAT_TESTING"
export GITHUB_PUBLIC_PAT="PUBLIC_PAT_TESTING"
export GH_TOKEN="MCP_PAT_TESTING"  # default state at session start

printf '\nPAT routing tests:\n'

# --- coo-labs/* (MCP PAT, no swap) ---

# Existing --repo flag form, coo-labs — no swap
out="$("$WRAPPER" --repo coo-labs/foo pr comment 1 --body "x")"
assert_contains "coo-labs via --repo: keeps MCP_PAT" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# Positional repo arg, coo-labs — no swap (new coverage)
out="$("$WRAPPER" repo view coo-labs/foo)"
assert_contains "gh repo view coo-labs/foo: keeps MCP_PAT" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# gh api repos/coo-labs/...
out="$("$WRAPPER" api repos/coo-labs/foo/issues)"
assert_contains "gh api repos/coo-labs: keeps MCP_PAT" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# gh api orgs/coo-labs
out="$("$WRAPPER" api orgs/coo-labs/repos)"
assert_contains "gh api orgs/coo-labs: keeps MCP_PAT" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# --- non-coo-labs (PUBLIC PAT swap) ---

# Existing --repo flag form, non-coo-labs — swaps
out="$("$WRAPPER" --repo venpopov/foo pr comment 1 --body "x")"
assert_contains "venpopov via --repo: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# gh repo fork positional (the failure case that motivated this PR)
out="$("$WRAPPER" repo fork venpopov/foo)"
assert_contains "gh repo fork venpopov/foo: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

out="$("$WRAPPER" repo fork anthropics/claude-code --org vade-coo)"
assert_contains "gh repo fork anthropics/... --org vade-coo: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# gh repo create non-coo-labs
out="$("$WRAPPER" repo create venpopov/new-repo --public)"
assert_contains "gh repo create venpopov/new-repo: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# gh repo clone with HTTPS URL
out="$("$WRAPPER" repo clone https://github.com/anthropics/foo)"
assert_contains "gh repo clone https URL: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# gh repo clone with SSH URL
out="$("$WRAPPER" repo clone git@github.com:anthropics/foo)"
assert_contains "gh repo clone SSH URL: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# gh api repos/<non-coo-labs>/...
out="$("$WRAPPER" api repos/anthropics/claude-code/issues)"
assert_contains "gh api repos/anthropics/...: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# gh api repos/<non-coo-labs>/.../forks (the today fork failure case)
out="$("$WRAPPER" api -X POST repos/venpopov/foo/forks)"
assert_contains "gh api -X POST repos/venpopov/.../forks: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# gh api orgs/<non-coo-labs>
out="$("$WRAPPER" api orgs/anthropics/repos)"
assert_contains "gh api orgs/anthropics: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# gh api users/<non-coo-labs>
out="$("$WRAPPER" api users/octocat)"
assert_contains "gh api users/octocat: swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# gh api with leading slash on path
out="$("$WRAPPER" api /repos/anthropics/foo)"
assert_contains "gh api /repos/... (leading slash): swaps to PUBLIC_PAT" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# --- template/flag-value disambiguation ---

# gh repo create --template anthropics/foo coo-labs/new — must pick coo-labs, not anthropics
out="$("$WRAPPER" repo create --template anthropics/foo coo-labs/new --public)"
assert_contains "gh repo create --template foreign/X coo-labs/Y: keeps MCP_PAT (target wins)" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# Symmetric: --template coo-labs/foo venpopov/new — must pick venpopov, swap
out="$("$WRAPPER" repo create --template coo-labs/foo venpopov/new --public)"
assert_contains "gh repo create --template coo-labs/X venpopov/Y: swaps to PUBLIC_PAT (target wins)" "$out" "GH_TOKEN=PUBLIC_PAT_TESTING"

# --- GITHUB_PUBLIC_PAT unset: no override even for non-coo-labs ---

out="$(env -u GITHUB_PUBLIC_PAT GITHUB_MCP_PAT="$GITHUB_MCP_PAT" GH_TOKEN="$GH_TOKEN" CLAUDE_CODE_REMOTE_SESSION_ID="$CLAUDE_CODE_REMOTE_SESSION_ID" COO_GH_REAL="$WORK/gh-real" "$WRAPPER" repo fork venpopov/foo)"
assert_contains "GITHUB_PUBLIC_PAT unset: no swap, keeps MCP_PAT" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# --- uncovered subcommands: no swap ---

# gh repo list (action not in our list) — no routing fires
out="$("$WRAPPER" repo list venpopov)"
# Note: 'venpopov' here is the *owner argument* to `gh repo list`; we
# deliberately don't extract from `gh repo list` since its positional
# is owner-only (not owner/name). MCP_PAT remains.
assert_contains "gh repo list <owner>: keeps MCP_PAT (uncovered action)" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# gh release create (uncovered) — no swap
out="$("$WRAPPER" release create v1.0.0)"
assert_contains "gh release create: keeps MCP_PAT (uncovered)" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# ============================================================
# App-token routing tests (coo-memory#837).
# ============================================================
# Org-admin REST endpoints (issue-types, properties, custom roles)
# get routed to a GitHub App installation token, minted via
# $VADE_RUNTIME_DIR/scripts/gh-app-token.sh, bypassing the
# identity-vs-token rule (MEMO-2026-05-21-w6qz) that 403s the
# fine-grained PAT on org-admin operations.

printf '\nApp-token routing tests:\n'

# Stand up a mock minter under a fake $VADE_RUNTIME_DIR so the wrapper
# can invoke it without reading 1Password or hitting GitHub. The mock
# prints a known sentinel token (or exits non-zero for failure-mode
# coverage).
FAKE_RUNTIME="$WORK/fake-runtime"
mkdir -p "$FAKE_RUNTIME/scripts"
cat > "$FAKE_RUNTIME/scripts/gh-app-token.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${MOCK_MINTER_FAIL:-0}" = "1" ]; then
  echo "mock minter: deliberate failure" >&2
  exit 3
fi
echo "APP_TOKEN_TESTING"
EOF
chmod +x "$FAKE_RUNTIME/scripts/gh-app-token.sh"
export VADE_RUNTIME_DIR="$FAKE_RUNTIME"
export GITHUB_APP_ID="999000"
export GITHUB_APP_INSTALLATION_ID="888777"

# --- org-admin auto-routes ---

out="$("$WRAPPER" api orgs/coo-labs/issue-types)"
assert_contains "gh api orgs/coo-labs/issue-types: mints App token" "$out" "GH_TOKEN=APP_TOKEN_TESTING"

out="$("$WRAPPER" api orgs/coo-labs/issue-types/123)"
assert_contains "gh api orgs/coo-labs/issue-types/<id>: mints App token" "$out" "GH_TOKEN=APP_TOKEN_TESTING"

out="$("$WRAPPER" api -X PUT orgs/coo-labs/issue-types/123)"
assert_contains "gh api -X PUT orgs/coo-labs/issue-types/<id>: mints App token" "$out" "GH_TOKEN=APP_TOKEN_TESTING"

out="$("$WRAPPER" api orgs/coo-labs/properties/values)"
assert_contains "gh api orgs/coo-labs/properties/values: mints App token" "$out" "GH_TOKEN=APP_TOKEN_TESTING"

out="$("$WRAPPER" api orgs/coo-labs/custom-repository-roles)"
assert_contains "gh api orgs/coo-labs/custom-repository-roles: mints App token" "$out" "GH_TOKEN=APP_TOKEN_TESTING"

# --- non-org-admin paths stay on MCP_PAT (regression coverage) ---

out="$("$WRAPPER" api orgs/coo-labs/repos)"
assert_contains "gh api orgs/coo-labs/repos: keeps MCP_PAT (not org-admin)" "$out" "GH_TOKEN=MCP_PAT_TESTING"

out="$("$WRAPPER" api repos/coo-labs/coo-memory)"
assert_contains "gh api repos/coo-labs/...: keeps MCP_PAT (not org-admin)" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# --- explicit opt-in via GH_USE_APP_TOKEN=1 ---

out="$(GH_USE_APP_TOKEN=1 "$WRAPPER" api user)"
assert_contains "GH_USE_APP_TOKEN=1: mints App token regardless of path" "$out" "GH_TOKEN=APP_TOKEN_TESTING"

out="$(GH_USE_APP_TOKEN=1 "$WRAPPER" api graphql -f query=foo)"
assert_contains "GH_USE_APP_TOKEN=1 + graphql: mints App token" "$out" "GH_TOKEN=APP_TOKEN_TESTING"

# --- GITHUB_APP_ID unset: routing falls through (no App-token attempt) ---

out="$(env -u GITHUB_APP_ID -u GITHUB_APP_INSTALLATION_ID \
  GITHUB_MCP_PAT="$GITHUB_MCP_PAT" GITHUB_PUBLIC_PAT="$GITHUB_PUBLIC_PAT" \
  GH_TOKEN="$GH_TOKEN" CLAUDE_CODE_REMOTE_SESSION_ID="$CLAUDE_CODE_REMOTE_SESSION_ID" \
  COO_GH_REAL="$WORK/gh-real" VADE_RUNTIME_DIR="$VADE_RUNTIME_DIR" \
  "$WRAPPER" api orgs/coo-labs/issue-types)"
assert_contains "GITHUB_APP_ID unset: org-admin path keeps MCP_PAT (no mint)" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# --- minter failure: warn + fall back to PAT (no silent 403 swap) ---

out="$(MOCK_MINTER_FAIL=1 "$WRAPPER" api orgs/coo-labs/issue-types 2>&1)"
assert_contains "minter failure: warns" "$out" "App-token mint failed"
assert_contains "minter failure: falls back to MCP_PAT" "$out" "GH_TOKEN=MCP_PAT_TESTING"

# --- minter missing: warn + fall back to PAT ---

out="$(VADE_RUNTIME_DIR="/nonexistent-vade-runtime" \
  GITHUB_APP_ID="$GITHUB_APP_ID" GITHUB_APP_INSTALLATION_ID="$GITHUB_APP_INSTALLATION_ID" \
  GITHUB_MCP_PAT="$GITHUB_MCP_PAT" GITHUB_PUBLIC_PAT="$GITHUB_PUBLIC_PAT" \
  GH_TOKEN="$GH_TOKEN" CLAUDE_CODE_REMOTE_SESSION_ID="$CLAUDE_CODE_REMOTE_SESSION_ID" \
  COO_GH_REAL="$WORK/gh-real" \
  "$WRAPPER" api orgs/coo-labs/issue-types 2>&1)"
assert_contains "minter missing: warns" "$out" "minter not found"
assert_contains "minter missing: falls back to MCP_PAT" "$out" "GH_TOKEN=MCP_PAT_TESTING"

printf '\n'
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed tests:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
