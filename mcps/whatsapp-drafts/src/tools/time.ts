import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { registerWithWitness } from "../witness.ts";
import { jsonResult } from "./_result.ts";

export function registerTimeTool(server: McpServer) {
  registerWithWitness(
    server,
    "get_whatsapp_current_time",
    {
      description:
        "Return the current local time (the daemon and MCP host's system clock). " +
        "Useful for resolving relative `since` filters like 'last 24h'.",
    },
    async () => {
      const now = new Date();
      return jsonResult({
        ok: true,
        iso: now.toISOString(),
        unix_ms: now.getTime(),
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      });
    },
  );
}
