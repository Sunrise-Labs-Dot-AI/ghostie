#!/usr/bin/env bun
// iMessage daemon entry point. Long-running process launched + supervised by
// the Messages for AI menu-bar app (IMessageDaemonController). Because the
// menu-bar app holds the "Messages for AI" Full Disk Access grant, this
// daemon — its child — inherits FDA for chat.db (verified by the Step 0
// spike). It serves a peer-authenticated Unix-socket JSON-RPC API at
// ~/.messages-mcp/daemon.sock; the Claude-launched MCP is a thin client.
//
// PID-file lock prevents two daemons running at once.

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

import { PATHS } from "./paths.ts";
import { startRpcServer } from "./server.ts";

async function main() {
  if (!existsSync(PATHS.root)) {
    mkdirSync(PATHS.root, { recursive: true, mode: 0o700 });
  }
  // umask 0077 → files we create end up 0600/0700.
  process.umask(0o077);

  acquirePidLock();

  const rpc = await startRpcServer();

  const shutdown = async (signal: string) => {
    process.stderr.write(`Received ${signal}, shutting down imessage-drafts-daemon...\n`);
    try { await rpc.stop(); } catch { /* ignore */ }
    releasePidLock();
    process.exit(0);
  };
  process.on("SIGTERM", () => { void shutdown("SIGTERM"); });
  process.on("SIGINT", () => { void shutdown("SIGINT"); });

  process.stderr.write(`imessage-drafts-daemon listening at ${PATHS.daemonSock}\n`);
}

function acquirePidLock(): void {
  if (existsSync(PATHS.daemonPid)) {
    const existing = readFileSync(PATHS.daemonPid, "utf8").trim();
    const pid = Number.parseInt(existing, 10);
    if (Number.isFinite(pid) && pid > 0) {
      try {
        process.kill(pid, 0); // Signal 0 → probe existence only.
        process.stderr.write(`Another imessage-drafts-daemon is already running (PID ${pid}). Exiting.\n`);
        process.exit(1);
      } catch {
        // Stale pid file — previous process is gone.
      }
    }
  }
  if (!existsSync(dirname(PATHS.daemonPid))) {
    mkdirSync(dirname(PATHS.daemonPid), { recursive: true, mode: 0o700 });
  }
  writeFileSync(PATHS.daemonPid, String(process.pid), { mode: 0o600 });
}

function releasePidLock(): void {
  try { unlinkSync(PATHS.daemonPid); } catch { /* ignore */ }
}

main().catch((err) => {
  process.stderr.write(`fatal: ${(err as Error).message}\n${(err as Error).stack ?? ""}\n`);
  releasePidLock();
  process.exit(1);
});
