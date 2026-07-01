// Send audit + atomic rate-limit accounting.
//
// The audit row is INSERTED in the SAME SQLite transaction that
// runs the cap / burst / inter-send checks. This is what makes the
// "two concurrent sends can't both squeak past the cap boundary"
// invariant work. SQLite serializes writers on a single .db file;
// the transaction is atomic across all four predicates.
//
// What the audit captures:
//   - ts          : unix ms (cap window is calendar-day UTC)
//   - draft_id    : the draft UUID that was sent
//   - to_handle   : recipient JID
//   - body_sha256 : hex SHA-256 of the SENT body
//   - status      : "ok" | "send_failed"
//
// Notably NOT captured: the body itself, or any plaintext-payload field.
// The hash is enough to prove "we sent message X" without storing the
// content. Grep audit for the body would fail by design.

import { Database } from "bun:sqlite";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { PATHS } from "../paths.ts";
import type { Settings } from "../settings.ts";

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS sends (
  ts          INTEGER NOT NULL,
  draft_id    TEXT NOT NULL,
  to_handle   TEXT NOT NULL,
  body_sha256 TEXT NOT NULL,
  status      TEXT NOT NULL CHECK(status IN ('ok','send_failed'))
);
CREATE INDEX IF NOT EXISTS idx_sends_ts ON sends(ts DESC);
`;

let _db: Database | null = null;

export function getAuditDb(): Database {
  if (_db != null) return _db;
  const path = PATHS.auditDb;
  if (!existsSync(dirname(path))) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  }
  const db = new Database(path, { create: true });
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA synchronous = NORMAL");
  db.exec(SCHEMA_SQL);
  try { chmodSync(path, 0o600); } catch { /* ignore */ }
  for (const suffix of ["-wal", "-shm"] as const) {
    try { chmodSync(path + suffix, 0o600); } catch { /* not created yet */ }
  }
  _db = db;
  return db;
}

/** Error codes returned across the RPC + MCP layer. Exposed as an enum
 *  so Claude-side tool callers can disambiguate failure modes. */
export const SEND_ERR = {
  DAILY_CAP_HIT: "DAILY_CAP_HIT",
  BURST_LIMIT_HIT: "BURST_LIMIT_HIT",
  INTER_SEND_TOO_FAST: "INTER_SEND_TOO_FAST",
} as const;
export type SendErr = typeof SEND_ERR[keyof typeof SEND_ERR];

export interface ReserveOk {
  ok: true;
  /** Caller invokes this with status after Baileys returns. */
  commit: (status: "ok" | "send_failed") => void;
  /** Caller invokes this if Baileys never gets called (e.g., crash). */
  rollback: () => void;
}
export interface ReserveErr {
  ok: false;
  error: SendErr;
  detail: string;
}
export type ReserveResult = ReserveOk | ReserveErr;

/**
 * Atomically check daily-cap + burst + inter-send and reserve a slot
 * by inserting a pending row. Caller MUST call commit() or rollback()
 * exactly once.
 *
 * The row is inserted with status 'send_failed' (pessimistic). On
 * Baileys success, commit('ok') updates it. On failure, commit(
 * 'send_failed') is a no-op (already in the right state). On caller
 * crash before commit, the row remains 'send_failed' — counted against
 * the cap (intentional: prevents retry-storm spam).
 *
 * Returns ReserveErr without inserting if any predicate fails.
 */
export function reserveSend(args: {
  draft_id: string;
  to_handle: string;
  body_sha256: string;
  settings: Settings;
  now?: number;
}): ReserveResult {
  const db = getAuditDb();
  const now = args.now ?? Date.now();
  const { daily_cap, max_burst_in_60s, min_inter_send_ms } = args.settings;

  // Calendar-day UTC boundary for the daily cap.
  const today = new Date(now);
  today.setUTCHours(0, 0, 0, 0);
  const utcDayStart = today.getTime();

  // All checks run inside one transaction so concurrent reserveSend
  // calls can't both pass the same boundary. BEGIN IMMEDIATE acquires
  // the write lock up-front to prevent reader/writer races on the
  // count queries.
  let result: ReserveResult | null = null;
  db.exec("BEGIN IMMEDIATE");
  try {
    const dailyCount = (db.prepare("SELECT COUNT(*) AS c FROM sends WHERE ts >= ?").get(utcDayStart) as { c: number }).c;
    if (dailyCount >= daily_cap) {
      result = { ok: false, error: SEND_ERR.DAILY_CAP_HIT, detail: `daily cap ${daily_cap} reached (${dailyCount} sends today UTC)` };
      db.exec("ROLLBACK");
      return result;
    }

    const burstCount = (db.prepare("SELECT COUNT(*) AS c FROM sends WHERE ts >= ?").get(now - 60_000) as { c: number }).c;
    if (burstCount >= max_burst_in_60s) {
      result = { ok: false, error: SEND_ERR.BURST_LIMIT_HIT, detail: `${burstCount} sends in last 60s (limit ${max_burst_in_60s})` };
      db.exec("ROLLBACK");
      return result;
    }

    const lastTs = (db.prepare("SELECT ts FROM sends ORDER BY ts DESC LIMIT 1").get() as { ts: number } | null)?.ts;
    if (lastTs != null) {
      const elapsed = now - lastTs;
      if (elapsed < min_inter_send_ms) {
        result = { ok: false, error: SEND_ERR.INTER_SEND_TOO_FAST, detail: `${elapsed}ms since last send (min ${min_inter_send_ms}ms)` };
        db.exec("ROLLBACK");
        return result;
      }
    }

    db.prepare(`
      INSERT INTO sends (ts, draft_id, to_handle, body_sha256, status)
      VALUES (?, ?, ?, ?, 'send_failed')
    `).run(now, args.draft_id, args.to_handle, args.body_sha256);
    db.exec("COMMIT");
  } catch (e) {
    try { db.exec("ROLLBACK"); } catch { /* ignore */ }
    throw e;
  }

  let settled = false;
  return {
    ok: true,
    commit: (status) => {
      if (settled) return;
      settled = true;
      db.prepare("UPDATE sends SET status = ? WHERE ts = ? AND draft_id = ?").run(status, now, args.draft_id);
    },
    rollback: () => {
      if (settled) return;
      settled = true;
      // Caller never got to Baileys — row stays as 'send_failed' which
      // intentionally consumes a cap slot to prevent retry storms.
    },
  };
}

/** Read-only audit view for inspecting recent sends (debug / test use). */
export function recentSends(limit: number = 100): Array<{
  ts: number;
  draft_id: string;
  to_handle: string;
  body_sha256: string;
  status: string;
}> {
  const db = getAuditDb();
  return db.prepare("SELECT ts, draft_id, to_handle, body_sha256, status FROM sends ORDER BY ts DESC LIMIT ?").all(limit) as Array<{
    ts: number;
    draft_id: string;
    to_handle: string;
    body_sha256: string;
    status: string;
  }>;
}

/** Test seam. */
export function _resetForTesting(): void {
  if (_db != null) {
    _db.close();
    _db = null;
  }
}
