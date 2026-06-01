"""url_source taxonomy and reconcile invariants.

Originally inlined at scripts/transcript-url-backfill.py:157-169. Promoted to
the package because every mass-mutation tool that touches a sidecar's
session_url must respect the same boundary (briefing 039 Phase 3).

Briefing 039 "Constraints" §"Never automatically clear a session_url whose
url_source is..." is the binding rule. AUTHORITATIVE_URL_SOURCES is the
immutable set: a reconcile script MUST refuse to overwrite a sidecar whose
existing url_source is in this set. RECONCILE_ELIGIBLE_URL_SOURCES is the
mutable set: derived from prose-scanning votes that may be relitigated by a
later scan with stronger signals.
"""

from __future__ import annotations

AUTHORITATIVE_URL_SOURCES: frozenset[str] = frozenset(
    {
        "title-fast-path",
        "html-extract",
        "env-recovery",
        "export-meta-fallback",
        "claudeai-events-uuid",
    }
)

RECONCILE_ELIGIBLE_URL_SOURCES: frozenset[str] = frozenset(
    {
        "scan-pr-link",
        "scan-tool-result",
        "scan-pattern-a",
        "scan-prose-vote",
    }
)

VALID_URL_SOURCES: frozenset[str] = AUTHORITATIVE_URL_SOURCES | RECONCILE_ELIGIBLE_URL_SOURCES


def is_authoritative(url_source: str | None) -> bool:
    """True if the given url_source must never be overwritten by a reconcile.

    None and the empty string both return False — a sidecar with no url_source
    tag predates the taxonomy and is reconcile-eligible.
    """
    if not url_source:
        return False
    return url_source in AUTHORITATIVE_URL_SOURCES


def dominant_scan_source(parts: dict[str, int]) -> str:
    """Pick the canonical scan-* source for a URL given its signal breakdown.

    Priority: pr_link > tool_result_exact > pattern_a > prose_*. Inputs are the
    per-signal vote counts from the scan-transcript algorithm; the returned
    string is one of RECONCILE_ELIGIBLE_URL_SOURCES.
    """
    if parts.get("pr_link", 0) > 0:
        return "scan-pr-link"
    if parts.get("tool_result_exact", 0) > 0:
        return "scan-tool-result"
    if parts.get("pattern_a", 0) > 0:
        return "scan-pattern-a"
    return "scan-prose-vote"
