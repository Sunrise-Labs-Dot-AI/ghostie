# AGENTS.md: tests/

Inherits the repo root AGENTS.md. Cross-cutting experience and contract tests that sit above the per-package Bun and Swift unit suites.

## What's here

- `experience/`: `mcp-agent-choice-contract.mjs`, `mcp-stdio-contract.sh`, `site-update-checks.mjs` (the agent-facing MCP contract and site-update checks).
- `fixtures/`: shared test fixtures.

## Working rules

- Run via `bash scripts/test-experience.sh` (the harness that drives this dir); per-package unit tests live under their own package, not here.
- These guard the stdio MCP contract and the agent-choice surface; update them when the MCP tool shape or agent-facing behavior changes.
- Use fixtures, never live `chat.db` or real message content.

## Don't

- Don't put per-package unit tests here; keep those in `mcps/<name>` or `menubar/Tests`.
- Don't introduce real message bodies or PII into fixtures.

## Canonical doc

Repo `CLAUDE.md` (Build & dev loop) and root `AGENTS.md` (Build / test).
