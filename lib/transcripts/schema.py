"""Sidecar schema — Pydantic v2 boundary types for the rendered/<sid>.meta.json shape.

Canonical reference for what a v3 sidecar contains. The renderer at
scripts/lifecycle/session-end-transcript-render.py:compute_metadata constructs
this shape; reconcile scripts must validate against it; the coo-console worker
parses it for the /transcripts/ list page.

PARSER_VERSION is the schema version stored as renderer_version in the sidecar.
Sidecars at version <PARSER_VERSION are rerender-eligible.

History:
  v1: original — session_id, started_at, ended_at, duration_seconds,
      entry_count, *_turn_count, *_call_count, error_count,
      first_user_preview, session_url, renderer_version.
  v2: SKIPPED — some out-of-tree code paths wrote first_user_uuid alone with
      rv=2; we incremented past it to avoid collision.
  v3: + first_user_uuid, models, cwds, cc_version (briefing 039 + #388).
"""

from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, ConfigDict, Field

PARSER_VERSION: int = 3


class UrlSource(str, Enum):
    """Allowed url_source values. Mirrors provenance.VALID_URL_SOURCES.

    Kept in sync via tests/test_schema.py::test_url_source_enum_matches_provenance.
    """

    TITLE_FAST_PATH = "title-fast-path"
    HTML_EXTRACT = "html-extract"
    ENV_RECOVERY = "env-recovery"
    EXPORT_META_FALLBACK = "export-meta-fallback"
    SCAN_PR_LINK = "scan-pr-link"
    SCAN_TOOL_RESULT = "scan-tool-result"
    SCAN_PATTERN_A = "scan-pattern-a"
    SCAN_PROSE_VOTE = "scan-prose-vote"


class Sidecar(BaseModel):
    """Schema v3 sidecar — /transcripts/<sid>.meta.json on R2.

    Strict-by-default: extra fields raise (forces us to bump the schema rather
    than accreting silent fields). url_source is optional because v1 sidecars
    predate the taxonomy and the renderer omits it when _compute_session_url
    returned no source.
    """

    model_config = ConfigDict(extra="forbid", frozen=False, str_strip_whitespace=False)

    session_id: str
    started_at: str | None
    ended_at: str | None
    duration_seconds: int = Field(ge=0)
    entry_count: int = Field(ge=0)
    user_turn_count: int = Field(ge=0)
    assistant_turn_count: int = Field(ge=0)
    tool_call_count: int = Field(ge=0)
    error_count: int = Field(ge=0)
    first_user_preview: str
    first_user_uuid: str
    models: list[str]
    cwds: list[str]
    cc_version: str
    session_url: str | None
    renderer_version: int = Field(ge=1)
    url_source: UrlSource | None = None
