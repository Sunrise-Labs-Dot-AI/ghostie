// Phase A2 — analytics core. A faithful TypeScript port of
// skills/texting-analytics/scripts/analyze.py. Platform-agnostic: consumes
// ONLY the normalized export contract (v1.0), knows nothing about iMessage.
//
// Parity notes (vs the Python reference, checked by Gate 3):
//  - Python's round() is banker's rounding (half-to-even) on the binary float
//    → `pyRound` below. Integer counts are exact; 1-decimal percentages match
//    to tolerance (the plan's float-tolerant analysis gate).
//  - statistics.median averages the two middle values for even n → `median`.
//  - Map/array insertion order is preserved so stable-sort tie-breaks match
//    the Python (which iterates events in the same order). The one spot Python
//    uses an unordered set (talk_listen per-thread union) can tie-break
//    differently on exact word-total ties — rare, and within Gate-3 tolerance.

import type { NormalizedEvent, NormalizedThread, NormalizedExport } from "./chatdb-export.ts";
import { looksLikeBusinessHandle } from "./business.ts";

// Business detection lives in business.ts now (the shared filter used by Keep
// Tabs, Birthdays, and Wrapped). Re-exported here so existing importers of
// counterpartyClass keep working.
export { counterpartyClass } from "./business.ts";
export type { CounterpartyClass } from "./business.ts";

const SUBSTANTIVE = new Set(["text", "media"]);
const REPLY_CAP_MIN = 960; // 16h: longer gaps are conversation death, not a reply

// ── numeric helpers (match Python) ──────────────────────────────────────────

/**
 * CPython round(): round-half-to-even at `nd` decimals, operating on the
 * float's EXACT decimal value (not `x * 10^n`, which re-rounds and loses which
 * side of the boundary the true value is on — e.g. 0.35*10 → 3.5 exactly,
 * but 0.35's true value is 0.34999… so Python rounds DOWN to 0.3).
 * We read the exact expansion via toFixed(nd+25) and round the digit string.
 */
export function pyRound(x: number, nd = 0): number {
  if (!Number.isFinite(x)) return x;
  const neg = x < 0;
  const ax = Math.abs(x);
  const s = ax.toFixed(Math.min(100, nd + 25)); // exact-enough expansion
  const dot = s.indexOf(".");
  const intPart = dot < 0 ? s : s.slice(0, dot);
  const frac = dot < 0 ? "" : s.slice(dot + 1);
  const keep = frac.slice(0, nd);
  const rest = frac.slice(nd);
  const unit = 10 ** -nd;
  const base = Number(intPart + (keep ? "." + keep : ""));

  let roundUp = false;
  const restTrimmed = rest.replace(/0+$/, "");
  if (restTrimmed !== "") {
    const first = rest[0]!;
    if (first > "5") roundUp = true;
    else if (first < "5") roundUp = false;
    else {
      const after = rest.slice(1).replace(/0+$/, "");
      if (after !== "") roundUp = true; // strictly past the half → up
      else {
        // exactly half → round to even (last kept digit)
        const lastKeep = nd > 0 ? keep[nd - 1] ?? "0" : intPart[intPart.length - 1] ?? "0";
        roundUp = Number(lastKeep) % 2 === 1;
      }
    }
  }
  // Clean binary noise from the addition back to nd decimals.
  const result = Number((base + (roundUp ? unit : 0)).toFixed(nd));
  return neg ? -result : result;
}

/** statistics.median: sorted middle, or mean of the two middles for even n. */
export function median(xs: number[]): number {
  const n = xs.length;
  if (n === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const mid = n >> 1;
  return n % 2 ? s[mid]! : (s[mid - 1]! + s[mid]!) / 2;
}

function mean(xs: number[]): number {
  if (xs.length === 0) return 0;
  let sum = 0;
  for (const x of xs) sum += x;
  return sum / xs.length;
}

/** max(pool, key) — returns the FIRST element achieving the max (Python semantics). */
function maxBy<T>(pool: T[], key: (t: T) => number | [number, number]): T | null {
  let best: T | null = null;
  let bestK: number | [number, number] | null = null;
  for (const item of pool) {
    const k = key(item);
    if (bestK === null || cmpKey(k, bestK) > 0) {
      best = item;
      bestK = k;
    }
  }
  return best;
}
function minBy<T>(pool: T[], key: (t: T) => number): T | null {
  let best: T | null = null;
  let bestK = Infinity;
  for (const item of pool) {
    const k = key(item);
    if (k < bestK) {
      best = item;
      bestK = k;
    }
  }
  return best;
}
function firstMaterialHighlight<T extends { name: string; your_share_pct: number }>(
  pool: T[],
  predicate: (t: T) => boolean,
  compare: (a: T, b: T) => number,
  usedNames: Set<string>,
): T | null {
  const candidates = pool.filter((item) => predicate(item) && !usedNames.has(item.name));
  if (!candidates.length) return null;
  candidates.sort(compare);
  const winner = candidates[0] ?? null;
  if (winner) usedNames.add(winner.name);
  return winner;
}
function cmpKey(a: number | [number, number], b: number | [number, number]): number {
  const av = Array.isArray(a) ? a : [a, 0];
  const bv = Array.isArray(b) ? b : [b, 0];
  if (av[0]! !== bv[0]!) return av[0]! - bv[0]!;
  return av[1]! - bv[1]!;
}

// ── thread classification ───────────────────────────────────────────────────

function businessThreadIds(threads: Map<string, NormalizedThread>, events: NormalizedEvent[]): Set<string> {
  const counterparty = new Map<string, string | null>();
  for (const e of events) {
    const t = threads.get(e.thread_id);
    if (!t || t.is_group || e.from_me) continue;
    if (!counterparty.has(e.thread_id)) counterparty.set(e.thread_id, e.sender_key);
  }
  const out = new Set<string>();
  for (const [tid, sk] of counterparty) {
    // Handle-only here (analytics has the sender key, not a Contacts name);
    // also catches no-reply emails, which counterpartyClass alone would miss.
    if (looksLikeBusinessHandle(sk)) out.add(tid);
  }
  return out;
}

function sizeBucket(pc: number | null | undefined, largeMin = 6): string {
  if (pc == null) return "unknown";
  if (pc <= 2) return "one_to_one";
  return pc < largeMin ? "small" : "large";
}

// ── blocks ──────────────────────────────────────────────────────────────────

export function latencyBlock(threads: Map<string, NormalizedThread>, events: NormalizedEvent[]) {
  const byThread = new Map<string, NormalizedEvent[]>();
  for (const e of events) {
    const t = threads.get(e.thread_id);
    if (!t || t.is_group || !SUBSTANTIVE.has(e.kind)) continue;
    let arr = byThread.get(e.thread_id);
    if (!arr) { arr = []; byThread.set(e.thread_id, arr); }
    arr.push(e);
  }
  const deltas: number[] = [];
  let tcount = 0;
  for (const evs of byThread.values()) {
    evs.sort((a, b) => (a.ts_ms ?? 0) - (b.ts_ms ?? 0));
    let had = false;
    for (let i = 0; i < evs.length; i++) {
      const e = evs[i]!;
      if (e.from_me) continue;
      const nxt = evs.slice(i + 1).find((x) => x.from_me);
      if (nxt) {
        const d = ((nxt.ts_ms ?? 0) - (e.ts_ms ?? 0)) / 60000;
        if (d > 0 && d < REPLY_CAP_MIN) {
          deltas.push(d);
          had = true;
        }
      }
    }
    if (had) tcount++;
  }
  const n = deltas.length;
  const pct = (thr: number) => (n ? pyRound((100 * deltas.filter((d) => d <= thr).length) / n, 1) : 0);
  return {
    total_reply_pairs: n,
    pct_within_5min: pct(5),
    pct_within_30min: pct(30),
    pct_within_1hr: pct(60),
    pct_within_4hr: pct(240),
    mean_minutes: n ? pyRound(mean(deltas), 1) : 0,
    median_minutes: n ? pyRound(median(deltas), 1) : 0,
    thread_count: tcount,
    window_label: "past 24 months",
  };
}

export function ballBlock(threads: Map<string, NormalizedThread>, events: NormalizedEvent[], untilMs: number) {
  const last = new Map<string, NormalizedEvent>();
  for (const e of events) {
    if (!SUBSTANTIVE.has(e.kind)) continue;
    const cur = last.get(e.thread_id);
    if (!cur || (e.ts_ms ?? 0) > (cur.ts_ms ?? 0)) last.set(e.thread_id, e);
  }
  const recent = [...last.values()].sort((a, b) => (b.ts_ms ?? 0) - (a.ts_ms ?? 0)).slice(0, 100);
  const sampled = recent.length;
  const bic = recent.filter((e) => e.from_me).length;
  const live = recent.filter((e) => untilMs - (e.ts_ms ?? 0) <= 30 * 86400 * 1000).length;
  return {
    total_threads_sampled: sampled,
    threads_with_ball_in_court: bic,
    pct_ball_in_court: sampled ? pyRound((100 * bic) / sampled, 1) : 0,
    live_conversations_estimate: live,
    snapshot_label: "now",
  };
}

interface GroupAgg { total: number; user: number; user_react: number; peer: number; peer_react: number }

export function groupBlock(threads: Map<string, NormalizedThread>, events: NormalizedEvent[], minMsgs = 20, largeMin = 6) {
  const groups = new Map<string, NormalizedThread>();
  for (const [tid, t] of threads) if (t.is_group) groups.set(tid, t);

  const per = new Map<string, GroupAgg>();
  for (const e of events) {
    if (!groups.has(e.thread_id)) continue;
    let d = per.get(e.thread_id);
    if (!d) { d = { total: 0, user: 0, user_react: 0, peer: 0, peer_react: 0 }; per.set(e.thread_id, d); }
    const react = e.kind === "reaction";
    const substantive = SUBSTANTIVE.has(e.kind);
    if (!(react || substantive)) continue;
    d.total += substantive ? 1 : 0;
    if (e.from_me) {
      if (substantive) d.user += 1;
      if (react) d.user_react += 1;
    } else {
      if (substantive) d.peer += 1;
      if (react) d.peer_react += 1;
    }
  }
  // Keep only groups with real activity.
  for (const [tid, d] of [...per]) if (d.total < minMsgs) per.delete(tid);

  let tot = 0, um = 0, ur = 0, pm = 0, pr = 0;
  for (const d of per.values()) { tot += d.total; um += d.user; ur += d.user_react; pm += d.peer; pr += d.peer_react; }

  const perThread: any[] = [];
  let silent = 0, mostly = 0;
  const buckets = new Map<string, { groups: number; total: number; user: number }>();
  for (const [tid, d] of per) {
    const pc = groups.get(tid)!.participant_count;
    const bucket = sizeBucket(pc, largeMin);
    let b = buckets.get(bucket);
    if (!b) { b = { groups: 0, total: 0, user: 0 }; buckets.set(bucket, b); }
    b.groups += 1; b.total += d.total; b.user += d.user;
    if (d.user === 0 && d.user_react === 0) silent += 1;
    const uTotal = d.user + d.user_react;
    if (uTotal && d.user_react / uTotal >= 0.5) mostly += 1;
    const upct = d.total ? pyRound((100 * d.user) / d.total, 1) : 0;
    const fair = pc && pc > 1 && d.total ? pyRound(upct / (100 / pc), 2) : null;
    perThread.push({
      thread_label: groups.get(tid)!.display_name || tid,
      participant_count: pc,
      size: bucket,
      total: d.total,
      user_count: d.user,
      user_pct: upct,
      fair_share_ratio: fair,
      user_reaction_pct: d.user + d.user_react ? pyRound((100 * d.user_react) / (d.user + d.user_react), 1) : 0,
    });
  }
  // worst offender BEFORE truncation (silent groups must stay eligible).
  let worstOffender: any = null;
  if (perThread.length) {
    const zero = perThread.filter((t) => (t.user_count ?? 1) === 0);
    const pool = zero.length ? zero : perThread;
    worstOffender = maxBy(pool, (t) => [t.total ?? 0, -(t.user_count ?? 0)] as [number, number]);
  }
  perThread.sort((a, b) => b.user_pct - a.user_pct);
  const perThreadTop = perThread.slice(0, 12);

  const bySize: Record<string, { groups: number; contribution_pct: number }> = {};
  for (const [b, v] of buckets) bySize[b] = { groups: v.groups, contribution_pct: v.total ? pyRound((100 * v.user) / v.total, 1) : 0 };

  return {
    total_groups_analyzed: per.size,
    total_messages_in_groups: tot,
    user_messages_in_groups: um,
    user_contribution_pct: tot ? pyRound((100 * um) / tot, 1) : 0,
    user_reaction_rate_pct: um + ur ? pyRound((100 * ur) / (um + ur), 1) : 0,
    peer_reaction_rate_pct: pm + pr ? pyRound((100 * pr) / (pm + pr), 1) : 0,
    groups_where_user_silent: silent,
    groups_mostly_reactions: mostly,
    by_size: bySize,
    per_thread: perThreadTop,
    worst_offender: worstOffender,
  };
}

function rankedCounts(counts: Map<string, number>, threads: Map<string, NormalizedThread>, limit: number) {
  const ranked = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit);
  return ranked.map(([tid, c]) => ({ name: threads.get(tid)?.display_name || tid, count: c }));
}

export function topPeopleBlock(threads: Map<string, NormalizedThread>, events: NormalizedEvent[], limit = 10) {
  const counts = new Map<string, number>();
  for (const e of events) {
    if (!e.from_me || !SUBSTANTIVE.has(e.kind)) continue;
    const t = threads.get(e.thread_id);
    if (!t || t.is_group) continue;
    counts.set(e.thread_id, (counts.get(e.thread_id) ?? 0) + 1);
  }
  return rankedCounts(counts, threads, limit);
}

export function topPeopleL30Block(threads: Map<string, NormalizedThread>, events: NormalizedEvent[], untilMs: number, limit = 10) {
  const since = untilMs - 30 * 86400 * 1000;
  const counts = new Map<string, number>();
  for (const e of events) {
    if (!e.from_me || !SUBSTANTIVE.has(e.kind)) continue;
    if ((e.ts_ms ?? 0) < since) continue;
    const t = threads.get(e.thread_id);
    if (!t || t.is_group) continue;
    counts.set(e.thread_id, (counts.get(e.thread_id) ?? 0) + 1);
  }
  return rankedCounts(counts, threads, limit);
}

export function topPeopleByCharsBlock(threads: Map<string, NormalizedThread>, events: NormalizedEvent[], limit = 10) {
  const chars = new Map<string, number>();
  for (const e of events) {
    if (!e.from_me || !SUBSTANTIVE.has(e.kind)) continue;
    const t = threads.get(e.thread_id);
    if (!t || t.is_group) continue;
    const n = e.text_len ?? 0;
    if (n <= 0) continue;
    chars.set(e.thread_id, (chars.get(e.thread_id) ?? 0) + n);
  }
  const ranked = [...chars.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit);
  return ranked.map(([tid, c]) => ({ name: threads.get(tid)?.display_name || tid, chars: c }));
}

export function talkListenBlock(threads: Map<string, NormalizedThread>, events: NormalizedEvent[], personLimit = 8) {
  const sent = new Map<string, number>();
  const recv = new Map<string, number>();
  for (const e of events) {
    if (!SUBSTANTIVE.has(e.kind)) continue;
    const t = threads.get(e.thread_id);
    if (!t || t.is_group) continue;
    const n = e.text_len ?? 0;
    if (n <= 0) continue;
    const bucket = e.from_me ? sent : recv;
    bucket.set(e.thread_id, (bucket.get(e.thread_id) ?? 0) + n);
  }
  // union of thread ids (insertion order: sent first, then new recv keys).
  const ids = new Set<string>([...sent.keys(), ...recv.keys()]);
  const perThread: any[] = [];
  for (const tid of ids) {
    const s = sent.get(tid) ?? 0;
    const r = recv.get(tid) ?? 0;
    if (s + r < 200) continue;
    if (s === 0 || r === 0) continue;
    perThread.push({
      name: threads.get(tid)?.display_name || tid,
      you_words: Math.round(s / 5),
      them_words: Math.round(r / 5),
      your_share_pct: pyRound((100 * s) / (s + r), 1),
    });
  }
  let totalSent = 0, totalRecv = 0;
  for (const v of sent.values()) totalSent += v;
  for (const v of recv.values()) totalRecv += v;
  const totalSentWords = Math.round(totalSent / 5);
  const totalRecvWords = Math.round(totalRecv / 5);
  const overall = totalSent + totalRecv > 0 ? pyRound((100 * totalSent) / (totalSent + totalRecv), 1) : 50;
  perThread.sort((a, b) => b.you_words + b.them_words - (a.you_words + a.them_words));
  const top = perThread.slice(0, personLimit);
  const used = new Set<string>();
  const mostBalanced = minBy(top, (p) => Math.abs(p.your_share_pct - 50));
  if (mostBalanced) used.add(mostBalanced.name);
  const mostYouTalk = firstMaterialHighlight(
    top,
    (p) => p.your_share_pct >= 60,
    (a, b) => b.your_share_pct - a.your_share_pct,
    used,
  );
  const mostYouListen = firstMaterialHighlight(
    top,
    (p) => p.your_share_pct <= 40,
    (a, b) => a.your_share_pct - b.your_share_pct,
    used,
  );
  return {
    you_words: totalSentWords,
    them_words: totalRecvWords,
    your_share_pct: overall,
    per_thread: top,
    highlights: { most_balanced: mostBalanced, most_you_talk: mostYouTalk, most_you_listen: mostYouListen },
  };
}

// ── top-level orchestration (mirrors analyze.py main) ───────────────────────

export interface AnalyzeOptions {
  windowDays?: number; // default 365; 0 = all-time
  sinceMs?: number;
  untilMs?: number;
  largeMin?: number;
  keepBusiness?: boolean;
  nowMs?: number; // only used if there are zero events
}

export function analyze(exports: NormalizedExport[], opts: AnalyzeOptions = {}) {
  const windowDays = opts.windowDays ?? 365;
  const largeMin = opts.largeMin ?? 6;

  const threads = new Map<string, NormalizedThread>();
  let events: NormalizedEvent[] = [];
  for (const ex of exports) {
    for (const t of ex.threads) threads.set(t.thread_id, t);
    for (const e of ex.events) if (e.ts_ms != null) events.push(e);
  }

  let biz = new Set<string>();
  if (!opts.keepBusiness) {
    biz = businessThreadIds(threads, events);
    if (biz.size) {
      events = events.filter((e) => !biz.has(e.thread_id));
      for (const tid of [...threads.keys()]) if (biz.has(tid)) threads.delete(tid);
    }
  }

  // reduce, not Math.max(...spread) — the spread overflows the call stack on
  // 100k+ events.
  let untilMs: number;
  if (opts.untilMs != null && Number.isFinite(opts.untilMs)) {
    untilMs = opts.untilMs;
  } else if (events.length) {
    let mx = -Infinity;
    for (const e of events) if (e.ts_ms! > mx) mx = e.ts_ms!;
    untilMs = mx;
  } else {
    untilMs = opts.nowMs ?? Date.now();
  }
  const sinceMs = opts.sinceMs != null && Number.isFinite(opts.sinceMs)
    ? opts.sinceMs
    : windowDays <= 0 ? 0 : untilMs - windowDays * 86400 * 1000;
  const eventsFull = events.filter((e) => e.ts_ms! <= untilMs);
  const windowed = sinceMs > 0 ? eventsFull.filter((e) => e.ts_ms! >= sinceMs) : eventsFull;

  return {
    latency: latencyBlock(threads, windowed),
    ball_in_court: ballBlock(threads, eventsFull, untilMs),
    group_contribution: groupBlock(threads, windowed, 20, largeMin),
    top_people: topPeopleBlock(threads, windowed),
    top_people_l30: topPeopleL30Block(threads, windowed, untilMs),
    top_people_by_chars: topPeopleByCharsBlock(threads, windowed),
    talk_listen: talkListenBlock(threads, windowed),
    filters: {
      excluded_business_1to1_threads: biz.size,
      window_days: windowDays,
      since_ts_ms: sinceMs,
      until_ts_ms: untilMs,
    },
  };
}
