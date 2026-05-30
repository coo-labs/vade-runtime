#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
transcript-url-backfill.py — coo-labs/coo-console#23 (post-comment algorithm).

One-shot patcher that backfills `session_url` into R2
`rendered/<sid>.meta.json` sidecars for the slice of historical
sessions that produced a per-session auto-meta-PR in coo-logs.

Algorithm (per the 2026-05-30 comment on coo-console#23):

  1. Load coo-labs/coo-logs/index/session_artifacts.json — the
     nightly reverse index from session URLs to authored artifacts.
  2. Walk it once; for every coo-logs PR whose title matches
     `meta: auto-commit sidecar for <UUID>`, build the map
     sid -> session_url.
  3. List R2 `<key-prefix>/*.meta.json` sidecars; for each missing
     `session_url`, look the sid up in the map; on hit, fetch,
     patch in place, PUT back.

Coverage caveat: only sids landed by per-session auto-meta-PRs are
in scope. Sids landed by bulk PRs, or never auto-PR'd at all
(pre-pipeline ciphertext-only sessions backfilled by
`transcript-render-backfill.py`), are out of scope for this script
— they need a different recovery path (e.g. the lossy heuristic
from the original #23 body) or are accepted as gap. Empirically
about 16% of the missing-session_url population sits in the
in-scope slice (see #23 comment thread for the cohort breakdown).

Usage:
  transcript-url-backfill.py [--limit N] [--dry-run] [--include-populated]
                             [--key-prefix rendered]

Env:
  R2_TRANSCRIPTS_ACCESS_KEY_ID      — R2 access key
  R2_TRANSCRIPTS_SECRET_ACCESS_KEY  — R2 secret key
Read at run time via `op`:
  op://COO/r2-transcripts/endpoint
  op://COO/r2-transcripts/bucket
Reads `coo-labs/coo-logs` contents via `gh api` (PAT-routed by
gh-coo-wrap.sh; no env-token prefix).

Exit 0 on success (including --dry-run); 1 on arg/env error; 2 if
any per-sidecar patch failed. Per-sidecar failures log to stderr
and continue — fail-soft.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

SESSION_ID_RE = re.compile(
    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"
)
RENDERED_KEY_RE = re.compile(r"/([a-f0-9-]{36})\.meta\.json$")
AUTO_META_PR_TITLE_RE = re.compile(
    r"meta:\s*auto-commit\s+sidecar\s+for\s+"
    r"([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})",
    re.IGNORECASE,
)


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[transcript-url-backfill] {msg}\n")


def _op_read(ref: str) -> str:
    if not shutil.which("op"):
        return ""
    try:
        out = subprocess.run(
            ["op", "read", ref],
            check=True, capture_output=True, text=True, timeout=10,
        )
        return out.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def _r2_client():
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        raise RuntimeError(
            "R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY missing"
        )
    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not endpoint or not bucket:
        raise RuntimeError(
            "R2 endpoint or bucket not readable from op://COO/r2-transcripts/{endpoint,bucket}"
        )
    import boto3
    from botocore.config import Config

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="auto",
        config=Config(signature_version="s3v4", retries={"max_attempts": 3, "mode": "standard"}),
    )
    return s3, bucket


def _load_session_artifacts_index() -> dict:
    try:
        out = subprocess.run(
            ["gh", "api",
             "repos/coo-labs/coo-logs/contents/index/session_artifacts.json",
             "-H", "Accept: application/vnd.github.raw"],
            check=True, capture_output=True, text=True, timeout=30,
        )
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"gh api failed: rc={e.returncode} stderr={e.stderr.strip()[:200]}"
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("gh api timed out after 30s")
    return json.loads(out.stdout)


def _build_sid_to_url_map(index: dict) -> dict[str, str]:
    out: dict[str, str] = {}
    for session in index.get("sessions", []):
        url = (session.get("session_url") or "").strip()
        if not url:
            continue
        for art in session.get("artifacts", []):
            if art.get("type") != "pr" or art.get("repo") != "coo-labs/coo-logs":
                continue
            hit = AUTO_META_PR_TITLE_RE.search(art.get("title", ""))
            if not hit:
                continue
            sid = hit.group(1).lower()
            existing = out.get(sid)
            if existing and existing != url:
                _stderr(
                    f"conflict for {sid}: existing={existing} new={url} — keeping first"
                )
                continue
            out[sid] = url
    return out


def _list_candidate_sidecars(
    s3, bucket: str, key_prefix: str, include_populated: bool
) -> list[tuple[str, str]]:
    """Return [(sid, r2_key), ...] for sidecars eligible for patching."""
    cands: list[tuple[str, str]] = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=f"{key_prefix}/"):
        for obj in page.get("Contents", []) or []:
            key = obj["Key"]
            m = RENDERED_KEY_RE.search(key)
            if not m or not SESSION_ID_RE.match(m.group(1)):
                continue
            sid = m.group(1)
            try:
                body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
                meta = json.loads(body)
            except Exception as e:
                _stderr(f"  skip {sid}: failed to read sidecar: {e}")
                continue
            if meta.get("session_url") and not include_populated:
                continue
            cands.append((sid, key))
    return cands


def _patch_one(s3, bucket: str, key: str, session_url: str) -> tuple[bool, str]:
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        meta = json.loads(body)
    except Exception as e:
        return False, f"read failed: {e}"
    prev = (meta.get("session_url") or "").strip()
    if prev == session_url:
        return True, "no-op (already set)"
    meta["session_url"] = session_url
    body_new = json.dumps(meta, separators=(",", ":")).encode("utf-8")
    try:
        s3.put_object(
            Bucket=bucket, Key=key, Body=body_new,
            ContentType="application/json; charset=utf-8",
        )
    except Exception as e:
        return False, f"put failed: {e}"
    return True, (f"{prev!r} -> {session_url}" if prev else f"set -> {session_url}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__.splitlines()[1] if __doc__ else "",
    )
    p.add_argument("--limit", type=int, default=None,
                   help="patch at most N sidecars (default: all hits)")
    p.add_argument("--dry-run", action="store_true",
                   help="print sid<TAB>session_url assignments without patching")
    p.add_argument("--include-populated", action="store_true",
                   help="also consider sidecars whose session_url is already set")
    p.add_argument("--key-prefix", default="rendered",
                   help="R2 key prefix for rendered HTML/meta (default: rendered)")
    args = p.parse_args(argv)

    try:
        s3, bucket = _r2_client()
    except RuntimeError as e:
        _stderr(str(e))
        return 1

    _stderr("loading coo-labs/coo-logs/index/session_artifacts.json…")
    try:
        index = _load_session_artifacts_index()
    except RuntimeError as e:
        _stderr(str(e))
        return 1
    sid_to_url = _build_sid_to_url_map(index)
    _stderr(f"  {len(sid_to_url)} sids carry a per-session auto-meta-PR")

    key_prefix = args.key_prefix.rstrip("/")
    _stderr(f"scanning r2://{bucket}/{key_prefix}/ for sidecars…")
    candidates = _list_candidate_sidecars(s3, bucket, key_prefix, args.include_populated)
    _stderr(
        f"  {len(candidates)} sidecar(s) eligible "
        f"({'missing or populated' if args.include_populated else 'missing'} session_url)"
    )

    hits = [(sid, key, sid_to_url[sid]) for sid, key in candidates if sid in sid_to_url]
    _stderr(
        f"  {len(hits)} resolvable via title-fast-path "
        f"({len(candidates) - len(hits)} unresolved)"
    )

    if args.limit is not None:
        hits = hits[: args.limit]
        _stderr(f"  limited to {len(hits)}")

    if args.dry_run:
        for sid, _key, url in hits:
            sys.stdout.write(f"{sid}\t{url}\n")
        return 0

    ok = 0
    failed = 0
    for i, (sid, key, url) in enumerate(hits, 1):
        _stderr(f"[{i}/{len(hits)}] {sid}")
        success, detail = _patch_one(s3, bucket, key, url)
        if success:
            ok += 1
            _stderr(f"  OK · {detail}")
        else:
            failed += 1
            _stderr(f"  FAIL · {detail}")

    _stderr(f"done: ok={ok} fail={failed} total={len(hits)}")
    return 0 if failed == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
