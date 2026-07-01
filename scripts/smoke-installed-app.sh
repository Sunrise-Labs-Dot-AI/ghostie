#!/usr/bin/env bash
set -euo pipefail

APP="${1:-/Applications/Ghostie.app}"
MACOS="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"

if [[ ! -d "$APP" ]]; then
  echo "✗ app not found: $APP" >&2
  exit 2
fi

expected=(
  "MessagesForAIMenu"
  "messages-for-ai-backend"
  "ghostie-mcp"
  "imessage-drafts-mcp"
  "whatsapp-drafts-mcp"
  "imessage-drafts-daemon"
  "whatsapp-drafts-daemon"
  "wrapped-generator"
  "texting-analytics-generator"
  "birthday-generator"
)

echo "==> bundle sidecars"
for name in "${expected[@]}"; do
  path="$MACOS/$name"
  [[ -x "$path" ]] || { echo "✗ missing executable sidecar: $name" >&2; exit 1; }
  size="$(stat -f%z "$path")"
  echo "  ✓ $name ($size bytes)"
done

backend_size="$(stat -f%z "$MACOS/messages-for-ai-backend")"
if (( backend_size < 20000000 )); then
  echo "✗ shared backend is implausibly small: $backend_size bytes" >&2
  exit 1
fi

for launcher in ghostie-mcp imessage-drafts-mcp whatsapp-drafts-mcp imessage-drafts-daemon whatsapp-drafts-daemon wrapped-generator texting-analytics-generator birthday-generator; do
  size="$(stat -f%z "$MACOS/$launcher")"
  if (( size > 1000000 )); then
    echo "✗ launcher $launcher is too large ($size bytes); expected a thin launcher, not a copied backend" >&2
    exit 1
  fi
done

sparkle_current="$FRAMEWORKS/Sparkle.framework/Versions/Current"
if [[ ! -L "$sparkle_current" ]]; then
  echo "✗ Sparkle.framework Versions/Current is not a symlink; release zips must preserve symlinks" >&2
  exit 1
fi
echo "  ✓ Sparkle symlink preserved"

smoke_stdio_mcp() {
  local label="$1"
  local bin="$2"
  local output
  output="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"installed-app-smoke","version":"0"}}}' | "$bin")"
  if ! grep -q '"serverInfo"' <<<"$output"; then
    echo "✗ $label did not return an MCP initialize response" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "  ✓ $label initialize"
}

echo "==> stdio MCP initialize"
smoke_stdio_mcp "iMessage MCP" "$MACOS/imessage-drafts-mcp"
smoke_stdio_mcp "Ghostie MCP" "$MACOS/ghostie-mcp"
smoke_stdio_mcp "WhatsApp MCP" "$MACOS/whatsapp-drafts-mcp"

echo "==> installed-app smoke passed"
