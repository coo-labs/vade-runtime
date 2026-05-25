# vade-runtime — Repo Instructions for Claude Code

This repository produces the **reproducible development
environment** for VADE. Changes here affect every contributor's
loop, so treat them carefully.

## Session-start reading

1. This file.
2. `README.md`.
3. `Dockerfile` and `.devcontainer/devcontainer.json` (once they
   exist).
4. The public authority and decision-rights document at
   [vade-governance/authority.md](https://github.com/coo-labs/vade-governance/blob/main/authority.md)
   — for what may and may not be done autonomously.

## Scope

Work in this repository is scoped to the development container and
toolchain pinning. Its job is to keep the dev environment clean,
pinned, and fast.

## What may be done autonomously

- Draft Dockerfile changes on a feature branch.
- Update pinned tool versions, with reasoning captured in the
  commit message.
- Add or revise scripts under `scripts/`.
- Open pull requests for review.
- Run local builds to verify changes (`docker build .`).

## What requires explicit approval

- Pushing image tags to any registry.
- Merging to `main`.
- Changing the base image family (e.g. from Debian to Alpine).
- Adding dependencies that aren't in-scope for VADE development.

## Pinning discipline

Every tool version added to the image must be pinned in
`versions.lock` (once that file exists) with rationale. Unpinned
dependencies cause silent dev-env drift across contributors, which
is the exact class of bug this repository exists to prevent.

## Current state

Alpha. Minimal Dockerfile in place (based on `node:20.19.1-bookworm-slim`)
with Claude Code CLI and `tsx` pre-installed. `.devcontainer/devcontainer.json`
forwards ports 5173 (Vite) and 7600 (MCP WebSocket bridge), and mounts
a named volume for the `~/.vade/library/` canvas library. `scripts/bootstrap.sh`
and `scripts/healthcheck.sh` handle first-run setup and smoke testing.
See `versions.lock` for pinned tools.

Next planned additions (deferred until needed): Rust toolchain via
`rustup` when the first performance module lands, Python 3.12 when a
canvas artifact needs scientific helpers.

## Bootstrap CI

PRs that touch `scripts/`, `.claude/`, `.mcp.json`, `versions.lock`,
or `Dockerfile` trigger
`.github/workflows/bootstrap-regression.yml`, which stages a
cloud-style workspace under `/home/user`, runs `scripts/cloud-setup.sh`
+ `scripts/session-start-sync.sh` end-to-end in **fake-env mode**
(PATH-shadowed `op` and `curl`-to-`api.github.com/user` mocks under
`scripts/ci/mocks/`), then asserts the integrity-check report has no
degraded invariants modulo the `VADE_CI_ALLOWLIST` env. Catches
script-level regressions like #66, #72, #73, #83 at PR-open time
without burning a Claude Code session per check. Tracked at #86.

Layer-2 (SDK-driven harness load test) is sibling work at #85.
This Layer-1 suite does not exercise Claude Code reading
`settings.json`, MCP startup, skill loading, or live 1Password / GitHub
PAT round-trips — those stay in the manual fresh-container ritual
until #85 closes.

What runs:
1. `scripts/ci/run-bootstrap-regression.sh` stages
   `$VADE_CI_WORKSPACE_ROOT/{vade-runtime,vade-coo-memory,vade-core}`
   from the PR checkout (sibling repos are stubbed).
2. Generates fixture ed25519 keys per run; their fingerprints are
   exported as `COO_AUTH_FP_EXPECTED` / `COO_SIGN_FP_EXPECTED` so
   `install_coo_ssh_keys` validates against the substituted material.
3. Mocks `op` (returns canned vade-coo-shaped responses) and `curl`
   (intercepts only `api.github.com/user`; other URLs forward).
4. Provisions an isolated `$HOME` so the runner's `~/.gitconfig` /
   `~/.claude` stay untouched.
5. Runs `cloud-setup.sh` → `session-start-sync.sh` →
   `integrity-check.sh`; reads `integrity-check.json`, applies
   `VADE_CI_ALLOWLIST`, fails if anything degraded remains.
6. Renders a per-group markdown table and posts/updates a sticky PR
   comment (header marker `<!-- bootstrap-regression-comment -->`).

Allowlist defaults to empty. E1–E4 (live MCP probes) skip in CI by
design; F1–F4 (culture-substrate invariants) skip cleanly because
the staged `vade-coo-memory` is a stub without `.git`. Bump the
allowlist via the workflow's `VADE_CI_ALLOWLIST` env or the
`workflow_dispatch` input — cite the reason in the commit so the
next operator can audit.

Local run (from a vade-runtime checkout, against a scratch workspace
to avoid clobbering production /home/user):

```sh
VADE_CI_WORKSPACE_ROOT=/tmp/vade-ci-workspace \
  bash scripts/ci/run-bootstrap-regression.sh "$PWD"
```

Smoke-test the suite itself by editing `cloud-setup.sh` /
`session-start-sync.sh` to comment out a call like
`ensure_workspace_identity_link` or `merge_coo_settings_env` — the
runner should report the corresponding C1/D4 invariant as degraded
and exit 1.
