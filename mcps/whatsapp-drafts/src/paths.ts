// Canonical filesystem paths under ~/.whatsapp-mcp/.
//
// Lazily resolved (Proxy with getters) so tests can set
// WHATSAPP_MCP_HOME *after* this module is first imported — important
// because Bun's test runner shares a process across .test.ts files and
// they need different tmp dirs.

import { homedir } from "node:os";
import { join } from "node:path";

function home(): string {
  return process.env.WHATSAPP_MCP_HOME ?? join(homedir(), ".whatsapp-mcp");
}

export const PATHS = {
  /** Root directory — mode 0700 at install time. */
  get root() { return home(); },
  /** Unix socket the daemon listens on. */
  get daemonSock() { return join(home(), "daemon.sock"); },
  /** PID lock file (single-instance guard). */
  get daemonPid() { return join(home(), "daemon.pid"); },
  /** Baileys session credentials. AES-GCM wrapped with Keychain key. */
  get sessionDb() { return join(home(), "session.db"); },
  /** Plaintext message cache (symmetric with iMessage chat.db). */
  get messagesDb() { return join(home(), "messages.db"); },
  /** Send audit + atomic rate-limit accounting. */
  get auditDb() { return join(home(), "audit.db"); },
  /** Staged drafts (JSON files, mode 0600). */
  get draftsDir() { return join(home(), "drafts"); },
  /** Private, draft-owned outbound attachment snapshots. */
  get draftAttachmentsDir() { return join(home(), "draft-attachments"); },
  /** On-demand-downloaded media payloads (photos/videos/docs), mode 0700.
   *  Swept by age on daemon start so it doesn't grow unbounded. */
  get mediaDir() { return join(home(), "media"); },
  /** User-editable settings (Zod-validated; fail-closed on parse error). */
  get settingsJson() { return join(home(), "settings.json"); },
  /** Agent-set thread priorities (read directly by the menu bar app). */
  get threadPrioritiesJson() { return join(home(), "thread-priorities.json"); },
  /** Recovery sentinel — written on loggedOut, blocks daemon auto-restart. */
  get loggedOutSentinel() { return join(home(), "LOGGED_OUT"); },
};
