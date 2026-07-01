import { test, expect } from "bun:test";
import { pyRound, median, counterpartyClass, analyze, talkListenBlock } from "./analyze.ts";
import type { NormalizedExport, NormalizedThread } from "./chatdb-export.ts";

test("pyRound: banker's rounding (half-to-even), matching Python round()", () => {
  expect(pyRound(0.5)).toBe(0); // half → even (0)
  expect(pyRound(1.5)).toBe(2); // half → even (2)
  expect(pyRound(2.5)).toBe(2); // half → even (2)
  expect(pyRound(3.5)).toBe(4);
  expect(pyRound(0.25, 1)).toBe(0.2); // 0.25 exact → even
  expect(pyRound(0.35, 1)).toBe(0.3); // 0.35 is <0.35 in binary → down
  expect(pyRound(41.573, 1)).toBe(41.6);
  expect(pyRound(60.0, 1)).toBe(60);
});

test("median: matches statistics.median (mean of two middles for even n)", () => {
  expect(median([])).toBe(0);
  expect(median([5])).toBe(5);
  expect(median([3, 1, 2])).toBe(2); // sorts internally
  expect(median([1, 2, 3, 4])).toBe(2.5); // even → average
  expect(median([10, 2, 8, 4])).toBe(6);
});

test("counterpartyClass: business vs person pattern detection", () => {
  expect(counterpartyClass("+14045550147")).toBe("person");
  expect(counterpartyClass("foo@bar.com")).toBe("person");
  expect(counterpartyClass("262966")).toBe("shortcode"); // 6-digit shortcode
  expect(counterpartyClass("+18002223333")).toBe("tollfree"); // 800
  expect(counterpartyClass("+18332223333")).toBe("tollfree"); // 833
  expect(counterpartyClass("AMAZON")).toBe("alpha");
  expect(counterpartyClass("+15551234567")).toBe("person");
  expect(counterpartyClass(null)).toBe("person");
});

test("analyze: end-to-end on a tiny synthetic export", () => {
  const day = 86400 * 1000;
  const t0 = 1_700_000_000_000;
  const ex: NormalizedExport = {
    schema_version: "1.0",
    source_platform: "imessage",
    window: { since_ms: 0, until_ms: t0 + day },
    generated_at_ms: t0 + day,
    truncated: false,
    threads: [
      { platform: "imessage", thread_id: "imessage:a", is_group: false, participant_count: 2, display_name: "Alice", last_event_ts_ms: t0 + day },
      { platform: "imessage", thread_id: "imessage:spam", is_group: false, participant_count: 2, display_name: "ALERTS", last_event_ts_ms: t0 },
    ],
    events: [
      // Alice 1:1: inbound then a fast outbound reply (2 min), then user has last word
      { platform: "imessage", thread_id: "imessage:a", event_id: "e1", sender_key: "+15551110000", from_me: false, ts_ms: t0, kind: "text", text_len: 10 },
      { platform: "imessage", thread_id: "imessage:a", event_id: "e2", sender_key: null, from_me: true, ts_ms: t0 + 2 * 60 * 1000, kind: "text", text_len: 40 },
      { platform: "imessage", thread_id: "imessage:a", event_id: "e3", sender_key: null, from_me: true, ts_ms: t0 + day, kind: "text", text_len: 5 },
      // business thread (alpha sender) — should be filtered out
      { platform: "imessage", thread_id: "imessage:spam", event_id: "e4", sender_key: "ALERTS", from_me: false, ts_ms: t0, kind: "text", text_len: 100 },
    ],
  };
  const out = analyze([ex], { windowDays: 0 });
  // business thread excluded
  expect(out.filters.excluded_business_1to1_threads).toBe(1);
  // one reply pair, within 5 min
  expect(out.latency.total_reply_pairs).toBe(1);
  expect(out.latency.pct_within_5min).toBe(100);
  // user had the last word in the one sampled thread
  expect(out.ball_in_court.total_threads_sampled).toBe(1);
  expect(out.ball_in_court.pct_ball_in_court).toBe(100);
  // top people: Alice, 2 outbound substantive
  expect(out.top_people).toEqual([{ name: "Alice", count: 2 }]);
});

test("analyze: custom range excludes events after the selected end", () => {
  const day = 86400 * 1000;
  const t0 = 1_700_000_000_000;
  const ex: NormalizedExport = {
    schema_version: "1.0",
    source_platform: "imessage",
    window: { since_ms: 0, until_ms: t0 + 10 * day },
    generated_at_ms: t0 + 10 * day,
    truncated: false,
    threads: [
      { platform: "imessage", thread_id: "imessage:a", is_group: false, participant_count: 2, display_name: "Alice", last_event_ts_ms: t0 + 10 * day },
    ],
    events: [
      { platform: "imessage", thread_id: "imessage:a", event_id: "old-in", sender_key: "+15551110000", from_me: false, ts_ms: t0, kind: "text", text_len: 10 },
      { platform: "imessage", thread_id: "imessage:a", event_id: "old-out", sender_key: null, from_me: true, ts_ms: t0 + day, kind: "text", text_len: 10 },
      { platform: "imessage", thread_id: "imessage:a", event_id: "future-out", sender_key: null, from_me: true, ts_ms: t0 + 10 * day, kind: "text", text_len: 10 },
    ],
  };

  const out = analyze([ex], { sinceMs: t0, untilMs: t0 + 2 * day });

  expect(out.filters.since_ts_ms).toBe(t0);
  expect(out.filters.until_ts_ms).toBe(t0 + 2 * day);
  expect(out.top_people).toEqual([{ name: "Alice", count: 1 }]);
  expect(out.ball_in_court.total_threads_sampled).toBe(1);
});

test("talkListenBlock: highlights are distinct and require material talk/listen skew", () => {
  const threads = new Map<string, NormalizedThread>([
    ["balanced", { platform: "imessage", thread_id: "balanced", is_group: false, participant_count: 2, display_name: "Balanced", last_event_ts_ms: 0 }],
    ["talk", { platform: "imessage", thread_id: "talk", is_group: false, participant_count: 2, display_name: "Talk", last_event_ts_ms: 0 }],
    ["listen", { platform: "imessage", thread_id: "listen", is_group: false, participant_count: 2, display_name: "Listen", last_event_ts_ms: 0 }],
  ]);
  const events = [
    { thread_id: "balanced", from_me: true, ts_ms: 1, kind: "text", text_len: 508 },
    { thread_id: "balanced", from_me: false, ts_ms: 2, kind: "text", text_len: 492 },
    { thread_id: "talk", from_me: true, ts_ms: 3, kind: "text", text_len: 800 },
    { thread_id: "talk", from_me: false, ts_ms: 4, kind: "text", text_len: 200 },
    { thread_id: "listen", from_me: true, ts_ms: 5, kind: "text", text_len: 250 },
    { thread_id: "listen", from_me: false, ts_ms: 6, kind: "text", text_len: 750 },
  ] as any;

  const out = talkListenBlock(threads, events);

  expect(out.highlights.most_balanced?.name).toBe("Balanced");
  expect(out.highlights.most_you_talk?.name).toBe("Talk");
  expect(out.highlights.most_you_listen?.name).toBe("Listen");
  expect(new Set(Object.values(out.highlights).filter(Boolean).map((h: any) => h.name)).size).toBe(3);
});

test("talkListenBlock: a barely-over-half balanced thread is not a talk-more highlight", () => {
  const threads = new Map<string, NormalizedThread>([
    ["balanced", { platform: "imessage", thread_id: "balanced", is_group: false, participant_count: 2, display_name: "Balanced", last_event_ts_ms: 0 }],
  ]);
  const events = [
    { thread_id: "balanced", from_me: true, ts_ms: 1, kind: "text", text_len: 508 },
    { thread_id: "balanced", from_me: false, ts_ms: 2, kind: "text", text_len: 492 },
  ] as any;

  const out = talkListenBlock(threads, events);

  expect(out.highlights.most_balanced?.name).toBe("Balanced");
  expect(out.highlights.most_you_talk).toBeNull();
  expect(out.highlights.most_you_listen).toBeNull();
});
