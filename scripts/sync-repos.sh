#!/usr/bin/env bash
# Sync all coo-labs repos in this folder with their GitHub origin.
# Auto-handles the safe cases; reports anything that needs a human.

# a symlink to this file should be made from coo-labs-workspace/sync-repos.sh

set -u

ROOT="${DEV_DIR}/coo-labs"

REPOS=(coo4one coo-logs coo-memory vade-canvas coo-harness site tjsonl skills coo-console)

echo $ROOT

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

ok()    { printf "  %s✓%s %s\n" "$GREEN"  "$RESET" "$1"; }
warn()  { printf "  %s!%s %s\n" "$YELLOW" "$RESET" "$1"; }
fail()  { printf "  %s✗%s %s\n" "$RED"    "$RESET" "$1"; }

declare -a SKIPPED=()
declare -a FAILED=()

for name in "${REPOS[@]}"; do
  dir="$ROOT/$name"
  printf "\n%s== %s ==%s\n" "$BOLD" "$name" "$RESET"

  if [ ! -d "$dir/.git" ]; then
    fail "not a git repo"
    FAILED+=("$name: not a git repo")
    continue
  fi

  cd "$dir" || { fail "cannot cd"; FAILED+=("$name: cd failed"); continue; }

  # Dirty working tree → skip (don't want to stash/commit silently).
  if [ -n "$(git status --porcelain)" ]; then
    warn "dirty working tree — skipping"
    git status --short | sed 's/^/    /'
    SKIPPED+=("$name: dirty working tree")
    continue
  fi

  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
  if [ -z "$branch" ]; then
    warn "detached HEAD — skipping"
    SKIPPED+=("$name: detached HEAD")
    continue
  fi

  # Fetch.
  if ! git fetch --prune origin >/dev/null 2>&1; then
    fail "fetch failed (auth/network?)"
    FAILED+=("$name: fetch failed")
    continue
  fi
  ok "fetched origin"

  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || upstream=""
  if [ -z "$upstream" ]; then
    warn "branch '$branch' has no upstream — skipping pull/push"
    SKIPPED+=("$name: no upstream for $branch")
    continue
  fi

  local_sha="$(git rev-parse @)"
  remote_sha="$(git rev-parse '@{u}')"
  base_sha="$(git merge-base @ '@{u}')"

  if [ "$local_sha" = "$remote_sha" ]; then
    ok "up to date with $upstream"
    continue
  fi

  if [ "$local_sha" = "$base_sha" ]; then
    # Behind only → fast-forward pull.
    if git merge --ff-only '@{u}' >/dev/null 2>&1; then
      ok "fast-forwarded from $upstream"
    else
      fail "ff pull failed"
      FAILED+=("$name: ff pull failed")
    fi
    continue
  fi

  if [ "$remote_sha" = "$base_sha" ]; then
    ahead="$(git rev-list --count '@{u}..@')"
    # Don't auto-push protected branches — they should go through PR review.
    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
      warn "ahead of $upstream by $ahead — not auto-pushing $branch (open a PR instead)"
      SKIPPED+=("$name: $ahead unpushed commit(s) on $branch")
      continue
    fi
    if out="$(git push origin "$branch" 2>&1)"; then
      ok "pushed $branch to origin ($ahead commit(s))"
    else
      fail "push failed: $(echo "$out" | head -1)"
      FAILED+=("$name: push failed")
    fi
    continue
  fi

  # Diverged → won't auto-resolve.
  ahead="$(git rev-list --count '@{u}..@')"
  behind="$(git rev-list --count '@..@{u}')"
  warn "diverged ($ahead ahead, $behind behind) — skipping, resolve manually"
  SKIPPED+=("$name: diverged $ahead/$behind")
done

printf "\n%s== summary ==%s\n" "$BOLD" "$RESET"
if [ ${#SKIPPED[@]} -eq 0 ] && [ ${#FAILED[@]} -eq 0 ]; then
  ok "all repos synced cleanly"
  exit 0
fi
for line in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do warn "$line"; done
for line in "${FAILED[@]+"${FAILED[@]}"}"; do fail "$line"; done
[ ${#FAILED[@]} -eq 0 ] || exit 1
