#!/usr/bin/env bash
# Migrate runtime-granted "always allow" permission decisions from
# .claude/settings.local.json (gitignored, ephemeral on cloud) into
# coo-harness/.claude/settings.json (version-controlled), then
# auto-commit + push on the current branch.
#
# Wired as a Stop hook so every turn-end checks for new permission
# decisions and persists them. Idempotent: when no new entries are
# present in local-not-in-shared, exits silently.
#
# Skips auto-commit on main/master (or detached HEAD); writes
# settings.json regardless and surfaces a notice. Append-only:
# does not remove from .local.json (ephemeral) and does not delete
# from shared.allow when local has the same pattern in deny — in
# practice the runtime prompt only writes to .allow, so the conflict
# case is theoretical.
#
# Flags:
#   --dry-run   compute and print delta; do not write, commit, or push.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

boot_log_record "persist-permissions" start dry_run="$DRY_RUN"
trap '_rc=$?; boot_log_record "persist-permissions" end $([ $_rc -eq 0 ] && echo ok || echo fail) rc=$_rc' EXIT

SHARED="$RUNTIME_ROOT/.claude/settings.json"
if [ ! -f "$SHARED" ]; then
  log_err "persist-permissions: no shared settings.json at $SHARED; skip"
  exit 0
fi

# Find local settings.local.json. CLAUDE_PROJECT_DIR is most reliable;
# fall back to $HOME-relative and the cloud /home/user fallback so the
# hook works regardless of which user the harness runs as.
LOCAL=""
for candidate in \
  "${CLAUDE_PROJECT_DIR:-}/.claude/settings.local.json" \
  "$HOME/.claude/settings.local.json" \
  "/root/.claude/settings.local.json" \
  "/home/user/.claude/settings.local.json"; do
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    LOCAL="$candidate"
    break
  fi
done

if [ -z "$LOCAL" ]; then
  exit 0
fi

# Compute deltas for allow / deny / ask. Missing keys → empty array.
delta=$(jq -n --slurpfile l "$LOCAL" --slurpfile s "$SHARED" '
  def arr(p): (($l[0] | getpath(p)) // []) - (($s[0] | getpath(p)) // []) | unique;
  {
    allow: arr(["permissions","allow"]),
    deny:  arr(["permissions","deny"]),
    ask:   arr(["permissions","ask"])
  }
')

new_count=$(jq -r '[.allow,.deny,.ask] | flatten | length' <<< "$delta")
if [ "$new_count" -eq 0 ]; then
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "[persist-permissions] would migrate $new_count entry/entries from $LOCAL → $SHARED:"
  jq . <<< "$delta"
  exit 0
fi

# Snapshot whether settings.json has prior uncommitted changes BEFORE
# we write. If yes, we'll still apply the migration (so the user's
# session benefits this turn), but skip auto-commit so we don't bundle
# our diff into their work-in-progress.
prior_diff=0
if ! git -C "$RUNTIME_ROOT" diff --quiet HEAD -- .claude/settings.json 2>/dev/null; then
  prior_diff=1
fi

# Apply delta to shared. Append at the end of each array (jq array
# concat preserves existing order; new entries land sorted-unique at
# the tail). Drop empty optional keys (.ask) so we don't write {} for
# permission types that were never used.
tmp=$(mktemp)
jq --argjson d "$delta" '
  .permissions.allow = ((.permissions.allow // []) + $d.allow) |
  .permissions.deny  = ((.permissions.deny  // []) + $d.deny) |
  (if ($d.ask | length) > 0
    then .permissions.ask = ((.permissions.ask // []) + $d.ask)
    else .
  end)
' "$SHARED" > "$tmp"

if ! jq -e '.permissions.allow | type == "array"' "$tmp" >/dev/null; then
  log_err "persist-permissions: sanity-check failed; refusing to overwrite $SHARED"
  rm -f "$tmp"
  exit 1
fi

mv "$tmp" "$SHARED"

# Auto-commit + push when branch is non-main and settings.json had no
# prior uncommitted changes. Always log what we did.
cd "$RUNTIME_ROOT"
branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -z "$branch" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  log "persist-permissions: wrote $new_count entry/entries to settings.json on branch '${branch:-detached}'; not auto-committing."
  exit 0
fi
if [ "$prior_diff" = "1" ]; then
  log "persist-permissions: pre-existing changes to settings.json; wrote $new_count entry/entries but skipping auto-commit (commit manually)."
  exit 0
fi

git add .claude/settings.json
if git diff --cached --quiet; then
  exit 0
fi

msg=$(printf 'settings.json: persist %d runtime-granted permission(s)\n\nMigrated from %s by persist-permissions Stop hook.' \
  "$new_count" "${LOCAL/$HOME/\$HOME}")
git commit -m "$msg" >/dev/null

# Push with retry per CLAUDE.md guidance (2s, 4s, 8s, 16s).
pushed=0
for delay in 0 2 4 8 16; do
  [ "$delay" -gt 0 ] && sleep "$delay"
  if git push -u origin "$branch" >/dev/null 2>&1; then
    pushed=1
    break
  fi
done

if [ "$pushed" = "1" ]; then
  log "persist-permissions: migrated $new_count entry/entries; committed + pushed to $branch."
else
  log_err "persist-permissions: migrated $new_count + committed locally; push failed after 4 retries (will retry next session)."
fi

exit 0
