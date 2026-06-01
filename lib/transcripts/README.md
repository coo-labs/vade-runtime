# transcripts/

Internal Python library for the VADE transcript pipeline. **Not published.**
Imported by scripts in `scripts/lib/` and `scripts/lifecycle/`.

This is the primitive layer: R2 access, schema types, and provenance
invariants. Orchestration (the SessionEnd hook, mass-mutation drivers) stays
in `scripts/` — see Decision 2 in
[handoff-transcripts-substrate.md](../../handoff-transcripts-substrate.md)
and the principal-engineer / SRE review chain it cites.

## Layout

| File | What it owns |
|---|---|
| `r2.py` | boto3 client, 1Password credential plumbing, sidecar GET/PUT |
| `schema.py` | Pydantic v2 `Sidecar` (schema v3), `UrlSource` enum, `PARSER_VERSION` |
| `provenance.py` | `AUTHORITATIVE_URL_SOURCES`, `RECONCILE_ELIGIBLE_URL_SOURCES`, `is_authoritative()` |
| `__init__.py` | Public API re-exports |
| `py.typed` | PEP 561 marker — package ships type information |

## Importing

From any `coo-harness` script:

```python
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
from transcripts import Sidecar, is_authoritative, r2_client
```

(`parents[2]` from `scripts/lifecycle/foo.py`; `parents[1]` from `scripts/foo.py`.)

For local dev with editor tooling: `uv pip install -e .` from the repo root
puts the package on PYTHONPATH cleanly.

## Quality bar

- `ruff check lib/transcripts` + `ruff format --check lib/transcripts`
- `mypy lib/transcripts` (strict mode on public API)
- `pytest lib/transcripts/tests/` (≥80% coverage on the package)

CI runs all three under `.github/workflows/lib-transcripts.yml`.

## What's settled (don't relitigate without reading the handoff first)

1. **Internal module, not a separate repo.** Two consumers, both COO-controlled.
2. **`render_hook` orchestration stays in `scripts/lifecycle/`**, not here. This
   package contains primitives only.
3. **Durability/correctness split deferred** — `session-end-transcript-export.py`
   already does atomic PUT-with-object-metadata (#215).

Full reasoning in `handoff-transcripts-substrate.md` (Decisions 1-10).
