#!/usr/bin/env bash
# Post or update a sticky CI PR comment.
#
# Identifies the prior comment by a magic header marker (default
# "<!-- bootstrap-regression-comment -->") emitted by the summary
# renderer so re-runs replace the previous comment instead of
# stacking duplicates.
#
# Required env (set by the workflow step):
#   GH_TOKEN         — token with issues:write
#   PR               — pull request number
#   REPO             — owner/name
# Optional env:
#   VADE_CI_SUMMARY_OUT     — path to the rendered markdown summary
#                             (default /tmp/bootstrap-regression-summary.md)
#   VADE_CI_COMMENT_HEADER  — override the marker for non-Layer-1
#                             comment streams (e.g. Layer-2 harness
#                             uses '<!-- layer2-harness-comment -->').
#                             Must match the marker the summary file's
#                             first line emits, or this script will
#                             post a new comment instead of updating.
set -euo pipefail

SUMMARY="${VADE_CI_SUMMARY_OUT:-/tmp/bootstrap-regression-summary.md}"
HEADER="${VADE_CI_COMMENT_HEADER:-<!-- bootstrap-regression-comment -->}"
TAG="${VADE_CI_LOG_TAG:-ci-pr-comment}"

if [ ! -f "$SUMMARY" ]; then
  echo "[$TAG] summary file missing at $SUMMARY; nothing to post" >&2
  exit 0
fi
if [ -z "${PR:-}" ] || [ -z "${REPO:-}" ]; then
  echo "[$TAG] PR or REPO unset; skipping comment" >&2
  exit 0
fi

EXISTING_ID="$(
  gh api "/repos/$REPO/issues/$PR/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"$HEADER\")) | .id" \
    2>/dev/null | head -1 || true
)"

PAYLOAD="$(mktemp)"
trap 'rm -f "$PAYLOAD"' EXIT
jq -n --rawfile body "$SUMMARY" '{body: $body}' > "$PAYLOAD"

if [ -n "$EXISTING_ID" ]; then
  echo "[$TAG] updating existing comment $EXISTING_ID"
  gh api --method PATCH "/repos/$REPO/issues/comments/$EXISTING_ID" \
    --input "$PAYLOAD" >/dev/null
else
  echo "[$TAG] posting new comment on PR #$PR"
  gh api --method POST "/repos/$REPO/issues/$PR/comments" \
    --input "$PAYLOAD" >/dev/null
fi
