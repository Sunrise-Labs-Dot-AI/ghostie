import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerWithWitness } from "../witness.ts";
import { CurrentTimeShape } from "../schema.ts";
import { jsonResult } from "./_result.ts";

export function registerTimeTool(server: McpServer): void {
  registerWithWitness(
    server,
    "get_current_time",
    {
      title: "Current time (for constructing `since` filters)",
      description:
        "Returns the current time in ISO-8601 (UTC) plus the same instant formatted in the system's local timezone. Use this when constructing the `since` parameter for list/search tools so you don't have to guess timezone offsets.",
      inputSchema: CurrentTimeShape,
    },
    async () => {
      const now = new Date();
      // System timezone — picked up from the environment so the same
      // binary works for any user without recompilation. Falls back to
      // UTC if the runtime can't resolve a zone (rare).
      const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
      const localFormatter = new Intl.DateTimeFormat("en-CA", {
        timeZone: tz,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
      });
      return jsonResult({
        utc_iso: now.toISOString(),
        local: localFormatter.format(now),
        local_timezone: tz,
        epoch_ms: now.getTime(),
      });
    }
  );
}
