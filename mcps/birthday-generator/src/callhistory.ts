// macOS Call/FaceTime history reader — an affinity signal the text-only path
// misses (the parent you call weekly but rarely text). Metadata only: address +
// timestamp, never content (calls have none). Same TCC-protected zone as
// chat.db, so the menu-bar-spawned binary already has access via launcher
// attribution. Best-effort: returns an empty map if the DB is missing or its
// schema differs, so the tool degrades gracefully.

import { Database } from "bun:sqlite";
import { homedir } from "node:os";
import { join } from "node:path";
import { canonHandle } from "../../imessage-drafts/src/chatdb/canon.ts";

// Core Data stores ZDATE as seconds since 2001-01-01 UTC.
const CORE_DATA_EPOCH = 978_307_200;

export interface CallAgg {
  count: number;
  lastMs: number | null;
  original: string; // first-seen ZADDRESS (dispatchable form) for this canon
}

export function defaultCallDbPath(): string {
  return join(homedir(), "Library", "Application Support", "CallHistoryDB", "CallHistory.storedata");
}

// canon handle → ALL call timestamps (unix ms), for cadence math. Phone + audio
// + video FaceTime are all in ZCALLRECORD, keyed by ZADDRESS (phone/email), which
// canonHandle folds to the same key as the text side. Best-effort: empty map on
// missing DB / schema mismatch.
export function readCallDates(dbPath: string): Map<string, number[]> {
  const out = new Map<string, number[]>();
  let db: Database;
  try {
    db = new Database(dbPath, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch {
    return out;
  }
  try {
    let rows: { addr: string | null; date: number | bigint | null }[];
    try {
      rows = db
        .query<{ addr: string | null; date: number | bigint | null }, []>(
          "SELECT ZADDRESS AS addr, ZDATE AS date FROM ZCALLRECORD WHERE ZADDRESS IS NOT NULL AND ZDATE IS NOT NULL",
        )
        .all();
    } catch {
      return out;
    }
    for (const r of rows) {
      if (r.addr == null || r.date == null) continue;
      const canon = canonHandle(String(r.addr));
      if (!canon) continue;
      const ms = Math.round((Number(r.date) + CORE_DATA_EPOCH) * 1000);
      const arr = out.get(canon);
      if (arr) arr.push(ms);
      else out.set(canon, [ms]);
    }
    return out;
  } finally {
    db.close();
  }
}

// canon handle → { count, lastMs } across all call records.
export function readCallHistory(dbPath: string): Map<string, CallAgg> {
  const out = new Map<string, CallAgg>();
  let db: Database;
  try {
    db = new Database(dbPath, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch {
    return out; // missing / unreadable (no FDA) → no call signal
  }
  try {
    let rows: { addr: string | null; date: number | bigint | null }[];
    try {
      rows = db
        .query<{ addr: string | null; date: number | bigint | null }, []>(
          "SELECT ZADDRESS AS addr, ZDATE AS date FROM ZCALLRECORD WHERE ZADDRESS IS NOT NULL",
        )
        .all();
    } catch {
      return out; // table/columns absent on this macOS version
    }
    for (const r of rows) {
      if (r.addr == null) continue;
      // ZADDRESS is normally a phone-number string (or a FaceTime email).
      // canonHandle digit-strips, so even lightly-formatted values resolve;
      // a non-string archived value just canonicalizes to noise and is ignored.
      const original = String(r.addr);
      const canon = canonHandle(original);
      if (!canon) continue;
      const ms = r.date == null ? null : Math.round((Number(r.date) + CORE_DATA_EPOCH) * 1000);
      const agg = out.get(canon) ?? { count: 0, lastMs: null, original };
      agg.count += 1;
      if (ms != null && (agg.lastMs == null || ms > agg.lastMs)) agg.lastMs = ms;
      out.set(canon, agg);
    }
    return out;
  } finally {
    db.close();
  }
}
