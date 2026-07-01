## Summary

- 

## Tests / Evals

- [ ] Swift changes: `cd menubar && rm -f .build/build.db && swift test`
- [ ] MCP/generator changes: `bun --bun tsc --noEmit && bun test`
- [ ] Skill changes: `python3 -m unittest discover -s tests`
- [ ] Experience coverage: `scripts/test-experience.sh`

## Regression Coverage

- [ ] P0/P1 fix includes a deterministic regression test/eval, or this PR explains why it cannot.
- [ ] No real message bodies, contact identifiers, API keys, or raw handles were added to tests, logs, fixtures, screenshots, or docs.
