---
name: tagging-taxonomy
description: "Apply or look up VADE issue metadata. Use when filing, triaging, or searching issues across coo-labs repos by dimension (issue type, area, Readiness field, Priority field, needs/blocked). Native types + Issue fields are the primary metadata layer per MEMO-2026-05-21-xfqh; operational reference: `coo/operations/issue-fields-and-types.md` (field list, pinning matrix, API surface). `area:*` and qualifier labels are what remains label-encoded."
---

# VADE issue tagging taxonomy

The coo-labs repos share metadata across two layers:

1. **Native issue types + Issue fields** (org-wide; primary as of
   2026-05-21 per MEMO-2026-05-21-xfqh) — handles the `Type`,
   `Priority`, `Readiness`, `Effort`, and per-type fields
   (`Output kind`, `Research question`, `Skill kind`, `Skill name`).
   Set via issue templates + the `bridge-form-fields-trigger.yml`
   workflow on `issues.opened`.
2. **Labels** (per-repo or org-wide) — handles what remains
   label-encoded: `area:*`, qualifiers (`needs:*`, `blocked:*`),
   semantic tags (`emancipatory`, `external-code`, `publish`,
   `permanently-open`), and discussion-specific labels.

Canonical refs:
- `vade-coo-memory/coo/operations/issue-fields-and-types.md` —
  field list, pinning matrix, API surface, migration stages.
- `vade-coo-memory/coo/label_taxonomy.md` — surviving label
  dimensions + the retired `type:*`/`readiness:*`/`prio:*` history.

Read the canonical refs when the digest below looks stale.

## When to use this skill

Invoke when you need to:

- Apply labels (`area:*` + qualifiers) to an issue you are filing
  or triaging.
- Pick the "next task to work on" — filter by the native Readiness
  field (`gh issue list --search "readiness:Ready"`).
- Route an issue to the right agent profile via native issue type +
  `area:*`.
- Decide whether something is gated (`needs:*`, `blocked:*`).
- Check whether a label is valid, deprecated, or missing.

Don't invoke for: PR-level review labels (none defined), project-board
`Status` / `Owner` fields (those live on the project, not on labels —
see `coo/operations/project-board.md`), or commit-message conventions
(handled elsewhere).

## The dimensions

Each issue carries metadata from each dimension independently.
Some are native fields (Type / Priority / Readiness / Effort); others
are labels (`area:*`, qualifiers).

### 1. Native issue type — kind of work (exactly one)

Set via the issue template's `type:` front-matter or the GitHub UI
type picker. Retires the `type:*` label dimension as of 2026-05-21.

| Native type | Replaces label | Meaning |
|---|---|---|
| `Task` | (default) | Default kind of implementable work |
| `Bug` | `type:bug` | Defect; behaviour diverges from intended |
| `Feature` | `type:feat` | New capability or user-facing behaviour |
| `Chore` | `type:chore` | Build, tooling, infra, housekeeping |
| `Docs` | `type:docs` | Documentation-only change |
| `Refactor` | `type:refactor` | Internal restructure, no behaviour change |
| `Test` | `type:test` | Test coverage, fixtures, harness |
| `Research` | `type:research` | Spike or investigation |
| `Epic` | `type:epic` | Parent issue covering multiple implementable children |
| `Skill` | (no prior label) | Skill lifecycle work (idea / implement / review / revise / evaluate). **Title form**: `/<skill-name>: <short description>` (e.g. `/peer-review: tighten Phase 2 ingest`). The slash-prefix makes board scan-ability immediate; the `Skill kind` and `Skill name` native fields carry the lifecycle phase + canonical name. |

The retired `type:*` labels remain on historical issues for
record-keeping; do NOT apply them to new issues. GitHub default
labels `bug` / `enhancement` / `documentation` are present but the
native type is canonical when both apply.

### 2. `area:*` — where in the system (one or two; LABEL)

Prefix is universal; value list is per-repo. Adding a new `area:*`
value is unilateral — just create the label. `area:*` stays a label
because the per-repo vocabulary fights org-wide field scope (the
field would either flatten the vocabulary or require per-type
duplication).

| Repo | Values |
|---|---|
| **Universal** (any repo) | `area:docs`, `area:ci`, `area:deploy` |
| `vade-coo-memory` | `area:memory`, `area:identity`, `area:agents`, `area:skills`, `area:governance` |
| `vade-runtime` | `area:cloud-env`, `area:mcp`, `area:bootstrap`, `area:hooks` |
| `vade-core` | `area:canvas`, `area:mcp`, `area:storage`, `area:auth`, `area:ui`, `area:cloud` |
| `vade-governance` | `area:authority`, `area:policy` |
| `vade-agent-logs` | `area:sessions`, `area:schema` |

### 3. `Readiness` field — agent-routable? (single-select)

**The headline dimension.** Drives agent assignment. Pinned to all
types except Docs / Refactor.

| Field value | Replaces label | Agent-routable? |
|---|---|---|
| `Ready` | `readiness:ready` | **yes** |
| `Needs design` | `readiness:needs-design` | no |
| `Needs research` | `readiness:needs-research` | research agent |
| `Needs breakdown` | `readiness:needs-breakdown` | no |

Set via the issue template's Readiness dropdown (bridged) or the
side-panel field on existing issues. Transitions: `Needs research`
→ spike lands → new or updated `Ready`. `Needs breakdown` → Epic
with children; parent flips to `Ready` only once every child is
itself `Ready` or worked.

### 4. `Priority` field — urgency (single-select)

Pinned to all types.

| Field value | Replaces label | Meaning |
|---|---|---|
| `P0` | `prio:P0` | Blocker; drop other work |
| `P1` | `prio:P1` | High; next in queue |
| `P2` | `prio:P2` | Normal; scheduled in current horizon |
| `P3` | `prio:P3` | Backlog; someday/maybe |

Default is P2 if absent. Set via the issue template's Priority
dropdown (bridged) or the side-panel field.

### 5. Qualifiers (zero or more; LABELS)

| Label | Meaning |
|---|---|
| `needs:bdfl-approval` | Decision gate pending BDFL ack |
| `blocked:bdfl-go-ahead` | Externally blocked on BDFL before work starts |
| `blocked:upstream` | Blocked on a third-party change |
| `emancipatory` | Lowers the barrier for other humans/agents (MEMO 2026-04-20-01) |
| `external-code` | Integrates, audits, or cherry-picks third-party code |
| `good first issue` | GitHub default; genuinely approachable by a newcomer |
| `help wanted` | GitHub default; explicit ask for external contributions |

### Legacy — `proj:*` (retained, not extended)

`vade-coo-memory` has `proj:bootstrap`, `proj:pm-migration`,
`proj:workspace-relocate`, `proj:skills-research`, `proj:coo-identity`,
`proj:proposed-epic`. **Don't create new `proj:*` labels.** Use
native issue type `Epic` + GitHub sub-issues for new parent/child
linkage.

## Classification checklist

When asked to tag a new issue, run this in order:

1. **Pick the issue type via the issue template.** Each per-type
   template (`bug.yml`, `feature.yml`, `chore.yml`, etc.) sets the
   native type via `type:` front-matter. If the issue was opened
   with the wrong template, the type can be reassigned via the
   GitHub UI's type picker or `updateIssueIssueType` GraphQL
   mutation.
2. **Pick one or two `area:*`** from the repo's vocabulary. If
   none fit, create a new `area:*` label rather than force-fitting,
   or leave area off if the issue genuinely spans no clear area.
3. **Pick the Readiness field value** via the template dropdown
   (bridged on creation) or the side-panel field. Only set `Ready`
   when *a coding agent can start today*. When the description is
   thin, leave Readiness unset (implicit "untriaged") rather than
   guess.
4. **Optionally set the Priority field** — only if the issue
   signals urgency explicitly. Default is P2.
5. **Add any qualifier labels** (`needs:*`, `blocked:*`,
   `emancipatory`, `external-code`) that apply.
6. **Apply labels with `gh`:**

   ```bash
   gh issue edit <N> --repo coo-labs/<repo> \
     --add-label "area:agents,needs:bdfl-approval"
   ```

   For native fields, use the GitHub UI side-panel, or the
   `setIssueFieldValue` GraphQL mutation. Per-issue field-value
   setting works with the standard fine-grained PAT.

## Search recipes — "what should I work on?"

Native fields are searchable as first-class GitHub search
qualifiers (case-insensitive on org-level Issue-field entities).
Find issues a coding agent can take:

```bash
gh issue list --repo coo-labs/vade-coo-memory \
  --search "readiness:Ready" --state open
```

Find the research queue:

```bash
gh issue list --repo coo-labs/vade-coo-memory \
  --search "readiness:'Needs research'" --state open
```

Blocked on BDFL (anywhere):

```bash
for r in vade-coo-memory vade-runtime vade-core vade-governance vade-agent-logs; do
  gh issue list --repo coo-labs/$r --label "needs:bdfl-approval" --state open
done
```

Issues that need breakdown before anyone picks them up:

```bash
gh issue list --repo coo-labs/<repo> \
  --search "readiness:'Needs breakdown'" --state open
```

Active work in a specific area across repos:

```bash
for r in vade-coo-memory vade-runtime vade-core vade-governance vade-agent-logs; do
  gh issue list --repo coo-labs/$r --label "area:memory" --state open
done
```

Ready feature work in vade-core:

```bash
gh issue list --repo coo-labs/vade-core \
  --search "type:Feature readiness:Ready" --state open
```

The `priority:` qualifier does not yet resolve in `gh issue list
--search` (REST/GraphQL only as of 2026-05-21). Use the side-panel
Priority filter on the project board, or
`gh api graphql -f query='{ ... issueFieldValues ... }'` for
programmatic access.

For historical issues that pre-date the migration, the retired
`type:*`, `readiness:*`, `prio:*` labels still match via `--label`
— the backfill set both label + native field on those, so either
filter works for closed issues. New issues only carry the native
field.

## Routing hints (for future agent routers)

Skip unless Readiness is `Ready`; then pick an agent profile from
native type + `area:*`:

| Native type | `area:` | Suggested agent profile |
|---|---|---|
| `Bug` | `canvas` | `claude-code-debug` + tldraw knowledge |
| `Feature` | `mcp` | `claude-code` + MCP skill pack |
| `Research` | any | `research-agent` (deep-research profile) |
| `Docs` | any | Haiku-class model (cheap, fast) |
| `Refactor` | any | `claude-code` + repo-aware `simplify` skill |

Gates: `needs:bdfl-approval` is a handshake; `blocked:*` is a hard
stop.

## Deprecated labels (do not apply to new issues)

Kept to avoid breaking closed-issue references. Map forward as shown:

| Old | New |
|---|---|
| `track:memory` | `area:memory` |
| `track:boot-opt` | `area:agents` (or `area:memory` by scope) |
| `track:orchestration` | `area:agents` |
| `track:self-assess` | `area:agents` |
| `docs-only` | `type:docs` |
| `canvas` (vade-core) | `area:canvas` |
| `feat` (vade-core) | `type:feat` |
| `milestone-1` (vade-core) | GitHub milestones |
| `Strategy` (vade-agent-logs) | `type:research` |
| `epic:ipad-live` | `type:epic` + sub-issues |
| `phase:3-pilot` | no replacement; use milestones |
| `Discussion-update`, `COO essay` | ad-hoc; consider retiring |

## Maintenance — what requires a memo

- **New `area:*` value** → unilateral; just create the label.
- **New native issue type or Issue field option** → memo-worthy
  (cross-repo invariant); also requires org-admin scope (App
  installation token per MEMO-2026-05-21-4wgy).
- **New qualifier label** (`needs:*`, `blocked:*`, semantic tag)
  → memo-worthy.
- **Renaming an existing dimension** → memo-worthy.

Per-repo drift under `area:*` is allowed. Everything else is a
cross-repo invariant.

## Canonical sources

```text
vade-coo-memory/coo/operations/issue-fields-and-types.md   # primary
vade-coo-memory/coo/label_taxonomy.md                       # label scheme
vade-coo-memory/coo/memos/2026-05-21-xfqh.md                # adoption memo
```

When this digest and the canonical docs disagree, the canonical
docs win. Update this skill; don't drift the taxonomy.
