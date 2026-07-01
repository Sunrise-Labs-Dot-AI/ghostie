// The identification engine: reads chat.db (read-only) to score WHO to text.
//   - frequency: outbound substantive count per 1:1 contact + global rank
//   - recency: days since the last message in either direction
//   - wished-before: did the user send this person a birthday text near their
//     birthday in a prior year — detected on-device, emitting ONLY a boolean +
//     year(s), never a message body (privacy guard enforces this).
//
// Best-effort: if chat.db can't be opened (no Full Disk Access), returns
// available:false and baseline (zero) signals so the tool still lists birthdays.

import { Database } from "bun:sqlite";
import { decodeAttributedBody } from "../../imessage-drafts/src/chatdb/decode.ts";
import { appleDateToIsoUtc } from "../../imessage-drafts/src/chatdb/open.ts";
import { canonHandle } from "../../imessage-drafts/src/chatdb/canon.ts";
import { readCallHistory, type CallAgg } from "./callhistory.ts";

const APPLE_EPOCH = 978307200; // 2001-01-01 UTC, unix seconds
const DAY_MS = 86_400_000;
// Birthday-wish phrasing. The ±window date proximity below keeps "bday"/
// "birthday" from false-firing on unrelated mentions. Exported so the seed scan
// (seed.ts) can reuse it for wish-date birthday inference.
export const BDAY_RE = /(happy.{0,12}b(?:irth)?day|\bhbd\b|\bbday\b|\bbirthday\b)/i;

export interface SignalCandidate {
  key: string; // stable id to map results back (caller-assigned)
  handles: string[]; // canonical
  month: number;
  day: number;
}

export interface ContactSignals {
  out_count: number;
  text_rank: number | null; // 1-based among all 1:1 contacts by outbound text volume
  call_count: number;
  call_rank: number | null; // 1-based among all contacts by call volume
  last_texted_days: number | null;
  last_call_days: number | null;
  wished_before: boolean;
  wished_years: number[];
}

export interface SignalsResult {
  byKey: Map<string, ContactSignals>;
  available: boolean; // false when chat.db couldn't be read
}

export interface SignalsOpts {
  topN: number;
  nowMs?: number;
  wishedWindowDays?: number; // ± days around the birthday to count as a wish
  lookbackYears?: number; // how far back to scan for prior wishes
  callDbPath?: string; // CallHistory DB; omit to skip the call signal
}

export class PrivacyGuardError extends Error {}

// Defense-in-depth regression guard. The result shape carries ONLY
// counts/booleans/years today — no body is ever assigned into it — so this has
// nothing to catch in the current code. It exists so a FUTURE field that
// accidentally embeds message text (e.g. a "matched wish preview") fails loudly
// in tests/CI instead of leaking. The REAL invariant is enforced by
// construction (we only write primitives); this is belt-and-suspenders.
//
// It looks for a multi-word body appearing verbatim in the serialized output.
// The space requirement is deliberate: the serialized output is space-free JSON
// of numbers/booleans/years, so requiring a space means it can ONLY match if a
// future field embeds a real (multi-word) message body — and it avoids false
// positives where a numeric body like "2024" coincides with a year in
// wished_years or a short body equals a JSON key. Limits: a single-token body
// (no space) is not caught; if you add a string field sourced from chat.db,
// scrutinize that line directly rather than trusting this scan.
export function assertNoBodyLeak(serialized: string, bodies: Iterable<string>): void {
  for (const b of bodies) {
    const t = b.trim();
    if (t.includes(" ") && t.length >= 6 && serialized.includes(t)) {
      throw new PrivacyGuardError(`privacy guard tripped: a ${t.length}-char message body leaked into output`);
    }
  }
}

function baseline(candidates: SignalCandidate[]): Map<string, ContactSignals> {
  const m = new Map<string, ContactSignals>();
  for (const c of candidates) {
    m.set(c.key, {
      out_count: 0,
      text_rank: null,
      call_count: 0,
      call_rank: null,
      last_texted_days: null,
      last_call_days: null,
      wished_before: false,
      wished_years: [],
    });
  }
  return m;
}

function appleToMs(raw: number | bigint | null): number | null {
  const iso = appleDateToIsoUtc(raw);
  if (!iso) return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : ms;
}

function nearAnniversary(msg: Date, month: number, day: number, windowDays: number): boolean {
  for (const yr of [msg.getFullYear() - 1, msg.getFullYear(), msg.getFullYear() + 1]) {
    const t = new Date(yr, month - 1, day);
    const diff = Math.abs(Math.round((msg.getTime() - t.getTime()) / DAY_MS));
    if (diff <= windowDays) return true;
  }
  return false;
}

interface ChatAgg { out: number; last: number | null; chatIds: number[] }

// 1:1 chat → its single contact handle (canonical + the original dispatchable
// form from chat.db, e.g. +14045550147). Shared by computeSignals and the gaps
// scan so the SQL lives in one place.
export interface OneToOne { canon: string; original: string }
export function scanOneToOne(db: Database): Map<number, OneToOne> {
  const m = new Map<number, OneToOne>();
  for (const r of db
    .query<{ chat_id: number; pc: number; hid: string | null }, []>(
      `SELECT chj.chat_id AS chat_id, COUNT(*) AS pc, MIN(h.id) AS hid
         FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
        GROUP BY chj.chat_id`,
    )
    .all()) {
    if (r.pc === 1 && r.hid) m.set(r.chat_id, { canon: canonHandle(r.hid), original: r.hid });
  }
  return m;
}

export interface PerChatRow { chat_id: number; out_cnt: number; last_date: number | bigint | null }
export function scanPerChat(db: Database): PerChatRow[] {
  return db
    .query<PerChatRow, []>(
      `SELECT cmj.chat_id AS chat_id,
              SUM(CASE WHEN m.is_from_me = 1
                        AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3999)
                        AND (m.item_type IS NULL OR m.item_type = 0)
                       THEN 1 ELSE 0 END) AS out_cnt,
              MAX(m.date) AS last_date
         FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        GROUP BY cmj.chat_id`,
    )
    .all();
}

export function computeSignals(
  dbPath: string,
  candidates: SignalCandidate[],
  opts: SignalsOpts,
): SignalsResult {
  const byKey = baseline(candidates);
  if (candidates.length === 0) return { byKey, available: true };

  const nowMs = opts.nowMs ?? Date.now();
  const wishedWindowDays = opts.wishedWindowDays ?? 3;
  const lookbackYears = opts.lookbackYears ?? 8;

  let db: Database;
  try {
    db = new Database(dbPath, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch {
    return { byKey, available: false };
  }

  try {
    // 1:1 detection + per-chat aggregates (shared with the gaps scan).
    const oneToOne = scanOneToOne(db);
    const perChat = scanPerChat(db);

    // Fold into per-canonical-handle aggregates (1:1 only).
    const perCanon = new Map<string, ChatAgg>();
    for (const row of perChat) {
      const canon = oneToOne.get(row.chat_id)?.canon;
      if (!canon) continue;
      const agg = perCanon.get(canon) ?? { out: 0, last: null, chatIds: [] };
      agg.out += Number(row.out_cnt ?? 0);
      const lastNum = row.last_date == null ? null : Number(row.last_date);
      if (lastNum != null && (agg.last == null || lastNum > agg.last)) agg.last = lastNum;
      agg.chatIds.push(row.chat_id);
      perCanon.set(canon, agg);
    }

    // Global text rank by outbound volume (1-based; only contacts with >0 outbound).
    const textRanked = [...perCanon.entries()]
      .filter(([, a]) => a.out > 0)
      .sort((x, y) => y[1].out - x[1].out);
    const textRankByCanon = new Map<string, number>();
    textRanked.forEach(([canon], i) => textRankByCanon.set(canon, i + 1));

    // Call history (best-effort, metadata-only) → a separate affinity axis. The
    // person you call but rarely text (a parent) ranks here, not in text. lastMs
    // is already unix-ms (Core Data epoch handled in the reader).
    const perCall: Map<string, CallAgg> = opts.callDbPath ? readCallHistory(opts.callDbPath) : new Map();
    const callRanked = [...perCall.entries()]
      .filter(([, a]) => a.count > 0)
      .sort((x, y) => y[1].count - x[1].count);
    const callRankByCanon = new Map<string, number>();
    callRanked.forEach(([canon], i) => callRankByCanon.set(canon, i + 1));

    // Per-candidate fold + chat_id → candidate map for the wish scan.
    const chatIdToKey = new Map<number, string>();
    for (const cand of candidates) {
      const sig = byKey.get(cand.key)!;
      let out = 0;
      let lastRaw: number | null = null;
      let bestTextRank: number | null = null;
      let callCount = 0;
      let lastCallMs: number | null = null;
      let bestCallRank: number | null = null;
      for (const h of cand.handles) {
        const agg = perCanon.get(h);
        if (agg) {
          out += agg.out;
          if (agg.last != null && (lastRaw == null || agg.last > lastRaw)) lastRaw = agg.last;
          const r = textRankByCanon.get(h);
          if (r != null && (bestTextRank == null || r < bestTextRank)) bestTextRank = r;
          for (const cid of agg.chatIds) if (!chatIdToKey.has(cid)) chatIdToKey.set(cid, cand.key);
        }
        const call = perCall.get(h);
        if (call) {
          callCount += call.count;
          if (call.lastMs != null && (lastCallMs == null || call.lastMs > lastCallMs)) lastCallMs = call.lastMs;
          const cr = callRankByCanon.get(h);
          if (cr != null && (bestCallRank == null || cr < bestCallRank)) bestCallRank = cr;
        }
      }
      sig.out_count = out;
      sig.text_rank = bestTextRank;
      sig.call_count = callCount;
      sig.call_rank = bestCallRank;
      const lastMs = appleToMs(lastRaw);
      sig.last_texted_days = lastMs == null ? null : Math.max(0, Math.floor((nowMs - lastMs) / DAY_MS));
      sig.last_call_days = lastCallMs == null ? null : Math.max(0, Math.floor((nowMs - lastCallMs) / DAY_MS));
    }

    // Wished-before scan, scoped to candidate chats only.
    const chatIds = [...chatIdToKey.keys()];
    const seenBodies: string[] = [];
    if (chatIds.length > 0) {
      const sinceMs = nowMs - lookbackYears * 365.25 * DAY_MS;
      const sinceNs = Math.trunc((sinceMs / 1000 - APPLE_EPOCH) * 1e9);
      const placeholders = chatIds.map(() => "?").join(",");
      const rows = db
        .query<{ chat_id: number; date: number | bigint | null; text: string | null; ab: Uint8Array | null }, (number)[]>(
          `SELECT cmj.chat_id AS chat_id, m.date AS date, m.text AS text, m.attributedBody AS ab
             FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE m.is_from_me = 1 AND cmj.chat_id IN (${placeholders}) AND m.date >= ?`,
        )
        .all(...chatIds, sinceNs);

      const candByKey = new Map(candidates.map((c) => [c.key, c]));
      for (const row of rows) {
        const key = chatIdToKey.get(row.chat_id);
        if (!key) continue;
        const cand = candByKey.get(key);
        if (!cand) continue;
        const body = row.text ?? decodeAttributedBody(row.ab);
        if (!body) continue;
        seenBodies.push(body);
        const ms = appleToMs(row.date);
        if (ms == null) continue;
        const when = new Date(ms);
        if (!nearAnniversary(when, cand.month, cand.day, wishedWindowDays)) continue;
        if (!BDAY_RE.test(body)) continue;
        const sig = byKey.get(key)!;
        sig.wished_before = true;
        const yr = when.getFullYear();
        if (!sig.wished_years.includes(yr)) sig.wished_years.push(yr);
      }
    }

    // Privacy guard: no decoded body may appear in the serialized result.
    const result: SignalsResult = { byKey, available: true };
    assertNoBodyLeak(JSON.stringify([...byKey.values()]), seenBodies);
    for (const sig of byKey.values()) sig.wished_years.sort((a, b) => a - b);
    return result;
  } finally {
    db.close();
  }
}
