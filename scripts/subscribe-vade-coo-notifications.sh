#!/usr/bin/env bash
# subscribe-vade-coo-notifications: poll GitHub's notifications API for the
# vade-coo user; emit one stdout line per new participating notification.
#
# Closes vade-coo-memory#841: a session-side push-shaped primitive for
# @vade-coo mentions across all repos, without depending on a session-spawn
# (coo-on-assign workflow) or a per-issue subscription. Cloud sessions can't
# be pushed to; this is the cleanest pull-as-push the cloud product permits.
#
# Suitable for the `Monitor` tool: each printed line is one event
# notification, flushed.
#
# Usage:
#   subscribe-vade-coo-notifications.sh [poll_seconds]
#
# Defaults: poll every 60s.
#
# State: single global "seen" file under
# ${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}/notifications-watch/
# records IDs of notifications already emitted, so restarts don't re-emit
# history. First run records the current state silently (no events emitted)
# and only future activity surfaces.
#
# Scope: queries `notifications?participating=true&all=false`. That filter
# is server-side and returns only notifications where the user is directly
# participating or mentioned — exactly the surface we want. Notifications
# from passive repo-watch don't fire. The script does not mark notifications
# as read on GitHub (that's Ven's UI's responsibility); the local seen-list
# is the only state.
#
# Authentication: relies on GITHUB_MCP_PAT (the vade-coo PAT) being set.
# GH_TOKEN fallback for non-COO contexts.
#
# Exit codes:
#   0  graceful shutdown (SIGINT/SIGTERM)
#   1  missing GitHub token
#   2  argument error

set -eu

usage() {
  cat <<'EOF'
Usage: subscribe-vade-coo-notifications.sh [poll_seconds]

Poll the vade-coo user's GitHub notifications feed; emit one stdout line
per new participating notification (mention, assign, review_requested,
comment, etc.), suitable for `Monitor` tail-streaming.

Arguments:
  [poll_seconds]   Polling interval, default 60

Environment:
  GITHUB_MCP_PAT        vade-coo PAT (preferred — the notifications feed is
                        the COO's own)
  GH_TOKEN              Fallback if MCP PAT unset
  VADE_CLOUD_STATE_DIR  State directory root (defaults to ~/.vade-cloud-state)

Examples:
  subscribe-vade-coo-notifications.sh
  subscribe-vade-coo-notifications.sh 30
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

poll="${1:-60}"

if ! [[ "$poll" =~ ^[0-9]+$ ]]; then
  echo "error: poll_seconds must be a positive integer (got: $poll)" >&2
  exit 2
fi

token="${GITHUB_MCP_PAT:-${GH_TOKEN:-}}"
if [ -z "$token" ]; then
  echo "error: GITHUB_MCP_PAT or GH_TOKEN must be set" >&2
  exit 1
fi

state_root="${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}"
state_dir="$state_root/notifications-watch"
mkdir -p "$state_dir"
state_file="$state_dir/seen.list"
touch "$state_file"

trap 'echo "[notifications-watch] shutdown" >&2; exit 0' INT TERM

echo "[notifications-watch] subscribed: vade-coo participating notifications (poll ${poll}s)" >&2

poll_attempt=0
while true; do
  poll_attempt=$((poll_attempt + 1))
  if ! resp=$(GH_TOKEN="$token" gh api \
      'notifications?all=false&participating=true&per_page=50' \
      2>/tmp/notif-stderr.$$); then
    err=$(cat /tmp/notif-stderr.$$ 2>/dev/null || echo "")
    rm -f /tmp/notif-stderr.$$
    if echo "$err" | grep -q 'Resource not accessible by personal access token'; then
      echo "[notifications-watch] FATAL: PAT lacks notifications:read scope." >&2
      echo "[notifications-watch] The GITHUB_MCP_PAT (vade-coo fine-grained PAT) needs" >&2
      echo "[notifications-watch] the 'Notifications' (read) user-level permission added." >&2
      echo "[notifications-watch] Rotate at: https://github.com/settings/personal-access-tokens" >&2
      echo "[notifications-watch] Update: op://COO/vade-coo-self-2026-04" >&2
      exit 1
    fi
    echo "[notifications-watch] poll failed (attempt ${poll_attempt}); retrying in ${poll}s: $err" >&2
    rm -f /tmp/notif-stderr.$$
    sleep "$poll"
    continue
  fi
  rm -f /tmp/notif-stderr.$$

  STATE_FILE="$state_file" python3 - "$resp" <<'PY'
import json, os, sys

try:
    items = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

if not isinstance(items, list):
    sys.exit(0)

state_file = os.environ['STATE_FILE']

with open(state_file, 'r') as f:
    seen = {line.strip() for line in f if line.strip()}

first_run = not seen
new_ids = []

def emit(n):
    nid = n.get('id') or ''
    reason = n.get('reason') or '<unknown>'
    repo = (n.get('repository') or {}).get('full_name') or '<unknown>'
    subject = n.get('subject') or {}
    title = (subject.get('title') or '').replace('\n', ' ').strip()
    if len(title) > 120:
        title = title[:117] + '...'
    stype = subject.get('type') or ''
    url = subject.get('latest_comment_url') or subject.get('url') or ''
    updated = n.get('updated_at') or ''

    # Translate the API url back to the human-readable html_url for
    # convenience: api.github.com/repos/X/Y/issues/N/comments/Z →
    # github.com/X/Y/issues/N#issuecomment-Z. Best-effort; if it doesn't
    # match the expected shape, emit the API URL unchanged.
    html_url = url
    if 'api.github.com/repos/' in url:
        rest = url.split('api.github.com/repos/', 1)[1]
        if '/issues/comments/' in rest:
            # PR review comment shape: repos/X/Y/issues/comments/Z
            # Subject URL still points at the issue/PR; this is just the
            # API URL of the comment. Use the issue URL from subject.url.
            issue_api = subject.get('url') or ''
            if 'api.github.com/repos/' in issue_api:
                issue_path = issue_api.split('api.github.com/repos/', 1)[1]
                comment_id = rest.rsplit('/', 1)[-1]
                html_url = f'https://github.com/{issue_path}#issuecomment-{comment_id}'
        elif '/issues/' in rest and '/comments/' in rest:
            # repos/X/Y/issues/N/comments/Z
            parts = rest.split('/comments/')
            issue_path = parts[0]
            comment_id = parts[1]
            html_url = f'https://github.com/{issue_path.replace("/issues/", "/issues/")}#issuecomment-{comment_id}'
        elif '/pulls/' in rest:
            html_url = f'https://github.com/{rest.replace("/pulls/", "/pull/", 1)}'
        elif '/issues/' in rest:
            html_url = f'https://github.com/{rest}'

    print(f'[notification:{reason}] {repo} {stype}: {title} @ {updated}', flush=True)
    print(f'  {html_url}', flush=True)

for n in items:
    nid = n.get('id')
    if not nid:
        continue
    if nid not in seen:
        new_ids.append(nid)
        if not first_run:
            emit(n)

if new_ids:
    with open(state_file, 'a') as f:
        for nid in new_ids:
            f.write(str(nid) + '\n')

if first_run and new_ids:
    print(f'[notifications-watch] initial state recorded: {len(new_ids)} existing items', file=sys.stderr, flush=True)
PY

  sleep "$poll"
done
