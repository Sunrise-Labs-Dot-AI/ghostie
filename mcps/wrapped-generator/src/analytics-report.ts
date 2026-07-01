import { analyze, counterpartyClass, pyRound } from "./analyze.ts";
import { buildAnalyticsReport } from "./build-wrapped.ts";
import type { NormalizedEvent, NormalizedExport, NormalizedThread } from "./chatdb-export.ts";

const SUBSTANTIVE = new Set(["text", "media"]);

function localDateKey(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function localMonthKey(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}

function localWeekKey(ms: number): string {
  const d = new Date(ms);
  const mondayOffset = (d.getDay() + 6) % 7;
  const start = new Date(d.getFullYear(), d.getMonth(), d.getDate() - mondayOffset);
  return localDateKey(start.getTime());
}

function trendGranularity(sinceMs: number, untilMs: number): "day" | "week" | "month" {
  const spanDays = sinceMs > 0 ? Math.max(1, (untilMs - sinceMs) / 86400000) : Infinity;
  if (spanDays <= 62) return "day";
  if (spanDays <= 400) return "week";
  return "month";
}

function businessThreadIds(threads: Map<string, NormalizedThread>, events: NormalizedEvent[]): Set<string> {
  const counterparty = new Map<string, string | null>();
  for (const e of events) {
    const t = threads.get(e.thread_id);
    if (!t || t.is_group || e.from_me) continue;
    if (!counterparty.has(e.thread_id)) counterparty.set(e.thread_id, e.sender_key);
  }
  const out = new Set<string>();
  for (const [tid, sk] of counterparty) {
    if (counterpartyClass(sk) !== "person") out.add(tid);
  }
  return out;
}

function analysisWindow(exp: NormalizedExport, analysis: any) {
  const sinceMs = analysis.filters?.since_ts_ms ?? 0;
  const untilMs = analysis.filters?.until_ts_ms ?? Date.now();
  const threads = new Map(exp.threads.map((t) => [t.thread_id, t]));
  const inWindow = exp.events.filter((e) => {
    const ts = e.ts_ms ?? 0;
    return ts >= sinceMs && ts <= untilMs;
  });
  const business = businessThreadIds(threads, inWindow);
  return {
    sinceMs,
    untilMs,
    threads,
    events: inWindow.filter((e) => !business.has(e.thread_id)),
  };
}

export function activityTrendBlock(
  threads: Map<string, NormalizedThread>,
  events: NormalizedEvent[],
  sinceMs: number,
  untilMs: number,
) {
  const granularity = trendGranularity(sinceMs, untilMs);
  const bucketKey = granularity === "day" ? localDateKey : granularity === "week" ? localWeekKey : localMonthKey;
  const rows = new Map<string, {
    period: string;
    label: string;
    sent: number;
    received: number;
    one_to_one_sent: number;
    one_to_one_received: number;
    group_sent: number;
    group_received: number;
  }>();
  for (const e of events) {
    if (!SUBSTANTIVE.has(e.kind)) continue;
    const t = threads.get(e.thread_id);
    if (!t) continue;
    const key = bucketKey(e.ts_ms ?? 0);
    let row = rows.get(key);
    if (!row) {
      row = {
        period: key,
        label: key,
        sent: 0,
        received: 0,
        one_to_one_sent: 0,
        one_to_one_received: 0,
        group_sent: 0,
        group_received: 0,
      };
      rows.set(key, row);
    }
    if (e.from_me) {
      row.sent += 1;
      if (t.is_group) row.group_sent += 1;
      else row.one_to_one_sent += 1;
    } else {
      row.received += 1;
      if (t.is_group) row.group_received += 1;
      else row.one_to_one_received += 1;
    }
  }
  return {
    granularity,
    rows: [...rows.values()].sort((a, b) => a.period.localeCompare(b.period)),
  };
}

export function rhythmBlock(events: NormalizedEvent[]) {
  const buckets: Array<{ weekday: number; hour: number; sent: number; received: number; total: number }> = [];
  for (let weekday = 0; weekday < 7; weekday++) {
    for (let hour = 0; hour < 24; hour++) buckets.push({ weekday, hour, sent: 0, received: 0, total: 0 });
  }
  for (const e of events) {
    if (!SUBSTANTIVE.has(e.kind)) continue;
    const d = new Date(e.ts_ms ?? 0);
    const bucket = buckets[d.getDay() * 24 + d.getHours()];
    if (!bucket) continue;
    if (e.from_me) bucket.sent += 1;
    else bucket.received += 1;
    bucket.total += 1;
  }
  const first = buckets[0];
  const peak = first ? buckets.reduce((best, bucket) => bucket.sent > best.sent ? bucket : best, first) : null;
  return { buckets, peak_sent: peak && peak.sent > 0 ? peak : null };
}

export function conversationMixBlock(threads: Map<string, NormalizedThread>, events: NormalizedEvent[]) {
  const oneToOne = { sent: 0, received: 0 };
  const groups = { sent: 0, received: 0 };
  const kinds: Record<string, { sent: number; received: number }> = {};
  for (const e of events) {
    const t = threads.get(e.thread_id);
    if (!t) continue;
    const dir = e.from_me ? "sent" : "received";
    if (SUBSTANTIVE.has(e.kind)) {
      if (t.is_group) groups[dir] += 1;
      else oneToOne[dir] += 1;
    }
    const kind = kinds[e.kind] ?? { sent: 0, received: 0 };
    kind[dir] += 1;
    kinds[e.kind] = kind;
  }
  return { one_to_one: oneToOne, groups, kinds };
}

export function normalizedQuery(q: string | null): string {
  return (q ?? "").trim().toLowerCase();
}

export function filterExportByThread(exp: NormalizedExport, query: string | null): { exp: NormalizedExport; matchedThreadIds: Set<string>; query: string | null } {
  const q = normalizedQuery(query);
  if (!q) return { exp, matchedThreadIds: new Set(exp.threads.map((t) => t.thread_id)), query: null };
  const matched = new Set<string>();
  for (const t of exp.threads) {
    const haystack = [t.thread_id, t.display_name ?? ""].join(" ").toLowerCase();
    if (haystack.includes(q)) matched.add(t.thread_id);
  }
  return {
    exp: {
      ...exp,
      threads: exp.threads.filter((t) => matched.has(t.thread_id)),
      events: exp.events.filter((e) => matched.has(e.thread_id)),
    },
    matchedThreadIds: matched,
    query: query?.trim() || null,
  };
}

export function outboundCount(exp: NormalizedExport, sinceMs: number, untilMs: number): number {
  let n = 0;
  for (const e of exp.events) {
    const ts = e.ts_ms ?? 0;
    if (e.from_me && SUBSTANTIVE.has(e.kind) && ts >= sinceMs && ts <= untilMs) n++;
  }
  return n;
}

export function attachTextingAnalyticsBlocks(analysis: any, exp: NormalizedExport) {
  const { sinceMs, untilMs, threads, events } = analysisWindow(exp, analysis);
  analysis.activity_trend = activityTrendBlock(threads, events, sinceMs, untilMs);
  analysis.rhythm = rhythmBlock(events);
  analysis.conversation_mix = conversationMixBlock(threads, events);
  return analysis;
}

function summaryMetrics(analysis: any, totalSent: number | null) {
  const oneToOneSent = analysis.conversation_mix?.one_to_one?.sent ?? 0;
  const groupSent = analysis.conversation_mix?.groups?.sent ?? 0;
  const sentTotal = oneToOneSent + groupSent;
  return {
    total_sent: totalSent ?? 0,
    median_reply_minutes: analysis.latency?.median_minutes ?? 0,
    ball_in_court_pct: analysis.ball_in_court?.pct_ball_in_court ?? 0,
    group_share_pct: analysis.group_contribution?.user_contribution_pct ?? 0,
    one_to_one_sent_pct: sentTotal > 0 ? pyRound((100 * oneToOneSent) / sentTotal, 1) : 0,
  };
}

export function addPreviousComparison(
  analysis: any,
  currentTotalSent: number | null,
  previous: any,
  previousTotalSent: number | null,
) {
  const current = summaryMetrics(analysis, currentTotalSent);
  const prev = summaryMetrics(previous, previousTotalSent);
  const metric = (key: keyof ReturnType<typeof summaryMetrics>, label: string, unit: string) => ({
    key,
    label,
    unit,
    current: current[key],
    previous: prev[key],
    delta: pyRound((current[key] as number) - (prev[key] as number), 1),
  });
  analysis.comparison = {
    mode: "previous_period",
    metrics: [
      metric("total_sent", "Sent", "count"),
      metric("median_reply_minutes", "Median reply", "minutes"),
      metric("ball_in_court_pct", "Ball in court", "percent"),
      metric("group_share_pct", "Group share", "percent"),
      metric("one_to_one_sent_pct", "1:1 outbound", "percent"),
    ],
  };
}

export function buildTextingAnalyticsReport(analysis: any, opts: { totalSent?: number | null; showPeople?: boolean; generatedAtMs?: number } = {}) {
  const report = buildAnalyticsReport(analysis, opts);
  return {
    ...report,
    activity_trend: analysis.activity_trend ?? null,
    rhythm: analysis.rhythm ?? null,
    conversation_mix: analysis.conversation_mix ?? null,
    comparison: analysis.comparison ?? null,
  };
}

export function analyzeTextingAnalytics(exp: NormalizedExport, opts: { windowDays: number; sinceMs?: number; untilMs?: number }) {
  const analysis: any = analyze([exp], opts);
  return attachTextingAnalyticsBlocks(analysis, exp);
}
