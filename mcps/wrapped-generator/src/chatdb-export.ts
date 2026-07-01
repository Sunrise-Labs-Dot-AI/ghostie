// Phase A1 — iMessage chat.db → normalized message export (contract v1.0).
//
// A faithful TypeScript port of skills/texting-analytics/scripts/adapters/
// imessage_chatdb.py, with ONE deliberate upgrade: it reuses the iMessage
// daemon's CANONICAL attributedBody decoder (../imessage-drafts/.../decode.ts)
// instead of the adapter's older heuristic. The daemon's decoder is the
// bug-fixed version (the adapter mis-parses bodies ≥128 chars); the Python
// adapter is being aligned to match so the parity harness compares the same
// correct logic. See the plan's Phase A1 note.
//
// Metadata only: reads LENGTH(text) / decoded-body LENGTH, never stores a body.
// Opens read-only. In production the binary is launched by the menu-bar app
// (which holds Full Disk Access via launcher attribution); for parity testing
// pass --db pointing at a static chat.db snapshot.

import { Database } from "bun:sqlite";
import { decodeAttributedBody } from "../../imessage-drafts/src/chatdb/decode.ts";

const APPLE_EPOCH = 978307200; // 2001-01-01 UTC, in unix seconds
const TWO_YEAR_DAYS = 730; // behavior-analytics ceiling (matches the Python adapter)

export type EventKind = "reaction" | "system" | "media" | "text" | "other";

export interface NormalizedThread {
  platform: "imessage";
  thread_id: string;
  is_group: boolean;
  participant_count: number;
  display_name: string | null;
  last_event_ts_ms: number | null;
}

export interface NormalizedEvent {
  platform: "imessage";
  thread_id: string;
  event_id: string;
  sender_key: string | null;
  from_me: boolean;
  ts_ms: number | null;
  kind: EventKind;
  text_len: number | null;
}

export interface NormalizedExport {
  schema_version: "1.0";
  source_platform: "imessage";
  window: { since_ms: number; until_ms: number };
  generated_at_ms: number;
  truncated: boolean;
  threads: NormalizedThread[];
  events: NormalizedEvent[];
}

// `message.date` is Apple-epoch nanoseconds on High Sierra+ (~1.8e18) and
// seconds on older macOS (~7e8); the magnitude check disambiguates. Mirrors
// the Python `apple_to_ms` EXACTLY — both languages cast the integer to an
// IEEE-754 double for the `/1e9`, so the rounded ms is byte-identical.
export function appleToMs(d: number | bigint | null): number | null {
  if (d == null) return null;
  const dn = typeof d === "bigint" ? Number(d) : d;
  const secs = Math.abs(dn) > 1e12 ? dn / 1e9 : dn;
  return roundHalfEven((secs + APPLE_EPOCH) * 1000);
}

function msToAppleNs(ms: number): number {
  return Math.trunc((ms / 1000 - APPLE_EPOCH) * 1e9);
}

// Python's built-in round() uses banker's rounding (round-half-to-even);
// JS Math.round() rounds half toward +Infinity. They differ by 1 only when
// the value lands exactly on a `.5` boundary with an even integer part —
// 11 of ~105k events on a real chat.db. Metric-irrelevant (1ms on
// minute-scale buckets), but matching it keeps the export parity gate a
// strict equality check.
function roundHalfEven(x: number): number {
  const floor = Math.floor(x);
  const frac = x - floor;
  if (frac < 0.5) return floor;
  if (frac > 0.5) return floor + 1;
  return floor % 2 === 0 ? floor : floor + 1;
}

// Normalize a chat.db handle id to a stable key: lowercase emails, "+digits"
// for phones, pass through anything else. Mirrors the Python `norm_handle`.
export function normHandle(hid: string | null): string | null {
  if (!hid) return null;
  if (hid.includes("@")) return hid.toLowerCase();
  const digits = hid.replace(/^\+/, "");
  if (/^\d+$/.test(digits)) return "+" + digits;
  return hid;
}

// Classify a message row. Mirrors the Python `kind_for`:
//   tapback (associated_message_type 2000-3999) → reaction
//   non-zero item_type (group rename, add/leave) → system
//   has attachment → media
//   has a text column OR an attributedBody → text
//   otherwise → other
export function kindFor(
  assoc: number | null,
  itemType: number | null,
  hasAttach: number | boolean | null,
  tlen: number | null,
  hasBody: boolean,
): EventKind {
  if (assoc && assoc >= 2000 && assoc <= 3999) return "reaction";
  if (itemType && itemType !== 0) return "system";
  if (hasAttach) return "media";
  if (tlen || hasBody) return "text";
  return "other";
}

export interface ExportArgs {
  dbPath: string;
  /** Bound to the last N days from now. Ignored when allTime is true. */
  sinceDays?: number;
  sinceMs?: number;
  untilMs?: number;
  allTime?: boolean;
  /** Injectable clock for deterministic tests (unix ms). */
  nowMs?: number;
}

interface ChatRow {
  ROWID: number;
  guid: string;
  style: number | null;
  display_name: string | null;
  chat_identifier: string | null;
}

interface MessageRow {
  guid: string;
  date: number | bigint | null;
  is_from_me: number;
  item_type: number | null;
  assoc: number | null;
  att: number | null;
  tlen: number | null;
  ab: Uint8Array | null;
  sender: string | null;
  chat_id: number;
}

export function exportChatDb(args: ExportArgs): NormalizedExport {
  const untilMs = args.nowMs ?? Date.now();
  let sinceMs: number;
  let sinceNs: number;
  if (args.allTime) {
    sinceMs = 0;
    sinceNs = 0;
  } else {
    const sinceDays = Math.min(args.sinceDays ?? TWO_YEAR_DAYS, TWO_YEAR_DAYS);
    sinceMs = untilMs - sinceDays * 86400 * 1000;
    sinceNs = Math.trunc((sinceMs / 1000 - APPLE_EPOCH) * 1e9);
  }

  const db = new Database(args.dbPath, { readonly: true });
  db.exec("PRAGMA query_only = ON;");

  try {
    // Thread dimension: participant counts + chat metadata.
    const pcount = new Map<number, number>();
    for (const r of db
      .query<{ chat_id: number; n: number }, []>(
        "SELECT chat_id, COUNT(*) AS n FROM chat_handle_join GROUP BY chat_id",
      )
      .all()) {
      pcount.set(r.chat_id, r.n);
    }

    const threads: NormalizedThread[] = [];
    // chat ROWID → [thread_id, is_group]
    const rowidToTid = new Map<number, { tid: string; isGroup: boolean }>();
    for (const r of db
      .query<ChatRow, []>("SELECT ROWID, guid, style, display_name, chat_identifier FROM chat")
      .all()) {
      const isGroup = r.style === 43;
      const tid = `imessage:${r.guid}`;
      rowidToTid.set(r.ROWID, { tid, isGroup });
      const n = (pcount.get(r.ROWID) ?? 1) + 1; // + the user
      threads.push({
        platform: "imessage",
        thread_id: tid,
        is_group: isGroup,
        participant_count: n,
        display_name: r.display_name || r.chat_identifier || null,
        last_event_ts_ms: null, // backfilled below
      });
    }

    // Event stream.
    const events: NormalizedEvent[] = [];
    const rows = db
      .query<MessageRow, [number]>(
        `SELECT m.guid AS guid, m.date AS date,
                m.is_from_me AS is_from_me, m.item_type AS item_type,
                m.associated_message_type AS assoc, m.cache_has_attachments AS att,
                LENGTH(m.text) AS tlen, m.attributedBody AS ab,
                h.id AS sender, cmj.chat_id AS chat_id
           FROM message m
           JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
           LEFT JOIN handle h ON h.ROWID = m.handle_id
          WHERE m.date >= ?`,
      )
      .all(sinceNs);

    for (const r of rows) {
      const sess = rowidToTid.get(r.chat_id);
      if (!sess) continue;
      const fromMe = r.is_from_me === 1;
      const sender = fromMe ? null : normHandle(r.sender);
      let tlen = r.tlen;
      if (!tlen && r.ab != null) {
        const dec = decodeAttributedBody(r.ab);
        // Count CODE POINTS, not UTF-16 code units — SQLite's LENGTH(text)
        // (the non-null-text path) counts code points, and the Python
        // reference uses len(str). JS `.length` would count an emoji as 2,
        // drifting text_len (which feeds the Talker/Listener word counts).
        tlen = dec ? [...dec].length : null;
      }
      events.push({
        platform: "imessage",
        thread_id: sess.tid,
        event_id: `imessage:${r.guid}`,
        sender_key: sender,
        from_me: fromMe,
        ts_ms: appleToMs(r.date),
        kind: kindFor(r.assoc, r.item_type, r.att, tlen, r.ab != null),
        text_len: tlen,
      });
    }

    // Backfill last_event_ts_ms per thread; drop threads with no events.
    const last = new Map<string, number>();
    for (const e of events) {
      if (e.ts_ms != null && e.ts_ms > (last.get(e.thread_id) ?? 0)) {
        last.set(e.thread_id, e.ts_ms);
      }
    }
    for (const t of threads) {
      t.last_event_ts_ms = last.get(t.thread_id) ?? null;
    }

    return {
      schema_version: "1.0",
      source_platform: "imessage",
      window: { since_ms: sinceMs, until_ms: untilMs },
      generated_at_ms: untilMs,
      truncated: false,
      threads: threads.filter((t) => last.has(t.thread_id)),
      events,
    };
  } finally {
    db.close();
  }
}

// ── message-body read (the ONE content-reading path) ────────────────────────
//
// The emoji/style/age pass needs message TEXT, which the metadata-only export
// above deliberately omits. This read produces { text, from_me, kind, assoc }
// rows for emoji_stats — the same shape the Python skill feeds emoji_stats.py.
// Bodies live only in memory here; emoji_stats emits aggregates ONLY and a
// guard rejects any body leak. Reuses the proven kindFor + decoder.

export interface MessageBody {
  text: string | null;
  from_me: boolean;
  kind: EventKind;
  assoc: number | null;
  ts_ms?: number | null;
}

interface BodyRow {
  date: number | bigint | null;
  is_from_me: number;
  item_type: number | null;
  assoc: number | null;
  att: number | null;
  text: string | null;
  ab: Uint8Array | null;
}

export function exportMessageBodies(args: ExportArgs): MessageBody[] {
  const untilMs = args.nowMs ?? Date.now();
  const effectiveUntilMs = args.untilMs ?? untilMs;
  const sinceMs = args.sinceMs ?? (
    args.allTime
      ? 0
      : untilMs - Math.min(args.sinceDays ?? TWO_YEAR_DAYS, TWO_YEAR_DAYS) * 86400 * 1000
  );
  const sinceNs = msToAppleNs(sinceMs);
  const untilNs = msToAppleNs(effectiveUntilMs);

  const db = new Database(args.dbPath, { readonly: true });
  db.exec("PRAGMA query_only = ON;");
  try {
    const rows = db
      .query<BodyRow, [number, number]>(
        `SELECT m.date AS date, m.is_from_me AS is_from_me, m.item_type AS item_type,
                m.associated_message_type AS assoc, m.cache_has_attachments AS att,
                m.text AS text, m.attributedBody AS ab
           FROM message m
          WHERE m.date >= ? AND m.date <= ?`,
      )
      .all(sinceNs, untilNs);

    const out: MessageBody[] = [];
    for (const r of rows) {
      const body = r.text ?? decodeAttributedBody(r.ab);
      const tlen = body ? [...body].length : null;
      out.push({
        text: body,
        from_me: r.is_from_me === 1,
        kind: kindFor(r.assoc, r.item_type, r.att, tlen, r.ab != null),
        assoc: r.assoc,
        ts_ms: appleToMs(r.date),
      });
    }
    return out;
  } finally {
    db.close();
  }
}
