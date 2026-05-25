#!/usr/bin/env bash
# subscribe-pr-mergeable: poll a GitHub PR's mergeable state; emit one
# stdout line per transition (MERGEABLE <-> CONFLICTING; final MERGED /
# CLOSED).
#
# Closes the gap that `mcp__github__subscribe_pr_activity` doesn't fill:
# GitHub does not emit a webhook event when `mergeable_state` transitions
# from clean to dirty (base-branch motion turns an open PR into a merge
# conflict), so the existing subscription can't surface it. This script
# polls instead. Sibling to subscribe-discussion.sh.
#
# Suitable for the `Monitor` tool: each printed line is one event
# notification, flushed. Exits 0 once the PR enters a terminal state
# (MERGED or CLOSED), since the subscription is naturally over.
#
# Usage:
#   subscribe-pr-mergeable.sh <owner/repo> <pr-number> [poll_seconds]
#
# Defaults: poll every 120s. `mergeable` lags base-branch pushes by
# ~30s; tighter polling mostly observes UNKNOWN transients.
#
# State: per-PR last-known state file under
# ${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}/pr-mergeable-watch/
# records the last-emitted mergeable value. First run records the
# current state silently (no event emitted) and only future
# transitions surface.
#
# UNKNOWN handling: `mergeable` reports UNKNOWN transiently while GitHub
# recomputes after a push. Transitions through UNKNOWN are not emitted;
# only transitions between concrete states (MERGEABLE <-> CONFLICTING)
# fire events. UNKNOWN is recorded internally so a subsequent
# concrete-value read can be compared against the last concrete state,
# not against UNKNOWN.
#
# Authentication: relies on GITHUB_MCP_PAT or GH_TOKEN being set.
#
# Exit codes:
#   0  graceful shutdown (SIGINT/SIGTERM) or terminal state (MERGED/CLOSED)
#   1  missing GitHub token
#   2  argument error

set -eu

usage() {
  cat <<'EOF'
Usage: subscribe-pr-mergeable.sh <owner/repo> <pr-number> [poll_seconds]

Poll a GitHub PR's mergeable state; emit one stdout line per
transition, suitable for `Monitor` tail-streaming.

Arguments:
  <owner/repo>     Target repository (e.g. coo-labs/coo-memory)
  <pr-number>      Pull request number
  [poll_seconds]   Polling interval, default 120

Environment:
  GITHUB_MCP_PAT        GitHub PAT (preferred)
  GH_TOKEN              Fallback if MCP PAT unset
  VADE_CLOUD_STATE_DIR  State directory root (defaults to ~/.vade-cloud-state)

Examples:
  subscribe-pr-mergeable.sh coo-labs/coo-memory 734
  subscribe-pr-mergeable.sh coo-labs/coo-harness 254 60
EOF
}

if [ $# -lt 2 ]; then
  usage >&2
  exit 2
fi

case "$1" in -h|--help) usage; exit 0 ;; esac

repo="$1"
number="$2"
poll="${3:-120}"

if ! [[ "$repo" == */* ]]; then
  echo "error: repo must be in <owner/name> form (got: $repo)" >&2
  exit 2
fi
if ! [[ "$number" =~ ^[0-9]+$ ]]; then
  echo "error: pr-number must be a positive integer (got: $number)" >&2
  exit 2
fi
if ! [[ "$poll" =~ ^[0-9]+$ ]]; then
  echo "error: poll_seconds must be a positive integer (got: $poll)" >&2
  exit 2
fi

owner="${repo%%/*}"
name="${repo##*/}"

token="${GITHUB_MCP_PAT:-${GH_TOKEN:-}}"
if [ -z "$token" ]; then
  echo "error: GITHUB_MCP_PAT or GH_TOKEN must be set" >&2
  exit 1
fi

state_root="${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}"
state_dir="$state_root/pr-mergeable-watch"
mkdir -p "$state_dir"
state_file="$state_dir/${owner}__${name}__${number}.state"

trap 'echo "[pr-mergeable-watch] shutdown ($repo#$number)" >&2; exit 0' INT TERM

last_concrete=""
if [ -f "$state_file" ]; then
  last_concrete="$(cat "$state_file" 2>/dev/null || true)"
fi
first_run=1
if [ -n "$last_concrete" ]; then
  first_run=0
fi

echo "[pr-mergeable-watch] subscribed: $repo#$number (poll ${poll}s)" >&2

while true; do
  if ! resp=$(GH_TOKEN="$token" gh pr view "$number" \
      --repo "$repo" \
      --json state,mergeable,mergeStateStatus 2>/dev/null); then
    echo "[pr-mergeable-watch] poll failed; retrying in ${poll}s" >&2
    sleep "$poll"
    continue
  fi

  state="$(printf '%s' "$resp"   | jq -r '.state // ""'             2>/dev/null || true)"
  merge="$(printf '%s' "$resp"   | jq -r '.mergeable // ""'         2>/dev/null || true)"
  status="$(printf '%s' "$resp"  | jq -r '.mergeStateStatus // ""'  2>/dev/null || true)"

  case "$state" in
    MERGED|CLOSED)
      echo "PR $repo#$number $state (final)"
      rm -f "$state_file"
      exit 0
      ;;
  esac

  case "$merge" in
    MERGEABLE|CONFLICTING)
      if [ "$first_run" = "1" ]; then
        printf '%s\n' "$merge" > "$state_file"
        echo "[pr-mergeable-watch] initial state: $merge (mergeStateStatus=$status)" >&2
        last_concrete="$merge"
        first_run=0
      elif [ "$merge" != "$last_concrete" ]; then
        echo "PR $repo#$number mergeable: $last_concrete → $merge (mergeStateStatus=$status)"
        printf '%s\n' "$merge" > "$state_file"
        last_concrete="$merge"
      fi
      ;;
    UNKNOWN|"")
      : # transient — don't emit, don't update last_concrete
      ;;
    *)
      echo "[pr-mergeable-watch] unexpected mergeable value: $merge" >&2
      ;;
  esac

  sleep "$poll"
done
