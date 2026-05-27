#!/usr/bin/env bash
# Print a compact boot digest of In Progress items on the VADE project
# board, grouped by Milestone.
#
# SessionStart hook; lands in the boot context as a system-reminder so
# the agent can read "what's in flight" without running the query itself.
# Replaces the "Boot recall" instruction that used to live in CLAUDE.md
# (coo-memory#813).
#
# Graceful no-op when GITHUB_TOKEN/GH_TOKEN is unset, when gh is missing,
# or when the API call fails. Never breaks session start.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

boot_log_record project-board-digest start
trap '_rc=$?; boot_log_record project-board-digest end $([ $_rc -eq 0 ] && echo ok || echo fail) rc=$_rc' EXIT

wait_for_coo_bootstrap 60

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-${GITHUB_MCP_PAT:-}}}"
if [ -z "$TOKEN" ]; then
  log "GH_TOKEN unset; skipping project-board digest."
  exit 0
fi

if ! check_cmd gh || ! check_cmd jq; then
  log "gh or jq missing; skipping project-board digest."
  exit 0
fi

# Project 1 currently holds ~370 items; --limit must exceed total or the
# fetch silently truncates. 1000 gives comfortable headroom.
RESPONSE="$(GH_TOKEN="$TOKEN" gh project item-list 1 --owner coo-labs \
  --format json --limit 1000 2>/dev/null || echo '')"

if [ -z "$RESPONSE" ]; then
  log "project item-list failed; skipping digest."
  exit 0
fi

# Echo the formatted block. jq does all the work — group by milestone,
# sort milestones alphabetically (with "(no milestone)" last), then
# emit one section per milestone.
printf '%s' "$RESPONSE" | jq -r '
  [.items[] | select(.status == "In Progress")] as $ip
  | if ($ip | length) == 0 then
      "Boot: VADE project — no items In Progress."
    else
      ($ip
        | group_by(.milestone.title // "~no-milestone")
        | sort_by(.[0].milestone.title // "~no-milestone")
      ) as $groups
      | (
          "Boot: VADE project — In Progress (\($ip | length) item\(if ($ip|length)==1 then "" else "s" end) across \($groups | length) milestone\(if ($groups|length)==1 then "" else "s" end)):"
        ),
        ($groups[] | (
          "  [\(.[0].milestone.title // "(no milestone)")]"
        ), (
          .[] | "    \(.repository | sub("https://github.com/coo-labs/"; ""))#\(.content.number) — \(.title)"
        )),
        "URL: github.com/orgs/coo-labs/projects/1 (filter status:\"In Progress\")"
    end
'
