# Texting Fixture Library

Public-safe synthetic datasets for experience evals.

Rules:

- Do not commit real message bodies, handles, contact names, phone numbers, emails, or chat exports.
- Prefer normalized exports and aggregate `analysis` blocks over raw text.
- Use obviously synthetic labels such as `Sample Contact A` or `Synthetic Crew`.
- Regenerate committed Wrapped personas with:

```sh
node tests/fixtures/texting/generate-wrapped-fixtures.mjs --write
```

CI checks that the generated JSON remains current.

Wrapped personas cover supported, cautious, and playful archetypes plus age
guardrails. Texting-age fixtures must not rely on slang or reply speed; use
writing style, inline emoji, volume, sample size, and active-day aggregates.
