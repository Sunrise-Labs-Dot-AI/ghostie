import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { deriveArchetype, deriveWorstGhost, buildAnalyticsReport, buildData, buildWrapped } from "./build-wrapped.ts";

const wrappedAppJsx = readFileSync(
  new URL("../../../skills/texting-analytics/wrapped/app.jsx", import.meta.url),
  "utf8",
);

test("deriveArchetype: priority-ordered selection (parity with build_wrapped.py)", () => {
  // Ghost: tiny group share + silent in most groups
  expect(deriveArchetype(8, 90, 44, 60, 0.7, 12, 15, null).name).toBe("The Group Chat Ghost");
  // Town Crier: dominates the group volume
  expect(deriveArchetype(7, 20, 42, 50, 51.2, 0, 9, null).name).toBe("The Town Crier");
  // Lightning Round: instant + consistent
  expect(deriveArchetype(1, 4, 82, 44, 14, 1, 10, null).name).toBe("The Lightning Round");
  // Royalty: LOW last-word rate — threads parked on your reply
  expect(deriveArchetype(22, 40, 24, 12, 9, 2, 11, null).name).toBe("Left-on-Read Royalty");
  // Last Word: very high last-word rate
  expect(deriveArchetype(9, 18, 40, 88, 12, 3, 14, null).name).toBe("The Last Word");
  // Ping-Pong Pro: fast + high-ish last-word rate
  expect(deriveArchetype(2.5, 7, 68, 62, 12, 1, 10, null).name).toBe("The Ping-Pong Pro");
  // Group MVP
  expect(deriveArchetype(6, 15, 50, 45, 33, 0, 8, null).name).toBe("The Group MVP");
  // Emoji extremes — only when the emoji pass actually ran
  expect(deriveArchetype(5, 12, 52, 40, 15, 1, 10, 52).name).toBe("The Emoji Maximalist");
  expect(deriveArchetype(18, 30, 24, 42, 12, 1, 10, 0.8).name).toBe("The Deadpan");
  // Sorry-Just-Saw-This: slow median + monster tail
  expect(deriveArchetype(50, 240, 10, 40, 10, 2, 12, null).name).toBe("The Sorry-Just-Saw-This");
  // Slow Burn: slow median, honest tail
  expect(deriveArchetype(95, 120, 6, 44, 10, 2, 12, null).name).toBe("The Slow Burn");
  // Fast Starter: slow tail + low median
  expect(deriveArchetype(4, 77, 47, 44, 8.8, 2, 19, 23).name).toBe("The Fast Starter");
  // Quick Draw
  expect(deriveArchetype(2.5, 8, 72, 45, 18, 1, 10, 23).name).toBe("The Quick Draw");
  // VIP Room: fast 1:1, silent in most groups
  expect(deriveArchetype(6, 14, 48, 44, 5.5, 6, 10, 23).name).toBe("The VIP Room");
  // Quiet Lurker
  expect(deriveArchetype(12, 25, 20, 42, 4, 3, 14, 23).name).toBe("The Quiet Lurker");
  // Main Stage: low-ish last-word rate + real group presence
  expect(deriveArchetype(12, 25, 30, 28, 21, 0, 9, 23).name).toBe("The Main Stage");
  // Context-keyed reads (corpus-level signals) — sit between the distinctive
  // single-signal reads and the generic fallbacks.
  expect(deriveArchetype(18, 30, 22, 50, 22, 1, 12, 23, { reactionRate: 52 }).name).toBe("The Reaction Regular");
  expect(deriveArchetype(18, 30, 22, 50, 22, 1, 12, 23, {
    totalSent: 10000,
    threadCount: 70,
    topPeople: [{ count: 1200 }],
  }).name).toBe("The Social Connector");
  expect(deriveArchetype(18, 30, 22, 50, 22, 1, 12, 23, {
    totalSent: 3000,
    topPeople: [{ count: 1000 }],
  }).name).toBe("The Inner-Circle Texter");
  expect(deriveArchetype(18, 30, 22, 50, 22, 1, 12, 23, { totalSent: 18000 }).name).toBe("The High-Volume Texter");
  // Diplomat
  expect(deriveArchetype(12, 24, 34, 52, 11, 1, 10, 23).name).toBe("The Diplomat");
  // Steady fallback
  expect(deriveArchetype(35, 50, 14, 66, 10, 1, 12, 23).name).toBe("The Steady Hand");
  // Ball-in-court reads are marked playful (read-state is unknowable)
  expect(deriveArchetype(9, 30, 40, 82, 12, 3, 14, 0).support_level).toBe("playful");
});

test("deriveArchetype: table spans at least 16 distinct archetypes", () => {
  const names = new Set([
    deriveArchetype(8, 90, 44, 60, 0.7, 12, 15, null).name,
    deriveArchetype(7, 20, 42, 50, 51.2, 0, 9, null).name,
    deriveArchetype(1, 4, 82, 44, 14, 1, 10, null).name,
    deriveArchetype(22, 40, 24, 12, 9, 2, 11, null).name,
    deriveArchetype(9, 18, 40, 88, 12, 3, 14, null).name,
    deriveArchetype(2.5, 7, 68, 62, 12, 1, 10, null).name,
    deriveArchetype(6, 15, 50, 45, 33, 0, 8, null).name,
    deriveArchetype(5, 12, 52, 40, 15, 1, 10, 52).name,
    deriveArchetype(18, 30, 24, 42, 12, 1, 10, 0.8).name,
    deriveArchetype(50, 240, 10, 40, 10, 2, 12, null).name,
    deriveArchetype(95, 120, 6, 44, 10, 2, 12, null).name,
    deriveArchetype(4, 77, 47, 44, 8.8, 2, 19, 23).name,
    deriveArchetype(2.5, 8, 72, 45, 18, 1, 10, 23).name,
    deriveArchetype(6, 14, 48, 44, 5.5, 6, 10, 23).name,
    deriveArchetype(12, 25, 20, 42, 4, 3, 14, 23).name,
    deriveArchetype(12, 25, 30, 28, 21, 0, 9, 23).name,
    deriveArchetype(12, 24, 34, 52, 11, 1, 10, 23).name,
    deriveArchetype(35, 50, 14, 66, 10, 1, 12, 23).name,
  ]);
  expect(names.size).toBeGreaterThanOrEqual(16);
});

test("deriveArchetype: missing emoji block (null) never fires emoji archetypes", () => {
  const name = deriveArchetype(18, 30, 24, 42, 12, 1, 10, null).name;
  expect(name).not.toBe("The Deadpan");
  expect(name).not.toBe("The Emoji Maximalist");
});

test("deriveArchetype: why-string number formatting matches Python (%g / %.1f / %.0f)", () => {
  const a = deriveArchetype(4, 77, 47, 44, 8.8, 2, 19, 23);
  expect(a.why).toBe("median reply 4 min, but the mean is 77 min — the long tail tells on you.");
  const ghost = deriveArchetype(8, 90, 44, 60, 0.7, 12, 15, null);
  expect(ghost.why).toBe("0.7% group share, silent in 12 of 15 groups."); // %.1f
  const royalty = deriveArchetype(22, 40, 24, 12, 9, 2, 11, null);
  expect(royalty.why).toBe("you had the last word in only 12% of threads — the other 88% are parked on your reply.");
});

test("deriveWorstGhost: prefers the worst_offender block; else scans per_thread", () => {
  expect(deriveWorstGhost({ worst_offender: { thread_label: "Sunnydale Parents", total: 1462, user_count: 0 } }))
    .toEqual({ name: "Sunnydale Parents", messages: 1462, userSent: 0 });
  // fallback: per_thread, prefer a zero-contribution thread
  const g = { per_thread: [{ thread_label: "A", total: 80, user_count: 30 }, { thread_label: "B", total: 50, user_count: 0 }] };
  expect(deriveWorstGhost(g)).toEqual({ name: "B", messages: 50, userSent: 0 });
  expect(deriveWorstGhost({ per_thread: [] })).toBeNull();
});

test("buildData: card arc + window label + injected fields", () => {
  const analysis = {
    latency: { median_minutes: 4.4, mean_minutes: 77, pct_within_5min: 47 },
    ball_in_court: { pct_ball_in_court: 60 },
    group_contribution: { user_contribution_pct: 10.1, groups_where_user_silent: 5, total_groups_analyzed: 89, worst_offender: { thread_label: "G", total: 100, user_count: 0 } },
    top_people: [{ name: "Alice", count: 10 }],
    top_people_l30: [{ name: "Alice", count: 3 }],
    talk_listen: { you_words: 1000, them_words: 1100, your_share_pct: 47.6 },
    emoji: { pct_messages_with_emoji: 5.3 },
    age: {
      estimated_age: 47,
      band: "gen_x",
      label: "Gen X",
      approx_age: "44-59",
      confidence: "medium",
      drivers: ["Proper capitalization", "Uses 'lol' non-ironically", "Period ending a short single-sentence text"],
      sample_size: 500,
      active_days: 45,
      evidence_count: 3,
    },
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const data = buildData(analysis, { year: 2026, totalSent: 8391, showPeople: true });
  expect(data.cards).toEqual(["cover", "volume", "people", "people_l30", "talk_listen", "latency", "ballincourt", "groups", "emoji", "age", "archetype", "share"]);
  expect(data.archetype.name).toBe("The Fast Starter");
  expect(data.archetype.drivers).toEqual(["4.4 min median reply", "77 min mean reply", "47% within five"]);
  expect(data.totalSent).toBe(8391);
  expect(data.ballInCourt).toBe(60);
  expect(data.windowLabel).toMatch(/^\w{3} \d{4} — \w{3} \d{4}$/);
  // no-people suppresses the personal cards
  const pub = buildData(analysis, { totalSent: 8391, showPeople: false });
  expect(pub.cards).not.toContain("people");
  expect(pub.cards).not.toContain("talk_listen");
});

test("buildData: suppresses texting-age card when evidence guardrails fail", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    age: {
      estimated_age: 35,
      band: "millennial",
      label: "Millennial",
      approx_age: "28-43",
      confidence: "low",
      drivers: [],
      sample_size: 22,
      evidence_count: 1,
    },
    filters: { window_days: 0, since_ts_ms: 0, until_ts_ms: 1780272000000 },
  };

  const data = buildData(analysis, {});

  expect(data.cards).not.toContain("age");
  expect(data.age).toBeUndefined();
});

test("buildWrapped: embeds BOTH windows in one HTML (in-page toggle data)", () => {
  const yearAnalysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const allTimeAnalysis = {
    ...yearAnalysis,
    filters: { window_days: 0, since_ts_ms: 0, until_ts_ms: 1780272000000 },
  };
  const { html, data, allTimeData } = buildWrapped(
    yearAnalysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: "/* app */" },
    { totalSent: 8391, allTimeAnalysis, allTimeTotalSent: 48200 },
  );
  expect(html).toContain("window.WRAPPED_DATASETS = ");
  expect(html).toContain('"past_year":');
  expect(html).toContain('"all_time":');
  expect(html).toContain("/* app */");
  expect(data.windowLabel).toMatch(/^\w{3} \d{4} — \w{3} \d{4}$/);
  expect(data.totalSent).toBe(8391);
  expect(allTimeData.windowLabel).toBe("All time");
  expect(allTimeData.totalSent).toBe(48200);
  // No window choice flags anymore — and no treatment plumbing.
  expect(html).not.toContain("WRAPPED_TREATMENT");
  expect(html).not.toContain("WRAPPED_TOGGLE = {");
});

test("buildWrapped: without an all-time analysis the all_time slot is null", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    filters: { window_days: 0, since_ts_ms: 0, until_ts_ms: 1780272000000 },
  };
  const { html, data, allTimeData } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: "/* app */" },
    {},
  );
  expect(allTimeData).toBeNull();
  expect(html).toContain('"all_time":null');
  expect(data.windowLabel).toBe("All time");
});

test("buildWrapped: embedded app keeps native preview telemetry guarded for browser use", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    filters: { window_days: 0, since_ts_ms: 0, until_ts_ms: 1780272000000 },
  };
  const { html } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: wrappedAppJsx },
    {},
  );

  expect(html).toContain("messagesForAIWrapped");
  expect(html).toContain("window.webkit?.messageHandlers?.messagesForAIWrapped?.postMessage");
  expect(html).toContain("notifyNative('loaded')");
  expect(html).toContain("notifyNative('toggle_window')");
});

test("buildWrapped: generated Texting Wrapped content points at textingwrapped.com", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const { html } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: wrappedAppJsx },
    {},
  );

  expect(html).toContain("textingwrapped.com");
  expect(html).not.toContain("messagesfor.ai");
});

test("buildWrapped: embedded app has unique card export filenames and native file bridge", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    top_people: [{ name: "Alice", count: 10 }],
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const { html } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: wrappedAppJsx },
    {},
  );

  expect(html).toContain("function cardExportName(index, extension = 'png')");
  expect(html).toContain("texting-wrapped-${DATA.year}-${n}-${slugPart(cardKey)}.${extension}");
  expect(html).toContain("function allCardsExportName(extension = 'png')");
  expect(html).toContain("texting-wrapped-${DATA.year}-all-cards.${extension}");
  expect(html).toContain("function sendNativeWrappedFile");
  expect(html).toContain("action: nativeAction");
  expect(html).toContain("'export_card'");
  expect(html).toContain("'export_all'");
  expect(html).toContain("navigator.share");
});

test("buildWrapped: embedded app exposes native snapshot API and hides browser controls in native preview", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    top_people: [{ name: "Alice", count: 10 }],
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const { html } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: wrappedAppJsx },
    {},
  );

  expect(html).toContain("__MESSAGES_FOR_AI_NATIVE_PREVIEW");
  expect(html).toContain("__messagesForAIWrappedSnapshot");
  expect(html).toContain("data-wrapped-capture-active");
  expect(html).toContain("shareableIndices");
  expect(html).toContain("{!nativePreview && (");
  expect(html).toContain("{!nativePreview && idx === CARDS.length - 1 && (");
});

test("buildWrapped: share recap includes average reply in a clean grid", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    top_people: [{ name: "Alice", count: 10 }],
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const { html } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: wrappedAppJsx },
    {},
  );

  expect(html).toContain("label: 'average reply'");
  expect(html).toContain("tiles.slice(0, 10)");
});

test("buildWrapped: cover card includes non-captured navigation guidance", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const { html } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: wrappedAppJsx },
    {},
  );

  expect(html).toContain("function NavigationHint()");
  expect(html).toContain("Navigate");
  expect(html).toContain("Arrow keys");
  expect(html).toContain("Swipe or drag");
  expect(html).not.toContain("Tap card edges");
  expect(html).toContain("const showNavigationHint = idx === 0 && !capturing");
  expect(html).toContain("{showNavigationHint && <NavigationHint />}");
  expect(html).toContain("data-wrapped-capture-active={isActive ? 'true' : undefined}");
});

test("buildWrapped: recap tile grid stays bounded for pager styling", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    top_people: [{ name: "A Very Long Contact Name", count: 1000 }],
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const { html } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: wrappedAppJsx },
    {},
  );

  expect(html).toContain("gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)'");
  expect(html).toContain("boxSizing: 'border-box'");
  expect(html).toContain("minWidth: 0");
});

test("buildWrapped: generated capture path is local and self-contained", () => {
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: { user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const { html } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: wrappedAppJsx },
    {},
  );

  expect(html).not.toContain("https://unpkg.com/html2canvas");
  expect(html).toContain("html2canvas 1.4.1");
  expect(html).toContain("html2canvas=");
});

test("buildWrapped: chat.db-derived names can't break out of the inline <script> (XSS)", () => {
  // A group renamed to a </script> breakout payload reaches WRAPPED_DATA via
  // worst_offender. The serialized data must NOT contain a literal </script>
  // (which the HTML tokenizer would honor), but must still round-trip the value.
  const payload = `</script><img src=x onerror="alert(document.domain)">`;
  const analysis = {
    latency: { median_minutes: 5, mean_minutes: 30, pct_within_5min: 40 },
    ball_in_court: { pct_ball_in_court: 50 },
    group_contribution: {
      user_contribution_pct: 15, groups_where_user_silent: 2, total_groups_analyzed: 10,
      worst_offender: { thread_label: payload, total: 99, user_count: 0 },
    },
    filters: { window_days: 0, since_ts_ms: 0, until_ts_ms: 1780272000000 },
  };
  const { html, data } = buildWrapped(
    analysis,
    { ios: "/* ios */", treatments: "/* treatments */", app: "/* app */" },
    {},
  );
  // Breakout neutralized: no literal </script> immediately followed by markup.
  expect(html).not.toContain(`</script><img`);
  // Escaped form is present instead, and the data round-trips intact.
  expect(html).toContain(`\\u003c/script`);
  expect(data.worstGhost.name).toBe(payload);
});

test("buildData: year derives from the window end, not a hardcoded 2026", () => {
  const mk = (untilMs: number) => buildData(
    { latency: {}, ball_in_court: {}, group_contribution: {}, filters: { window_days: 0, since_ts_ms: 0, until_ts_ms: untilMs } },
    {},
  ).year;
  expect(mk(Date.UTC(2027, 5, 1))).toBe(2027);
  expect(mk(Date.UTC(2031, 0, 15))).toBe(2031);
});

test("buildAnalyticsReport: exposes workbench metrics and respects showPeople", () => {
  const analysis = {
    latency: { median_minutes: 12, mean_minutes: 40, pct_within_5min: 20 },
    ball_in_court: { pct_ball_in_court: 35, live_conversations_estimate: 19 },
    group_contribution: { user_contribution_pct: 8, groups_where_user_silent: 2, total_groups_analyzed: 10 },
    top_people: [{ name: "Alice", count: 99 }],
    top_people_l30: [{ name: "Alice", count: 12 }],
    top_people_by_chars: [{ name: "Alice", chars: 12345 }],
    talk_listen: { you_words: 100, them_words: 150, your_share_pct: 40 },
    emoji: { pct_messages_with_emoji: 7 },
    filters: { window_days: 365, since_ts_ms: 1748736000000, until_ts_ms: 1780272000000 },
  };
  const report = buildAnalyticsReport(analysis, { totalSent: 500, generatedAtMs: 42, showPeople: false });
  expect(report.schema_version).toBe("1.0");
  expect(report.generated_at_ms).toBe(42);
  expect(report.total_sent).toBe(500);
  expect(report.latency.median_minutes).toBe(12);
  expect(report.top_people).toEqual([]);
  expect(report.talk_listen).toBeNull();
});
