#!/usr/bin/env bash
# coo-boot-incident-collect.sh
# Forensic collector for the 2026-05-30 suspected Opus-4.8 boot-behavior incident
# (coo-labs/coo-harness#357). Captures the redacted transcript, env, system-prompt
# inputs, and the ground-truth model id; archives; opens one PR to coo-logs.
#
# Redaction is delegated to the EXISTING, CI-tested pipeline
# (coo-harness/scripts/lib/transcript-redact.sh) — do not reinvent it.
#
# Run once, report the printed PR URL, and STOP.
# Dry-run: INCIDENT_DRY_RUN=1 bash coo-boot-incident-collect.sh
set -uo pipefail

SID="${CLAUDE_CODE_SESSION_ID:-unknown}"; SID8="${SID:0:8}"
DAY="2026-05-30_opus-4.8-boot"; DRY="${INCIDENT_DRY_RUN:-0}"

# --- locate checkouts ---
COO_LOGS=""; for c in "${VADE_COO_LOGS_DIR:-}" /home/user/coo-logs; do
  [ -n "$c" ] && [ -d "$c/.git" ] && { COO_LOGS="$c"; break; }; done
[ -z "$COO_LOGS" ] && { echo "FATAL: coo-logs not found"; exit 3; }
REDACT=""; for r in "${VADE_RUNTIME_DIR:-/home/user/coo-harness}/scripts/lib/transcript-redact.sh" /home/user/coo-harness/scripts/lib/transcript-redact.sh; do
  [ -x "$r" ] && { REDACT="$r"; break; }; done
[ -z "$REDACT" ] && { echo "FATAL: transcript-redact.sh not found"; exit 3; }

# --- locate transcript jsonl ---
JSONL=""; for base in "$HOME/.claude/projects" /root/.claude/projects /home/user/.claude/projects; do
  [ -d "$base" ] || continue
  f="$(find "$base" -maxdepth 2 -name "${SID}.jsonl" 2>/dev/null | head -1)"
  [ -n "$f" ] && { JSONL="$f"; break; }; done

WORK="$(mktemp -d)"; PAYLOAD="$WORK/payload"; SPI="$PAYLOAD/system-prompt-inputs"
mkdir -p "$SPI"
echo "[collect] sid=$SID8 redactor=$REDACT transcript=${JSONL:-<none>} dry=$DRY"

redact() { "$REDACT" 2>/dev/null; }  # stdin -> redacted stdout, full pipeline

# --- transcript (redacted) + ground-truth model id ---
if [ -n "$JSONL" ]; then
  redact < "$JSONL" > "$PAYLOAD/transcript.redacted.jsonl"
  python3 - "$JSONL" "$PAYLOAD/summary.json" "$SID8" <<'PY'
import json,sys
jsonl,out,sid=sys.argv[1:4]
models=set(); last=None
for line in open(jsonl,encoding="utf-8",errors="replace"):
    try: r=json.loads(line)
    except: continue
    m=(r.get("message") or {}).get("model")
    if m: models.add(m); last=m
json.dump({"session_id_8":sid,"models_seen":sorted(models),
  "model_last_turn":last,"model_switched_mid_session":len(models)>1,
  "note":"model id is ground truth from transcript per-turn message.model"},
  open(out,"w"),indent=2)
print("[collect] models=%s switched=%s"%(",".join(sorted(models)) or "?",len(models)>1))
PY
else
  echo '{"session_id_8":"'"$SID8"'","error":"transcript jsonl not found"}' > "$PAYLOAD/summary.json"
fi

# --- env (redacted) ---
env | sort | redact > "$PAYLOAD/env.redacted.txt"

# --- system-prompt inputs (redacted) ---
for f in "$HOME/.claude/output-styles/coo.md" /home/user/.claude/output-styles/coo.md; do
  [ -f "$f" ] && redact < "$f" > "$SPI/output-style-coo.md" && break; done
for f in "$HOME/.claude/settings.json" /home/user/.claude/settings.json; do
  [ -f "$f" ] && redact < "$f" > "$SPI/settings.json" && break; done
RC="$(readlink -f /home/user/CLAUDE.md 2>/dev/null)"; [ -f "$RC" ] && redact < "$RC" > "$SPI/CLAUDE.md.resolved.md"
[ -f "${CLAUDE_CODE_DIAGNOSTICS_FILE:-}" ] && redact < "$CLAUDE_CODE_DIAGNOSTICS_FILE" > "$SPI/diag.redacted.log"
{ echo "version=${CLAUDE_CODE_VERSION:-?}"; echo "runner=${CLAUDE_CODE_ENVIRONMENT_RUNNER_VERSION:-?}";
  echo "entrypoint=${CLAUDE_CODE_ENTRYPOINT:-?}"; echo "cwd=$(pwd)";
  echo "claude_md_symlink=$(readlink /home/user/CLAUDE.md 2>/dev/null)"; } > "$SPI/runtime.txt"

cat > "$PAYLOAD/README.md" <<EOF
# Boot-behavior incident capture — session $SID8

For coo-labs/coo-harness#357 (suspected Opus-4.8 boot-behavior regression).
Agent ran \`coo-boot-incident-collect.sh\` and stopped — the collector is fixed
code so the capture itself does not vary by model.

Redaction: delegated to coo-harness/scripts/lib/transcript-redact.sh (CI-tested).
Model id: ground truth from the transcript — see summary.json.

Contents: transcript.redacted.jsonl, env.redacted.txt, summary.json,
system-prompt-inputs/ (output-style, settings.json, resolved CLAUDE.md, diag, runtime).
EOF

# --- archive ---
DEST="$COO_LOGS/incidents/$DAY/$SID8"; mkdir -p "$DEST"
( cd "$PAYLOAD" && tar -czf "$WORK/$SID8.tar.gz" . )
cp "$WORK/$SID8.tar.gz" "$DEST/$SID8.tar.gz"
cp "$PAYLOAD/summary.json" "$DEST/summary.json"
cp "$PAYLOAD/README.md" "$DEST/README.md"
echo "[collect] archive: $DEST/$SID8.tar.gz ($(du -h "$DEST/$SID8.tar.gz"|cut -f1))"; cat "$DEST/summary.json"

[ "$DRY" = "1" ] && { echo "[collect] DRY_RUN — no PR. Inspect $DEST"; exit 0; }

# --- branch / commit / push / PR (unique per session) ---
BR="incident/opus48-boot/$SID8"
git -C "$COO_LOGS" checkout -B "$BR" >/dev/null 2>&1
git -C "$COO_LOGS" add "incidents/$DAY/$SID8" >/dev/null 2>&1
git -C "$COO_LOGS" -c user.name="Coo" -c user.email="coo@vade-app.dev" \
  commit -q -m "incident(opus48-boot): diagnostic capture $SID8"
for i in 1 2 3 4; do git -C "$COO_LOGS" push -u origin "$BR" && break || sleep $((2**i)); done
gh pr create --repo coo-labs/coo-logs --base main --head "$BR" \
  --title "incident(opus48-boot): diagnostic capture $SID8 [model in summary.json]" \
  --body "Forensic boot-behavior capture for coo-labs/coo-harness#357. Model id is ground-truth from the transcript (incidents/$DAY/$SID8/summary.json). Redacted via the standard transcript-redact pipeline. Agent ran the collector and stopped.

Closes: n/a"
