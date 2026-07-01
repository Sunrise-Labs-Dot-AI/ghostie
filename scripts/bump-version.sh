#!/usr/bin/env bash
#
# bump-version.sh <version> — set every "soft" version string to <version>.
#
# The .app's own version is NOT here: build-release.sh stamps
# CFBundleShortVersionString straight from its <version> argument. This
# script handles the files that DON'T follow that arg automatically — the
# Claude Code plugin manifest, MCP package manifests, and MCP stdio server
# metadata — so a single release version propagates everywhere (lockstep
# release, option A).
#
# Files patched (top-level "version" field only):
#   - .claude-plugin/plugin.json
#   - mcps/ghostie/package.json
#   - mcps/imessage-drafts/package.json
#   - mcps/whatsapp-drafts/package.json
#   - mcps/wrapped-generator/package.json
#   - mcps/birthday-generator/package.json
#   - mcps/ghostie/src/index.ts
#   - mcps/imessage-drafts/src/index.ts
#   - mcps/whatsapp-drafts/src/index.ts
#
# Accepts the version with or without a leading "v" (v0.3.4 or 0.3.4); the
# files always get the bare number (0.3.4). Idempotent — safe to re-run.
#
# Usage:
#   bash scripts/bump-version.sh v0.3.4
#   bash scripts/bump-version.sh 0.3.4
#
# Normally you don't call this directly — scripts/release.sh runs it for you.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RAW="${1:?usage: bump-version.sh <version>  (e.g. v0.3.4 or 0.3.4)}"
VNUM="${RAW#v}"  # strip a leading v if present

# Validate: 3 or 4 dotted numbers (the project uses both 0.3.4 and 0.3.3.1).
if ! [[ "$VNUM" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "✗ '$RAW' is not a valid version. Expected like 0.3.4 or 0.3.3.1." >&2
  exit 1
fi

FILES=(
  ".claude-plugin/plugin.json"
  "mcps/ghostie/package.json"
  "mcps/imessage-drafts/package.json"
  "mcps/whatsapp-drafts/package.json"
  "mcps/wrapped-generator/package.json"
  "mcps/birthday-generator/package.json"
)

MCP_INDEX_FILES=(
  "mcps/ghostie/src/index.ts"
  "mcps/imessage-drafts/src/index.ts"
  "mcps/whatsapp-drafts/src/index.ts"
)

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "✗ expected file not found: $f" >&2
    exit 1
  fi
  before="$(grep -E '^  "version": "' "$f" | head -1 || true)"
  # Patch ONLY the top-level field: a line starting with exactly two spaces
  # then "version": "...". Dependencies (deeper indent / different keys) and
  # any nested "version" never match this anchor.
  perl -i -pe 's/^(  "version": ")[^"]*(")/${1}'"$VNUM"'${2}/' "$f"
  after="$(grep -E '^  "version": "' "$f" | head -1 || true)"
  if [ -z "$after" ]; then
    echo "✗ no top-level \"version\" field found in $f — nothing patched." >&2
    exit 1
  fi
  printf '  %-44s %s\n' "$f" "→ $VNUM"
done

for f in "${MCP_INDEX_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "✗ expected file not found: $f" >&2
    exit 1
  fi
  before_count="$(grep -Ec 'name: "[^"]+", version: "[^"]+"' "$f" || true)"
  if [ "$before_count" -ne 1 ]; then
    echo "✗ expected exactly one MCP server metadata line in $f; found $before_count." >&2
    exit 1
  fi
  perl -i -pe 's/(name: "[^"]+", version: ")[^"]*(")/${1}'"$VNUM"'${2}/' "$f"
  after_count="$(grep -Ec 'name: "[^"]+", version: "'"$VNUM"'"' "$f" || true)"
  if [ "$after_count" -ne 1 ]; then
    echo "✗ MCP server version field in $f did not patch cleanly." >&2
    exit 1
  fi
  printf '  %-44s %s\n' "$f" "→ $VNUM"
done

echo "✓ bumped soft versions to $VNUM"
