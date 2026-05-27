#!/usr/bin/env bash
# CI smoke test for scripts/coo-identity-digest.sh gap-warning behavior.
#
# Locks down the contract added after coo-labs/coo-memory#1069 shipped
# three boot-digest regressions: when expected input files / dirs are
# missing, every guarded section in the digest must emit a
# `⚠ DIGEST GAP` warning to stdout rather than silently no-op.
#
# Pre-fix, the script ran to exit 0 with empty section blocks; the
# hook self-test still passed (script exists, exits 0) and the
# integrity-check stayed green. Ven caught the gap only by reading the
# transcript and noticing missing content. This test makes the gap a
# CI-observable regression.
#
# Asserts:
#
#   1. Synthetic missing-files run produces three DIGEST GAP markers
#      (identity layer, lineage, memos). Catches removal of any of the
#      three else-branches added in this commit.
#
#   2. Each gap warning names the expected path (so the operator's fix
#      is obvious from the boot output).
#
#   3. Synthetic populated-files run produces ZERO DIGEST GAP markers
#      and DOES produce the three section headers. Catches the inverse
#      regression: false-positive warnings on healthy boots.
#
#   4. Missing jq specifically surfaces the jq-not-on-PATH variant of
#      the memo gap, not the file-not-found variant. Catches the
#      if/elif distinction collapsing into a single message.
#
# The test does NOT exercise:
#   - Live MEM_REPO content (test stubs minimal files).
#   - Bootstrap posture / MCP-surface / cloud-receipt blocks.
#   - The SessionStart-hook chain (Layer-2, coo-harness#85).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIGEST_SRC="$REPO_ROOT/scripts/coo-identity-digest.sh"

if [ ! -x "$DIGEST_SRC" ]; then
  echo "FAIL: $DIGEST_SRC not executable" >&2
  exit 1
fi

WORKDIR="$(mktemp -d -t digest-gap-warnings-test-XXXXXX)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label" >&2
    echo "    expected substring: $needle" >&2
    echo "    actual (first 40 lines):" >&2
    printf '%s' "$haystack" | head -40 | sed 's/^/      /' >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $label" >&2
    echo "    unexpected substring present: $needle" >&2
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_count() {
  local haystack="$1" needle="$2" expected="$3" label="$4"
  local actual
  actual="$(printf '%s' "$haystack" | grep -cF -- "$needle" || true)"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label (count=$actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (got count=$actual, expected $expected)" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Assert 1+2: empty MEM_REPO produces three gap warnings, each naming
# its expected path.
# ──────────────────────────────────────────────────────────────────────

echo "[case 1] empty MEM_REPO → three DIGEST GAP warnings"
EMPTY_REPO="$WORKDIR/empty-mem-repo"
mkdir -p "$EMPTY_REPO"
# CLAUDE.md must exist; the top-level gate exits 0 silently otherwise.
touch "$EMPTY_REPO/CLAUDE.md"

out1="$(COO_MEMORY_DIR="$EMPTY_REPO" bash "$DIGEST_SRC" 2>&1 || true)"

assert_count "$out1" "⚠ DIGEST GAP" 3 \
  "three DIGEST GAP markers emitted"
assert_contains "$out1" "Identity layer (CB-* / OG-*) unavailable" \
  "identity-layer gap surfaces section name"
assert_contains "$out1" "$EMPTY_REPO/identity/identity_layer.md" \
  "identity-layer gap names expected path"
assert_contains "$out1" "Active lineage events unavailable" \
  "lineage gap surfaces section name"
assert_contains "$out1" "$EMPTY_REPO/lineage" \
  "lineage gap names expected path"
assert_contains "$out1" "Latest memos unavailable" \
  "memos gap surfaces section name"
assert_contains "$out1" "$EMPTY_REPO/memos/memo_index.json" \
  "memos gap names expected path"
assert_contains "$out1" "memo_index.json not found" \
  "memos gap names file-missing cause"

# ──────────────────────────────────────────────────────────────────────
# Assert 3: populated MEM_REPO produces ZERO gap warnings AND the three
# expected section headers.
# ──────────────────────────────────────────────────────────────────────

echo "[case 2] populated MEM_REPO → zero DIGEST GAP, three section headers"
FULL_REPO="$WORKDIR/full-mem-repo"
mkdir -p "$FULL_REPO/identity" "$FULL_REPO/lineage" "$FULL_REPO/memos"
touch "$FULL_REPO/CLAUDE.md"
cat >"$FULL_REPO/identity/identity_layer.md" <<'EOF'
# Identity layer test fixture
CB-001 — placeholder.
EOF
# Minimal memo_index.json with one entry so jq produces output.
cat >"$FULL_REPO/memos/memo_index.json" <<'EOF'
[{"id":"2026-05-27-test","status":"active","title":"Fixture memo"}]
EOF

out2="$(COO_MEMORY_DIR="$FULL_REPO" bash "$DIGEST_SRC" 2>&1 || true)"

assert_not_contains "$out2" "⚠ DIGEST GAP" \
  "no gap warnings when files present"
assert_contains "$out2" "Identity layer (CB-* / OG-*) — inlined from" \
  "identity-layer section renders"
# Lineage dir exists but is empty — no events to print, but no gap
# warning either: the directory IS present, so the guard succeeds.
# Section header should render even with zero events inside.
assert_contains "$out2" "Active lineage events" \
  "lineage section header renders even when empty"
assert_contains "$out2" "Latest memos (10 most recent" \
  "memos section renders with fixture entry"
assert_contains "$out2" "2026-05-27-test" \
  "memo digest renders the fixture entry id"

# ──────────────────────────────────────────────────────────────────────
# Assert 4: missing jq surfaces the jq-specific variant, not
# the file-not-found variant.
# ──────────────────────────────────────────────────────────────────────

echo "[case 3] memo_index present + jq off PATH → jq-specific gap"
JQ_PATH="$WORKDIR/sanitized-path-bin"
mkdir -p "$JQ_PATH"
# Synthesize a PATH that has bash + standard tools but no jq. We do
# this by symlinking only the binaries the script needs (excluding jq).
for cmd in bash sh cat grep sed awk readlink basename dirname cd ls \
           printf echo tr mktemp date node id sort find; do
  if real="$(command -v "$cmd" 2>/dev/null)"; then
    ln -sf "$real" "$JQ_PATH/$(basename "$cmd")"
  fi
done

out3="$(COO_MEMORY_DIR="$FULL_REPO" PATH="$JQ_PATH" bash "$DIGEST_SRC" 2>&1 || true)"

assert_contains "$out3" "Latest memos unavailable" \
  "memos gap fires when jq absent"
assert_contains "$out3" "jq not on PATH" \
  "memos gap names jq-specific cause"
assert_not_contains "$out3" "memo_index.json not found" \
  "jq-missing case does NOT report file-missing"

# ──────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────

echo ""
echo "test-digest-gap-warnings: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
