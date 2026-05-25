#!/usr/bin/env bash
# Render integrity-check.json + the runner's pass/fail decision into a
# markdown summary suitable for a PR comment. Called by
# run-bootstrap-regression.sh; idempotent and safe to invoke standalone
# for local previewing.
#
# Args:
#   $1  integrity-check.json path
#   $2  runner-result JSON (ok/degraded/allowed/passed/total)
#   $3  output markdown path
#   $4  allowlist (comma-separated invariant ids; informational only)
set -euo pipefail

INTEGRITY="$1"
RESULT="$2"
OUT="$3"
ALLOWLIST="${4:-}"

node -e '
  const fs = require("fs");
  const [integrityPath, resultPath, outPath, allowlistRaw] = process.argv.slice(1);
  const data = JSON.parse(fs.readFileSync(integrityPath, "utf8"));
  const result = JSON.parse(fs.readFileSync(resultPath, "utf8"));
  const allow = (allowlistRaw || "").split(",").map(s => s.trim()).filter(Boolean);
  const ok = result.ok;
  const lines = [];
  lines.push("<!-- bootstrap-regression-comment -->");
  lines.push("## Bootstrap regression — " + (ok ? "PASS ✅" : "FAIL ❌"));
  lines.push("");
  lines.push(
    "Ran `scripts/cloud-setup.sh` → `scripts/session-start-sync.sh` → " +
    "`scripts/integrity-check.sh` in fake-env mode (mock `op` + " +
    "`curl`-to-github-api)."
  );
  lines.push("");
  lines.push("- **Invariants**: `" + result.passed + "/" + result.total + "` passed");
  if (result.degraded.length) {
    lines.push("- **Degraded (failing this PR)**: `" + result.degraded.join("`, `") + "`");
  }
  if (result.allowed.length) {
    lines.push("- **Allowlisted (would-be-degraded but tolerated)**: `" + result.allowed.join("`, `") + "`");
  }
  if (allow.length) {
    lines.push("- **Configured allowlist**: `" + allow.join("`, `") + "`");
  }
  lines.push("- **Session id**: `" + (data.session_id || "unknown") + "`");
  lines.push("- **Checked at**: `" + (data.checked_at || "unknown") + "`");
  lines.push("");

  // Per-group breakdown.
  const symbol = (v) => {
    if (v.info) return ":information_source:";
    if (v.skipped) return ":fast_forward:";
    return v.ok ? ":white_check_mark:" : ":x:";
  };
  for (const g of Object.keys(data.groups).sort()) {
    lines.push("### Group " + g);
    lines.push("");
    lines.push("| ID | Status | Detail |");
    lines.push("| --- | --- | --- |");
    for (const k of Object.keys(data.groups[g]).sort()) {
      const v = data.groups[g][k];
      const status = symbol(v) + " " + (v.info ? "info" : v.skipped ? "skip" : v.ok ? "pass" : "fail");
      const detail = String(v.detail || "")
        .replace(/\|/g, "\\|")
        .replace(/\r?\n/g, " ")
        .slice(0, 240);
      lines.push("| " + k + " | " + status + " | " + detail + " |");
    }
    lines.push("");
  }

  lines.push("---");
  lines.push("");
  lines.push("Workflow: `.github/workflows/bootstrap-regression.yml`. " +
             "Re-run by pushing to this PR or using the workflow_dispatch trigger. " +
             "Tracked at coo-labs/vade-runtime#86.");

  fs.writeFileSync(outPath, lines.join("\n") + "\n");
' "$INTEGRITY" "$RESULT" "$OUT" "$ALLOWLIST"

echo "[ci-bootstrap-regression] Wrote markdown summary to $OUT"
