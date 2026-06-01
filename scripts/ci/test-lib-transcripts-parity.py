#!/usr/bin/env python3
"""Parity check: lib/transcripts/ matches the inlined definitions in scripts/.

Confirms that the consolidated primitives in lib/transcripts/ match the values
the existing scripts hardcode. Run before any script-port PR ships — if this
fails, the port would silently change behavior.

Checks:
  1. AUTHORITATIVE_URL_SOURCES, RECONCILE_ELIGIBLE_URL_SOURCES, VALID_URL_SOURCES
     in lib/transcripts/provenance.py match the frozensets at the top of
     scripts/transcript-url-backfill.py.
  2. PARSER_VERSION in lib/transcripts/schema.py matches the integer
     scripts/lifecycle/session-end-transcript-render.py uses.
  3. dominant_scan_source picks the same canonical scan-* tag as
     scripts/transcript-url-backfill.py's _dominant_scan_source function.

Exits 0 on full parity, 1 on any divergence.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = REPO_ROOT / "lib"
URL_BACKFILL = REPO_ROOT / "scripts" / "transcript-url-backfill.py"
RENDERER = REPO_ROOT / "scripts" / "lifecycle" / "session-end-transcript-render.py"

sys.path.insert(0, str(LIB_DIR))


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    failures: list[str] = []

    from transcripts.provenance import (
        AUTHORITATIVE_URL_SOURCES as LIB_AUTH,
        RECONCILE_ELIGIBLE_URL_SOURCES as LIB_RECON,
        VALID_URL_SOURCES as LIB_VALID,
        dominant_scan_source as lib_dom,
    )
    from transcripts.schema import PARSER_VERSION as LIB_PV

    backfill = _load_module("transcript_url_backfill", URL_BACKFILL)
    if set(backfill.AUTHORITATIVE_URL_SOURCES) != set(LIB_AUTH):
        failures.append(
            f"AUTHORITATIVE_URL_SOURCES drift — "
            f"script={sorted(backfill.AUTHORITATIVE_URL_SOURCES)} "
            f"lib={sorted(LIB_AUTH)}"
        )
    if set(backfill.RECONCILE_ELIGIBLE_URL_SOURCES) != set(LIB_RECON):
        failures.append(
            f"RECONCILE_ELIGIBLE_URL_SOURCES drift — "
            f"script={sorted(backfill.RECONCILE_ELIGIBLE_URL_SOURCES)} "
            f"lib={sorted(LIB_RECON)}"
        )
    if set(backfill.VALID_URL_SOURCES) != set(LIB_VALID):
        failures.append(
            f"VALID_URL_SOURCES drift — "
            f"script={sorted(backfill.VALID_URL_SOURCES)} "
            f"lib={sorted(LIB_VALID)}"
        )

    for parts in [
        {"pr_link": 1, "tool_result_exact": 1, "pattern_a": 1, "prose": 1},
        {"pr_link": 0, "tool_result_exact": 1},
        {"pattern_a": 1},
        {"prose": 5},
        {},
    ]:
        script_val = backfill._dominant_scan_source(parts)
        lib_val = lib_dom(parts)
        if script_val != lib_val:
            failures.append(
                f"dominant_scan_source({parts}) — script={script_val} lib={lib_val}"
            )

    renderer = _load_module("session_end_transcript_render", RENDERER)
    if renderer.PARSER_VERSION != LIB_PV:
        failures.append(
            f"PARSER_VERSION drift — script={renderer.PARSER_VERSION} lib={LIB_PV}"
        )

    if failures:
        sys.stderr.write("PARITY FAILURES:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print(f"parity OK — {len(LIB_AUTH)} auth, {len(LIB_RECON)} reconcile, PARSER_VERSION={LIB_PV}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
