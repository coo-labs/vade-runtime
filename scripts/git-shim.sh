#!/usr/bin/env bash
# vade-coo git shim — intercepts `git push` and routes through
# git-push-with-fallback.sh so the cloud git-proxy 403 wraparound
# (coo-harness#67) is the default behavior, not an opt-in.
#
# Installed by coo-bootstrap.sh as a symlink at <bindir>/git, where
# bindir is _snapshot_user_bindir (typically /home/user/.local/bin on
# cloud, ${HOME}/.local/bin on Mac). PATH already prepends that bindir,
# so this shim shadows the system git.
#
# Behavior:
#   - First arg "push" → exec git-push-with-fallback.sh with the rest.
#   - Anything else (status, fetch, commit, push with global flags
#     before the subcommand, etc.) → exec system git directly.
#   - VADE_GIT_SHIM_BYPASS=1 in env → unconditionally exec system git.
#     The shim itself sets this on its own subprocess so the wrapper's
#     internal `git push` / `git remote get-url` / etc. don't recurse.
#
# Removal:
#   rm "$(command -v git)" if it points to this shim, or unset PATH
#   prepend in your shell. The shim is fail-soft — if the wrapper or
#   readlink misbehaves, all paths fall through to system git.

set -uo pipefail

# Resolve the system git: first git in PATH that isn't this shim.
_resolve_system_git() {
  if [ -n "${VADE_SYSTEM_GIT:-}" ] && [ -x "$VADE_SYSTEM_GIT" ]; then
    printf '%s' "$VADE_SYSTEM_GIT"
    return 0
  fi
  local self candidate self_real cand_real
  self="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    cand_real="$(readlink -f -- "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    [ "$cand_real" = "$self" ] && continue
    printf '%s' "$candidate"
    return 0
  done < <(type -ap git 2>/dev/null)
  printf '/usr/bin/git'
}

SYSTEM_GIT="$(_resolve_system_git)"

# Bypass cases: env-flag set (recursion / opt-out), no args, or first
# arg is anything other than the bare subcommand "push". The shim
# deliberately does NOT try to parse `git -c key=val push` or
# `git -C dir push` — those invocations bypass to system git, which is
# the safe default. The wrapper handles the common case (`git push
# <args>`) which is what agent loops and humans type 99% of the time.
if [ -n "${VADE_GIT_SHIM_BYPASS:-}" ] || [ "${1:-}" != "push" ]; then
  exec "$SYSTEM_GIT" "$@"
fi

# Resolve the wrapper relative to this shim's source. The shim is
# typically a symlink at <bindir>/git → <runtime>/scripts/git-shim.sh,
# and the wrapper is its sibling at <runtime>/scripts/git-push-with-fallback.sh.
# Cloud and Mac paths differ; readlink resolution avoids hard-coding either.
_shim_real="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"
_shim_dir="$(dirname -- "$_shim_real")"
WRAPPER="${VADE_GIT_PUSH_WRAPPER:-$_shim_dir/git-push-with-fallback.sh}"

if [ ! -x "$WRAPPER" ]; then
  exec "$SYSTEM_GIT" "$@"
fi

shift  # drop "push"
export VADE_GIT_SHIM_BYPASS=1
exec bash "$WRAPPER" "$@"
