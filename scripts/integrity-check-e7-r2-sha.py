#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
integrity-check-e7-r2-sha.py — R2 ciphertext SHA-mismatch sample probe.

Samples the K most-recent post-fix coo-logs meta.json files,
GETs each R2 object, computes SHA256 over the bytes, compares to
meta.ciphertext_sha256. Output one line on stdout:

  OK|<sampled>|<mismatches>|<errors>     — probe completed
  SKIP|<reason>                            — preconditions unmet
  ERROR|<message>                          — probe configuration failed

Stderr carries per-row detail when --verbose. Always exits 0 on
probe-completion (a mismatch finding does not exit nonzero); exits
nonzero only on internal/configuration errors.

Additive observability over the now-fixed pipeline: coo-harness#212
landed atomic IfNoneMatch first-write-wins in
session-end-transcript-export.py at 2026-05-03T09:01:47Z (closing #204
+ MEMO 2026-05-03-bgk3). Mismatches in post-fix sessions would
indicate a regression in the encrypt-then-PUT flow; pre-fix sessions
are filtered out via the post-cutoff parameter.

coo-harness#209 — proposed E7 boot-time integrity invariant.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime
from pathlib import Path


def _emit(line: str) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _parse_iso(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--logs-dir",
        default="/home/user/coo-logs/transcripts",
        help="Path to coo-logs/transcripts root.",
    )
    ap.add_argument(
        "--sample-k",
        type=int,
        default=3,
        help="Number of most-recent eligible meta.json files to sample.",
    )
    ap.add_argument(
        "--post-cutoff",
        default="2026-05-03T09:01:47+00:00",
        help="Only sample meta.json with exported_at >= this (ISO8601). "
        "Default = coo-harness#212 merge time.",
    )
    ap.add_argument("--verbose", action="store_true", help="Per-row detail to stderr.")
    args = ap.parse_args()

    access = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access or not secret:
        _emit("SKIP|R2_TRANSCRIPTS_ACCESS_KEY_ID/SECRET_ACCESS_KEY missing")
        return 0

    logs_dir = Path(args.logs_dir)
    if not logs_dir.is_dir():
        _emit(f"SKIP|logs-dir not found: {logs_dir}")
        return 0

    try:
        cutoff = _parse_iso(args.post_cutoff)
    except ValueError:
        _emit(f"ERROR|invalid --post-cutoff: {args.post_cutoff}")
        return 1

    candidates: list[tuple[datetime, Path, dict]] = []
    for meta_path in logs_dir.rglob("*.meta.json"):
        try:
            data = json.loads(meta_path.read_text())
        except Exception:
            continue
        if not data.get("r2", {}).get("uploaded"):
            continue
        ea = data.get("exported_at", "")
        if not ea:
            continue
        try:
            exported_at = _parse_iso(ea)
        except ValueError:
            continue
        if exported_at < cutoff:
            continue
        candidates.append((exported_at, meta_path, data))

    if not candidates:
        _emit("SKIP|no eligible post-cutoff meta.json's")
        return 0

    candidates.sort(key=lambda x: x[0], reverse=True)
    sample = candidates[: args.sample_k]

    try:
        import boto3
        from botocore.config import Config
        from botocore.exceptions import ClientError
    except ImportError as e:
        _emit(f"ERROR|boto3 import failed: {e}")
        return 1

    first = sample[0][2]
    endpoint = first.get("r2", {}).get("endpoint")
    bucket = first.get("r2", {}).get("bucket")
    if not endpoint or not bucket:
        _emit("ERROR|endpoint/bucket missing from meta.r2")
        return 1

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access,
        aws_secret_access_key=secret,
        region_name="auto",
        config=Config(
            signature_version="s3v4",
            retries={"max_attempts": 2, "mode": "standard"},
        ),
    )

    mismatches = 0
    errors = 0
    for exported_at, meta_path, data in sample:
        key = data.get("r2", {}).get("key", "")
        expected = data.get("ciphertext_sha256", "")
        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            body = obj["Body"].read()
            actual = hashlib.sha256(body).hexdigest()
            if actual != expected:
                mismatches += 1
                if args.verbose:
                    print(
                        f"MISMATCH {key}: expected={expected[:12]}… actual={actual[:12]}…",
                        file=sys.stderr,
                    )
            elif args.verbose:
                print(f"MATCH {key}: sha={actual[:12]}…", file=sys.stderr)
        except ClientError as e:
            errors += 1
            code = e.response.get("Error", {}).get("Code", "unknown")
            if args.verbose:
                print(f"ERROR {key}: ClientError {code}", file=sys.stderr)
        except Exception as e:
            errors += 1
            if args.verbose:
                print(f"ERROR {key}: {type(e).__name__}: {e}", file=sys.stderr)

    _emit(f"OK|{len(sample)}|{mismatches}|{errors}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
