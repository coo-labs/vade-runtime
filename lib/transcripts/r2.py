"""R2 client + credential plumbing + sidecar I/O primitives.

Consolidates the _op_read / _r2_creds / _r2_client / list_keys quartet that was
copy-pasted across scripts/lib/list-r2-transcripts.py, scripts/lib/transcript-
meta-backfill.py, scripts/lib/transcript-fetch.py, and the lifecycle scripts.

Credentials sourced from:
  - env: R2_TRANSCRIPTS_ACCESS_KEY_ID, R2_TRANSCRIPTS_SECRET_ACCESS_KEY
  - 1Password: op://COO/r2-transcripts/{endpoint,bucket}

boto3 is imported lazily inside r2_client because the type stubs aren't
universally available and we want the package importable without boto3 for
pure-schema consumers (the coo-console worker hypothetically, the test
harness in CI before deps are installed).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mypy_boto3_s3.client import S3Client
else:
    S3Client = Any


class R2Error(RuntimeError):
    """Raised on R2 credential / coordinate resolution failures."""


@dataclass(frozen=True)
class R2Coordinates:
    """Resolved R2 access tuple — credentials + endpoint + bucket name."""

    access_key: str
    secret_key: str
    endpoint: str
    bucket: str


def _op_read(ref: str) -> str:
    """Read a 1Password secret by op-reference. Returns "" on any failure.

    Intentionally swallows errors — callers check the empty string and raise
    a domain-specific error with full context. This matches the existing
    scripts' behavior so the consolidated primitive is drop-in compatible.
    """
    if not shutil.which("op"):
        return ""
    try:
        out = subprocess.run(
            ["op", "read", ref],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return out.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def r2_coordinates() -> R2Coordinates:
    """Resolve R2 credentials + endpoint + bucket from env + 1Password.

    Raises R2Error with a remediation-pointing message on any missing piece.
    """
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        raise R2Error(
            "R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY "
            "missing — source ~/.vade/coo-env first"
        )
    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not endpoint or not bucket:
        raise R2Error(
            "op://COO/r2-transcripts/{endpoint,bucket} unreadable — "
            "verify OP_SERVICE_ACCOUNT_TOKEN and 1Password provisioning"
        )
    return R2Coordinates(
        access_key=access_key,
        secret_key=secret_key,
        endpoint=endpoint,
        bucket=bucket,
    )


def r2_client(coords: R2Coordinates | None = None) -> S3Client:
    """Build a boto3 S3 client wired for Cloudflare R2.

    If coords is None, calls r2_coordinates() to resolve them. boto3 imported
    lazily so the package is importable without boto3 installed.
    """
    if coords is None:
        coords = r2_coordinates()
    import boto3  # noqa: PLC0415 — lazy by design
    from botocore.config import Config  # noqa: PLC0415

    return boto3.client(
        "s3",
        endpoint_url=coords.endpoint,
        aws_access_key_id=coords.access_key,
        aws_secret_access_key=coords.secret_key,
        region_name="auto",
        config=Config(
            signature_version="s3v4",
            retries={"max_attempts": 3, "mode": "standard"},
        ),
    )


def list_keys(prefix: str, s3: S3Client | None = None) -> list[dict[str, Any]]:
    """Paginated list_objects_v2 under a prefix. Returns list of
    {key, size, last_modified} dicts (last_modified ISO-formatted).
    """
    coords: R2Coordinates | None = None
    if s3 is None:
        coords = r2_coordinates()
        s3 = r2_client(coords)
    bucket = coords.bucket if coords else _bucket_from_env_or_op()
    out: list[dict[str, Any]] = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            out.append(
                {
                    "key": obj["Key"],
                    "size": obj["Size"],
                    "last_modified": obj["LastModified"].isoformat(),
                }
            )
    return out


def _bucket_from_env_or_op() -> str:
    """Bucket name only — used when a caller passed their own s3 client.

    A caller that brings its own boto3 client still needs to tell us which
    bucket; we re-resolve it rather than threading it through every call site.
    """
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not bucket:
        raise R2Error("bucket name unresolvable via 1Password")
    return bucket


def read_sidecar(
    session_id: str,
    *,
    key_prefix: str = "rendered",
    s3: S3Client | None = None,
) -> dict[str, Any] | None:
    """Fetch and JSON-decode rendered/<key_prefix>/<sid>.meta.json from R2.

    Returns None on NoSuchKey (sidecar not yet written). Raises on any other
    boto3 error so callers don't conflate "missing" with "broken".
    """
    if s3 is None:
        s3 = r2_client()
    bucket = _bucket_from_env_or_op()
    key = f"{key_prefix}/{session_id}.meta.json"
    try:
        obj = s3.get_object(Bucket=bucket, Key=key)
    except Exception as e:
        if _is_no_such_key(e):
            return None
        raise
    body = obj["Body"].read()
    parsed = json.loads(body)
    if not isinstance(parsed, dict):
        raise R2Error(
            f"malformed sidecar at {key}: expected JSON object, got {type(parsed).__name__}"
        )
    return parsed


def _is_no_such_key(e: BaseException) -> bool:
    """True if a boto3-raised exception means 'the key does not exist'.

    botocore raises ClientError whose `response['Error']['Code']` is the
    canonical surface ('NoSuchKey' for missing keys); boto3 also exposes typed
    subclasses like s3.exceptions.NoSuchKey whose class name matches. Check
    both. Duck-typed on `.response` so we don't have to import botocore here.
    """
    response = getattr(e, "response", None)
    if isinstance(response, dict):
        code = response.get("Error", {}).get("Code", "")
        if code == "NoSuchKey" or code == "404":
            return True
    return type(e).__name__ == "NoSuchKey"


def write_sidecar(
    session_id: str,
    sidecar: dict[str, Any],
    *,
    key_prefix: str = "rendered",
    s3: S3Client | None = None,
) -> None:
    """Upload a sidecar dict as rendered/<key_prefix>/<sid>.meta.json.

    No safety guard against overwriting authoritative url_source — that's the
    caller's responsibility (use provenance.is_authoritative on the existing
    sidecar's url_source before calling this). Keeping the primitive dumb means
    every caller has to think about the invariant explicitly.
    """
    if s3 is None:
        s3 = r2_client()
    bucket = _bucket_from_env_or_op()
    key = f"{key_prefix}/{session_id}.meta.json"
    body = json.dumps(sidecar, indent=2, sort_keys=True).encode("utf-8")
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=body,
        ContentType="application/json",
    )
