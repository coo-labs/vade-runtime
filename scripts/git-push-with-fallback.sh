#!/usr/bin/env bash
# git push wrapper with direct-URL fallback for the cloud git-proxy 403 issue.
#
# The Claude Code cloud sandbox routes git through a local proxy at
# 127.0.0.1:<port>/git/<owner>/<repo>. The proxy intermittently returns
# HTTP 403 on push (often only the second push onward of a session) and,
# separately, substitutes a token without `workflow` scope on workflow-file
# pushes. Pushing directly to github.com with the COO PAT is reliable.
# See vade-app/vade-runtime#67 for the diagnostic write-up.
#
# Usage:
#   scripts/git-push-with-fallback.sh [<git push args>...]
#
# Behaviour:
#   1. Run `git push <args>`.
#   2. On non-zero exit, scan output for proxy-class failure markers.
#      Match → reconstruct the same push against
#      https://vade-coo:${GITHUB_MCP_PAT}@github.com/<owner>/<repo>.git
#      and retry exactly once.
#      No match (genuine permission denial, bad refspec, etc.) → exit
#      with the original status, no retry.
#
# Requires GITHUB_MCP_PAT in the environment for the fallback path. If
# unset, the wrapper passes the original failure through with a
# pointer at coo-bootstrap.sh.
#
# Credential-leak hardening (vade-app/vade-runtime#124):
#   The fallback push targets a credential-bearing URL. To prevent the
#   PAT from leaking into stdout or .git/config when `-u` /
#   `--set-upstream` is present, the wrapper:
#     · strips upstream flags from the fallback args and re-establishes
#       tracking via `git config branch.<X>.remote=<symbolic remote>`
#       after the push lands;
#     · pipes fallback push output through a sed redactor that masks
#       any `<user>:<password>@` URL.
#
# Silent-failure hardening (vade-app/vade-runtime#280):
#   The wrapper writes every state transition (entry, primary push rc,
#   marker-match decision, fallback push rc) to a durable log at
#   ~/.vade/git-push-fallback.log so cases where stderr is swallowed
#   by an outer harness (bootstrap-trace, captured CI runner, etc.)
#   leave a recoverable forensic trail. The fallback push output is
#   also tee'd to a tmp file and dumped to the log on rc!=0, so the
#   PAT-redacted git stderr is available for triage even when the
#   interactive stream was empty. Set VADE_GIT_PUSH_FALLBACK_LOG=<path>
#   to override the log location.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# Patterns that indicate the harness git proxy refused or dropped the push.
# Anything matching is eligible for the direct-URL fallback. Keep this
# list narrow — we don't want to retry genuine permission errors.
readonly PROXY_FAILURE_PATTERNS='HTTP 403|send-pack: unexpected disconnect|the remote end hung up unexpectedly|refusing to allow an OAuth App|workflow.*scope'

# Sed expression that masks any `<user>:<password>@` segment of a URL.
# Defensive against the wrapper's own credential URL leaking from any
# git-emitted line we don't otherwise control.
readonly PAT_REDACT_SED='s|(https?://[^:/[:space:]]+:)[^@[:space:]]+@|\1***@|g'

resolve_remote_from_args() {
  local a
  for a in "$@"; do
    case "$a" in
      -*) continue ;;
      *) printf '%s' "$a"; return 0 ;;
    esac
  done
  printf 'origin'
}

extract_repo_path() {
  local url="$1"
  local path
  # Proxy form: http(s)://[user@]host[:port]/git/owner/repo[.git]
  path="$(printf '%s' "$url" | sed -nE 's#^https?://[^/]+/git/(.+)$#\1#p')"
  printf '%s' "${path%.git}"
}

# Parse the push refspec out of a git push arg list. Prints two lines —
# <local-branch> and <remote-ref-name> — used to restore upstream
# tracking after a fallback push that had `-u` stripped. Empty output
# when a refspec can't be determined.
parse_push_refspec() {
  local remote="$1"; shift
  local seen_remote=0 a
  for a in "$@"; do
    case "$a" in
      -u|--set-upstream) continue ;;
      -*) continue ;;
    esac
    if [ "$seen_remote" -eq 0 ] && [ "$a" = "$remote" ]; then
      seen_remote=1
      continue
    fi
    local raw="${a#+}"  # strip force-push prefix
    local src dst
    if [[ "$raw" == *:* ]]; then
      src="${raw%%:*}"
      dst="${raw#*:}"
    else
      src="$raw"
      dst="$raw"
    fi
    printf '%s\n%s\n' "$src" "$dst"
    return 0
  done
  local cur
  cur="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ -n "$cur" ]; then
    printf '%s\n%s\n' "$cur" "$cur"
  fi
}

PUSH_OUT_TMP=""
FALLBACK_OUT_TMP=""
cleanup() {
  [ -n "${PUSH_OUT_TMP:-}" ] && rm -f "$PUSH_OUT_TMP"
  [ -n "${FALLBACK_OUT_TMP:-}" ] && rm -f "$FALLBACK_OUT_TMP"
}
trap cleanup EXIT

# Surface a line to BOTH stderr and the durable wrapper log under
# ~/.vade/git-push-fallback.log. Bug #280: under the bootstrap-trace
# harness and in some cloud-sandbox conditions, stderr from a piped
# `git push` got eaten before reaching the user — leaving rc=1 with no
# visible diagnostic. Tagging every important state transition through
# this helper guarantees there is *always* a durable trail on disk even
# when the interactive stderr stream is closed/redirected/swallowed.
WRAPPER_LOG="${VADE_GIT_PUSH_FALLBACK_LOG:-${HOME}/.vade/git-push-fallback.log}"
log_both() {
  local msg="$*"
  log_err "$msg"
  mkdir -p "$(dirname "$WRAPPER_LOG")" 2>/dev/null || return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo)"
  printf '%s [pid=%d] %s\n' "$ts" "$$" "$msg" >> "$WRAPPER_LOG" 2>/dev/null || true
  # Bounded retention.
  if [ "$(wc -l < "$WRAPPER_LOG" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -n 500 "$WRAPPER_LOG" > "${WRAPPER_LOG}.tmp" 2>/dev/null \
      && mv -f "${WRAPPER_LOG}.tmp" "$WRAPPER_LOG" 2>/dev/null
  fi
}

# Tee variant of log_both that also dumps the underlying push output
# file to the wrapper log. Used when the wrapper returns non-zero so
# the next session's investigator has the raw git stderr/stdout on
# disk even if stderr was swallowed at runtime.
dump_to_log() {
  local label="$1" file="$2"
  [ -f "$file" ] || return 0
  mkdir -p "$(dirname "$WRAPPER_LOG")" 2>/dev/null || return 0
  {
    printf -- '--- %s ---\n' "$label"
    cat "$file" 2>/dev/null || true
    printf -- '--- end %s ---\n' "$label"
  } >> "$WRAPPER_LOG" 2>/dev/null || true
}

main() {
  log_both "wrapper start: args=[$*]"

  if ! PUSH_OUT_TMP="$(mktemp 2>/dev/null)"; then
    log_both "mktemp failed; running git push directly with no fallback"
    exec git push "$@"
  fi
  local tmp="$PUSH_OUT_TMP"

  # Run the primary push. Two output sinks for resilience against the
  # symptom in #280 where stderr from a piped invocation was swallowed:
  # (a) tee to the user's terminal as before, (b) the always-present
  # $tmp file we grep against, (c) appended into $WRAPPER_LOG after
  # rc!=0 so a silent stderr is recoverable post-hoc.
  local rc=0
  # `2>&1 | tee` is the canonical capture-and-display pattern.
  # PIPESTATUS[0] is the only correct way to read git's exit under
  # `set -o pipefail`; assign immediately on the next line — any
  # intervening command (including a conditional branch on $?) will
  # overwrite it.
  git push "$@" 2>&1 | tee "$tmp"
  rc="${PIPESTATUS[0]:-1}"
  log_both "primary push: rc=$rc bytes_captured=$(wc -c < "$tmp" 2>/dev/null || echo 0)"
  if [ "$rc" -eq 0 ]; then
    return 0
  fi

  # Non-zero. From here on every return path must (1) emit a stderr
  # line via log_both, (2) include the captured git output in the
  # wrapper log so a silent-stderr session leaves a forensic trail.
  dump_to_log "primary push (rc=$rc)" "$tmp"

  if ! grep -qE "$PROXY_FAILURE_PATTERNS" "$tmp"; then
    log_both "git push failed (rc=$rc) with no proxy-failure marker; passing through"
    return "$rc"
  fi
  log_both "proxy-failure marker matched; preparing fallback"

  local remote current_url repo_path repo_owner
  remote="$(resolve_remote_from_args "$@")"
  if ! current_url="$(git remote get-url "$remote" 2>/dev/null)" || [ -z "$current_url" ]; then
    log_both "could not resolve remote '$remote'; not falling back"
    return "$rc"
  fi
  case "$current_url" in
    *github.com*)
      log_both "remote '$remote' already targets github.com; failure is not proxy-related"
      return "$rc"
      ;;
  esac
  repo_path="$(extract_repo_path "$current_url")"
  if [ -z "$repo_path" ]; then
    log_both "could not extract owner/repo from '$current_url'; not falling back"
    return "$rc"
  fi
  repo_owner="${repo_path%%/*}"

  # PAT selection by remote owner (MEMO-2026-05-12-22m9). vade-app/*
  # remotes use the fine-grained MCP PAT (default write surface);
  # other remotes use the classic public-repo PAT when available.
  # Mirrors the gh-coo-wrap routing layer for symmetric coverage —
  # `git push` to a fork at venpopov/foo would otherwise fall back
  # with the wrong PAT and re-403.
  local fallback_pat fallback_pat_name fallback_user
  if [ "$repo_owner" != "vade-app" ] && [ -n "${GITHUB_PUBLIC_PAT:-}" ]; then
    fallback_pat="$GITHUB_PUBLIC_PAT"
    fallback_pat_name="GITHUB_PUBLIC_PAT"
    fallback_user="vade-coo"
  elif [ -n "${GITHUB_MCP_PAT:-}" ]; then
    fallback_pat="$GITHUB_MCP_PAT"
    fallback_pat_name="GITHUB_MCP_PAT"
    fallback_user="vade-coo"
  else
    log_both "git proxy push failed but no GitHub PAT is set (GITHUB_MCP_PAT, GITHUB_PUBLIC_PAT); cannot fall back"
    log_both "  run scripts/coo-bootstrap.sh (or source ~/.vade/coo-env) to populate them"
    return "$rc"
  fi

  local direct_url="https://${fallback_user}:${fallback_pat}@github.com/${repo_path}.git"
  local masked_url="https://${fallback_user}:***@github.com/${repo_path}.git"
  log_both "git proxy push failed; retrying via $masked_url (using $fallback_pat_name)"

  # Build fallback args: substitute direct_url for the remote token, and
  # drop -u / --set-upstream (the upstream-tracking config gets written
  # explicitly post-push, see #124).
  local -a new_args=()
  local seen_remote=0 has_upstream=0 a
  for a in "$@"; do
    case "$a" in
      -u|--set-upstream) has_upstream=1; continue ;;
    esac
    if [ "$seen_remote" -eq 0 ] && [ "$a" = "$remote" ]; then
      new_args+=("$direct_url")
      seen_remote=1
    else
      new_args+=("$a")
    fi
  done
  if [ "$seen_remote" -eq 0 ]; then
    local current_branch
    current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ -z "$current_branch" ]; then
      log_both "no remote in args and detached HEAD; cannot construct fallback push"
      return "$rc"
    fi
    new_args+=("$direct_url" "HEAD:refs/heads/$current_branch")
  fi

  # Fallback push: same belt-and-suspenders treatment as the primary —
  # capture to a tmp file for forensics, run output through the PAT
  # redactor, AND tee to stdout/stderr. The prior implementation piped
  # straight through `sed` with no separate capture; if sed exited
  # non-zero (e.g., SIGPIPE on closed terminal) or stderr was swallowed,
  # there was no recoverable diagnostic. Now the raw (post-redaction)
  # output lands in $FALLBACK_OUT_TMP and gets dumped to $WRAPPER_LOG
  # whenever the fallback returns non-zero.
  local fallback_rc
  if ! FALLBACK_OUT_TMP="$(mktemp 2>/dev/null)"; then
    # Degraded path: lose the forensic dump but still run the fallback.
    log_both "fallback mktemp failed; running fallback push without capture"
    git push "${new_args[@]}" 2>&1 | sed -E "$PAT_REDACT_SED"
    fallback_rc="${PIPESTATUS[0]:-1}"
  else
    local ftmp="$FALLBACK_OUT_TMP"
    # The pipeline: git → sed (redactor) → tee (sink to file + stdout).
    # PIPESTATUS[0] still captures git's exit code; tee's exit
    # ($PIPESTATUS[2]) and sed's ($PIPESTATUS[1]) are non-fatal for
    # routing purposes.
    git push "${new_args[@]}" 2>&1 | sed -E "$PAT_REDACT_SED" | tee "$ftmp"
    fallback_rc="${PIPESTATUS[0]:-1}"
    log_both "fallback push: rc=$fallback_rc bytes_captured=$(wc -c < "$ftmp" 2>/dev/null || echo 0)"
    if [ "$fallback_rc" -ne 0 ]; then
      dump_to_log "fallback push (rc=$fallback_rc)" "$ftmp"
    fi
  fi
  if [ "$fallback_rc" -ne 0 ]; then
    log_both "fallback push failed; rc=$fallback_rc (forensic trail: $WRAPPER_LOG)"
    return "$fallback_rc"
  fi
  log_both "fallback push succeeded"

  # Restore upstream tracking via the symbolic remote so .git/config
  # stays free of the credential URL. Skip silently if the user didn't
  # ask for upstream-setting.
  if [ "$has_upstream" -eq 1 ]; then
    local refs local_branch remote_ref merge_ref
    refs="$(parse_push_refspec "$remote" "$@")"
    local_branch="$(printf '%s' "$refs" | sed -n '1p')"
    remote_ref="$(printf '%s' "$refs" | sed -n '2p')"
    if [ -n "$local_branch" ] && [ -n "$remote_ref" ]; then
      case "$remote_ref" in
        refs/*) merge_ref="$remote_ref" ;;
        *) merge_ref="refs/heads/$remote_ref" ;;
      esac
      git config "branch.${local_branch}.remote" "$remote"
      git config "branch.${local_branch}.merge" "$merge_ref"
    else
      log_both "fallback push succeeded but could not parse refspec; upstream not restored — run 'git push -u $remote <branch>' manually if needed"
    fi
  fi
}

# Run main only when invoked as a script (not when sourced for testing).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
