"""Tests for transcripts.r2 — credential plumbing + sidecar I/O.

No live R2 calls. Credential resolution tested via env + subprocess mocks;
sidecar I/O tested via a fake boto3-shaped client.
"""

from __future__ import annotations

import io
import json
from typing import Any, cast
from unittest.mock import patch

import pytest

from transcripts.r2 import (
    R2Coordinates,
    R2Error,
    list_keys,
    r2_coordinates,
    read_sidecar,
    write_sidecar,
)


def _s3(client: FakeS3Client) -> Any:
    """Cast a duck-typed fake into the S3Client position for mypy."""
    return cast(Any, client)


@pytest.fixture
def r2_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("R2_TRANSCRIPTS_ACCESS_KEY_ID", "ak-test")
    monkeypatch.setenv("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "sk-test")


class FakeS3Client:
    """boto3-S3-shaped fake. Records calls so tests can assert on them."""

    def __init__(self, objects: dict[str, bytes] | None = None) -> None:
        self.objects = objects or {}
        self.puts: list[dict[str, Any]] = []
        self.gets: list[dict[str, Any]] = []
        self.lists: list[dict[str, Any]] = []

    def get_object(self, *, Bucket: str, Key: str) -> dict[str, Any]:
        self.gets.append({"Bucket": Bucket, "Key": Key})
        if Key not in self.objects:
            raise FakeNoSuchKey(f"NoSuchKey: {Key}")
        return {"Body": io.BytesIO(self.objects[Key])}

    def put_object(
        self,
        *,
        Bucket: str,
        Key: str,
        Body: bytes,
        ContentType: str = "",
    ) -> dict[str, Any]:
        self.objects[Key] = Body
        self.puts.append(
            {
                "Bucket": Bucket,
                "Key": Key,
                "Body": Body,
                "ContentType": ContentType,
            }
        )
        return {}

    def get_paginator(self, op: str) -> FakePaginator:
        return FakePaginator(self)


class FakePaginator:
    def __init__(self, client: FakeS3Client) -> None:
        self.client = client

    def paginate(self, *, Bucket: str, Prefix: str) -> list[dict[str, Any]]:
        self.client.lists.append({"Bucket": Bucket, "Prefix": Prefix})
        contents = [
            {
                "Key": k,
                "Size": len(v),
                "LastModified": _FakeDateTime(),
            }
            for k, v in self.client.objects.items()
            if k.startswith(Prefix)
        ]
        return [{"Contents": contents}] if contents else [{}]


class _FakeDateTime:
    def isoformat(self) -> str:
        return "2026-06-01T00:00:00Z"


class FakeNoSuchKey(Exception):
    pass


class TestR2Coordinates:
    def test_missing_access_key_raises(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("R2_TRANSCRIPTS_ACCESS_KEY_ID", raising=False)
        monkeypatch.setenv("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "sk")
        with pytest.raises(R2Error, match="missing"):
            r2_coordinates()

    def test_missing_secret_key_raises(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("R2_TRANSCRIPTS_ACCESS_KEY_ID", "ak")
        monkeypatch.delenv("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", raising=False)
        with pytest.raises(R2Error, match="missing"):
            r2_coordinates()

    def test_missing_endpoint_raises(self, r2_env: None) -> None:
        with (
            patch("transcripts.r2._op_read", return_value=""),
            pytest.raises(R2Error, match="unreadable"),
        ):
            r2_coordinates()

    def test_full_resolution_returns_coordinates(self, r2_env: None) -> None:
        def fake_op(ref: str) -> str:
            return {
                "op://COO/r2-transcripts/endpoint": "https://r2.example",
                "op://COO/r2-transcripts/bucket": "bkt",
            }[ref]

        with patch("transcripts.r2._op_read", side_effect=fake_op):
            coords = r2_coordinates()
        assert coords == R2Coordinates(
            access_key="ak-test",
            secret_key="sk-test",
            endpoint="https://r2.example",
            bucket="bkt",
        )


class TestReadSidecar:
    def test_returns_none_on_missing(self) -> None:
        client = FakeS3Client()
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            result = read_sidecar("nope", s3=_s3(client))
        assert result is None

    def test_returns_parsed_json(self) -> None:
        payload = {"session_id": "abc", "renderer_version": 3}
        client = FakeS3Client(
            {
                "rendered/abc.meta.json": json.dumps(payload).encode("utf-8"),
            }
        )
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            result = read_sidecar("abc", s3=_s3(client))
        assert result == payload

    def test_respects_key_prefix(self) -> None:
        payload = {"session_id": "abc"}
        client = FakeS3Client(
            {
                "custom/abc.meta.json": json.dumps(payload).encode("utf-8"),
            }
        )
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            result = read_sidecar("abc", key_prefix="custom", s3=_s3(client))
        assert result == payload
        assert client.gets[0]["Key"] == "custom/abc.meta.json"


class TestWriteSidecar:
    def test_puts_serialized_json(self) -> None:
        client = FakeS3Client()
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            write_sidecar("abc", {"session_id": "abc"}, s3=_s3(client))
        assert len(client.puts) == 1
        put = client.puts[0]
        assert put["Key"] == "rendered/abc.meta.json"
        assert put["ContentType"] == "application/json"
        assert json.loads(put["Body"]) == {"session_id": "abc"}

    def test_sorts_keys(self) -> None:
        client = FakeS3Client()
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            write_sidecar("abc", {"z": 1, "a": 2}, s3=_s3(client))
        body = client.puts[0]["Body"].decode("utf-8")
        assert body.index('"a"') < body.index('"z"')


class TestListKeys:
    def test_returns_list_of_dicts(self) -> None:
        client = FakeS3Client(
            {
                "transcripts/2026/06/01/sid1.jsonl.gz.age": b"x",
                "transcripts/2026/06/01/sid2.jsonl.gz.age": b"yy",
            }
        )
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            results = list_keys("transcripts/2026/06/01/", s3=_s3(client))
        assert len(results) == 2
        keys = {r["key"] for r in results}
        assert keys == {
            "transcripts/2026/06/01/sid1.jsonl.gz.age",
            "transcripts/2026/06/01/sid2.jsonl.gz.age",
        }

    def test_filters_by_prefix(self) -> None:
        client = FakeS3Client(
            {
                "transcripts/2026/06/01/sid1.jsonl.gz.age": b"x",
                "rendered/sid1.html": b"y",
            }
        )
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            results = list_keys("rendered/", s3=_s3(client))
        assert len(results) == 1
        assert results[0]["key"] == "rendered/sid1.html"
