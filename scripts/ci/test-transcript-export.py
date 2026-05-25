#!/usr/bin/env python3
"""
CI smoke test for scripts/session-end-transcript-export.sh.

Asserts the export hook's contract end-to-end against an isolated
$HOME containing a synthetic jsonl with planted secrets:

  1. Hook resolves session id + jsonl path via CLAUDE_SESSION_ID
     override.
  2. Engine runs (transcript-redact.py via subprocess, hits captured
     to a temp file).
  3. gzip + age-encrypt succeed (subprocess returncode=0).
  4. Sidecar lands at <agent-logs>/transcripts/YYYY/MM/DD/<id>.meta.json
     with the expected JSON shape.
  5. redaction_hits non-zero for all three patterns added in this PR
     (r2-secret-access-key, age-secret-key, thinking-block).
  6. r2.uploaded == false (we run with VADE_TRANSCRIPT_EXPORT_DRY_RUN=1).
  7. ciphertext_sha256 is hex / 64 chars.

Same scanner-clean fixture-construction discipline as
test-transcript-redaction.py — secret shapes built via runtime
concatenation; no literal-shape strings on disk.

Exits 0 on full pass, 1 on any failure.
"""

from __future__ import annotations

import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
HOOK_SH = REPO_ROOT / "scripts" / "session-end-transcript-export.sh"


# Fixture builders — never write these literal strings to disk.
def _A(n: int) -> str:
    return "A" * n


def _r2_secret_hex64() -> str:
    # 64-char hex, lowercase. Cloudflare R2 secret-key shape.
    return "abcdef0123456789" * 4


def _age_identity() -> str:
    # AGE-SECRET-KEY-1 prefix + 58 uppercase Bech32-ish chars.
    return "AGE" + "-" + "SECRET" + "-" + "KEY" + "-" + "1" + _A(58)


def _build_synthetic_jsonl() -> str:
    today = datetime.datetime.now(datetime.timezone.utc).date()
    ts = f"{today.isoformat()}T00:00:00.000Z"
    events = [
        {"type": "user", "timestamp": ts, "content": "boot"},
        {
            "type": "assistant",
            "timestamp": ts,
            "content": [
                {
                    "type": "thinking",
                    "text": "should be wholesale-redacted regardless of length",
                },
                {"type": "text", "text": "ok"},
            ],
        },
        {
            "type": "system",
            "timestamp": ts,
            "content": (
                "export R2_TRANSCRIPTS_SECRET_ACCESS_KEY=" + _r2_secret_hex64()
            ),
        },
        {
            "type": "system",
            "timestamp": ts,
            "content": ("identity loaded: " + _age_identity()),
        },
    ]
    return "\n".join(json.dumps(e, separators=(",", ":")) for e in events) + "\n"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    if not HOOK_SH.is_file():
        fail(f"hook missing: {HOOK_SH}")
    if not shutil.which("age"):
        fail("age binary not on PATH (Dockerfile apt-get install age, or "
             "Ubuntu noble universe — see versions.lock)")

    sid = "test-session-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S")
    today = datetime.datetime.now(datetime.timezone.utc).date()

    with tempfile.TemporaryDirectory(prefix=f"transcript-export-test-{sid}-") as scratch:
        scratch_path = Path(scratch)
        # Mac-default layout that the hook prefers (Path.home() / GitHub / vade-app / coo-logs).
        fake_home = scratch_path / "home"
        agent_logs = fake_home / "GitHub" / "vade-app" / "coo-logs"
        projects = fake_home / ".claude" / "projects" / "test-proj"
        projects.mkdir(parents=True, exist_ok=True)
        agent_logs.mkdir(parents=True, exist_ok=True)

        jsonl_path = projects / f"{sid}.jsonl"
        jsonl_path.write_text(_build_synthetic_jsonl())

        env = {
            **os.environ,
            "HOME": str(fake_home),
            "CLAUDE_SESSION_ID": sid,
            "VADE_AGENT_LOGS_DIR": str(agent_logs),
            "VADE_TRANSCRIPT_EXPORT_DRY_RUN": "1",
            # Wipe any inherited R2 env so we never accidentally hit live R2.
            "R2_TRANSCRIPTS_ACCESS_KEY_ID": "",
            "R2_TRANSCRIPTS_SECRET_ACCESS_KEY": "",
            "TRANSCRIPTS_AGE_IDENTITY": "",
        }
        # The hook sources ~/.vade/coo-env if present — make sure that
        # file does NOT exist under the fake HOME so the test isolates
        # cleanly from any operator state.
        coo_env = fake_home / ".vade" / "coo-env"
        if coo_env.exists():
            coo_env.unlink()

        result = subprocess.run(
            ["bash", str(HOOK_SH)],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            fail(f"hook returned rc={result.returncode}; stderr:\n{result.stderr}")

        # The wrapper detaches the Python child via `setsid -f` so it can
        # survive harness teardown under CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
        # (coo-harness#181 / #182). The sidecar is written asynchronously
        # after the wrapper returns. Poll for up to 60s; the synthetic jsonl
        # is small (~4 events) so under normal conditions the export
        # completes in 1–2s.
        date_path = f"{today.year:04d}/{today.month:02d}/{today.day:02d}"
        sidecar = agent_logs / "transcripts" / date_path / f"{sid}.meta.json"
        err = agent_logs / "transcripts" / date_path / f"{sid}.export-error.txt"
        import time
        deadline = time.time() + 60.0
        while time.time() < deadline:
            if err.is_file():
                fail(f"unexpected export-error.txt:\n{err.read_text()[:1000]}")
            if sidecar.is_file():
                break
            time.sleep(0.25)
        if err.is_file():
            fail(f"unexpected export-error.txt:\n{err.read_text()[:1000]}")
        if not sidecar.is_file():
            tree = list((agent_logs / "transcripts").rglob("*"))
            log_dir = fake_home / ".vade" / "transcript-export-logs"
            log_dump = ""
            if log_dir.is_dir():
                logs = sorted(log_dir.glob("*.log"))
                if logs:
                    log_dump = "\n--- detached child log ---\n" + logs[-1].read_text()[-2000:]
            fail(f"sidecar not at {sidecar} after 60s wait; tree={tree}; stderr:\n{result.stderr}{log_dump}")

        meta = json.loads(sidecar.read_text())

        # Shape assertions.
        for key in (
            "schema_version", "parser_version", "session_id",
            "exported_at", "events_processed",
            "bytes_pre_redaction", "bytes_post_redaction",
            "bytes_post_gzip", "bytes_ciphertext", "ciphertext_sha256",
            "redaction_hits", "r2",
            "age_recipient_file", "age_recipient_pubkey",
        ):
            if key not in meta:
                fail(f"sidecar missing key: {key} (got {sorted(meta.keys())})")

        pubkey = meta["age_recipient_pubkey"]
        if not (isinstance(pubkey, str) and pubkey.startswith("age1") and len(pubkey) >= 50):
            fail(f"age_recipient_pubkey not a plausible age v1 pubkey: {pubkey!r}")

        if meta["session_id"] != sid:
            fail(f"session_id mismatch: {meta['session_id']!r} != {sid!r}")
        if meta["schema_version"] != 2:
            fail(f"schema_version != 2: {meta['schema_version']}")
        if meta["events_processed"] != 4:
            fail(f"events_processed != 4: {meta['events_processed']}")
        if meta["r2"].get("uploaded") is not False:
            fail(f"dry-run should set r2.uploaded=false; got {meta['r2']}")
        # coo-harness#207 fix shape (b): meta_key must be set in r2_target,
        # pointing at the flat-by-id R2 prefix used for the canonical record.
        expected_meta_key = f"transcripts/meta/{sid}.meta.json"
        if meta["r2"].get("meta_key") != expected_meta_key:
            fail(
                f"r2.meta_key mismatch: got {meta['r2'].get('meta_key')!r}, "
                f"expected {expected_meta_key!r}"
            )

        sha = meta["ciphertext_sha256"]
        if not (isinstance(sha, str) and len(sha) == 64
                and all(c in "0123456789abcdef" for c in sha)):
            fail(f"ciphertext_sha256 not 64-hex: {sha!r}")
        if meta["bytes_ciphertext"] <= 0:
            fail(f"bytes_ciphertext non-positive: {meta['bytes_ciphertext']}")

        hits = meta["redaction_hits"]
        for required in ("thinking-block", "r2-secret-access-key", "age-secret-key"):
            if hits.get(required, 0) < 1:
                fail(f"redaction_hits[{required!r}] expected ≥1, got {hits.get(required)}; full hits={hits}")

    print(textwrap.dedent("""\
        OK: transcript-export-hook smoke
          - sidecar shape: 12+ keys
          - schema_version: 2
          - r2.meta_key set (flat-by-id; #207 fix shape (b))
          - events_processed: 4
          - thinking-block redacted
          - r2-secret-access-key redacted
          - age-secret-key redacted
          - ciphertext sha256 valid
          - dry-run skipped R2 upload
        """))
    return 0


if __name__ == "__main__":
    sys.exit(main())
