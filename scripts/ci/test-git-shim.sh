#!/usr/bin/env bash
# test-git-shim: smoke-test the git shim that intercepts `git push`
# and routes it through git-push-with-fallback.sh (coo-harness#67).
#
# Strategy: install a mock system git that records its argv, plus a
# mock wrapper that records its argv. Run the shim with various arg
# shapes and assert the right binary is reached.
#
# Run: bash scripts/ci/test-git-shim.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/../git-shim.sh"

[ -x "$SHIM" ] || { echo "FAIL: shim not executable at $SHIM"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Mock system git: dumps argv to a log file.
cat > "$WORK/git-real" <<'EOF'
#!/usr/bin/env bash
log="${MOCK_GIT_LOG:-/dev/null}"
{
  printf 'INVOKED: git'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
} >> "$log"
EOF
chmod +x "$WORK/git-real"

# Mock wrapper: dumps argv to a separate log file.
cat > "$WORK/git-push-with-fallback.sh" <<'EOF'
#!/usr/bin/env bash
log="${MOCK_WRAPPER_LOG:-/dev/null}"
{
  printf 'INVOKED: wrapper'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
} >> "$log"
EOF
chmod +x "$WORK/git-push-with-fallback.sh"

# Stage the shim alongside the mock wrapper so readlink-based wrapper
# resolution finds the mock, not the real one.
cp "$SHIM" "$WORK/git-shim.sh"
chmod +x "$WORK/git-shim.sh"

PASS=0
FAIL=0

assert_log() {
  local label="$1" log="$2" expected="$3"
  local actual
  actual="$(cat "$log" 2>/dev/null || true)"
  if [ "$actual" = "$expected" ]; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

run_shim() {
  : > "$WORK/git.log"
  : > "$WORK/wrapper.log"
  MOCK_GIT_LOG="$WORK/git.log" \
  MOCK_WRAPPER_LOG="$WORK/wrapper.log" \
  VADE_SYSTEM_GIT="$WORK/git-real" \
  VADE_GIT_PUSH_WRAPPER="$WORK/git-push-with-fallback.sh" \
  unset_bypass=1 \
  bash "$WORK/git-shim.sh" "$@"
}

run_shim_with_bypass() {
  : > "$WORK/git.log"
  : > "$WORK/wrapper.log"
  MOCK_GIT_LOG="$WORK/git.log" \
  MOCK_WRAPPER_LOG="$WORK/wrapper.log" \
  VADE_SYSTEM_GIT="$WORK/git-real" \
  VADE_GIT_PUSH_WRAPPER="$WORK/git-push-with-fallback.sh" \
  VADE_GIT_SHIM_BYPASS=1 \
  bash "$WORK/git-shim.sh" "$@"
}

echo "test 1 — non-push subcommand passes through to system git"
run_shim status -sb
assert_log "git invoked" "$WORK/git.log" 'INVOKED: git [status] [-sb]'
assert_log "wrapper not invoked" "$WORK/wrapper.log" ''

echo "test 2 — bare git (no args) passes through"
run_shim
assert_log "git invoked with no args" "$WORK/git.log" 'INVOKED: git'
assert_log "wrapper not invoked" "$WORK/wrapper.log" ''

echo "test 3 — \`git push <args>\` routes to the wrapper"
run_shim push -u origin main
assert_log "git not invoked directly" "$WORK/git.log" ''
assert_log "wrapper invoked with shifted args" "$WORK/wrapper.log" 'INVOKED: wrapper [-u] [origin] [main]'

echo "test 4 — \`git push\` with no further args still routes to wrapper"
run_shim push
assert_log "wrapper invoked with no args" "$WORK/wrapper.log" 'INVOKED: wrapper'
assert_log "git not invoked directly" "$WORK/git.log" ''

echo "test 5 — VADE_GIT_SHIM_BYPASS=1 forces system git even on push"
run_shim_with_bypass push -u origin main
assert_log "git invoked under bypass" "$WORK/git.log" 'INVOKED: git [push] [-u] [origin] [main]'
assert_log "wrapper not invoked under bypass" "$WORK/wrapper.log" ''

echo "test 6 — global flags before push (\`git -c k=v push\`) bypass to system git"
# This is by design — the shim doesn't parse global flags.
run_shim -c remote.origin.fetch=foo push -u origin main
assert_log "git invoked (shim doesn't handle global flags)" "$WORK/git.log" 'INVOKED: git [-c] [remote.origin.fetch=foo] [push] [-u] [origin] [main]'
assert_log "wrapper not invoked" "$WORK/wrapper.log" ''

echo "test 7 — missing wrapper falls through to system git on push"
mv "$WORK/git-push-with-fallback.sh" "$WORK/git-push-with-fallback.sh.disabled"
run_shim push -u origin main
assert_log "git invoked when wrapper missing" "$WORK/git.log" 'INVOKED: git [push] [-u] [origin] [main]'
mv "$WORK/git-push-with-fallback.sh.disabled" "$WORK/git-push-with-fallback.sh"

echo
echo "=== results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
