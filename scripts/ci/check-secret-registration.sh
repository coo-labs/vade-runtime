#!/usr/bin/env bash
# Enforces the **Secret Registration Rule**:
#
# Every secret env var exported inside `fetch_coo_secrets`
# (scripts/lib/common.sh) MUST have a matching entry in
# scripts/lib/transcript-redaction.json with `secret_var` == the var
# name. This rule is the linchpin of the redaction pipeline's
# future-proofing posture: when a new MCP / integration adds a secret,
# CI fails until a redaction pattern is registered alongside it.
#
# Origin: coo-labs/coo-logs#64 security review §3.
#
# Exits 0 when the two sides agree, 1 with a diff on divergence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMON_SH="$RUNTIME_ROOT/scripts/lib/common.sh"
REDACT_JSON="$RUNTIME_ROOT/scripts/lib/transcript-redaction.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 2
fi

# Extract the body of fetch_coo_secrets. Use Python to slice between
# the `^fetch_coo_secrets()` line and the matching `^}` at column 0,
# so changes elsewhere in common.sh don't bleed in.
common_exports=$(
  python3 - <<PY
import re, sys
src = open("$COMMON_SH").read()
m = re.search(r"(?ms)^fetch_coo_secrets\s*\(\s*\)\s*\{(.*?)^\}\s*$", src)
if not m:
    print("ERROR: could not locate fetch_coo_secrets in $COMMON_SH", file=sys.stderr)
    sys.exit(2)
body = m.group(1)
seen = set()
# Match `export FOO=` or `export FOO="..."` or `export FOO FOO2=...`
for em in re.finditer(r"\bexport\s+([A-Z][A-Z0-9_]+)\b", body):
    seen.add(em.group(1))
# Filter out non-secret exports: derivatives like GITHUB_TOKEN that
# carry the same value as a registered secret should still be listed,
# but ones that aren't credential material can be excluded by name.
# Today there are no such exclusions; if a future export is non-secret
# (e.g. RUN_ID-style), add an annotation comment in common.sh and
# extend this filter. Conservative default: every exported var must
# be registered.
for v in sorted(seen):
    print(v)
PY
)

# Extract registered secret_vars from JSON. Skip null entries (those
# are patterns for shapes that aren't tied to a coo-env secret).
# secret_var may be a string OR an array of aliases (e.g. GITHUB_MCP_PAT
# and GITHUB_TOKEN both carry the same fine-grained-PAT shape).
registered_vars=$(jq -r '
  .patterns[] | select(.secret_var != null) |
  (if (.secret_var | type) == "array" then .secret_var[] else .secret_var end)
' "$REDACT_JSON" | sort -u)

unregistered=$(comm -23 <(printf '%s\n' "$common_exports" | sort -u) <(printf '%s\n' "$registered_vars"))
orphaned=$(comm -13   <(printf '%s\n' "$common_exports" | sort -u) <(printf '%s\n' "$registered_vars"))

fail=0
if [ -n "$unregistered" ]; then
  echo "FAIL: secrets exported by fetch_coo_secrets but with no transcript-redaction.json pattern:"
  while IFS= read -r v; do echo "       - $v"; done <<< "$unregistered"
  echo
  echo "Action: add a pattern entry to scripts/lib/transcript-redaction.json"
  echo "with \"secret_var\": \"<NAME>\" matching each line above. The Secret"
  echo "Registration Rule (coo-labs/coo-logs#64) requires this."
  fail=1
fi
if [ -n "$orphaned" ]; then
  echo "WARN: transcript-redaction.json registers secret_var that is no longer"
  echo "      exported by fetch_coo_secrets:"
  while IFS= read -r v; do echo "       - $v"; done <<< "$orphaned"
  echo
  echo "Action: either (a) the secret was retired and the pattern entry's"
  echo "secret_var should be set to null (keep the pattern in case the shape"
  echo "still appears in transcripts from third-party tool output), or"
  echo "(b) the pattern entry should be removed."
  # Orphaned entries are a warning, not an error. Stale patterns don't
  # leak secrets — they just clutter the table.
fi

if [ "$fail" -eq 0 ] && [ -z "$orphaned" ]; then
  echo "secret-registration parity OK: $(echo "$common_exports" | wc -l | tr -d ' ') exports, all registered"
fi

exit "$fail"
