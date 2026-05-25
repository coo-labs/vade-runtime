#!/usr/bin/env bash
# issue-comments: bounded fetch of an issue's comment thread.
#
# Substitute for `mcp__github__issue_read method=get_comments`, which
# is unbounded — coo-labs/coo-logs#64 returns ~30 KB on a
# single read across multiple analyst groups in the
# 2026-04-28 transcript-bloat-audit. Substrate fix: coo-harness#153
# (Tier 1 close-out of coo-memory#258).
#
# Default behavior is a compact projection of the form
#
#   ## comment N (login, ISO-date) [+R reactions]
#   <first 120 chars of body, single-line>...
#   <repo>#<n> comment <id>
#
# repeated up to a soft byte ceiling (default 10240 bytes). Output
# closes with a footer that reports truncation:
#
#   # truncated to K of M comments — pass --full to retrieve all
#
# When --full is passed, the entire raw thread is dumped (no
# projection, no ceiling) — caller is asserting they need it.
#
# Usage:
#   bash scripts/issue-comments.sh <owner/repo> <issue-number>
#   bash scripts/issue-comments.sh <owner/repo> <issue-number> --full
#   bash scripts/issue-comments.sh <owner/repo> <issue-number> --limit 5
#   bash scripts/issue-comments.sh <owner/repo> <issue-number> --since 2026-04-20
#
# Authentication: relies on GH_TOKEN being set by the caller (the
# canonical pattern is `GH_TOKEN="$GITHUB_MCP_PAT"`).
#
# Exit codes:
#   0  success
#   2  argument error
#   *  upstream gh / jq failure (propagated)

set -eu

usage() {
  cat <<'EOF'
Usage: issue-comments.sh <owner/repo> <issue-number> [options]

Bounded fetch of an issue comment thread; default-truncates to a soft
10 KB ceiling with a compact projection.

Options:
  --full              Return the full raw thread (no projection, no ceiling).
  --limit N           Cap the number of comments to N (most recent).
  --since ISO8601     Only return comments since this date (RFC 3339).
  --max-bytes N       Override the default 10240-byte soft ceiling.
  --body-chars N      Per-comment body excerpt length (default 120).
  -h, --help          Print this message.

Examples:
  issue-comments.sh coo-labs/coo-logs 64
  issue-comments.sh coo-labs/coo-logs 64 --full
  issue-comments.sh coo-labs/coo-logs 64 --limit 3
EOF
}

REPO=""
NUM=""
FULL=0
LIMIT=""
SINCE=""
MAX_BYTES=10240
BODY_CHARS=120

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)        usage; exit 0 ;;
    --full)           FULL=1; shift ;;
    --limit)          LIMIT="$2"; shift 2 ;;
    --since)          SINCE="$2"; shift 2 ;;
    --max-bytes)      MAX_BYTES="$2"; shift 2 ;;
    --body-chars)     BODY_CHARS="$2"; shift 2 ;;
    --)               shift; break ;;
    -*)               echo "issue-comments: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -z "$REPO" ]; then REPO="$1"
      elif [ -z "$NUM" ]; then NUM="$1"
      else echo "issue-comments: unexpected positional: $1" >&2; exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$NUM" ]; then
  usage >&2
  exit 2
fi

case "$REPO" in
  */*) ;;
  *) echo "issue-comments: <owner/repo> must contain a slash, got: $REPO" >&2; exit 2 ;;
esac
case "$NUM" in
  ''|*[!0-9]*) echo "issue-comments: <issue-number> must be numeric, got: $NUM" >&2; exit 2 ;;
esac

GH="${COO_GH_REAL:-gh}"
command -v "$GH" >/dev/null 2>&1 || { echo "issue-comments: $GH not found on PATH" >&2; exit 2; }

API_PATH="repos/${REPO}/issues/${NUM}/comments?per_page=100"
if [ -n "$SINCE" ]; then
  API_PATH="${API_PATH}&since=${SINCE}"
fi

# Fetch raw JSON array. --paginate concatenates pages into a single
# array via gh's built-in handling.
RAW="$("$GH" api "$API_PATH" --paginate)"

if [ "$FULL" -eq 1 ]; then
  printf '%s\n' "$RAW"
  exit 0
fi

# Apply LIMIT (most recent N) post-fetch. The jq filter:
#   * trims body to BODY_CHARS, single-lines it (collapse newlines to
#     ' / '), strips trailing whitespace
#   * sums non-zero reactions
#   * emits one paragraph per comment (terminated by a blank line)
#   * emits a final '__META total=<n> shown=<m>' line
#
# Output is text, not JSON, because we're optimizing for byte-cost
# in a model context window.

LIMIT_EXPR=".[-${LIMIT}:]"
[ -z "$LIMIT" ] && LIMIT_EXPR="."

PROJECTION="$(printf '%s' "$RAW" | jq -r \
  --argjson body_chars "$BODY_CHARS" \
  --arg repo "$REPO" \
  --arg num "$NUM" "
  ${LIMIT_EXPR} as \$slice
  | length as \$total
  | (\$slice | length) as \$shown
  | (\$slice | to_entries[] |
      .key as \$i |
      .value as \$c |
      (\$c.reactions // {}) as \$r |
      (((\$r.\"+1\"//0) + (\$r.\"-1\"//0) + (\$r.laugh//0) + (\$r.confused//0)
        + (\$r.heart//0) + (\$r.hooray//0) + (\$r.rocket//0) + (\$r.eyes//0))) as \$rsum |
      (\$c.body // \"\" | gsub(\"\\\\r\"; \"\") | gsub(\"\\\\n+\"; \" / \") | gsub(\"  +\"; \" \") | .[0:\$body_chars]) as \$snippet |
      \"## comment \(\$i + 1) (\(\$c.user.login // \"?\"), \(\$c.created_at[0:10]))\(if \$rsum > 0 then \" [+\(\$rsum) reactions]\" else \"\" end)\\n\(\$snippet)\(if (\$c.body // \"\" | length) > \$body_chars then \"...\" else \"\" end)\\n\(\$repo)#\(\$num) comment \(\$c.id)\\n\"
    ),
    \"__META total=\(\$total) shown=\(\$shown)\"
")"

# Split off the trailer (last line is the META marker).
META="$(printf '%s' "$PROJECTION" | tail -n 1)"
# Body is everything except the final META line.
BODY="$(printf '%s\n' "$PROJECTION" | sed '$d')"
TOTAL="$(printf '%s' "$META" | sed -n 's/^__META total=\([0-9]*\) shown=.*$/\1/p')"
SHOWN_LIMIT="$(printf '%s' "$META" | sed -n 's/^__META total=[0-9]* shown=\([0-9]*\)$/\1/p')"
TOTAL="${TOTAL:-0}"
SHOWN_LIMIT="${SHOWN_LIMIT:-0}"

# Apply byte ceiling: walk projection paragraph-by-paragraph and stop
# when the cumulative size would exceed MAX_BYTES.
KEPT_FILE="$(mktemp)"
OUT="$(printf '%s' "$BODY" | awk -v max="$MAX_BYTES" -v keptfile="$KEPT_FILE" '
  BEGIN { RS = ""; buf = ""; total = 0; kept = 0 }
  {
    block = $0 "\n\n"
    if (total + length(block) > max && kept > 0) { exit }
    buf = buf block
    total += length(block)
    kept++
  }
  END {
    printf "%s", buf
    print kept > keptfile
  }
')"
KEPT="$(cat "$KEPT_FILE")"
rm -f "$KEPT_FILE"

printf '%s\n' "$OUT"

# Footer: report truncation if either the byte ceiling or the --limit
# dropped comments. Always emit something so the reader knows the
# default-truncate is in effect.
if [ "$KEPT" -lt "$SHOWN_LIMIT" ]; then
  printf '# truncated to %d of %d comments — pass --full to retrieve all\n' "$KEPT" "$TOTAL"
elif [ "$SHOWN_LIMIT" -lt "$TOTAL" ]; then
  printf '# limited to %d of %d comments (--limit) — pass --full to retrieve all\n' "$SHOWN_LIMIT" "$TOTAL"
else
  printf '# %d of %d comments shown (default projection — pass --full for raw bodies)\n' "$KEPT" "$TOTAL"
fi
