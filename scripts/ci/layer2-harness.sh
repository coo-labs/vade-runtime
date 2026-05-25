#!/usr/bin/env bash
# Layer-2 SDK-driven harness (vade-runtime#85, Move 5 of the boot-
# architecture audit commission vade-app/vade-coo-memory#762).
#
# Companion to scripts/ci/run-bootstrap-regression.sh (Layer-1). Where
# Layer-1 exercises the cloud bootstrap chain at script granularity
# under PATH-shadowed mocks, Layer-2 builds the real Docker image from
# the PR diff and spawns a live Claude Agent SDK session inside the
# container. The SDK reads settings.json, fires the SessionStart hook
# chain, runs coo-identity-digest, and produces the digest output an
# agent would actually see at boot. The harness then asks the SDK
# session a single post-merge-confirmation question
#   ↳ "report whether `summary.ok=true`"
# and parses the answer.
#
# Workflow inputs (env from full-harness-layer2.yml):
#   IMG                  — Docker image tag built by the workflow step
#   ANTHROPIC_API_KEY    — secret; SDK auth
#   LAYER2_AGENT_MODEL   — model name (default sonnet-4-5)
#   PR_NUMBER            — pull-request number for sticky-comment scope
#   PR_SHA               — checkout sha (informational, in the summary)
#   RUN_ID, RUN_URL      — Actions run linkage
#
# Outputs (read by the workflow):
#   /tmp/layer2-harness-result.json       — {ok, cost_usd, model, …}
#   /tmp/layer2-harness-summary.md        — sticky-comment body
#   /tmp/layer2-harness-sdk-output.jsonl  — raw SDK stream-json
#   /tmp/layer2-harness-integrity-check.json — the integrity report
#                                              the SDK boot produced
#   /tmp/layer2-harness-build.log         — bootstrap build.log tail
#
# Cost: the SDK in --output-format stream-json emits a terminal
# `result` message that carries `total_cost_usd` and per-message
# token counts. The harness parses that into the summary so the PR
# comment shows the live per-run cost without a model + assumption
# back-of-envelope. The Phase C PR body still carries an a-priori
# back-of-envelope so the workflow's first surfaceable cost is the
# real one once a green run posts.
set -euo pipefail

IMG="${IMG:?IMG env required (Docker image tag built by the workflow)}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY env required}"
MODEL="${LAYER2_AGENT_MODEL:-claude-sonnet-4-5-20250929}"
PR_NUMBER="${PR_NUMBER:-}"
PR_SHA="${PR_SHA:-unknown}"
RUN_ID="${RUN_ID:-local}"
RUN_URL="${RUN_URL:-}"

OUT_RESULT="/tmp/layer2-harness-result.json"
OUT_SUMMARY="/tmp/layer2-harness-summary.md"
OUT_STREAM="/tmp/layer2-harness-sdk-output.jsonl"
OUT_INTEGRITY="/tmp/layer2-harness-integrity-check.json"
OUT_BUILDLOG="/tmp/layer2-harness-build.log"

log() { printf '[ci-layer2-harness] %s\n' "$*"; }

# Ensure result files exist even on early failure so the workflow's
# upload-artifacts step has something to grab.
: > "$OUT_STREAM"
: > "$OUT_BUILDLOG"
printf '{}\n' > "$OUT_INTEGRITY"
printf '{"ok":false,"phase":"init","detail":"harness did not complete"}\n' > "$OUT_RESULT"

# ── 1. Stage repo + mocks into a host scratch dir we'll bind-mount ──
SCRATCH="$(mktemp -d /tmp/layer2-scratch.XXXXXX)"
# mktemp -d creates the dir as mode 0700, owned by the host (GitHub
# Actions runner) UID. The Dockerfile drops to USER node (uid 1000),
# which can't traverse a 0700 host dir even via bind mount — `bash
# /workspace/layer2-entrypoint.sh` then fails with "Permission denied"
# (exit 126). 0755 lets the container's non-root user read the staged
# entrypoint + repo while the host's tmpdir-removal trap still works
# (the host owner retains write).
chmod 0755 "$SCRATCH"
trap 'rm -rf "$SCRATCH" 2>/dev/null || true' EXIT

log "Scratch dir: $SCRATCH"
log "Image: $IMG"
log "Model: $MODEL"

# Stage the PR working tree into $SCRATCH/vade-runtime so the container
# sees the same code that built the image, plus the CI-only helpers
# (mocks, etc.) that aren't baked into the image.
SOURCE_DIR="${GITHUB_WORKSPACE:-$PWD}"
( cd "$SOURCE_DIR" && tar c \
    --exclude='./.git' \
    --exclude='./node_modules' \
    . ) | ( cd "$SCRATCH" && mkdir -p vade-runtime && cd vade-runtime && tar x )

# Sibling repo stubs (mirror run-bootstrap-regression.sh §1):
# integrity-check C1 needs CLAUDE.md to symlink-target; F1–F4 skip
# cleanly without .git. Real cloud uses the live vade-coo-memory
# clone; CI uses a stub for the same shape Layer-1 uses.
mkdir -p "$SCRATCH/vade-coo-memory/coo" "$SCRATCH/vade-coo-memory/identity"
cat > "$SCRATCH/vade-coo-memory/CLAUDE.md" <<'STUB'
# vade-coo-memory CLAUDE.md (Layer-2 harness stub)

Placeholder so ensure_workspace_identity_link has a target and C1
passes. Real CLAUDE.md is at vade-app/vade-coo-memory:main/CLAUDE.md.
STUB
mkdir -p "$SCRATCH/vade-core/.claude"

# Drop the SDK prompt and entrypoint into the scratch dir so the
# container picks them up via the bind-mount.
cat > "$SCRATCH/layer2-prompt.txt" <<'PROMPT'
You are running inside a Layer-2 CI harness for the VADE boot
architecture. The cloud-setup chain has already run in fake-env mode
before you started. Your single task is to read the integrity-check
report and answer one question.

Procedure:

1. Read /home/user/.vade-cloud-state/integrity-check.json. If the file
   does not exist, that itself is a fail: report it and stop.

2. Parse `summary.ok` (boolean) and `summary.degraded` (array). If you
   cannot parse the file as JSON, report "PARSE_ERROR" with the first
   200 chars of file content and stop.

3. Emit your verdict as a single final-message line of EXACTLY one of:

       LAYER2_VERDICT: OK
       LAYER2_VERDICT: DEGRADED <comma,separated,invariant,ids>
       LAYER2_VERDICT: PARSE_ERROR
       LAYER2_VERDICT: MISSING_INTEGRITY_FILE

   followed by a one-paragraph human summary referencing the failing
   invariant IDs (if any) and the recovery sequence in the COO digest
   banner.

Constraints:
  - Use only the Bash and Read tools.
  - Do NOT attempt any other operations (no git, no gh, no editing).
  - Do NOT load the COO identity or post to Mem0 — you are a
    confirmation probe, not a COO session.
  - One-shot: do the minimum to answer the question.
PROMPT

cat > "$SCRATCH/layer2-entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
# Inside-container entrypoint for the Layer-2 harness.
#
# Stages /home/user, runs Layer-1's run-bootstrap-regression.sh as the
# fake-env bootstrap driver (so we don't fork the mock surface), then
# spawns `claude -p` against the post-merge-confirmation prompt.
set -uo pipefail

log() { printf '[layer2-entry] %s\n' "$*"; }

# Run Layer-1 directly against the bind-mounted source. Layer-1 already
# stages SOURCE_DIR → $VADE_CI_WORKSPACE_ROOT/vade-runtime and stubs
# vade-coo-memory + vade-core itself (it's designed to be the
# single staging entrypoint). The harness pre-copying into /home/user
# and then pointing Layer-1 at /home/user/vade-runtime triggers
# Layer-1's self-clobber guard (SOURCE_DIR == RUNTIME_DST → exit 2),
# caught on vrt#272 third run. /workspace is the bind-mount target
# (mounted by docker run -v from the host $SCRATCH).
# VADE_CI_WORKSPACE_ROOT=/home/user matches the production cloud
# path the audit cares about (vade-runtime / vade-coo-memory / vade-core
# live there). Let VADE_CI_TEST_HOME default to /tmp/vade-ci-home —
# Layer-1 rm -rf's TEST_HOME at line 145 to provision an isolated
# HOME; if TEST_HOME == WORKSPACE_ROOT, that wipe destroys the staged
# repos right after they were staged (caught on vrt#272 fourth run:
# "bash: /home/user/vade-runtime/scripts/cloud-setup.sh: No such file
# or directory"). The integrity-check.json still lands at
# $WORKSPACE_ROOT/.vade-cloud-state/ — that's pinned to WORKSPACE_ROOT,
# not TEST_HOME, so the Layer-2 SDK probe's prompt path stays valid.
export VADE_CI_WORKSPACE_ROOT=/home/user
log "Running Layer-1 bootstrap driver inside container"
set +e
bash /workspace/vade-runtime/scripts/ci/run-bootstrap-regression.sh \
  /workspace/vade-runtime > /tmp/layer1-driver.log 2>&1
DRIVER_RC=$?
set -e
log "Layer-1 driver exit: $DRIVER_RC"
# Tail the driver log on failure so the surface isn't dependent on
# artifact upload (caught on vrt#272 third run, where the only
# visible error was "Layer-1 driver exit: 2" with no diagnostic).
if [ "$DRIVER_RC" -ne 0 ]; then
  log "Layer-1 driver log tail:"
  tail -40 /tmp/layer1-driver.log | sed 's/^/[layer1] /'
  log "Diagnostic dump on driver failure:"
  log "  TEST_HOME = ${VADE_CI_TEST_HOME:-/tmp/vade-ci-home} (default)"
  log "  HOME (current shell) = $HOME"
  for cand in /tmp/vade-ci-home/.claude/settings.json \
              /home/user/.claude/settings.json \
              /root/.claude/settings.json; do
    if [ -f "$cand" ]; then
      log "  settings.json at $cand (size=$(wc -c <"$cand")B):"
      log "    first 400 chars:"
      head -c 400 "$cand" | sed 's/^/      /'
      log "    env keys via jq:"
      jq -r '.env // {} | keys[] // empty' "$cand" 2>&1 \
        | head -20 | sed 's/^/      /' || true
    fi
  done
fi
# Capture build.log + integrity-check.json for the host-side artifact
# upload. Layer-1 writes them under $VADE_CI_WORKSPACE_ROOT/.vade-cloud-state.
if [ -f /home/user/.vade-cloud-state/integrity-check.json ]; then
  cp -f /home/user/.vade-cloud-state/integrity-check.json /workspace/layer2-integrity-check.json
fi
if [ -f /home/user/.vade-cloud-state/build.log ]; then
  cp -f /home/user/.vade-cloud-state/build.log /workspace/layer2-build.log
fi
# Forward the Layer-1 driver log too so any post-mortem has it.
cp -f /tmp/layer1-driver.log /workspace/layer2-driver.log 2>/dev/null || true

if [ "$DRIVER_RC" -ne 0 ]; then
  log "Layer-1 driver failed; emitting fail marker. SDK will not run."
  printf '%s\n' '{"type":"result","subtype":"layer1_driver_failed","is_error":true,"total_cost_usd":0}' \
    > /workspace/layer2-sdk-output.jsonl
  exit 2
fi

# Drop a Layer-2-only CLAUDE.md into /workspace/cwd so the SDK session
# is one-shot and doesn't read the full COO boot reading order — we're
# a confirmation probe, not a COO session. The prompt itself names the
# scope; this is belt-and-suspenders.
mkdir -p /home/user/layer2-cwd
cat > /home/user/layer2-cwd/CLAUDE.md <<'CWDMD'
# Layer-2 confirmation probe

Constrained one-shot session inside the boot-architecture-audit CI.
Read the prompt and answer the integrity-check question. Do nothing else.
CWDMD

# Run the SDK session. stream-json gives us the structured result
# message we parse for total_cost_usd; output-format text would lose
# that.
PROMPT_FILE=/workspace/layer2-prompt.txt
log "Running claude -p (model=${LAYER2_AGENT_MODEL:-unset})"
set +e
cd /home/user/layer2-cwd
# CLAUDECODE in the env tells Claude Code it's already inside a Claude
# Code session; unset so the nested `claude -p` works (mirrors the
# skill-creator improve_description.py pattern).
unset CLAUDECODE
claude -p \
  --model "${LAYER2_AGENT_MODEL:-claude-sonnet-4-5-20250929}" \
  --output-format stream-json \
  --verbose \
  --permission-mode bypassPermissions \
  --allowed-tools 'Bash,Read' \
  < "$PROMPT_FILE" \
  > /workspace/layer2-sdk-output.jsonl 2>/workspace/layer2-sdk-stderr.log
SDK_RC=$?
set -e
log "claude -p exit: $SDK_RC"
exit "$SDK_RC"
ENTRYPOINT
chmod +x "$SCRATCH/layer2-entrypoint.sh"

# ── 2. Run the harness inside the container ─────────────────────────
log "docker run …"
# Bind /workspace, pass the API key and model name through env. We
# explicitly do NOT pass the runner's gitconfig / ssh / .claude — the
# image must produce a Mac/cloud-shaped environment from scratch.
# --rm keeps the host clean; --network bridge is the default and is
# fine for the fake-env mocks (no external traffic except SDK API).
set +e
# Run as root inside the container. The image's Dockerfile drops to
# USER node (uid 1000) — fine for devcontainer use, but the entrypoint
# needs to `mkdir /home/user` (requires write on /) and write under
# /workspace (bind-mount owned by the host runner's UID; node can't
# write there). Production cloud runs Claude Code as root — caught the
# regression on vrt#272's second run (mkdir/cp failures, then /workspace
# Permission denied on the fail-marker write). Running as root mirrors
# the production environment we're testing.
docker run --rm \
  --user 0:0 \
  -e ANTHROPIC_API_KEY \
  -e LAYER2_AGENT_MODEL="$MODEL" \
  -v "$SCRATCH:/workspace" \
  --workdir /workspace \
  "$IMG" \
  bash /workspace/layer2-entrypoint.sh
RUN_RC=$?
set -e
log "docker run exit: $RUN_RC"

# ── 3. Salvage artifacts from $SCRATCH back to /tmp ─────────────────
if [ -f "$SCRATCH/layer2-integrity-check.json" ]; then
  cp -f "$SCRATCH/layer2-integrity-check.json" "$OUT_INTEGRITY"
fi
if [ -f "$SCRATCH/layer2-build.log" ]; then
  cp -f "$SCRATCH/layer2-build.log" "$OUT_BUILDLOG"
fi
if [ -f "$SCRATCH/layer2-sdk-output.jsonl" ]; then
  cp -f "$SCRATCH/layer2-sdk-output.jsonl" "$OUT_STREAM"
fi

# ── 4. Parse the SDK stream for verdict + cost ──────────────────────
# stream-json line format: each line is one message; the terminal
# message has type=="result" and carries total_cost_usd + duration_ms.
# The assistant's final-text message carries our LAYER2_VERDICT: line.
LAYER2_AGENT_MODEL="$MODEL" OUT_RESULT="$OUT_RESULT" \
OUT_STREAM_PATH="$OUT_STREAM" OUT_INTEGRITY_PATH="$OUT_INTEGRITY" \
node -e '
  const fs = require("fs");
  const streamPath = process.env.OUT_STREAM_PATH;
  const integrityPath = process.env.OUT_INTEGRITY_PATH;
  let lines = [];
  try {
    lines = fs.readFileSync(streamPath, "utf8")
      .split(/\r?\n/)
      .filter(Boolean);
  } catch (e) {
    lines = [];
  }
  let resultMsg = null;
  let assistantText = "";
  for (const ln of lines) {
    let m;
    try { m = JSON.parse(ln); } catch { continue; }
    if (m && m.type === "result") {
      resultMsg = m;
    }
    if (m && m.type === "assistant" && m.message && m.message.content) {
      for (const block of m.message.content) {
        if (block.type === "text" && typeof block.text === "string") {
          assistantText += block.text + "\n";
        }
      }
    }
  }
  let verdict = null;
  let verdictDegraded = [];
  // Anchor to end-of-line so the optional degraded-id list does not
  // accidentally swallow the next sentence in the assistant text.
  // The prompt mandates EXACTLY this one-line form.
  const verdictMatch = assistantText.match(/^[ \t]*LAYER2_VERDICT:[ \t]*([A-Z_]+)(?:[ \t]+([\w,\-]+))?[ \t]*$/m);
  if (verdictMatch) {
    verdict = verdictMatch[1];
    if (verdictMatch[2]) {
      verdictDegraded = verdictMatch[2].split(",").map(s => s.trim()).filter(Boolean);
    }
  }
  // Special-case the layer1_driver_failed marker the entrypoint
  // writes when the bootstrap driver bombed before the SDK could run.
  if (!verdict && resultMsg && resultMsg.subtype === "layer1_driver_failed") {
    verdict = "LAYER1_DRIVER_FAILED";
  }
  let integrity = null;
  try {
    integrity = JSON.parse(fs.readFileSync(integrityPath, "utf8"));
  } catch (e) {
    integrity = null;
  }
  const summaryOk = integrity && integrity.summary && integrity.summary.ok === true;
  const summaryDegraded = (integrity && integrity.summary && integrity.summary.degraded) || [];
  const cost = resultMsg && typeof resultMsg.total_cost_usd === "number"
    ? resultMsg.total_cost_usd : null;
  const duration_ms = resultMsg && resultMsg.duration_ms;
  const num_turns = resultMsg && resultMsg.num_turns;
  const usage = resultMsg && resultMsg.usage;
  const sdkError = resultMsg && resultMsg.is_error === true;
  // ok iff: the agent reported OK AND summary.ok is true. Either side
  // missing → fail.
  const ok = verdict === "OK" && summaryOk === true;
  const out = {
    ok,
    verdict: verdict || "NO_VERDICT",
    summary_ok: summaryOk,
    summary_degraded: summaryDegraded,
    agent_reported_degraded: verdictDegraded,
    cost_usd: cost,
    duration_ms,
    num_turns,
    usage,
    sdk_is_error: sdkError,
    model: process.env.LAYER2_AGENT_MODEL || null,
  };
  fs.writeFileSync(process.env.OUT_RESULT, JSON.stringify(out, null, 2) + "\n");
  process.exit(0);
'

# ── 5. Render the sticky comment ────────────────────────────────────
PR_DISPLAY="${PR_NUMBER:-(no PR)}"
RUN_URL="${RUN_URL:-(local)}"
PR_SHA_DISPLAY="${PR_SHA:-unknown}"
PR_NUMBER="$PR_DISPLAY" RUN_URL="$RUN_URL" PR_SHA="$PR_SHA_DISPLAY" OUT_RESULT="$OUT_RESULT" OUT_SUMMARY="$OUT_SUMMARY" node -e '
  const fs = require("fs");
  const res = JSON.parse(fs.readFileSync(process.env.OUT_RESULT, "utf8"));
  const fmtCost = (c) => (c == null) ? "n/a" : ("$" + c.toFixed(4));
  const fmtDur = (ms) => (ms == null) ? "n/a" : (ms < 1000 ? ms + " ms" : (ms / 1000).toFixed(1) + " s");
  const head = res.ok ? "PASS ✅" : "FAIL ❌";
  const lines = [];
  lines.push("<!-- layer2-harness-comment -->");
  lines.push("## Layer-2 full-harness — " + head);
  lines.push("");
  lines.push("Built the runtime Docker image from this PR, ran " +
             "`scripts/cloud-setup.sh` end-to-end inside a fresh " +
             "container (Layer-1 fake-env mocks), then spawned a " +
             "Claude Agent SDK session and asked it to confirm " +
             "`summary.ok=true` in `integrity-check.json`.");
  lines.push("");
  lines.push("### Result");
  lines.push("");
  lines.push("| Field | Value |");
  lines.push("| --- | --- |");
  lines.push("| Agent verdict | `" + res.verdict + "`" + (res.agent_reported_degraded && res.agent_reported_degraded.length ? " (" + res.agent_reported_degraded.join(", ") + ")" : "") + " |");
  lines.push("| `summary.ok` | `" + String(res.summary_ok) + "` |");
  if (res.summary_degraded && res.summary_degraded.length) {
    lines.push("| Degraded invariants | `" + res.summary_degraded.join("`, `") + "` |");
  }
  lines.push("| Cost (this run) | **" + fmtCost(res.cost_usd) + "** |");
  lines.push("| Duration | " + fmtDur(res.duration_ms) + " |");
  lines.push("| Turns | " + (res.num_turns == null ? "n/a" : String(res.num_turns)) + " |");
  lines.push("| Model | `" + (res.model || "unknown") + "` |");
  if (res.usage) {
    const u = res.usage;
    const ins = u.input_tokens || 0;
    const outs = u.output_tokens || 0;
    const cReads = u.cache_read_input_tokens || 0;
    const cWrites = u.cache_creation_input_tokens || 0;
    lines.push("| Tokens (in / out / cache-read / cache-write) | " +
               ins + " / " + outs + " / " + cReads + " / " + cWrites + " |");
  }
  lines.push("| Run | [" + process.env.RUN_URL + "](" + process.env.RUN_URL + ") |");
  lines.push("| Commit | `" + (process.env.PR_SHA || "unknown") + "` |");
  lines.push("");
  lines.push("### Cost model");
  lines.push("");
  lines.push("Per-run cost is dominated by SDK tokens (Sonnet 4.5 default) " +
             "plus a small fixed cost for the GH Actions Linux minute used " +
             "by the `docker build --no-cache` step. Default cost ceiling " +
             "proposed in the audit plan: **$5/PR** (sticky for boot-impacting " +
             "paths; override via `ci:full-harness` label for explicit pulls).");
  lines.push("");
  lines.push("- A back-of-envelope pre-spike estimate is in the PR body; this " +
             "comment carries the **actual** per-run figure once a run completes.");
  lines.push("- The harness does NOT fail on cost overage — it surfaces and " +
             "informs the next-cycle ceiling tuning. If a single run exceeds " +
             "the ceiling materially, file a follow-up to either tighten the " +
             "prompt scope or re-pin a smaller model.");
  lines.push("");
  lines.push("### Workflow");
  lines.push("");
  lines.push("`.github/workflows/full-harness-layer2.yml` — auto-fires on PR " +
             "touch of `scripts/coo-bootstrap.sh`, `scripts/cloud-setup.sh`, " +
             "`scripts/lib/common.sh`, `scripts/session-start-sync.sh`, " +
             "`scripts/integrity-check.sh`, `.claude/settings.json`, " +
             "`.mcp.json`, or `Dockerfile`. Manual override-up via the " +
             "`ci:full-harness` PR label.");
  lines.push("");
  lines.push("Tracked at vade-app/vade-runtime#85 (closed by Move 5 of " +
             "vade-app/vade-coo-memory#762).");
  fs.writeFileSync(process.env.OUT_SUMMARY, lines.join("\n") + "\n");
'

log "Wrote summary: $OUT_SUMMARY"
log "Wrote result:  $OUT_RESULT"

# ── 6. Exit code reflects ok ────────────────────────────────────────
# Env-prefixed like the parse + render blocks above. Without the
# prefix, node -e sees process.env.OUT_RESULT as undefined and
# readFileSync throws ERR_INVALID_ARG_TYPE (caught the regression
# on the workflow's own introduction PR — vrt#272 first run).
OK="$(OUT_RESULT="$OUT_RESULT" node -e '
  const fs = require("fs");
  const r = JSON.parse(fs.readFileSync(process.env.OUT_RESULT, "utf8"));
  process.stdout.write(r.ok ? "1" : "0");
' || echo 0)"
if [ "$OK" = "1" ]; then
  log "PASS — Layer-2 harness confirms summary.ok=true"
  exit 0
fi
log "FAIL — Layer-2 harness did not confirm summary.ok=true (see sticky comment)"
exit 1
