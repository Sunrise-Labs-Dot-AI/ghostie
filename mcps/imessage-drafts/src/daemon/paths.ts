// Canonical filesystem paths under ~/.messages-mcp/ for the iMessage daemon.
// Mirrors mcps/whatsapp-drafts/src/paths.ts (daemon-relevant subset only —
// the iMessage MCP's draft/contacts/witness modules resolve their own paths
// independently, so this exists for the daemon + rpc-client to share).
//
// Lazily resolved (getters) so tests can set MESSAGES_MCP_HOME after import.

import { homedir } from "node:os";
import { join } from "node:path";

function home(): string {
  return process.env.MESSAGES_MCP_HOME ?? join(homedir(), ".messages-mcp");
}

export const PATHS = {
  /** Root directory — mode 0700. */
  get root() { return home(); },
  /** Unix socket the daemon listens on. */
  get daemonSock() { return join(home(), "daemon.sock"); },
  /** PID lock file (single-instance guard). */
  get daemonPid() { return join(home(), "daemon.pid"); },
  /** Log directory (the menu-bar controller pipes daemon stdout here). */
  get logsDir() { return join(home(), "logs"); },
};
