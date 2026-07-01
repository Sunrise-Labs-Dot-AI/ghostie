import { Database } from "bun:sqlite";
import { homedir } from "node:os";
import { existsSync } from "node:fs";
import { join } from "node:path";

const CHAT_DB_PATH = join(homedir(), "Library", "Messages", "chat.db");

let dbInstance: Database | null = null;

export function openChatDb(): Database {
  if (dbInstance) return dbInstance;
  const db = new Database(CHAT_DB_PATH, { readonly: true });
  db.exec("PRAGMA query_only = ON;");
  dbInstance = db;
  return db;
}

// Test seam: inject a pre-built in-memory SQLite handle so unit tests can
// exercise the query layer without macOS TCC / Full Disk Access. Production
// code paths never call this — it's only wired from `*.test.ts`.
export function _setChatDbForTesting(db: Database | null): void {
  dbInstance = db;
}

export function chatDbPath(): string {
  return CHAT_DB_PATH;
}

export type ChatDbOpenStatus = "ok" | "permission_denied" | "not_found" | "error";

export interface ChatDbDiagnostic {
  db_path: string;
  db_path_exists: boolean;
  open_status: ChatDbOpenStatus;
  open_error?: string;
}

// Probe-open chat.db without caching the handle or throwing. Used by the
// `health_check` tool to distinguish "FDA missing" from
// "file missing" from "schema mismatch" without taking down the rest of
// the server. We deliberately don't reuse `openChatDb()`'s cached
// instance — diagnostics should reflect live state, not a stale cache.
export function getChatDbDiagnostic(): ChatDbDiagnostic {
  const db_path = CHAT_DB_PATH;
  // existsSync without FDA returns false even when the file is there
  // (TCC denies the stat). Treat false-with-permission-denied open as
  // FDA-missing rather than not-found.
  const db_path_exists = existsSync(db_path);
  let probe: Database | null = null;
  try {
    probe = new Database(db_path, { readonly: true });
    probe.exec("PRAGMA query_only = ON;");
    probe.close();
    return { db_path, db_path_exists, open_status: "ok" };
  } catch (err) {
    try { probe?.close(); } catch { /* ignore */ }
    const e = err as NodeJS.ErrnoException & { message?: string };
    const code = e?.code ?? "";
    const msg = (e?.message ?? String(err)).toLowerCase();
    if (
      code === "EACCES" ||
      code === "EPERM" ||
      e?.errno === -13 ||
      // bun:sqlite via macOS's TCC authorizer hook reports FDA denial
      // as the literal string "authorization denied" — keep this in
      // sync with the matching list in contacts.ts.
      msg.includes("authorization denied") ||
      msg.includes("permission denied") ||
      msg.includes("operation not permitted") ||
      msg.includes("unable to open")
    ) {
      return { db_path, db_path_exists, open_status: "permission_denied", open_error: e?.message ?? String(err) };
    }
    if (code === "ENOENT" || msg.includes("no such file")) {
      return { db_path, db_path_exists, open_status: "not_found", open_error: e?.message ?? String(err) };
    }
    return { db_path, db_path_exists, open_status: "error", open_error: e?.message ?? String(err) };
  }
}

// Apple Cocoa epoch: 2001-01-01 00:00:00 UTC, in unix-ms terms.
const APPLE_EPOCH_OFFSET_MS = 978307200_000;

// `message.date` is nanoseconds since the Apple epoch on macOS High Sierra+,
// and seconds on older versions. The nanosecond values are huge (~1e18) and
// the second values are tiny (~7e8), so the magnitude check is reliable.
export function appleDateToIsoUtc(rawDate: number | bigint | null): string | null {
  if (rawDate == null) return null;
  const n = typeof rawDate === "bigint" ? Number(rawDate) : rawDate;
  if (!Number.isFinite(n) || n <= 0) return null;
  const unixMs = n > 1e15 ? Math.round(n / 1_000_000) + APPLE_EPOCH_OFFSET_MS : n * 1000 + APPLE_EPOCH_OFFSET_MS;
  return new Date(unixMs).toISOString();
}

// Inverse: ISO-8601 → Apple-epoch nanoseconds, for parameterized `since` filters
// against post-High-Sierra rows. Pre-High-Sierra rows compare unfavorably against
// a large `since` (their date < threshold), which is the safe default — they're
// older than any realistic `since` value anyway.
export function isoUtcToAppleDateNs(iso: string): bigint {
  const unixMs = Date.parse(iso);
  if (Number.isNaN(unixMs)) throw new Error(`invalid ISO-8601 timestamp: ${iso}`);
  return BigInt(unixMs - APPLE_EPOCH_OFFSET_MS) * 1_000_000n;
}
