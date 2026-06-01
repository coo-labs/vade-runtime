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
    than accreting silent fields).

    Backward compatibility: v3-only fields (first_user_uuid, models, cwds,
    cc_version) have defaults so the model can validate v1/v2 sidecars from
    the historical R2 backlog (~20 of 240 measured as of 2026-06-01). A
    reconcile pass that fetches every sidecar through read_sidecar and
    validates with Sidecar must not abort on the first pre-v3 entry.
    url_source is None when the renderer's _compute_session_url returned no
    source.

    Serialization: callers writing to R2 should use
    `model_dump(exclude_none=True)` to match the renderer's omit-when-falsy
    pattern (session-end-transcript-render.py:934 only sets url_source when
    truthy). The default model_dump() emits explicit JSON null, which would
    silently change the on-the-wire shape that downstream tools depend on.
    """

    model_config = ConfigDict(extra="forbid")

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
    session_url: str | None
    renderer_version: int = Field(ge=1)
    first_user_uuid: str = ""
    models: list[str] = Field(default_factory=list)
    cwds: list[str] = Field(default_factory=list)
    cc_version: str = ""
    url_source: UrlSource | None = None
