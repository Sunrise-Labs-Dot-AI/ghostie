#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Python skill tests"
for dir in skills/*/tests; do
  [ -d "$dir" ] || continue
  skill_dir="$(dirname "$dir")"
  echo "  -> $skill_dir"
  (cd "$skill_dir" && python3 -m unittest discover -s tests)
done

echo "==> Texting fixture generator checks"
node tests/fixtures/texting/generate-wrapped-fixtures.mjs --check

echo "==> Wrapped deterministic evals"
(cd mcps/wrapped-generator && bun test src/analyze.test.ts src/build-wrapped.test.ts src/wrapped-personalization.test.ts src/age-estimate.test.ts src/emoji-stats.test.ts)

echo "==> MCP stdio contract smoke"
tests/experience/mcp-stdio-contract.sh

echo "==> MCP all-tools agent-choice contract"
node tests/experience/mcp-agent-choice-contract.mjs

echo "==> Site/update/package metadata checks"
node tests/experience/site-update-checks.mjs

echo "==> Experience evals passed"
