"""Tests for transcripts.provenance.

The invariants here are load-bearing (briefing 039 §"Never automatically
clear..."). Test the set memberships explicitly rather than just round-tripping
constants — if someone moves a tag from one set to the other in a future PR,
this should fail loudly.
"""

from __future__ import annotations

from transcripts.provenance import (
    AUTHORITATIVE_URL_SOURCES,
    RECONCILE_ELIGIBLE_URL_SOURCES,
    VALID_URL_SOURCES,
    dominant_scan_source,
    is_authoritative,
)


class TestAuthoritativeSet:
    def test_contains_title_fast_path(self) -> None:
        assert "title-fast-path" in AUTHORITATIVE_URL_SOURCES

    def test_contains_html_extract(self) -> None:
        assert "html-extract" in AUTHORITATIVE_URL_SOURCES

    def test_contains_env_recovery(self) -> None:
        assert "env-recovery" in AUTHORITATIVE_URL_SOURCES

    def test_contains_export_meta_fallback(self) -> None:
        assert "export-meta-fallback" in AUTHORITATIVE_URL_SOURCES

    def test_exact_size(self) -> None:
        assert len(AUTHORITATIVE_URL_SOURCES) == 4

    def test_disjoint_from_reconcile_eligible(self) -> None:
        assert AUTHORITATIVE_URL_SOURCES.isdisjoint(RECONCILE_ELIGIBLE_URL_SOURCES)


class TestReconcileEligibleSet:
    def test_contains_scan_pr_link(self) -> None:
        assert "scan-pr-link" in RECONCILE_ELIGIBLE_URL_SOURCES

    def test_contains_scan_tool_result(self) -> None:
        assert "scan-tool-result" in RECONCILE_ELIGIBLE_URL_SOURCES

    def test_contains_scan_pattern_a(self) -> None:
        assert "scan-pattern-a" in RECONCILE_ELIGIBLE_URL_SOURCES

    def test_contains_scan_prose_vote(self) -> None:
        assert "scan-prose-vote" in RECONCILE_ELIGIBLE_URL_SOURCES

    def test_exact_size(self) -> None:
        assert len(RECONCILE_ELIGIBLE_URL_SOURCES) == 4


class TestValidUnion:
    def test_is_union_of_both_sets(self) -> None:
        assert VALID_URL_SOURCES == AUTHORITATIVE_URL_SOURCES | RECONCILE_ELIGIBLE_URL_SOURCES

    def test_size_is_sum(self) -> None:
        assert len(VALID_URL_SOURCES) == len(AUTHORITATIVE_URL_SOURCES) + len(
            RECONCILE_ELIGIBLE_URL_SOURCES
        )


class TestIsAuthoritative:
    def test_none_is_not_authoritative(self) -> None:
        assert is_authoritative(None) is False

    def test_empty_string_is_not_authoritative(self) -> None:
        assert is_authoritative("") is False

    def test_authoritative_tag_returns_true(self) -> None:
        assert is_authoritative("html-extract") is True

    def test_reconcile_eligible_tag_returns_false(self) -> None:
        assert is_authoritative("scan-pr-link") is False

    def test_unknown_tag_returns_false(self) -> None:
        assert is_authoritative("nonsense-source") is False


class TestDominantScanSource:
    def test_pr_link_wins_over_all(self) -> None:
        parts = {"pr_link": 1, "tool_result_exact": 10, "pattern_a": 10, "prose": 10}
        assert dominant_scan_source(parts) == "scan-pr-link"

    def test_tool_result_beats_pattern_and_prose(self) -> None:
        parts = {"pr_link": 0, "tool_result_exact": 1, "pattern_a": 10, "prose": 10}
        assert dominant_scan_source(parts) == "scan-tool-result"

    def test_pattern_a_beats_prose(self) -> None:
        parts = {"pr_link": 0, "tool_result_exact": 0, "pattern_a": 1, "prose": 10}
        assert dominant_scan_source(parts) == "scan-pattern-a"

    def test_only_prose_means_prose_vote(self) -> None:
        parts = {"prose": 5}
        assert dominant_scan_source(parts) == "scan-prose-vote"

    def test_empty_dict_means_prose_vote(self) -> None:
        assert dominant_scan_source({}) == "scan-prose-vote"

    def test_return_value_is_always_reconcile_eligible(self) -> None:
        for parts in [
            {"pr_link": 1},
            {"tool_result_exact": 1},
            {"pattern_a": 1},
            {},
        ]:
            assert dominant_scan_source(parts) in RECONCILE_ELIGIBLE_URL_SOURCES
