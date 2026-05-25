# vade-runtime

**Docker image and devcontainer for VADE.** Reproducible development
environment for the [VADE project](https://github.com/coo-labs).
This repo produces the container that `vade-core` (and eventually
task-agent workspaces) run inside during development.

## Status

**Alpha.** Minimal Dockerfile and devcontainer are in place. Node 20
LTS + Claude Code CLI + tsx pre-installed. Targets the vade-core
Vite/tldraw/MCP stack.

## What's in the image

| Tool | Version | Why |
|------|---------|-----|
| Node.js | 20.19.1 LTS | Runtime for vade-core app and MCP server |
| @anthropic-ai/claude-code | 1.0.120 | Agent CLI inside the container |
| tsx | 4.21.0 | Run the vade-canvas MCP server |
| git, build-essential, ca-certificates, curl | bookworm | Dev essentials |

See [`versions.lock`](./versions.lock) for the full pinned list and
rationale.

## Layout

```
vade-runtime/
├── Dockerfile                ← base image
├── .devcontainer/
│   └── devcontainer.json     ← VS Code / Codespaces entry point
├── .claude/                  ← shared Claude Code config (cloud sessions)
│   └── settings.json         ← hooks declared here; mirrored to ~/.claude/ at boot
├── scripts/
│   ├── bootstrap.sh          ← first-run setup (npm install, dirs)
│   ├── cloud-setup.sh        ← Claude Code web "Setup script" entry point
│   ├── coo-bootstrap.sh      ← COO identity setup (opt-in, see below)
│   └── healthcheck.sh        ← smoke test: versions + PATH
└── versions.lock             ← pinned tool versions + rationale
```

## How to use

### With VS Code (recommended)

Copy (or symlink) the `.devcontainer/` folder into the vade-core
checkout, then:

```bash
cd ~/GitHub/coo-labs/vade-core
code .
# → "Reopen in Container" when prompted
```

The container forwards port **5173** (Vite dev server) and **7600**
(VADE MCP WebSocket bridge). A named volume `vade-library` persists
`~/.vade/library/` across rebuilds.

### With Docker directly

```bash
docker build -t vade-runtime .
docker run -it --rm \
  -v "$PWD:/workspace" \
  -p 5173:5173 -p 7600:7600 \
  -v vade-library:/home/node/.vade \
  vade-runtime
```

### Verify the image

```bash
docker run --rm vade-runtime bash /workspace/scripts/healthcheck.sh
```

### With Claude Code on the web

The harness clones `vade-core`, `vade-runtime`, and `vade-coo-memory` into
`/home/user/` per session. Set the cloud environment's **Setup script** field
to:

```bash
#!/bin/bash
set -e
bash /home/user/vade-runtime/scripts/cloud-setup.sh
```

`cloud-setup.sh` mirrors `vade-runtime/.claude/` into `~/.claude/`:
subdirectories (`skills/`, `agents/`, `commands/`, `hooks/`) are symlinked so
edits in the repo are live next session start; `settings.json` is copied so
COO bootstrap can mutate the env block without dirtying the working tree.

To opt into the full local toolchain (npm install on vade-core, `tsx` global)
during cloud setup, set `VADE_BOOT_INSTALL=1` in the cloud environment vars.

## COO identity mode (cloud)

Claude Code web sessions can boot with a specific agent identity
(currently the `vade-coo` GitHub user) pre-wired: SSH keys for push
and signing, git identity, GitHub PAT, AgentMail API key. The
mechanism is opt-in via a single env var set in the cloud environment
config. See `vade-coo-memory/coo/cloud-env-bootstrap.md` for the
authoritative contract; architecture rationale in MEMO 2026-04-22-03.

### Activation

Set one env var in the Claude Code cloud environment → Environment
variables tab:

```
OP_SERVICE_ACCOUNT_TOKEN=ops_...
```

On next session boot, `cloud-setup.sh` detects the token and invokes
`scripts/coo-bootstrap.sh`, which:

1. Installs the 1Password `op` CLI to `~/.local/bin/` if missing
2. Authenticates with the service-account token
3. Reads SSH keys + PAT + AgentMail key from a 1Password vault named
   `COO`
4. Writes `~/.ssh/vade-coo-auth`, `~/.ssh/vade-coo-sign`,
   `~/.ssh/allowed_signers`, and `~/.gitconfig` with COO identity +
   signed-commit config
5. Writes `~/.vade/coo-env` (sourceable) and merges vars into
   `~/.claude/settings.json` so `.mcp.json` `${GITHUB_MCP_PAT}` and
   `${AGENTMAIL_API_KEY}` substitutions resolve
6. Validates the PAT is actually for `vade-coo` — aborts loudly on
   mismatch

If `OP_SERVICE_ACCOUNT_TOKEN` is unset, the bootstrap is a silent
no-op and the cloud env comes up in plain VADE mode.

### 1Password vault contract

The service account must have **read** access to a vault named `COO`
containing the following items. Items marked *best-effort* may be
absent — their absence warns and disables the corresponding feature
without blocking boot.

| Item reference | Type | What it holds |
|---|---|---|
| `op://COO/vade-coo-self-2026-04` | API Credential | GitHub fine-grained PAT (`credential` field) |
| `op://COO/agentmail-vade-coo` | API Credential | AgentMail API key (`credential` field) |
| `op://COO/mem0-vade-coo` | API Credential | Mem0 Platform API key (`credential` field; prefix `m0-`) — powers the `mem0-rest.sh` break-glass fallback when the Mem0 MCP OAuth transport is degraded |
| `op://COO/vade-coo-auth` | SSH Key | GitHub auth key (`ed25519`) |
| `op://COO/vade-coo-sign` | SSH Key | GitHub signing key (`ed25519`) |
| `op://COO/vade-canvas-coo` | API Credential | *Best-effort.* vade-canvas MCP bearer (`credential` field) — resolves the `${VADE_AUTH_TOKEN}` placeholder in `vade-core/.mcp.json`. Bearer must also appear in Fly's `VADE_AUTH_TOKENS.agents[]` for vade-canvas to accept it (see vade-core `docs/auth.md`). Absent until vade-core#93 follow-up creates it. |

Fingerprints validated at boot:

- auth: `SHA256:9vxJc6c69L8eaR6CvwdZoYDco24W6yN6GkKwnsm8Uys`
- sign: `SHA256:pZeA8xycAtIsVGwhMzR3mg4KG05n9ksFuy4F1ZVXn3A`

Mismatch = boot fails. Rotate keys → update fingerprints in
`scripts/lib/common.sh` (`COO_AUTH_FP_EXPECTED`, `COO_SIGN_FP_EXPECTED`).

### Push fallback for the cloud git proxy

The Claude Code cloud sandbox routes git through a local proxy
(`http://local_proxy@127.0.0.1:<port>/git/<owner>/<repo>`) that
intermittently 403s on push and, separately, substitutes a token
without `workflow` scope on workflow-file pushes
(`coo-labs/vade-runtime#67`).

`scripts/git-push-with-fallback.sh` wraps `git push` and, on a
proxy-class failure, retries once via
`https://vade-coo:${GITHUB_MCP_PAT}@github.com/<owner>/<repo>.git`,
preserving `vade-coo` attribution. Genuine failures (permission
denied, bad refspec, network down) pass through untouched with
the original exit status.

```bash
scripts/git-push-with-fallback.sh -u origin claude/my-branch
```

Requires `GITHUB_MCP_PAT` in env — populated by `coo-bootstrap.sh`
at session start.

### Extending to other sub-agents

The pattern is copyable. For a new agent (e.g., Night's Watch, PM
agent), create a parallel vault (`NIGHTS_WATCH`, `PM`), a parallel
service account, and either (a) clone `coo-bootstrap.sh` with the
new vault name, or (b) parameterize via a `VADE_AGENT_VAULT` env var
when this list grows past two. Keep the fingerprint-validation step
— it's cheap insurance against a wrong vault binding.

## Deferred

- **Rust** — planned for Phase 3+ performance modules. Add via
  `rustup` when the first Rust crate lands in vade-core.
- **Python 3.12** — planned for scientific helpers (numpy/scipy).
  Add when a canvas artifact needs it for agent-side computation.
- **pnpm** — TBD; sticking with npm until there's a concrete reason
  to switch.

## Governance

See [vade-governance](https://github.com/coo-labs/vade-governance).
Changes to the runtime image affect every contributor's dev loop,
so BDFL review is required for any non-trivial modification.

## License

TBD — likely MIT or Apache-2.0, decided before the first external
contribution window.
