// Thin JSON-RPC 2.0 client over the iMessage daemon's Unix socket. Used by
// the MCP stdio binary to ask the daemon (which holds Full Disk Access) to
// perform chat.db / AddressBook reads on its behalf.

import { PATHS } from "./paths.ts";
import {
  createDaemonCaller,
  DaemonRpcError,
  DaemonUnavailableError,
} from "../../../shared/src/daemon-client.ts";

export { DaemonRpcError, DaemonUnavailableError };

export const callDaemon = createDaemonCaller({
  socketPath: () => PATHS.daemonSock,
  unavailableMessage:
    "iMessage daemon not running — open the Messages for AI menu bar app " +
    "(it launches the daemon that reads chat.db). If it's already open, the " +
    "daemon may be starting; retry in a moment.",
});
