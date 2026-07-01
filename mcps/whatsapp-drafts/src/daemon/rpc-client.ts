// Thin JSON-RPC 2.0 client over the daemon's Unix socket. Used by the
// MCP stdio binary to talk to the daemon. Single-shot request/response;
// notifications (server-pushed events) are dropped here — the menu bar
// app handles subscriptions, not the MCP binary.

import { PATHS } from "../paths.ts";
import {
  createDaemonCaller,
  DaemonRpcError,
  DaemonUnavailableError,
} from "../../../shared/src/daemon-client.ts";

export { DaemonRpcError, DaemonUnavailableError };

export const callDaemon = createDaemonCaller({
  socketPath: () => PATHS.daemonSock,
  unavailableMessage: "WhatsApp daemon not running — check menu bar app (or run scripts/install.sh)",
});
