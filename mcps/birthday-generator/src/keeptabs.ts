// Keep Tabs recommendation engine: "who should I keep tabs on?" Reuses the
// birthday seed's per-canon text aggregation (scanOneToOne/scanPerChat) + the
// call-history affinity signal to recommend PEOPLE worth a recurring check-in,
// each with a suggested contact cadence. The user then picks who to actually
// watch in the Keep Tabs mini-app.
//
// vs. the --seed mode: seed surfaces *everyone* in regular contact for the
// birthday list-builder. Keep Tabs is tighter — it ranks by combined
// text+call affinity, FILTERS OUT BUSINESSES (shortcodes, toll-free, alpha
// sender IDs) via counterpartyClass, excludes anyone already on the watchlist,
// and derives a per-person suggested frequency. Recommendations the user adds
// become the watchlist the menu-bar app priority-queues against.
//
// Privacy: metadata-only — counts, day-deltas, names, and dispatchable handles.
// Never reads or emits message bodies (no wish-inference scan here at all).
// Best-effort: chat.db unreadable (no Full Disk Access) → available:false.

import { Database } from "bun:sqlite";
import { readCallHistory, readCallDates, type CallAgg } from "./callhistory.ts";
import { appleDateToIsoUtc } from "../../imessage-drafts/src/chatdb/open.ts";
import { scanOneToOne, scanPerChat } from "./signals.ts";
import { looksLikeBusiness } from "../../wrapped-generator/src/business.ts";

const DAY_MS = 86_400_000;

// Suggested-frequency presets (days). Named presets in the UI map to these.
export const FREQ_WEEKLY = 7;
export const FREQ_BIWEEKLY = 14;
export const FREQ_MONTHLY = 30;
export const FREQ_QUARTERLY = 90;
export const FREQ_SEMIANNUAL = 180;
export const FREQ_YEARLY = 365;

export interface KeepTabsRecommendation {
  name: string;
  best_handle: string | null; // dispatchable (chat.db E.164 / email / call address)
  out_count: number;
  call_count: number;
  last_texted_days: number | null;
  last_call_days: number | null;
  suggested_frequency_days: number;
  why: string;
}

export interface KeepTabsResult {
  available: boolean; // false when chat.db can't be opened (no Full Disk Access)
  recommendations: KeepTabsRecommendation[];
}

export interface KeepTabsOpts {
  nowMs: number;
  callDbPath?: string;
  excludeCanon?: Set<string>; // canon handles already on the watchlist — never recommended
  limit?: number; // default 15
}

interface Agg { canon: string; original: string | null; out: number; lastRaw: number | null; lastChatId: number | null; chatIds: number[] }

function daysSinceApple(raw: number | bigint | null, nowMs: number): number | null {
  const iso = appleDateToIsoUtc(raw);
  if (!iso) return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : Math.max(0, Math.floor((nowMs - ms) / DAY_MS));
}

function appleToMs(raw: number | bigint | null): number | null {
  const iso = appleDateToIsoUtc(raw);
  if (!iso) return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : ms;
}

// Median gap (in days) between distinct DAYS you actually communicated with a
// person — your real conversational cadence, across BOTH texts AND calls/FaceTime
// (you might never text someone you call weekly). NOT the gap between individual
// messages: a single back-and-forth produces many sub-day gaps and would always
// read as "daily". We collapse the most recent ~400 messages + the person's call
// timestamps to distinct calendar days, then take the median gap between
// consecutive contact-days. Returns null when there's too little history to form
// a gap (caller falls back to the volume bucket).
function medianCadenceDays(db: Database, chatIds: number[], callMs: number[]): number | null {
  const dayset = new Set<number>();
  if (chatIds.length > 0) {
    const placeholders = chatIds.map(() => "?").join(",");
    const rows = db
      .query<{ date: number | bigint | null }, number[]>(
        `SELECT m.date AS date FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
          WHERE cmj.chat_id IN (${placeholders}) AND m.date IS NOT NULL
          ORDER BY m.date DESC LIMIT 400`,
      )
      .all(...chatIds);
    for (const r of rows) {
      const ms = appleToMs(r.date);
      if (ms != null) dayset.add(Math.floor(ms / DAY_MS)); // distinct day index (days since epoch)
    }
  }
  // Fold in call/FaceTime days (recent ~200 calls, so an old call-heavy era can't
  // skew a now-texting relationship).
  for (const ms of callMs.slice().sort((a, b) => b - a).slice(0, 200)) {
    dayset.add(Math.floor(ms / DAY_MS));
  }
  const days = [...dayset].sort((a, b) => a - b);
  if (days.length < 2) return null;
  const gaps: number[] = [];
  for (let i = 1; i < days.length; i++) gaps.push(days[i]! - days[i - 1]!); // already whole days
  gaps.sort((a, b) => a - b);
  const mid = gaps.length >> 1;
  const median = gaps.length % 2 ? gaps[mid]! : (gaps[mid - 1]! + gaps[mid]!) / 2;
  return Math.max(1, Math.round(median));
}

// Affinity score: a call counts a bit more than a text (you call the people you
// care about even when you don't text them). Same weighting as the seed rank.
export function affinityScore(outCount: number, callCount: number): number {
  return callCount * 3 + outCount;
}

// The more recent contact OF EITHER KIND (text or call), in days. null = no
// contact recorded on that axis; the overall min treats null as +∞.
export function lastContactedDays(
  lastTextedDays: number | null,
  lastCallDays: number | null,
): number | null {
  if (lastTextedDays == null) return lastCallDays;
  if (lastCallDays == null) return lastTextedDays;
  return Math.min(lastTextedDays, lastCallDays);
}

// Suggest a target cadence from observed volume + recency. High-volume / very
// recent relationships → weekly; moderate → biweekly; the long tail → monthly.
// It's only a suggestion: the user overrides it with the frequency picker.
export function suggestFrequencyDays(
  outCount: number,
  callCount: number,
  lastTextedDays: number | null,
  lastCallDays: number | null,
): number {
  const score = affinityScore(outCount, callCount);
  const recent = lastContactedDays(lastTextedDays, lastCallDays);
  if (score >= 80 || (recent != null && recent <= 10)) return FREQ_WEEKLY;
  if (score >= 30 || (recent != null && recent <= 25)) return FREQ_BIWEEKLY;
  return FREQ_MONTHLY;
}

// Tempering constants for suggestedCadence (see below).
const WARM_MULT = 3; // warm if last contact within 3× the person's own rhythm…
const WARM_GRACE_DAYS = 21; // …OR within 21 days absolute (protects tight-rhythm friends)

// The go-forward target cadence, recency-tempered. The raw median is the rhythm
// you had WHEN ACTIVE, computed over old messages regardless of when — so a
// relationship that went quiet months ago would otherwise surface its stale tight
// rhythm (the "texted Frank every 4 days" bug, when you haven't texted in 168
// days). Rule: keep the precise median while you're roughly keeping it; once
// you've gone quiet well past it, loosen toward the silence (biweekly → monthly →
// quarterly) and never suggest tighter than the silence warrants. Designed +
// adversarially verified against the real contact distribution (warm gate keeps
// every active contact's rhythm untouched; lapsed contacts bucket on absolute
// silence; monotonic in silence).
export function suggestedCadence(
  median: number | null,
  lastContacted: number | null,
  outCount: number,
  callCount: number,
): number {
  // Too little history to form a median gap → reuse the volume/recency bucket so
  // the gate always has a concrete rhythm to temper (one code path, no special
  // case downstream).
  let rhythm = median != null && median >= 1
    ? median
    : suggestFrequencyDays(outCount, callCount, lastContacted, null);

  let result: number;
  if (lastContacted == null) {
    // Never contacted → no rhythm to keep; default loose.
    result = Math.max(rhythm, FREQ_QUARTERLY);
  } else if (lastContacted <= WARM_MULT * rhythm || lastContacted <= WARM_GRACE_DAYS) {
    // WARM: roughly keeping cadence → keep the precise rhythm untouched.
    result = rhythm;
  } else {
    // LAPSED: bucket on absolute silence, but never tighter than the rhythm.
    // Long silences loosen all the way to semiannual / yearly — for a contact
    // you last reached 20 months ago, "once a year" is the realistic target.
    const bucket =
      lastContacted <= 30 ? FREQ_WEEKLY
      : lastContacted <= 45 ? FREQ_BIWEEKLY
      : lastContacted <= 90 ? FREQ_MONTHLY
      : lastContacted <= 180 ? FREQ_QUARTERLY
      : lastContacted <= 365 ? FREQ_SEMIANNUAL
      : FREQ_YEARLY;
    result = Math.max(rhythm, bucket);
  }
  // Cap at the loosest preset: a "rhythm" longer than a year is sparse-thread
  // noise, not a cadence (medianCadenceDays can report hundreds of days for a
  // 2-message thread), and the UI has no looser preset anyway.
  return Math.min(result, FREQ_YEARLY);
}

function reasonFor(
  out: number,
  calls: number,
  lastTextedDays: number | null,
  lastCallDays: number | null,
): string {
  const parts: string[] = [];
  if (out > 0) parts.push(`${out} text${out === 1 ? "" : "s"}${lastTextedDays != null ? `, last ${lastTextedDays}d ago` : ""}`);
  if (calls > 0) parts.push(`${calls} call${calls === 1 ? "" : "s"}${lastCallDays != null ? `, last ${lastCallDays}d ago` : ""}`);
  return parts.join("; ");
}

export function buildKeepTabsRecommendations(
  dbPath: string,
  nameByCanon: Map<string, string>,
  opts: KeepTabsOpts,
): KeepTabsResult {
  const limit = opts.limit ?? 15;
  const exclude = opts.excludeCanon ?? new Set<string>();

  let db: Database;
  try {
    db = new Database(dbPath, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch {
    return { available: false, recommendations: [] };
  }

  try {
    const contacts = aggregateContacts(db, opts);
    const callDates: Map<string, number[]> = opts.callDbPath ? readCallDates(opts.callDbPath) : new Map();
    const scored: { rec: KeepTabsRecommendation; canon: string; chatIds: number[] }[] = [];
    for (const c of contacts.values()) {
      if (exclude.has(c.canon)) continue; // already watched or dismissed
      const name = nameByCanon.get(c.canon);
      if (!name) continue; // unnamed handle — can't present it, and a watchlist needs a person
      // Shared business filter (handle + name): drops shortcodes, toll-free,
      // alpha senders, no-reply emails, AND saved business names (e.g. a clinic
      // on a plain number named "One Medical") so the user never has to dismiss
      // a business from their recommendations. Same filter Don't Ghost uses.
      if (looksLikeBusiness(c.original, name)) continue;
      if (c.out === 0 && c.callCount === 0) continue; // no signal at all

      scored.push({
        rec: {
          name,
          best_handle: c.original,
          out_count: c.out,
          call_count: c.callCount,
          last_texted_days: c.lastTextedDays,
          last_call_days: c.lastCallDays,
          suggested_frequency_days: 0, // filled in below for the returned top-N
          why: reasonFor(c.out, c.callCount, c.lastTextedDays, c.lastCallDays),
        },
        canon: c.canon,
        chatIds: c.chatIds,
      });
    }

    // Rank by combined affinity, then keep the top-N. Like the seed, we do NOT
    // de-dupe by name: two distinct people can share a display name, and one
    // person with two handles appearing twice is a minor, user-reconcilable
    // artifact.
    scored.sort((x, y) => affinityScore(y.rec.out_count, y.rec.call_count) - affinityScore(x.rec.out_count, x.rec.call_count));
    const top = scored.slice(0, limit);

    // Default cadence = the MEDIAN gap you already have with that person across
    // texts AND calls/FaceTime (their real rhythm). Computed only for the returned
    // top-N (one query each), with the volume bucket as a fallback when there
    // isn't enough history.
    for (const s of top) {
      const median = medianCadenceDays(db, s.chatIds, callDates.get(s.canon) ?? []);
      const recent = lastContactedDays(s.rec.last_texted_days, s.rec.last_call_days);
      s.rec.suggested_frequency_days = suggestedCadence(median, recent, s.rec.out_count, s.rec.call_count);
    }
    return { available: true, recommendations: top.map((s) => s.rec) };
  } finally {
    db.close();
  }
}

interface ContactAggregate {
  canon: string;
  original: string | null;
  out: number;
  lastTextedDays: number | null;
  callCount: number;
  lastCallDays: number | null;
  threadId: number | null; // chat ROWID of the most-recently-active 1:1 chat; null if call-only
  chatIds: number[]; // all 1:1 chat ROWIDs for this person (for the median-cadence query)
}

// Shared per-canon aggregation: 1:1 outbound text volume + most-recent message
// (either direction), plus call volume + most-recent call. Used by BOTH the
// recommend and status modes so there's one chat.db/CallHistory scan. The
// caller owns the open db.
function aggregateContacts(db: Database, opts: KeepTabsOpts): Map<string, ContactAggregate> {
  const oneToOne = scanOneToOne(db);
  const byCanon = new Map<string, Agg>();
  for (const row of scanPerChat(db)) {
    const o = oneToOne.get(row.chat_id);
    if (!o) continue;
    const a = byCanon.get(o.canon) ?? { canon: o.canon, original: o.original, out: 0, lastRaw: null, lastChatId: null, chatIds: [] };
    a.out += Number(row.out_cnt ?? 0);
    if (!a.chatIds.includes(row.chat_id)) a.chatIds.push(row.chat_id);
    const lastNum = row.last_date == null ? null : Number(row.last_date);
    if (lastNum != null && (a.lastRaw == null || lastNum > a.lastRaw)) {
      a.lastRaw = lastNum;
      a.lastChatId = row.chat_id; // the chat ROWID of the most-recently-active 1:1 thread
    }
    byCanon.set(o.canon, a);
  }
  const perCall: Map<string, CallAgg> = opts.callDbPath ? readCallHistory(opts.callDbPath) : new Map();
  const out = new Map<string, ContactAggregate>();
  for (const canon of new Set<string>([...byCanon.keys(), ...perCall.keys()])) {
    const agg = byCanon.get(canon);
    const call = perCall.get(canon);
    out.set(canon, {
      canon,
      original: agg?.original ?? call?.original ?? null,
      out: agg?.out ?? 0,
      lastTextedDays: daysSinceApple(agg?.lastRaw ?? null, opts.nowMs),
      callCount: call?.count ?? 0,
      lastCallDays: call?.lastMs == null ? null : Math.max(0, Math.floor((opts.nowMs - call.lastMs) / DAY_MS)),
      threadId: agg?.lastChatId ?? null,
      chatIds: agg?.chatIds ?? [],
    });
  }
  return out;
}

export interface KeepTabsStatus {
  canon: string;
  thread_id: number | null; // chat ROWID for the iMessage priority key; null if call-only / no thread
  last_texted_days: number | null;
  last_call_days: number | null;
}

export interface KeepTabsStatusResult {
  available: boolean; // false when chat.db can't be opened (no Full Disk Access)
  statuses: KeepTabsStatus[];
}

export interface KeepTabsCadence {
  canon: string;
  suggested_frequency_days: number;
  // The more-recent of last text / last call, in days (null = never contacted).
  // Lets the UI make its copy honest ("last in touch ~5 months ago") instead of
  // claiming a present-tense cadence the silence contradicts.
  last_contacted_days: number | null;
}

export interface KeepTabsCadenceResult {
  available: boolean;
  cadences: KeepTabsCadence[];
}

// Recency-tempered suggested cadence for ARBITRARY canons — used when the user
// searches a contact by name to add them manually, so the picker defaults to a
// realistic go-forward cadence (not a stale active-era rhythm) even though they
// aren't in the affinity-ranked recommend list. Also returns last-contacted so
// the UI copy can be honest about a lapsed relationship.
export function buildKeepTabsCadence(
  dbPath: string,
  canons: string[],
  opts: KeepTabsOpts,
): KeepTabsCadenceResult {
  const want = new Set(canons);
  if (want.size === 0) return { available: true, cadences: [] };

  let db: Database;
  try {
    db = new Database(dbPath, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch {
    return { available: false, cadences: [] };
  }

  try {
    const contacts = aggregateContacts(db, opts);
    const callDates: Map<string, number[]> = opts.callDbPath ? readCallDates(opts.callDbPath) : new Map();
    const cadences: KeepTabsCadence[] = [];
    for (const canon of want) {
      const c = contacts.get(canon);
      const median = medianCadenceDays(db, c?.chatIds ?? [], callDates.get(canon) ?? []);
      const recent = lastContactedDays(c?.lastTextedDays ?? null, c?.lastCallDays ?? null);
      const freq = suggestedCadence(median, recent, c?.out ?? 0, c?.callCount ?? 0);
      cadences.push({ canon, suggested_frequency_days: freq, last_contacted_days: recent });
    }
    return { available: true, cadences };
  } finally {
    db.close();
  }
}

// Live last-contacted (text + call) for a specific set of WATCHED canons — what
// the menu bar needs to decide who's overdue vs. their target cadence. Unlike
// recommend, it does NOT business-filter or require a saved name: the user has
// already chosen to watch these people. A requested canon with no recorded
// contact comes back with nulls (the caller treats that as "very quiet").
export function buildKeepTabsStatus(
  dbPath: string,
  canons: string[],
  opts: KeepTabsOpts,
): KeepTabsStatusResult {
  const want = new Set(canons);
  if (want.size === 0) return { available: true, statuses: [] };

  let db: Database;
  try {
    db = new Database(dbPath, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch {
    return { available: false, statuses: [] };
  }

  try {
    const contacts = aggregateContacts(db, opts);
    const statuses: KeepTabsStatus[] = [];
    for (const canon of want) {
      const c = contacts.get(canon);
      statuses.push({
        canon,
        thread_id: c?.threadId ?? null,
        last_texted_days: c?.lastTextedDays ?? null,
        last_call_days: c?.lastCallDays ?? null,
      });
    }
    return { available: true, statuses };
  } finally {
    db.close();
  }
}
