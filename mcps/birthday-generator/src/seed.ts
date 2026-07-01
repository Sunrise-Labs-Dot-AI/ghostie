// Seed for the LLM-built birthday list: "who you're in regular contact with"
// (recent + real back-and-forth, OR a recent call), INCLUDING people with no saved
// birthday — that's where the gaps are. For people WITHOUT a saved birthday, infer
// an approximate birthday from the DATE of a past "happy birthday" text (the
// strongest free signal). The birthday-reminder skill takes this seed, confirms /
// sources the rest, asks the user about what's left, and produces the final list.
//
// Privacy: metadata-only. The wish-date inference reads message text on-device ONLY
// to match the birthday phrase + take the send date; it emits a month-day, never a
// body. NOTE: we do NOT use signals.ts's substring `assertNoBodyLeak` here — that
// guard assumes a body-free output (counts/booleans), but the SEED output contains
// contact NAMES (free text), which legitimately coincide with scanned message text
// and false-positive the guard (it crashed on real data). The only field derived
// from a body is `inferred_birthday`, so we instead assert it's a strict MM-DD —
// a precise, false-positive-free guarantee that no body content can leak.

import { Database } from "bun:sqlite";
import { readCallHistory, type CallAgg } from "./callhistory.ts";
import { appleDateToIsoUtc } from "../../imessage-drafts/src/chatdb/open.ts";
import { scanOneToOne, scanPerChat, BDAY_RE, PrivacyGuardError } from "./signals.ts";
import { looksLikeBusiness } from "../../wrapped-generator/src/business.ts";

const DAY_MS = 86_400_000;
const APPLE_EPOCH = 978_307_200; // 2001-01-01 UTC, unix seconds (for the wish-scan lookback)
const WISH_LOOKBACK_YEARS = 8;

export interface SeedContact {
  name: string;
  best_handle: string | null; // dispatchable (chat.db E.164 / call address)
  saved_birthday: string | null; // MM-DD / YYYY-MM-DD if already known
  inferred_birthday: string | null; // MM-DD inferred from a past wish (no-saved only)
  out_count: number;
  call_count: number;
  last_texted_days: number | null;
  last_call_days: number | null;
  reason: string;
}

export interface SeedResult {
  available: boolean; // false when chat.db can't be opened (no Full Disk Access)
  contacts: SeedContact[];
}

export interface SeedOpts {
  nowMs: number;
  callDbPath?: string;
  textRecencyDays?: number; // default 365 (the "Active relationships" preset)
  minOut?: number; // default 5
  callRecencyDays?: number; // default 365
  limit?: number; // default 300
  mutedCanon?: Set<string>; // canon handles the user dismissed — excluded from the seed
}

interface Agg { canon: string; original: string | null; out: number; lastRaw: number | null; chatIds: number[] }

function daysSinceApple(raw: number | bigint | null, nowMs: number): number | null {
  const iso = appleDateToIsoUtc(raw);
  if (!iso) return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : Math.max(0, Math.floor((nowMs - ms) / DAY_MS));
}

export function buildSeed(
  dbPath: string,
  nameByCanon: Map<string, string>,
  savedByCanon: Map<string, string>,
  opts: SeedOpts,
): SeedResult {
  const textRecencyDays = opts.textRecencyDays ?? 365;
  const minOut = opts.minOut ?? 5;
  const callRecencyDays = opts.callRecencyDays ?? 365;
  const limit = opts.limit ?? 300;

  let db: Database;
  try {
    db = new Database(dbPath, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch {
    return { available: false, contacts: [] };
  }

  try {
    // Per-canon text aggregate (1:1 only): outbound count + most-recent message
    // (either direction, for recency) + the chats (for the wish scan).
    const oneToOne = scanOneToOne(db);
    const byCanon = new Map<string, Agg>();
    for (const row of scanPerChat(db)) {
      const o = oneToOne.get(row.chat_id);
      if (!o) continue;
      const a = byCanon.get(o.canon) ?? { canon: o.canon, original: o.original, out: 0, lastRaw: null, chatIds: [] };
      a.out += Number(row.out_cnt ?? 0);
      const lastNum = row.last_date == null ? null : Number(row.last_date);
      if (lastNum != null && (a.lastRaw == null || lastNum > a.lastRaw)) a.lastRaw = lastNum;
      a.chatIds.push(row.chat_id);
      byCanon.set(o.canon, a);
    }

    const perCall: Map<string, CallAgg> = opts.callDbPath ? readCallHistory(opts.callDbPath) : new Map();

    // Threshold filter (Active relationships): recent text + real back-and-forth,
    // OR a recent call. Union of texters and callers.
    const muted = opts.mutedCanon ?? new Set<string>();
    const canons = new Set<string>([...byCanon.keys(), ...perCall.keys()]);
    const kept: { agg: Agg; calls: number; lastCallMs: number | null }[] = [];
    for (const canon of canons) {
      if (muted.has(canon)) continue; // user dismissed them — keep out of birthday flows
      const agg = byCanon.get(canon) ?? {
        canon, original: perCall.get(canon)?.original ?? null, out: 0, lastRaw: null, chatIds: [],
      };
      const call = perCall.get(canon);
      const calls = call?.count ?? 0;
      const lastCallMs = call?.lastMs ?? null;
      const lastTextedDays = daysSinceApple(agg.lastRaw, opts.nowMs);
      const lastCallDays = lastCallMs == null ? null : Math.max(0, Math.floor((opts.nowMs - lastCallMs) / DAY_MS));
      const regular =
        (lastTextedDays != null && lastTextedDays <= textRecencyDays && agg.out >= minOut) ||
        (lastCallDays != null && lastCallDays <= callRecencyDays && calls > 0);
      if (regular) kept.push({ agg, calls, lastCallMs });
    }

    // Wish-date inference, scoped to the no-saved-birthday kept contacts' chats.
    const inferTargets = new Map<number, string>(); // chat_id -> canon
    for (const k of kept) {
      if (savedByCanon.has(k.agg.canon)) continue;
      for (const cid of k.agg.chatIds) if (!inferTargets.has(cid)) inferTargets.set(cid, k.agg.canon);
    }
    const inferred = inferBirthdaysFromWishes(db, inferTargets, opts.nowMs);

    const contacts: SeedContact[] = [];
    for (const k of kept) {
      const name = nameByCanon.get(k.agg.canon);
      if (!name) continue; // unnamed handle — can't present it usefully
      // Shared business filter (handle + name): a birthday list is for people,
      // not businesses — keep DoorDash, a pharmacy, or a saved "One Medical" out
      // so the user never has to dismiss them. Same filter Don't Ghost + Keep
      // Tabs use.
      if (looksLikeBusiness(k.agg.original, name)) continue;
      const lastTextedDays = daysSinceApple(k.agg.lastRaw, opts.nowMs);
      const lastCallDays = k.lastCallMs == null ? null : Math.max(0, Math.floor((opts.nowMs - k.lastCallMs) / DAY_MS));
      const saved = savedByCanon.get(k.agg.canon) ?? null;
      contacts.push({
        name,
        best_handle: k.agg.original,
        saved_birthday: saved,
        inferred_birthday: saved ? null : (inferred.get(k.agg.canon) ?? null),
        out_count: k.agg.out,
        call_count: k.calls,
        last_texted_days: lastTextedDays,
        last_call_days: lastCallDays,
        reason: reasonFor(k.agg.out, k.calls, lastTextedDays, lastCallDays),
      });
    }

    // Rank by combined affinity (a call weighted a bit higher than a text). We do
    // NOT de-dupe by name: two genuinely distinct people can share a display name,
    // and collapsing them would silently drop a real contact (the seed's whole job
    // is to surface everyone). Rows are already per-canon-handle; a single person
    // with two handles may appear twice — minor, and the LLM/user reconciles it.
    const score = (c: SeedContact) => c.call_count * 3 + c.out_count;
    const ranked = contacts.sort((x, y) => score(y) - score(x)).slice(0, limit);

    // Defense-in-depth: the ONLY field derived from message content is
    // `inferred_birthday`, which is built as a month-day. Assert exactly that — a
    // precise guard (no false positives on the name-bearing output) that trips
    // loudly if a future change ever lets body text reach this field.
    for (const c of ranked) {
      if (c.inferred_birthday != null && !/^\d{2}-\d{2}$/.test(c.inferred_birthday)) {
        throw new PrivacyGuardError(`seed guard: inferred_birthday not MM-DD ('${c.inferred_birthday}')`);
      }
    }
    return { available: true, contacts: ranked };
  } finally {
    db.close();
  }
}

function reasonFor(out: number, calls: number, lastTextedDays: number | null, lastCallDays: number | null): string {
  const parts: string[] = [];
  if (out > 0) parts.push(`${out} text${out === 1 ? "" : "s"}${lastTextedDays != null ? `, last ${lastTextedDays}d ago` : ""}`);
  if (calls > 0) parts.push(`${calls} call${calls === 1 ? "" : "s"}${lastCallDays != null ? `, last ${lastCallDays}d ago` : ""}`);
  return parts.join("; ");
}

// For each target chat, find outbound birthday-wish messages; the send month-day
// approximates the contact's birthday. Returns canon -> "MM-DD" (most recent wish).
//
// Reads only the `text` column (modern messages store plaintext there), pre-filtered
// by a case-insensitive LIKE + an 8-year lookback so the scan stays cheap; BDAY_RE
// then confirms. We deliberately do NOT scan `attributedBody` / `text IS NULL` here:
// it would decode every old message (slow) and, more importantly, pull arbitrary
// message content that's irrelevant to inference. Older attributedBody-only wishes
// are missed (best-effort) — the skill asks the user about anyone left unresolved.
//
// Timezone: the month-day is taken in the host's LOCAL tz from the message instant.
// For this single-user-on-their-own-Mac tool that's the right call (the wish was
// composed in this Mac's tz), but a wish sent near local midnight can land a day
// off, so `inferred_birthday` is APPROXIMATE — the skill / user confirms it.
function inferBirthdaysFromWishes(
  db: Database,
  chatToCanon: Map<number, string>,
  nowMs: number,
): Map<string, string> {
  const inferred = new Map<string, string>();
  const chatIds = [...chatToCanon.keys()];
  if (chatIds.length === 0) return inferred;

  const sinceMs = nowMs - WISH_LOOKBACK_YEARS * 365.25 * DAY_MS;
  const sinceNs = Math.trunc((sinceMs / 1000 - APPLE_EPOCH) * 1e9);
  const placeholders = chatIds.map(() => "?").join(",");
  const best = new Map<string, { md: string; ms: number }>();
  const rows = db
    .query<{ chat_id: number; date: number | bigint | null; text: string | null }, number[]>(
      `SELECT cmj.chat_id AS chat_id, m.date AS date, m.text AS text
         FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE m.is_from_me = 1 AND cmj.chat_id IN (${placeholders}) AND m.date >= ?
          AND (m.text LIKE '%irthday%' OR m.text LIKE '%bday%' OR m.text LIKE '%hbd%')`,
    )
    .all(...chatIds, sinceNs);
  for (const row of rows) {
    const canon = chatToCanon.get(row.chat_id);
    if (!canon || !row.text || !BDAY_RE.test(row.text)) continue;
    const iso = appleDateToIsoUtc(row.date);
    if (!iso) continue;
    const ms = Date.parse(iso);
    if (Number.isNaN(ms) || ms > nowMs) continue;
    const d = new Date(ms);
    const md = `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    const prev = best.get(canon);
    if (!prev || ms > prev.ms) best.set(canon, { md, ms }); // most recent wish wins
  }
  for (const [canon, v] of best) inferred.set(canon, v.md);
  return inferred;
}
