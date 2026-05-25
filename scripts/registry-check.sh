#!/usr/bin/env bash
# registry-check: assert coo-labs/.github/repos.yaml matches live org state.
#
# Reads the canonical registry and the live `gh api orgs/coo-labs/repos`
# output; fails non-zero on any drift in:
#   - membership (repo in one list, missing from the other)
#   - visibility (public/private)
#   - status (registry.status vs live.archived)
#
# Designed for two invocation contexts:
#   - PR check in coo-labs/.github when repos.yaml changes
#   - Nightly schedule (catches drift introduced via the GitHub UI)
#
# Source: coo-memory#999 (F17b drift-check, load-bearing — without this the
# registry becomes a quieter drift problem than the literals it replaced).
#
# Portability: uses only `yq -r` with `+`-concat filter syntax; works on
# both mikefarah yq v4 (GitHub-hosted runners) and kislyuk yq (Python
# wrapper used in dev containers). Same compatibility surface as
# coo-memory/bin/configure-memo-autolinks.sh.
#
# Usage:
#   bash scripts/registry-check.sh           # exits 0 on clean, 1 on drift
#   bash scripts/registry-check.sh --quiet   # output only on drift

set -euo pipefail

OWNER="coo-labs"
QUIET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet)   QUIET=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "registry-check: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

: "${GH_TOKEN:=${GITHUB_MCP_PAT:-}}"
if [ -z "$GH_TOKEN" ]; then
  echo "registry-check: GH_TOKEN / GITHUB_MCP_PAT not set; cannot authenticate." >&2
  exit 2
fi
export GH_TOKEN

for tool in gh yq jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "registry-check: $tool not on PATH." >&2
    exit 2
  fi
done

# --- Fetch registry --------------------------------------------------------
registry_yaml="$(gh api "repos/$OWNER/.github/contents/repos.yaml" --jq '.content | @base64d')"
if [ -z "$registry_yaml" ]; then
  echo "registry-check: empty registry response from $OWNER/.github/repos.yaml" >&2
  exit 2
fi

# Tab-separated lines: name<TAB>visibility<TAB>status
registry_lines="$(yq -r '.repos[] | .name + "\t" + .visibility + "\t" + .status' <<<"$registry_yaml" | sort)"

# --- Fetch live list -------------------------------------------------------
# `gh api orgs/<org>/repos?type=all` includes archived repos when authenticated.
# coo-labs has ~12 repos; --paginate is cheap insurance against future growth.
live_lines="$(gh api "orgs/$OWNER/repos?type=all&per_page=100" --paginate \
  | jq -r '.[] | .name + "\t" + .visibility + "\t" + (if .archived then "archived" else "active" end)' \
  | sort)"

# --- Diff ------------------------------------------------------------------
registry_names="$(echo "$registry_lines" | cut -f1)"
live_names="$(echo "$live_lines" | cut -f1)"

only_registry="$(comm -23 <(echo "$registry_names") <(echo "$live_names"))"
only_live="$(comm -13 <(echo "$registry_names") <(echo "$live_names"))"

drift=0
report=()

if [ -n "$only_registry" ]; then
  drift=1
  report+=("Registry has repos not present in live org:")
  while IFS= read -r r; do report+=("  - $r"); done <<<"$only_registry"
fi

if [ -n "$only_live" ]; then
  drift=1
  report+=("Live org has repos not in registry:")
  while IFS= read -r r; do report+=("  - $r"); done <<<"$only_live"
fi

common="$(comm -12 <(echo "$registry_names") <(echo "$live_names"))"
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  reg_line="$(echo "$registry_lines" | awk -v r="$repo" -F'\t' '$1==r')"
  liv_line="$(echo "$live_lines"     | awk -v r="$repo" -F'\t' '$1==r')"
  if [ "$reg_line" != "$liv_line" ]; then
    drift=1
    reg_rest="$(echo "$reg_line" | cut -f2-)"
    liv_rest="$(echo "$liv_line" | cut -f2-)"
    report+=("$repo: drift — registry=[$reg_rest] live=[$liv_rest]")
  fi
done <<<"$common"

if [ "$drift" -eq 0 ]; then
  if [ "$QUIET" -eq 0 ]; then
    count="$(echo "$registry_names" | wc -l | tr -d ' ')"
    echo "registry-check: clean ($count repos match)"
  fi
  exit 0
fi

echo "registry-check: drift detected between $OWNER/.github/repos.yaml and live org state" >&2
for line in "${report[@]}"; do
  echo "$line" >&2
done
exit 1
