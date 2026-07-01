# Texting Wrapped — Research

Research package backing the "Texting Wrapped" product: population benchmarks, an
age-estimation rubric, the shareable card stats, and the full sourced narrative brief.

## Contents

| File | What it is | Use it for |
|------|-----------|------------|
| `texting-wrapped-research-brief.md` | Full narrative brief with sources & confidence ratings | Reading / understanding the evidence |
| `benchmarks.json` | Population distributions (reply latency, volume, on-read, group chat, read receipts) | Computing user-vs-population percentiles |
| `age_rubric.json` | Weighted feature → age-band scoring config | The "Texting Age" estimator |
| `shareable_card_stats.json` | The 7 share-card stats with copy templates | Building Wrapped cards |
| `sources.json` | Source registry keyed by `source_key` | In-product citations + confidence display |
| `charts/` | PNG charts (reply latency, volume, emoji, laugh tokens) | Decks / marketing |

## How the data files connect

- `benchmarks.json`, `age_rubric.json`, and `shareable_card_stats.json` all reference sources
  by a `source_key` that resolves in `sources.json`. (All 24 keys validated.)
- `shareable_card_stats.json` → `texting_age` card pulls its estimate from `age_rubric.json`.

## Important caveats before you productize

1. **Reply-latency baseline is open-time, not reply-time, on a European Android sample.**
   Use it directionally; recompute real percentiles from your own telemetry.
2. **Volume data is Pew 2011** — best age-cohort breakdown available, but old. Directional.
3. **Three metrics have NO solid public baseline** and are flagged `low` confidence:
   number of open "on-read" threads, read-receipt adoption by age, and relationship-type
   reply latency. These are exactly where your own product data would be novel.
4. **The rubric is probabilistic, not deterministic** — frame "Texting Age" as playful.
5. **Most data is US-centric**; platform mix (iMessage vs WhatsApp vs SMS) matters a lot.

## Confidence scale
`high` = peer-reviewed / large representative sample · `medium` = peer-reviewed w/ limits or
large-platform data w/ known bias · `low` = aggregator w/o methodology, anecdotal, or journalistic.

_Generated 2026-05-28._
