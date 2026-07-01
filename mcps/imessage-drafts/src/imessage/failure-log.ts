// Send-failure log. When a send_draft send fails (result not ok), we append one
// JSON-line record to ~/.messages-mcp/logs/send-failures.log so failures are
// visible instead of silently vanishing — the original bug was that a 1:1 send
// to a non-iMessage recipient could "succeed" via the buddy cascade and go into
// the void with nothing recorded anywhere.
//
// EXACT shared format (the Swift menu-bar send path writes the identical field
// set and sorted JSON key order):
//   {"duration_ms":1234,"error":"…","handle":"+1555…","platform":"imessage",
//    "route":"chat-id","source":"ts-send_draft","ts":"2026-06-22T21:00:00.000Z"}
//
// Privacy/security: `handle` (recipient phone/email) is on every line in
// cleartext, so the file is mode 0600 and we re-chmod on every append (mode on
// appendFileSync only applies on file CREATION — a same-UID attacker who
// pre-created the file 0644 would otherwise get a world-readable log). The
// logs dir is created 0700. Mirrors the hardening in audit.ts.
//
// Best-effort by contract: `record` NEVER throws. A logging failure must never
// affect the send result — the wire-level send already happened (or failed),
// and we don't want bookkeeping to mask that.

import { mkdirSync, existsSync, appendFileSync, lstatSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// The route the send took, for triage: which path failed.
//   - "chat-id"        : 1:1 send into a resolved addressable chat (new path)
//   - "buddy-cascade"  : 1:1 send via the iMessage→SMS buddy fallback
//   - "group"          : send into a resolved group chat by GUID
export type SendFailureRoute = "chat-id" | "buddy-cascade" | "group" | string;

export interface SendFailureEntry {
  ts: string;
  platform: "imessage";
  handle: string;
  route: SendFailureRoute;
  error: string;
  duration_ms: number;
  source: "ts-send_draft";
}

function logsDirPath(): string {
  return join(homedir(), ".messages-mcp", "logs");
}

function defaultLogPath(): string {
  return join(logsDirPath(), "send-failures.log");
}

let testOverridePath: string | null = null;

// Test seam: redirect the failure log to a tmp file without touching $HOME.
export function _setFailureLogPathForTesting(path: string | null): void {
  testOverridePath = path;
}

function logPath(): string {
  return testOverridePath ?? defaultLogPath();
}

// Pure: build the JSON-line record. Exported so the exact shape is unit-
// testable without filesystem I/O. `duration_ms` is floored to an int.
export function makeEntry(args: {
  handle: string;
  route: SendFailureRoute;
  error: string;
  duration_ms: number;
  ts?: Date;
}): SendFailureEntry {
  return {
    ts: (args.ts ?? new Date()).toISOString(),
    platform: "imessage",
    handle: args.handle,
    route: args.route,
    error: args.error,
    duration_ms: Math.max(0, Math.floor(args.duration_ms)),
    source: "ts-send_draft",
  };
}

// Pure: serialize one entry to its on-disk line (object + trailing newline).
// Swift's JSONEncoder uses `.sortedKeys`, so emit the same sorted key order.
export function encodeLine(entry: SendFailureEntry): string {
  return JSON.stringify({
    duration_ms: entry.duration_ms,
    error: entry.error,
    handle: entry.handle,
    platform: entry.platform,
    route: entry.route,
    source: entry.source,
    ts: entry.ts,
  }) + "\n";
}

function ensureDir(): void {
  const d = testOverridePath ? join(testOverridePath, "..") : logsDirPath();
  // Symlink defense: refuse if either the logs dir itself OR its parent has
  // been replaced with a symlink that would redirect our writes. Parallel to
  // the guard in audit.ts. lstatSync (not existsSync, which follows symlinks
  // and returns false for a dangling-symlink parent, skipping the guard).
  const parent = join(d, "..");
  try {
    if (lstatSync(parent).isSymbolicLink()) {
      throw new Error(`failure-log parent directory is a symlink, refusing to use: ${parent}`);
    }
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
  if (existsSync(d)) {
    if (lstatSync(d).isSymbolicLink()) {
      throw new Error(`failure-log directory is a symlink, refusing to use: ${d}`);
    }
    return;
  }
  mkdirSync(d, { recursive: true, mode: 0o700 });
}

// Best-effort append of a send-failure record. NEVER throws — any failure
// (FS error, symlink-guard refusal) is swallowed so logging can't affect the
// send result the caller returns. Returns the entry it attempted to write
// (handy for tests / callers that want to surface it), or null if the build
// itself somehow threw.
export function record(args: {
  handle: string;
  route: SendFailureRoute;
  error: string;
  duration_ms: number;
  ts?: Date;
}): SendFailureEntry | null {
  try {
    const entry = makeEntry(args);
    ensureDir();
    const path = logPath();
    appendFileSync(path, encodeLine(entry), { mode: 0o600 });
    // Re-chmod every append: the `mode` above only applies on CREATION, so a
    // same-UID attacker who pre-created the file 0644 would otherwise leave
    // recipient handles world-readable. Best-effort — the append already
    // landed; don't let an exotic-FS chmod failure surface as a thrown error.
    try {
      chmodSync(path, 0o600);
    } catch {
      /* best-effort */
    }
    return entry;
  } catch {
    // Swallow: a logging failure must never affect the send result.
    return null;
  }
}
