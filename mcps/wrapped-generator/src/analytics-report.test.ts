import { test, expect } from "bun:test";
import { buildAnalyticsReport } from "./build-wrapped.ts";
import {
  addPreviousComparison,
  analyzeTextingAnalytics,
  buildTextingAnalyticsReport,
  filterExportByThread,
  outboundCount,
} from "./analytics-report.ts";
import type { NormalizedExport } from "./chatdb-export.ts";

function syntheticExport(): NormalizedExport {
  const day = 86400 * 1000;
  const t0 = Date.UTC(2026, 0, 5, 9, 0, 0);
  return {
    schema_version: "1.0",
    source_platform: "imessage",
    window: { since_ms: 0, until_ms: t0 + 14 * day },
    generated_at_ms: t0 + 14 * day,
    truncated: false,
    threads: [
      { platform: "imessage", thread_id: "imessage:alice", is_group: false, participant_count: 2, display_name: "Alice", last_event_ts_ms: t0 + 2 * day },
      { platform: "imessage", thread_id: "imessage:family", is_group: true, participant_count: 5, display_name: "Family", last_event_ts_ms: t0 + 3 * day },
      { platform: "imessage", thread_id: "imessage:spam", is_group: false, participant_count: 2, display_name: "ALERTS", last_event_ts_ms: t0 + day },
    ],
    events: [
      { platform: "imessage", thread_id: "imessage:alice", event_id: "a1", sender_key: "+15551110000", from_me: false, ts_ms: t0, kind: "text", text_len: 10 },
      { platform: "imessage", thread_id: "imessage:alice", event_id: "a2", sender_key: null, from_me: true, ts_ms: t0 + 2 * 60 * 1000, kind: "text", text_len: 40 },
      { platform: "imessage", thread_id: "imessage:alice", event_id: "a3", sender_key: null, from_me: true, ts_ms: t0 + day, kind: "media", text_len: null },
      { platform: "imessage", thread_id: "imessage:family", event_id: "g1", sender_key: "+15552220000", from_me: false, ts_ms: t0 + 2 * day, kind: "text", text_len: 14 },
      { platform: "imessage", thread_id: "imessage:family", event_id: "g2", sender_key: null, from_me: true, ts_ms: t0 + 3 * day, kind: "text", text_len: 16 },
      { platform: "imessage", thread_id: "imessage:family", event_id: "g3", sender_key: null, from_me: true, ts_ms: t0 + 3 * day + 10, kind: "reaction", text_len: null },
      { platform: "imessage", thread_id: "imessage:spam", event_id: "s1", sender_key: "ALERTS", from_me: false, ts_ms: t0 + day, kind: "text", text_len: 100 },
    ],
  };
}

test("texting analytics report emits workbench-only blocks", () => {
  const exp = syntheticExport();
  const analysis = analyzeTextingAnalytics(exp, { windowDays: 0 });
  const report = buildTextingAnalyticsReport(analysis, { totalSent: outboundCount(exp, 0, Date.now()) });

  expect(report.activity_trend.rows.reduce((sum: number, row: any) => sum + row.sent, 0)).toBe(3);
  expect(report.rhythm.buckets).toHaveLength(168);
  expect(report.rhythm.peak_sent.sent).toBeGreaterThan(0);
  expect(report.conversation_mix.one_to_one.sent).toBe(2);
  expect(report.conversation_mix.groups.sent).toBe(1);
  expect(report.conversation_mix.kinds.reaction.sent).toBe(1);
});

test("thread filter scopes analytics-only report inputs", () => {
  const filtered = filterExportByThread(syntheticExport(), "family");
  const analysis = analyzeTextingAnalytics(filtered.exp, { windowDays: 0 });
  const report = buildTextingAnalyticsReport(analysis);

  expect(filtered.matchedThreadIds).toEqual(new Set(["imessage:family"]));
  expect(report.conversation_mix.one_to_one.sent).toBe(0);
  expect(report.conversation_mix.groups.sent).toBe(1);
});

test("previous-period comparison remains analytics-only", () => {
  const exp = syntheticExport();
  const day = 86400 * 1000;
  const current = analyzeTextingAnalytics(exp, {
    windowDays: 365,
    sinceMs: Date.UTC(2026, 0, 8),
    untilMs: Date.UTC(2026, 0, 10),
  });
  const previous = analyzeTextingAnalytics(exp, {
    windowDays: 365,
    sinceMs: Date.UTC(2026, 0, 5),
    untilMs: Date.UTC(2026, 0, 8) - 1,
  });
  addPreviousComparison(current, 1, previous, outboundCount(exp, Date.UTC(2026, 0, 5), Date.UTC(2026, 0, 8) - 1));
  const report = buildTextingAnalyticsReport(current);

  expect(report.comparison.mode).toBe("previous_period");
  expect(report.comparison.metrics.map((m: any) => m.key)).toContain("one_to_one_sent_pct");
  expect(day).toBe(86400000);
});

test("wrapped analytics report does not include workbench-only fields", () => {
  const report = buildAnalyticsReport({
    latency: {},
    ball_in_court: {},
    group_contribution: {},
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
    activity_trend: { rows: [] },
    rhythm: { buckets: [] },
    conversation_mix: { one_to_one: { sent: 1, received: 0 } },
    comparison: { mode: "previous_period", metrics: [] },
  });

  expect("activity_trend" in report).toBe(false);
  expect("rhythm" in report).toBe(false);
  expect("conversation_mix" in report).toBe(false);
  expect("comparison" in report).toBe(false);
});
