#!/usr/bin/env bash
# check-pat-freshness: detect whether the in-process COO PAT
# (env GITHUB_MCP_PAT) is stale relative to the canonical value in
# 1Password (op://COO/vade-coo-self-2026-04/token).
#
# Use this as the FIRST response when a `gh` write fails silently:
# exit 1, zero bytes stdout, zero bytes stderr. That signature is the
# canonical fingerprint of a stale-PAT mid-session — see
# MEMO-2026-05-21-r9rt and vade-coo-memory#820.
#
# Output (single line) one of:
#   OK <sha8>                          — env matches 1Password
#   STALE env=<sha8> op=<sha8>         — env differs; rotate session
#   OP-UNREACHABLE <reason>            — could not read 1Password
#   ENV-MISSING                        — GITHUB_MCP_PAT not in env
#
# Exit codes: 0 OK, 1 STALE, 2 OP-UNREACHABLE, 3 ENV-MISSING.
#
# Recovery on STALE: refresh the env in this session via
#   eval "$(op signin --account ...)"  # if running locally, or
#   export GITHUB_MCP_PAT="$(op read op://COO/vade-coo-self-2026-04/token)"
# and re-run the failed gh write. In cloud, a fresh session inherits
# the rotated value at boot.
#
# Source: issue vade-coo-memory#820.

set -eu

env_pat="${GITHUB_MCP_PAT:-}"
if [ -z "$env_pat" ]; then
  printf 'ENV-MISSING\n'
  exit 3
fi

env_sha=$(printf '%s' "$env_pat" | sha256sum | cut -c1-8)

if ! command -v op >/dev/null 2>&1; then
  printf 'OP-UNREACHABLE op-cli-missing\n'
  exit 2
fi
if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  printf 'OP-UNREACHABLE op-service-account-token-unset\n'
  exit 2
fi

if ! op_pat=$(op read "op://COO/vade-coo-self-2026-04/token" 2>/dev/null); then
  printf 'OP-UNREACHABLE op-read-failed\n'
  exit 2
fi
if [ -z "$op_pat" ]; then
  printf 'OP-UNREACHABLE op-read-empty\n'
  exit 2
fi

op_sha=$(printf '%s' "$op_pat" | sha256sum | cut -c1-8)

if [ "$env_sha" = "$op_sha" ]; then
  printf 'OK %s\n' "$env_sha"
  exit 0
else
  printf 'STALE env=%s op=%s\n' "$env_sha" "$op_sha"
  exit 1
fi
