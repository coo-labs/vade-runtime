#!/usr/bin/env bash
# coo-session-url: print the Claude Code session URL for the current
# session, derived from CLAUDE_CODE_REMOTE_SESSION_ID (fallback
# CLAUDE_CODE_SESSION_ID). Silent no-op outside Claude Code: empty
# stdout, exit 0.
#
# Used by the coo-harness gh-coo-wrap wrapper as the URL source, and
# by humans / scripts that need the URL ad-hoc — e.g. inside an
# editor body, a heredoc, or a manual MCP call.
#
# Source: issue vade-coo-memory#150; MEMO 2026-04-26-02.

set -eu

sid="${CLAUDE_CODE_REMOTE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -z "$sid" ] && exit 0

# CLAUDE_CODE_*_SESSION_ID is "cse_<id>"; the URL form is
# "session_<id>". Strip the cse_ prefix if present.
printf 'https://claude.ai/code/session_%s\n' "${sid#cse_}"
