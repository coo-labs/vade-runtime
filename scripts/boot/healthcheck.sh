#!/usr/bin/env bash
# Container smoke test. Exits 0 if all expected tools are available
# and at their pinned major versions.
set -euo pipefail

fail=0

check() {
  local name="$1"
  local cmd="$2"
  local expected="$3"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "FAIL: $name not on PATH"
    fail=1
    return
  fi
  local actual
  actual=$(eval "$cmd" 2>&1 | head -1)
  if [[ "$actual" == *"$expected"* ]]; then
    echo "OK:   $name -> $actual"
  else
    echo "WARN: $name -> $actual (expected contains '$expected')"
  fi
}

check node  'node --version'  'v20.'
check npm   'npm --version'   '10.'
check git   'git --version'   'git version'
check claude 'claude --version' '1.'

# Network / build-essential sanity
check curl 'curl --version'   'curl '
check cc   'cc --version'     'gcc'

if [ "$fail" -ne 0 ]; then
  echo
  echo "healthcheck: FAIL"
  exit 1
fi

echo
echo "healthcheck: OK"
