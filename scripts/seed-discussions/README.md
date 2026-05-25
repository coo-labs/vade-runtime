# `seed-discussions/`

One-shot seed scripts for the `coo-labs/vade-core` GitHub Discussions
categories. Kept after first-run for re-seeding if categories are
ever reset or new categories are added.

## Invocation

```sh
node scripts/seed-discussions/seed.mjs
```

The script is idempotent: it skips creation for any discussion whose
title already exists in the target category, and the pin attempt is
best-effort.

## Contents

- `seed.mjs` — main entry point. Iterates over the category README
  files and posts each to the matching category, then pins it.
- `announcements.md`, `coordination.md`, `qa.md`, `retrospectives.md`,
  `rfcs.md` — per-category README content sources.
