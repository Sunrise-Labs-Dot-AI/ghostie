#!/usr/bin/env bun
// Daemon entry point. Long-running process managed by launchd.
//
//   ~/Library/LaunchAgents/ai.sunriselabs.whatsapp-mcp.plist
//     → bin/whatsapp-daemon
//
// Responsibilities:
//   1. Maintain a persistent Baileys WebSocket connection
//   2. Capture incoming messages → messages.db
//   3. Serve a peer-authenticated Unix-socket JSON-RPC API at daemon.sock
//   4. Handle SIGTERM / SIGINT cleanly
//
// PID-file lock prevents two daemons running at once.

import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { PATHS } from "../paths.ts";
import { DEFAULT_SETTINGS, readSettings } from "../settings.ts";
import { sweepOldMessages } from "../storage/messages.ts";
import { WhatsAppConnection } from "./connection.ts";
import { startRpcServer } from "./server.ts";

const DAY_MS = 24 * 60 * 60 * 1000;
// Downloaded media is a re-fetchable cache; expire it so the dir can't grow
// unbounded. Anything older than this is removed on the daily/startup sweep.
const MEDIA_TTL_MS = 7 * DAY_MS;

async function main() {
  // Ensure runtime dir exists with mode 0700.
  if (!existsSync(PATHS.root)) {
    mkdirSync(PATHS.root, { recursive: true, mode: 0o700 });
  }
  if (!existsSync(PATHS.draftsDir)) {
    mkdirSync(PATHS.draftsDir, { recursive: true, mode: 0o700 });
  }

  // umask 0077 → all files we create end up 0600/0700.
  process.umask(0o077);

  // Single-instance guard via PID lock.
  acquirePidLock();

  const connection = new WhatsAppConnection();
  const rpc = await startRpcServer(connection);
  const retentionTimer = scheduleMessageRetentionSweep();

  const shutdown = async (signal: string) => {
    process.stderr.write(`Received ${signal}, shutting down...\n`);
    clearInterval(retentionTimer);
    try { await rpc.stop(); } catch { /* ignore */ }
    try { await connection.stop(); } catch { /* ignore */ }
    releasePidLock();
    process.exit(0);
  };
  process.on("SIGTERM", () => { void shutdown("SIGTERM"); });
  process.on("SIGINT", () => { void shutdown("SIGINT"); });

  // If the previous run was remotely unlinked, stay alive WITHOUT
  // connecting Baileys — the RPC server above is still listening so the
  // menubar's Reconnect flow can call unlinkAndReset to clear the
  // sentinel and trigger a fresh pairing. Exiting here (the v0.2.0
  // behavior) made unlinkAndReset unreachable: socket gone, menubar got
  // RPCError.readError.
  if (existsSync(PATHS.loggedOutSentinel)) {
    process.stderr.write("LOGGED_OUT sentinel present — awaiting menu bar Reconnect (unlinkAndReset) to re-pair.\n");
    connection.markLoggedOut();
    return;
  }

  await connection.start();
}

function acquirePidLock(): void {
  if (existsSync(PATHS.daemonPid)) {
    const existing = readFileSync(PATHS.daemonPid, "utf8").trim();
    const pid = Number.parseInt(existing, 10);
    if (Number.isFinite(pid) && pid > 0) {
      try {
        process.kill(pid, 0); // Signal 0 → just probe existence.
        process.stderr.write(`Another whatsapp-daemon is already running (PID ${pid}). Exiting.\n`);
        process.exit(1);
      } catch {
        // Stale pid file — process is gone.
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

function scheduleMessageRetentionSweep(): Timer {
  runMessageRetentionSweep("startup");
  runMediaSweep("startup");
  return setInterval(() => {
    runMessageRetentionSweep("daily");
    runMediaSweep("daily");
  }, DAY_MS);
}

// Delete on-demand-downloaded media files older than MEDIA_TTL_MS. Best-effort:
// a stat/unlink hiccup on one file never aborts the sweep or the daemon.
function runMediaSweep(reason: "startup" | "daily"): void {
  let dir: string;
  try {
    dir = PATHS.mediaDir;
    if (!existsSync(dir)) return;
  } catch { return; }
  const cutoff = Date.now() - MEDIA_TTL_MS;
  let deleted = 0;
  for (const name of readdirSync(dir)) {
    const file = join(dir, name);
    try {
      if (statSync(file).mtimeMs < cutoff) {
        unlinkSync(file);
        deleted += 1;
      }
    } catch { /* skip this file */ }
  }
  if (deleted > 0) {
    process.stderr.write(`media cache ${reason}: deleted ${deleted} expired file(s)\n`);
  }
}

function runMessageRetentionSweep(reason: "startup" | "daily"): void {
  try {
    const settings = readSettings();
    const deleted = sweepOldMessages(settings.message_retention_days * DAY_MS);
    if (deleted > 0) {
      process.stderr.write(`messages.db retention ${reason}: deleted ${deleted} old cached messages\n`);
    }
  } catch (err) {
    const deleted = sweepOldMessages(DEFAULT_SETTINGS.message_retention_days * DAY_MS);
    process.stderr.write(
      `messages.db retention ${reason}: settings unavailable; used default retention and deleted ${deleted} old cached messages (${(err as Error).message})\n`,
    );
  }
}
