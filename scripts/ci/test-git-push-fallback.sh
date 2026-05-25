#!/usr/bin/env bash
# test-git-push-fallback: unit-test the credential-leak hardening in
# scripts/git-push-with-fallback.sh (coo-labs/vade-runtime#124).
#
# Strategy: source the wrapper's helper functions in isolation and
# pipe-test their behavior on representative arg shapes. Also exercise
# the redaction sed against a stream containing a credential URL, and
# end-to-end the .git/config tracking restoration via a mock-git repo
# that pretends the fallback push succeeded.
#
# Run: bash scripts/ci/test-git-push-fallback.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../git-push-with-fallback.sh"

[ -f "$WRAPPER" ] || { echo "FAIL: wrapper not found at $WRAPPER"; exit 1; }

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected: %q\n    actual:   %q\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_match() {
  local label="$1" pattern="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qE "$pattern"; then
    printf '  FAIL: %s\n    pattern %q matched in: %q\n' "$label" "$pattern" "$haystack"
    FAIL=$((FAIL + 1))
  else
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  fi
}

assert_match() {
  local label="$1" pattern="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qE "$pattern"; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    pattern %q did not match in: %q\n' "$label" "$pattern" "$haystack"
    FAIL=$((FAIL + 1))
  fi
}

# Source the wrapper for direct access to helper functions. The wrapper
# guards `main "$@"` behind a BASH_SOURCE/0 check so sourcing is safe.
# shellcheck disable=SC1090
source "$WRAPPER"

echo "== parse_push_refspec =="

out="$(parse_push_refspec origin -u origin claude/foo)"
assert_eq "simple: -u origin claude/foo" "$(printf 'claude/foo\nclaude/foo\n')" "$out"

out="$(parse_push_refspec origin --set-upstream origin claude/foo:claude/bar)"
assert_eq "split refspec: --set-upstream origin claude/foo:claude/bar" \
  "$(printf 'claude/foo\nclaude/bar\n')" "$out"

out="$(parse_push_refspec origin -u origin +claude/foo)"
assert_eq "force prefix: -u origin +claude/foo" "$(printf 'claude/foo\nclaude/foo\n')" "$out"

out="$(parse_push_refspec origin -u origin claude/foo:refs/heads/claude/bar)"
assert_eq "explicit refs/heads/ in dst" \
  "$(printf 'claude/foo\nrefs/heads/claude/bar\n')" "$out"

echo "== PAT_REDACT_SED =="

leak_input='branch claude/foo set up to track '"'"'https://vade-coo:github_pat_AAAA1234@github.com/coo-labs/vade-runtime.git/claude/foo'"'"'.'
redacted="$(printf '%s' "$leak_input" | sed -E "$PAT_REDACT_SED")"
assert_no_match "PAT redacted from git tracking-set line" 'github_pat_' "$redacted"
assert_eq "redacted URL has *** placeholder" \
  "branch claude/foo set up to track 'https://vade-coo:***@github.com/coo-labs/vade-runtime.git/claude/foo'." \
  "$redacted"

multi_input='https://octocat:ghp_BBBB5678@github.com/foo/bar.git'
redacted_multi="$(printf '%s' "$multi_input" | sed -E "$PAT_REDACT_SED")"
assert_eq "redaction is user-agnostic" "https://octocat:***@github.com/foo/bar.git" "$redacted_multi"

clean_input='https://github.com/coo-labs/vade-runtime.git'
clean_out="$(printf '%s' "$clean_input" | sed -E "$PAT_REDACT_SED")"
assert_eq "redaction leaves clean URLs alone" "$clean_input" "$clean_out"

echo "== end-to-end: -u flag does not leak PAT into .git/config =="

# Stage a scratch repo whose `origin` remote points at a non-github proxy
# stand-in. The wrapper will detect the proxy URL pattern, fall back to
# the credential-bearing direct URL, and call `git push` against it. We
# intercept that call with a mock `git` that fails the first push (to
# trigger the fallback) and succeeds the second — bypassing the actual
# network — then verify the resulting .git/config.

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REAL_GIT="/usr/bin/git"
[ -x "$REAL_GIT" ] || { echo "FAIL: real git not at $REAL_GIT"; exit 1; }

MOCK_LOG="$WORK/git-mock.log"
STATE="$WORK/state"
cat > "$WORK/git" <<MOCKEOF
#!/usr/bin/env bash
# Forward read-only ops to the real git so the wrapper's setup calls
# (remote get-url, symbolic-ref, config write) work in this test.
case "\$1" in
  push)
    {
      printf 'MOCK PUSH ARGS:'
      for a in "\$@"; do printf ' [%s]' "\$a"; done
      printf '\n'
    } >> "$MOCK_LOG"
    if [ -f "$STATE" ]; then
      # Second-and-onward push: succeed.
      exit 0
    fi
    # First push: emit a proxy-failure marker and fail.
    : > "$STATE"
    printf 'remote: HTTP 403\n' >&2
    exit 1
    ;;
  *)
    exec $REAL_GIT "\$@"
    ;;
esac
MOCKEOF
chmod +x "$WORK/git"

REPO="$WORK/repo"
mkdir -p "$REPO"
(
  cd "$REPO"
  $REAL_GIT init -q -b main >/dev/null 2>&1
  $REAL_GIT -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
  $REAL_GIT checkout -q -b claude/test-branch
  $REAL_GIT remote add origin "http://local_proxy@127.0.0.1:8080/git/coo-labs/vade-runtime"
)

# Isolate HOME so the wrapper's `lib/common.sh` doesn't source the
# host's ~/.vade/coo-env and overwrite our test PAT (common.sh:234).
STUB_HOME="$WORK/stub-home"
mkdir -p "$STUB_HOME"

(
  cd "$REPO"
  PATH="$WORK:$PATH"
  HOME="$STUB_HOME" \
  GITHUB_MCP_PAT="test_pat_DO_NOT_LEAK_2222" \
    bash "$WRAPPER" -u origin claude/test-branch
) > "$WORK/wrapper.out" 2>&1

wrapper_out="$(cat "$WORK/wrapper.out")"
mock_log="$(cat "$MOCK_LOG" 2>/dev/null || true)"

assert_no_match "wrapper stdout/stderr does not contain PAT" \
  'test_pat_DO_NOT_LEAK_2222' "$wrapper_out"

config_remote="$($REAL_GIT -C "$REPO" config --get branch.claude/test-branch.remote || true)"
assert_eq ".git/config branch tracking remote = symbolic origin" "origin" "$config_remote"

config_merge="$($REAL_GIT -C "$REPO" config --get branch.claude/test-branch.merge || true)"
assert_eq ".git/config branch merge ref = refs/heads/claude/test-branch" \
  "refs/heads/claude/test-branch" "$config_merge"

# Two MOCK pushes recorded: first proxy attempt + fallback.
push_count="$(grep -c '^MOCK PUSH ARGS:' "$MOCK_LOG" 2>/dev/null || echo 0)"
assert_eq "mock saw two push attempts (proxy + fallback)" "2" "$push_count"

# First-attempt push (line 1): contains -u, contains [origin] (symbolic).
first_line="$(sed -n '1p' "$MOCK_LOG")"
assert_match "first push contains [-u]" '\[-u\]' "$first_line"
assert_match "first push contains [origin]" '\[origin\]' "$first_line"

# Fallback push (line 2): no -u, no --set-upstream, contains the direct URL.
second_line="$(sed -n '2p' "$MOCK_LOG")"
assert_no_match "fallback push args do not contain -u" '\[-u\]' "$second_line"
assert_no_match "fallback push args do not contain --set-upstream" '\[--set-upstream\]' "$second_line"
assert_match "fallback push args contain direct vade-coo URL" 'vade-coo:test_pat_DO_NOT_LEAK_2222@github.com' "$second_line"

# .git/config must NOT contain the PAT anywhere.
assert_no_match ".git/config contains no PAT" 'test_pat_DO_NOT_LEAK_2222' \
  "$(cat "$REPO/.git/config")"

echo
printf 'Results: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
