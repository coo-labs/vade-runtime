#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
transcript-pull-local.py — bulk-download and decrypt every available
session transcript from R2 for local inspection.

Operator's "give me everything for ad-hoc analysis" surface. Not part
of any cloud pipeline. Run on your laptop; the cloud SessionEnd hook
handles canonical export. The decrypted .jsonl files this script
produces are the redacted plaintext that already lives in R2 — i.e.
the rawest thing the storage tier holds.

Reads credentials from 1Password via the `op` CLI (must be signed in
or have OP_SERVICE_ACCOUNT_TOKEN set):
  op://COO/r2-transcripts/access-key-id
  op://COO/r2-transcripts/secret-access-key
  op://COO/r2-transcripts/endpoint
  op://COO/r2-transcripts/bucket
  op://COO/transcripts-age-key/credential

Idempotent: skips any session whose `<session_id>.jsonl` already
exists in the output dir with non-zero size. To force a re-pull,
delete the file (or the whole dir) and re-run.

Atomic per session: download + decrypt into a temp dir, then
os.rename onto the final path. An interrupted run never leaves a
half-written file on the visible surface.

Usage:
  scripts/transcript-pull-local.py [--out DIR] [--prefix PREFIX] [-v]

  --out DIR       Output directory. Default: ./transcripts/
  --prefix PFX    R2 key prefix to scan. Default: transcripts/
                  (Restrict e.g. transcripts/2026/05/ for one month.)
  -v, --verbose   Print one line per session including skips.

Dependencies (installed by you on the local machine):
  - `op` (1Password CLI), signed in
  - `age` binary on PATH
  - `uv` (the shebang runs the script under uv with boto3 pinned)
"""

from __future__ import annotations

import argparse
import gzip
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CIPHERTEXT_SUFFIX = ".jsonl.gz.age"
META_PREFIX_SEGMENT = "transcripts/meta/"


def _err(msg: str) -> None:
    sys.stderr.write(f"[transcript-pull] {msg}\n")


def _op_read(ref: str) -> str:
    try:
        out = subprocess.run(
            ["op", "read", ref],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
        return out.stdout.strip()
    except FileNotFoundError as e:
        raise RuntimeError(
            "1Password CLI (`op`) not found on PATH; install it from "
            "https://developer.1password.com/docs/cli/get-started/"
        ) from e
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"`op read {ref}` failed (exit {e.returncode}); "
            "ensure 1Password CLI is signed in (`eval $(op signin)`) "
            "or OP_SERVICE_ACCOUNT_TOKEN is set, and the slot exists. "
            f"stderr: {e.stderr.strip()!r}"
        ) from e
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"`op read {ref}` timed out after 15s") from e


def _preflight() -> None:
    missing = [tool for tool in ("op", "age") if not shutil.which(tool)]
    if missing:
        raise RuntimeError(
            "missing required tool(s) on PATH: "
            + ", ".join(missing)
            + " — install before running"
        )


def _load_creds() -> dict[str, str]:
    return {
        "access_key": _op_read("op://COO/r2-transcripts/access-key-id"),
        "secret_key": _op_read("op://COO/r2-transcripts/secret-access-key"),
        "endpoint": _op_read("op://COO/r2-transcripts/endpoint"),
        "bucket": _op_read("op://COO/r2-transcripts/bucket"),
        "age_identity": _op_read("op://COO/transcripts-age-key/credential"),
    }


def _r2_client(creds: dict[str, str]):
    import boto3
    from botocore.config import Config

    return boto3.client(
        "s3",
        endpoint_url=creds["endpoint"],
        aws_access_key_id=creds["access_key"],
        aws_secret_access_key=creds["secret_key"],
        region_name="auto",
        config=Config(
            signature_version="s3v4",
            retries={"max_attempts": 3, "mode": "standard"},
        ),
    )


def _list_ciphertext_keys(s3, bucket: str, prefix: str) -> list[tuple[str, str]]:
    """Return [(key, session_id), ...] for every ciphertext under `prefix`,
    excluding the `transcripts/meta/` JSON sidecars."""
    out: list[tuple[str, str]] = []
    for page in s3.get_paginator("list_objects_v2").paginate(
        Bucket=bucket, Prefix=prefix
    ):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.startswith(META_PREFIX_SEGMENT):
                continue
            if not key.endswith(CIPHERTEXT_SUFFIX):
                continue
            session_id = Path(key).name[: -len(CIPHERTEXT_SUFFIX)]
            out.append((key, session_id))
    return out


def _age_decrypt(ciphertext: Path, dst_gz: Path, identity: str) -> None:
    fd, id_path_str = tempfile.mkstemp(prefix="transcript-age-id-", suffix=".key")
    id_path = Path(id_path_str)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(identity)
            if not identity.endswith("\n"):
                f.write("\n")
        subprocess.run(
            ["age", "-d", "-i", str(id_path), "-o", str(dst_gz), str(ciphertext)],
            check=True,
            capture_output=True,
        )
    finally:
        try:
            id_path.unlink(missing_ok=True)
        except OSError:
            pass


def _gunzip(src: Path, dst: Path) -> None:
    with gzip.open(src, "rb") as fin, open(dst, "wb") as fout:
        shutil.copyfileobj(fin, fout)


def _pull_one(
    s3,
    bucket: str,
    key: str,
    session_id: str,
    age_identity: str,
    out_dir: Path,
    workdir: Path,
) -> None:
    """Download, decrypt, gunzip — atomic rename onto out_dir/<id>.jsonl."""
    ciphertext = workdir / f"{session_id}.jsonl.gz.age"
    gz = workdir / f"{session_id}.jsonl.gz"
    plaintext = workdir / f"{session_id}.jsonl"

    s3.download_file(bucket, key, str(ciphertext))
    _age_decrypt(ciphertext, gz, age_identity)
    _gunzip(gz, plaintext)

    final = out_dir / f"{session_id}.jsonl"
    os.replace(plaintext, final)

    for tmp in (ciphertext, gz):
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def main() -> int:
    p = argparse.ArgumentParser(
        prog="transcript-pull-local",
        description=__doc__.split("\n\n")[0],
    )
    p.add_argument(
        "--out",
        default="./transcripts",
        help="Output directory for decrypted .jsonl files (default: ./transcripts/)",
    )
    p.add_argument(
        "--prefix",
        default="transcripts/",
        help="R2 key prefix to scan (default: transcripts/). "
        "Narrow e.g. transcripts/2026/05/ to pull one month.",
    )
    p.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print one line per session (including skipped).",
    )
    args = p.parse_args()

    try:
        _preflight()
        creds = _load_creds()
    except RuntimeError as e:
        _err(str(e))
        return 1

    out_dir = Path(args.out).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    s3 = _r2_client(creds)

    try:
        entries = _list_ciphertext_keys(s3, creds["bucket"], args.prefix)
    except Exception as e:
        _err(f"R2 list failed: {e}")
        return 1

    if not entries:
        _err(f"no ciphertext objects under prefix={args.prefix!r}")
        return 0

    print(
        f"[transcript-pull] {len(entries)} ciphertext keys under {args.prefix!r}; "
        f"output → {out_dir}"
    )

    downloaded = 0
    skipped = 0
    failed = 0

    with tempfile.TemporaryDirectory(prefix="transcript-pull-") as tmp:
        workdir = Path(tmp)
        for key, session_id in entries:
            final = out_dir / f"{session_id}.jsonl"
            if final.exists() and final.stat().st_size > 0:
                skipped += 1
                if args.verbose:
                    print(f"  skip   {session_id}  ({final.name} exists)")
                continue
            try:
                _pull_one(
                    s3,
                    creds["bucket"],
                    key,
                    session_id,
                    creds["age_identity"],
                    out_dir,
                    workdir,
                )
                downloaded += 1
                if args.verbose:
                    print(f"  pull   {session_id}  ← {key}")
            except subprocess.CalledProcessError as e:
                failed += 1
                stderr = (e.stderr or b"").decode("utf-8", errors="replace").strip()
                _err(
                    f"decrypt/process failed for {session_id} (key={key}): "
                    f"exit {e.returncode} stderr={stderr!r}"
                )
            except Exception as e:
                failed += 1
                _err(f"pull failed for {session_id} (key={key}): {e}")

    print(
        f"[transcript-pull] done — downloaded={downloaded} "
        f"skipped={skipped} failed={failed}"
    )
    return 0 if failed == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
