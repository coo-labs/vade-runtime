"""Tests for transcripts.schema — Sidecar v3 boundary types."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from transcripts.provenance import VALID_URL_SOURCES
from transcripts.schema import PARSER_VERSION, Sidecar, UrlSource

VALID_SIDECAR_MIN: dict[str, object] = {
    "session_id": "abc123",
    "started_at": "2026-06-01T00:00:00",
    "ended_at": "2026-06-01T01:00:00",
    "duration_seconds": 3600,
    "entry_count": 42,
    "user_turn_count": 10,
    "assistant_turn_count": 10,
    "tool_call_count": 5,
    "error_count": 0,
    "first_user_preview": "hello",
    "first_user_uuid": "uuid-1",
    "models": ["claude-opus-4-7"],
    "cwds": ["/home/user"],
    "cc_version": "1.2.3",
    "session_url": "https://claude.ai/code/session_01abc",
    "renderer_version": 3,
}


class TestParserVersion:
    def test_is_three(self) -> None:
        assert PARSER_VERSION == 3


class TestUrlSourceEnum:
    def test_matches_provenance_set(self) -> None:
        enum_values = {member.value for member in UrlSource}
        assert enum_values == set(VALID_URL_SOURCES)


class TestSidecarValid:
    def test_minimal_valid_sidecar_parses(self) -> None:
        sc = Sidecar.model_validate(VALID_SIDECAR_MIN)
        assert sc.session_id == "abc123"
        assert sc.renderer_version == 3
        assert sc.url_source is None

    def test_with_url_source(self) -> None:
        payload = {**VALID_SIDECAR_MIN, "url_source": "html-extract"}
        sc = Sidecar.model_validate(payload)
        assert sc.url_source == UrlSource.HTML_EXTRACT

    def test_null_started_at(self) -> None:
        payload = {**VALID_SIDECAR_MIN, "started_at": None, "ended_at": None}
        sc = Sidecar.model_validate(payload)
        assert sc.started_at is None

    def test_null_session_url(self) -> None:
        payload = {**VALID_SIDECAR_MIN, "session_url": None}
        sc = Sidecar.model_validate(payload)
        assert sc.session_url is None


class TestSidecarRejections:
    def test_negative_count_rejected(self) -> None:
        payload = {**VALID_SIDECAR_MIN, "entry_count": -1}
        with pytest.raises(ValidationError):
            Sidecar.model_validate(payload)

    def test_renderer_version_zero_rejected(self) -> None:
        payload = {**VALID_SIDECAR_MIN, "renderer_version": 0}
        with pytest.raises(ValidationError):
            Sidecar.model_validate(payload)

    def test_extra_field_rejected(self) -> None:
        payload = {**VALID_SIDECAR_MIN, "spurious_key": "x"}
        with pytest.raises(ValidationError):
            Sidecar.model_validate(payload)

    def test_invalid_url_source_rejected(self) -> None:
        payload = {**VALID_SIDECAR_MIN, "url_source": "not-a-real-source"}
        with pytest.raises(ValidationError):
            Sidecar.model_validate(payload)

    def test_missing_required_field_rejected(self) -> None:
        payload = {k: v for k, v in VALID_SIDECAR_MIN.items() if k != "session_id"}
        with pytest.raises(ValidationError):
            Sidecar.model_validate(payload)


class TestSidecarRoundTrip:
    def test_dump_round_trips(self) -> None:
        original = Sidecar.model_validate(VALID_SIDECAR_MIN)
        dumped = original.model_dump()
        reparsed = Sidecar.model_validate(dumped)
        assert reparsed == original
