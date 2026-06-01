#!/usr/bin/env bash
# Post the bootstrap-regression PR comment ONLY when the suite fails;
# delete any prior failure-comment when the suite passes.
#
# Behavior matrix:
#   pass + no prior comment   → silent, no PR write (no context bloat for
#                                downstream agent sessions reading the PR).
#   pass + prior fail-comment → delete the stale comment (auto-cleanup
#                                after a fix lands).
#   fail + no prior comment   → post new fail-comment.
#   fail + prior comment      → update existing comment in place.
#
# Identifies prior comments by a magic header marker
# ("<!-- bootstrap-regression-comment -->") emitted by
# render-integrity-summary.sh so re-runs don't stack duplicates.
#
# Required env (set by the workflow step):
#   GH_TOKEN  — token with issues:write
#   PR        — pull request number
#   REPO      — owner/name
# Optional env:
#   VADE_CI_SUMMARY_OUT  — path to the rendered markdown summary
#                          (default /tmp/bootstrap-regression-summary.md)
#   VADE_CI_RESULT_OUT   — path to the structured result.json
#                          (default /tmp/bootstrap-regression-result.json,
#                          mirrors run-bootstrap-regression.sh's default)
set -euo pipefail

SUMMARY="${VADE_CI_SUMMARY_OUT:-/tmp/bootstrap-regression-summary.md}"
RESULT="${VADE_CI_RESULT_OUT:-/tmp/bootstrap-regression-result.json}"
HEADER='<!-- bootstrap-regression-comment -->'

if [ -z "${PR:-}" ] || [ -z "${REPO:-}" ]; then
  echo "[ci-bootstrap-regression] PR or REPO unset; skipping comment" >&2
  exit 0
fi

# Determine pass/fail from result.json. If result.json is missing
# (unexpected — would mean the suite aborted before the result step),
# default to "fail" so the operator gets a comment instead of silence.
OK="false"
if [ -f "$RESULT" ]; then
  OK="$(jq -r '.ok // false' "$RESULT")"
fi

EXISTING_ID="$(
  gh api "/repos/$REPO/issues/$PR/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"$HEADER\")) | .id" \
    2>/dev/null | head -1 || true
)"

if [ "$OK" = "true" ]; then
  if [ -n "$EXISTING_ID" ]; then
    echo "[ci-bootstrap-regression] pass: deleting stale fail-comment $EXISTING_ID"
    gh api --method DELETE "/repos/$REPO/issues/comments/$EXISTING_ID" >/dev/null
  else
    echo "[ci-bootstrap-regression] pass: no prior comment, nothing to post"
  fi
  exit 0
fi

# Fail path — post or update the sticky comment.
if [ ! -f "$SUMMARY" ]; then
  echo "[ci-bootstrap-regression] FAIL but summary file missing at $SUMMARY; cannot post" >&2
  exit 0
fi

PAYLOAD="$(mktemp)"
trap 'rm -f "$PAYLOAD"' EXIT
jq -n --rawfile body "$SUMMARY" '{body: $body}' > "$PAYLOAD"

if [ -n "$EXISTING_ID" ]; then
  echo "[ci-bootstrap-regression] fail: updating existing fail-comment $EXISTING_ID"
  gh api --method PATCH "/repos/$REPO/issues/comments/$EXISTING_ID" \
    --input "$PAYLOAD" >/dev/null
else
  echo "[ci-bootstrap-regression] fail: posting new fail-comment on PR #$PR"
  gh api --method POST "/repos/$REPO/issues/$PR/comments" \
    --input "$PAYLOAD" >/dev/null
fi
