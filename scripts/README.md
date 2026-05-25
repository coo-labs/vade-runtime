# `scripts/`

Hook-driven per-session scripts plus shared utilities and probes for
the VADE development environment. The flat top-level layout is
intentional under ~25 entries; sub-grouping is deferred until the
count justifies the cost of breaking references in `CLAUDE.md`,
`hooks-dispatch.sh`, `integrity-check.sh`, several memos, and
`cloud-setup.sh` itself.

## Inventory by role

**Boot (4)**
- `bootstrap.sh` — local bootstrap entry point.
- `cloud-setup.sh` — cloud bootstrap orchestrator (1Password fetch,
  identity install, settings.json merge).
- `coo-bootstrap.sh` — COO-identity-specific stage of the bootstrap
  pipeline; idempotent with a per-container epoch marker.
- `local-setup.sh` — local-machine bootstrap (Mac CLI surface).

**Session lifecycle (6)**
- `session-start-sync.sh` — re-syncs `~/.claude/` config from
  vade-runtime on every SessionStart.
- `session-lifecycle.sh` — boot/end-of-session reminders
  (`--end` flag selects mode).
- `coo-identity-digest.sh` — prints CLAUDE.md + recent memo headers
  into session context.
- `discussions-digest.sh` — prints new coo-labs org discussions.
- `memo-index.sh` — thin wrapper that delegates to
  `coo-memory/.claude/_lib/memo-index.sh`.
- `hooks-dispatch.sh` — central dispatcher resolving hook names to
  the canonical script via the five resolver rules (MEMO-2026-04-22-12).

**Wrappers / shims (4)**
- `gh-coo-wrap.sh` — `gh` wrapper attributing writes to `vade-coo`.
- `git-shim.sh` — git proxy + auth interceptor.
- `git-push-with-fallback.sh` — push with HTTPS-proxy 403 fallback.
- `issue-comments.sh` — bounded fetch of an issue comment thread
  (compact projection, default 10 KB ceiling, `--full` escape hatch).
  Substitute for unbounded `mcp__github__issue_read get_comments`
  (coo-harness#153, transcript-bloat-audit Tier 1).

**Probes (2)**
- `healthcheck.sh` — fast smoke-test of the bootstrap pipeline.
- `integrity-check.sh` — full invariant probe (Groups A–F).

**Cross-repo (1)**
- `sync-repos.sh` — bulk-pull / bulk-fetch across the coo-labs repos.

## Sub-folders

- `lib/` — sourced common functions; not entry points.
- `ci/` — CI runners (`run-bootstrap-regression.sh`, test scripts)
  and mocks under `ci/mocks/`.
- `seed-discussions/` — one-shot seed scripts for the org's GitHub
  Discussions categories; kept after first-run for re-seeding.

## Sub-grouping defer note

When the top-level `.sh` count exceeds ~25, restructure into
sub-folders by role. At that point document the break-points (which
references in CLAUDE.md, hooks-dispatch, integrity-check, memos, and
cloud-setup need updating).
