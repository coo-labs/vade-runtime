#!/usr/bin/env bash
# Sync .github/ISSUE_TEMPLATE/ from this repo (coo-labs/coo-harness, canonical)
# to all active non-meta consumer repos in coo-labs/, opening a labeled PR per
# consumer.
#
# Canonical: coo-memory#938 (F8). Replaces BetaHuhn/repo-file-sync-action
# after the action's Node 20 deprecation (coo-harness#321). Mechanism rationale:
# coo-memory/operations/template-centralization.md.
#
# Consumer list source: coo-labs/.github/repos.yaml (the F17 canonical
# registry). Same selector as the F17b drift-check this script obsoletes:
# active && tier != meta && name != coo-harness.
#
# Usage:
#   GH_TOKEN=<pat> bash scripts/sync-templates-to-consumers.sh
#   GH_TOKEN=<pat> bash scripts/sync-templates-to-consumers.sh --dry-run
#   GH_TOKEN=<pat> bash scripts/sync-templates-to-consumers.sh --repo coo-labs/coo-console
#
# Required: GH_TOKEN with contents:write + pull-requests:write on every
# coo-labs/* repo (the VADE_FIELDS_ADMIN_PAT in CI).

set -euo pipefail

DRY_RUN=0
ONLY_REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --repo)    ONLY_REPO="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${GH_TOKEN:?GH_TOKEN must be set (contents:write + pull-requests:write on coo-labs/*)}"

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
SRC_TEMPLATES="$REPO_ROOT/.github/ISSUE_TEMPLATE"
SYNC_BRANCH="sync/issue-templates"
PR_TITLE="sync(templates): auto-sync from canonical"
PR_LABELS="sync,sync:templates"

PR_BODY="$(cat <<'EOF'
Auto-synced from `coo-labs/coo-harness` canonical issue templates (F8).

**Edit the canonical**, not this PR: [`coo-harness/.github/ISSUE_TEMPLATE/`](https://github.com/coo-labs/coo-harness/tree/main/.github/ISSUE_TEMPLATE). Changes there auto-propagate here on next push to `main`.

- Canonical issue: [coo-memory#938](https://github.com/coo-labs/coo-memory/issues/938)
- Operations doc: [`operations/template-centralization.md`](https://github.com/coo-labs/coo-memory/blob/main/operations/template-centralization.md)
- Sync mechanism: [`coo-harness/scripts/sync-templates-to-consumers.sh`](https://github.com/coo-labs/coo-harness/blob/main/scripts/sync-templates-to-consumers.sh)

Orphan deletion is in effect — files deleted from the canonical are deleted here too.
EOF
)"

if [ -n "$ONLY_REPO" ]; then
  CONSUMERS="$ONLY_REPO"
else
  CONSUMERS="$(gh api repos/coo-labs/.github/contents/repos.yaml --jq '.content | @base64d' \
    | yq -r '.repos[] | select(.status == "active" and .tier != "meta" and .name != "coo-harness") | "coo-labs/" + .name')"
fi

failures=()
synced=()
skipped=()

for repo in $CONSUMERS; do
  [ -z "$repo" ] && continue
  echo "::group::$repo"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  if ! git clone --quiet --depth=1 "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git" "$tmpdir" 2>&1; then
    echo "::error::clone failed for $repo"
    failures+=("$repo")
    rm -rf "$tmpdir"
    echo "::endgroup::"
    continue
  fi

  rm -rf "$tmpdir/.github/ISSUE_TEMPLATE"
  mkdir -p "$tmpdir/.github"
  cp -a "$SRC_TEMPLATES" "$tmpdir/.github/ISSUE_TEMPLATE"

  cd "$tmpdir"
  git -c user.email='vade-coo@users.noreply.github.com' \
      -c user.name='vade-coo' \
      add .github/ISSUE_TEMPLATE

  if git diff --cached --quiet; then
    echo "no diff — $repo already in sync"
    skipped+=("$repo")
    cd "$REPO_ROOT"
    rm -rf "$tmpdir"
    echo "::endgroup::"
    continue
  fi

  git diff --cached --stat

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would push and open/update PR on $repo"
    synced+=("$repo (dry-run)")
    cd "$REPO_ROOT"
    rm -rf "$tmpdir"
    echo "::endgroup::"
    continue
  fi

  git -c user.email='vade-coo@users.noreply.github.com' \
      -c user.name='vade-coo' \
      commit -m "sync(templates): auto-sync from canonical"
  git checkout -B "$SYNC_BRANCH"
  if ! git push --force-with-lease origin "$SYNC_BRANCH" 2>&1; then
    echo "::error::push failed for $repo"
    failures+=("$repo")
    cd "$REPO_ROOT"
    rm -rf "$tmpdir"
    echo "::endgroup::"
    continue
  fi

  existing_pr="$(gh pr list -R "$repo" --head "$SYNC_BRANCH" --state open --json number --jq '.[0].number // empty')"
  if [ -n "$existing_pr" ]; then
    echo "PR #$existing_pr already open on $repo — force-push updated it"
  else
    if ! gh pr create -R "$repo" \
         --title "$PR_TITLE" \
         --body "$PR_BODY" \
         --label "$PR_LABELS" \
         --base main --head "$SYNC_BRANCH" 2>&1; then
      echo "::error::PR create failed for $repo"
      failures+=("$repo")
      cd "$REPO_ROOT"
      rm -rf "$tmpdir"
      echo "::endgroup::"
      continue
    fi
  fi

  synced+=("$repo")
  cd "$REPO_ROOT"
  rm -rf "$tmpdir"
  echo "::endgroup::"
done

echo ""
echo "=== summary ==="
echo "synced:   ${#synced[@]} (${synced[*]:-none})"
echo "skipped:  ${#skipped[@]} (${skipped[*]:-none})"
echo "failed:   ${#failures[@]} (${failures[*]:-none})"

[ "${#failures[@]}" -eq 0 ]
