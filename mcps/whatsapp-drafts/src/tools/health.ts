import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { callDaemon, DaemonRpcError, DaemonUnavailableError } from "../daemon/rpc-client.ts";
import { registerWithWitness } from "../witness.ts";
import { errorResult, jsonResult } from "./_result.ts";

interface ConnectionStatus {
  state: "connecting" | "connected" | "reconnecting" | "logged_out";
}

export function registerHealthTools(server: McpServer) {
  registerWithWitness(
    server,
    "whatsapp_mcp_health_check",
    {
      description:
        "Confirm the WhatsApp daemon is reachable and report its connection state " +
        "(connecting / connected / reconnecting / logged_out). Returns ok:false " +
        "with a clear reason if the daemon socket is not connectable.",
    },
    async () => {
      try {
        const status = await callDaemon<ConnectionStatus>("getConnectionStatus");
        return jsonResult({ ok: true, daemon: "reachable", ...status });
      } catch (e) {
        if (e instanceof DaemonUnavailableError) return errorResult(e.message);
        if (e instanceof DaemonRpcError) return errorResult(`daemon error (${e.code}): ${e.message}`);
        return errorResult(`unexpected error: ${(e as Error).message}`);
      }
    },
  );
}
