#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

smoke_mcp() {
  local label="$1"
  local cwd="$2"
  local expected_name="$3"
  local expected_tools="$4"
  local home
  home="$(mktemp -d "${TMPDIR:-/tmp}/mfa-mcp-contract.XXXXXX")"
  trap 'rm -rf "$home"' RETURN

  local input output
  input="$(printf '%s\n%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"experience-eval","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')"
  output="$(printf '%s\n' "$input" | (cd "$cwd" && HOME="$home" MESSAGES_FOR_AI_ROOT="$home/.messages-mcp" bun run src/index.ts))"

  LABEL="$label" EXPECTED_NAME="$expected_name" EXPECTED_TOOLS="$expected_tools" MCP_OUTPUT="$output" python3 - <<'PY'
import json
import os

label = os.environ["LABEL"]
expected_name = os.environ["EXPECTED_NAME"]
expected_tools = [item for item in os.environ["EXPECTED_TOOLS"].split(",") if item]
rows = [json.loads(line) for line in os.environ["MCP_OUTPUT"].splitlines() if line.strip()]
init = next((row for row in rows if row.get("id") == 1), None)
tools = next((row for row in rows if row.get("id") == 2), None)
actual_name = (((init or {}).get("result") or {}).get("serverInfo") or {}).get("name")
if actual_name != expected_name:
    raise SystemExit(f"{label} server name mismatch: {actual_name!r} != {expected_name!r}")
names = {tool.get("name") for tool in (((tools or {}).get("result") or {}).get("tools") or [])}
missing = [tool for tool in expected_tools if tool not in names]
if missing:
    raise SystemExit(f"{label} missing tools: {missing}; saw {sorted(names)}")
print(f"ok {label}: {len(names)} tools")
PY
}

smoke_mcp \
  "Ghostie" \
  "$ROOT/mcps/ghostie" \
  "ghostie-mcp" \
  "list_message_threads,search_message_history,stage_message_draft,ghostie_health_check"

smoke_mcp \
  "iMessage" \
  "$ROOT/mcps/imessage-drafts" \
  "imessage-drafts-mcp" \
  "list_threads,search_messages,stage_draft,health_check,propose_message_automation"

smoke_mcp \
  "WhatsApp" \
  "$ROOT/mcps/whatsapp-drafts" \
  "whatsapp-mcp" \
  "list_whatsapp_threads,search_whatsapps,stage_whatsapp_draft,whatsapp_mcp_health_check"
