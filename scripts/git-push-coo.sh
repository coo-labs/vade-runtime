#!/usr/bin/env bash
# git-push-coo — credential-safe direct-URL git push wrapper.
#
# THREAT MODEL
# ------------
# The cloud git-proxy occasionally returns HTTP 403 / drops connections
# on push (vade-runtime#67, #279, #280). When the proxy path and the
# documented fallback wrapper (`git-push-with-fallback.sh`) both fail,
# agents under live failure typically reach for the credential-inline
# URL form:
#
#   git push "https://vade-coo:${GITHUB_MCP_PAT}@github.com/<owner>/<repo>.git" \
#     <branch>:<branch>
#
# That works, but bash expands $GITHUB_MCP_PAT into the command line.
# The expanded URL — including the literal PAT — appears in:
#   · argv of every git subprocess (visible in `ps aux`)
#   · shell-trace output (`set -x`, harness xtrace captures)
#   · the verbose `git push` URL banner that prints to stderr
#   · any session transcript that captures those streams
#
# Two PAT exposures in a single session (vcm#792, vcm#793 pushes,
# 2026-05-20) triggered out-of-band rotation recommendations. This
# wrapper closes the leak structurally.
#
# MECHANISM
# ---------
# Git supports `GIT_ASKPASS` — a path to an executable that git
# invokes to prompt for credentials. The askpass binary receives a
# single argv: the prompt text ("Username for '<url>': " or
# "Password for '<url>': "). Whatever it prints to stdout is the
# answer. Critically:
#   · The PAT is read from an env var inside the askpass helper, so
#     it never appears in the helper's argv.
#   · The git push URL has no credential component, so the PAT never
#     appears in git's argv either.
#   · Env-var contents don't appear in `set -x` trace output the way
#     expanded argv does. (`set -x` shows resolved values when they
#     land in command lines; not when they sit in env.)
#
# Net: the PAT enters memory but not any printable command-line trace.
#
# USAGE
# -----
#   GITHUB_MCP_PAT=<pat> scripts/git-push-coo.sh <git-push-args>...
#
# Example:
#   scripts/git-push-coo.sh origin HEAD:refs/heads/my-branch
#   scripts/git-push-coo.sh https://github.com/vade-app/foo.git main
#
# The wrapper rewrites a credential-bearing remote URL (if present)
# to a clean URL before invoking git push; the PAT moves into the
# askpass helper instead. If the remote arg is a symbolic name like
# `origin`, the configured URL is used as-is (assumed clean).
#
# RELATIONSHIP TO EXISTING WRAPPERS
# ---------------------------------
# `scripts/git-push-with-fallback.sh` currently constructs a
# credential-inline URL for its fallback push and relies on a sed
# redactor to mask output. That wrapper should migrate to use the
# askpass mechanism in this file — see TODO below. Migration is
# non-trivial because the fallback wrapper composes args dynamically
# (strips `-u`, restores tracking post-push) and the PAT selection
# is owner-dependent (GITHUB_MCP_PAT vs GITHUB_PUBLIC_PAT). Tracking
# follow-up issue rather than refactoring inline here.
#
# TODO(vade-runtime#281 follow-up): migrate `git-push-with-fallback.sh`
# to source the askpass helper from this script (or factor the helper
# into `scripts/lib/git-askpass.sh`). Keep the per-call shim shape;
# don't switch to a persistent credential.helper (the gitconfig
# footprint is itself an artifact, see #281 "Alternative considered").

set -uo pipefail

readonly PAT_ENV_DEFAULT="GITHUB_MCP_PAT"
readonly COO_USER_DEFAULT="vade-coo"

# Pick PAT env var: explicit COO_PUSH_TOKEN_ENV beats default. The
# helper reads from $COO_PUSH_TOKEN at runtime; we set that from
# whichever source var the caller named.
PAT_ENV="${COO_PUSH_TOKEN_ENV:-$PAT_ENV_DEFAULT}"
COO_USER="${COO_PUSH_USER:-$COO_USER_DEFAULT}"

# Read the secret into a local; we'll re-export it as COO_PUSH_TOKEN
# (a stable name the askpass helper consumes) so different callers
# can plug in GITHUB_MCP_PAT, GITHUB_PUBLIC_PAT, etc., without the
# helper caring.
PAT_VALUE="${!PAT_ENV:-}"
if [ -z "$PAT_VALUE" ]; then
  echo "[git-push-coo] ${PAT_ENV} is unset; cannot push." >&2
  echo "[git-push-coo]   set ${PAT_ENV} (or COO_PUSH_TOKEN_ENV=<var>) and retry." >&2
  exit 2
fi

# Create the askpass helper in a private temp dir. mktemp -d gives
# a 0700 dir; the helper inside gets chmod 700 explicitly.
ASKPASS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/git-askpass-coo.XXXXXX")"
if [ -z "$ASKPASS_DIR" ] || [ ! -d "$ASKPASS_DIR" ]; then
  echo "[git-push-coo] mktemp -d failed; cannot stage askpass helper." >&2
  exit 1
fi
ASKPASS_FILE="${ASKPASS_DIR}/askpass.sh"

cleanup() {
  if [ -n "${ASKPASS_DIR:-}" ] && [ -d "$ASKPASS_DIR" ]; then
    rm -rf -- "$ASKPASS_DIR"
  fi
}
trap cleanup EXIT INT TERM HUP

# The helper itself. It reads $COO_PUSH_TOKEN and $COO_PUSH_USER from
# env (exported below). No PAT in its argv, no PAT in its file body.
cat > "$ASKPASS_FILE" <<'ASKPASS'
#!/bin/sh
# git askpass helper. argv[1] is the prompt text:
#   "Username for 'https://github.com': "
#   "Password for 'https://vade-coo@github.com': "
case "$1" in
  Username*) printf '%s\n' "${COO_PUSH_USER:-vade-coo}" ;;
  Password*) printf '%s\n' "${COO_PUSH_TOKEN:-}" ;;
  *)         printf '%s\n' "${COO_PUSH_TOKEN:-}" ;;
esac
ASKPASS
chmod 700 "$ASKPASS_FILE"

# Strip any embedded `<user>:<password>@` from the remote URL if the
# caller passed one. Looks for an arg matching https://...@... and
# rewrites to https://host/path. Symbolic remotes (`origin`) and
# clean URLs pass through unchanged.
declare -a SAFE_ARGS=()
for arg in "$@"; do
  case "$arg" in
    https://*@github.com/*|https://*@*github*)
      # Rewrite https://user:pass@host/path → https://host/path
      cleaned="$(printf '%s' "$arg" | sed -E 's#^(https?://)[^@/[:space:]]+@#\1#')"
      SAFE_ARGS+=("$cleaned")
      ;;
    *)
      SAFE_ARGS+=("$arg")
      ;;
  esac
done

# Export everything the helper needs and invoke git. GIT_TERMINAL_PROMPT=0
# ensures git never falls back to interactive tty prompting if askpass
# misbehaves — better to fail loud than to hang silently in CI.
export GIT_ASKPASS="$ASKPASS_FILE"
export COO_PUSH_TOKEN="$PAT_VALUE"
export COO_PUSH_USER="$COO_USER"
export GIT_TERMINAL_PROMPT=0

git push "${SAFE_ARGS[@]}"
exit "$?"
