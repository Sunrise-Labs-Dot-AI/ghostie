// Phase A3 — assemble the self-contained Wrapped HTML. Port of build_wrapped.py.
// Maps analysis.json → the card DATA and inlines the design .jsx (source of
// truth for the look) into one file. The .jsx + rubric are embedded into the
// compiled binary by the caller (index.ts) and passed in as `assets`.
//
// Parity note: the emitted HTML is NOT byte-identical to the Python output
// (json.dumps uses ", "/": " separators; JSON.stringify is compact) — but the
// browser ignores that. The parity-checked artifact is the injected
// WRAPPED_DATA object (buildData), which IS identical.

import { pyRound } from "./analyze.ts";
// @ts-ignore — browser bundle imported as text so generated Wrapped HTML does
// not depend on a remote CDN for PNG capture.
import html2canvasSource from "html2canvas/dist/html2canvas.min.js" with { type: "text" };

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const dayLabel = (d: Date) => `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;

// Python %g (default 6 sig figs, strip trailing zeros + trailing dot).
function pyG(x: number): string {
  if (x === 0) return "0";
  let s = x.toPrecision(6);
  if (s.includes(".") && !s.includes("e")) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return s;
}
// Python {:.1f} / {:.0f} — round-half-to-even via pyRound, then fixed decimals.
const f1 = (x: number) => pyRound(x, 1).toFixed(1);
const f0 = (x: number) => String(pyRound(x, 0));

interface Archetype {
  name: string;
  short: string;
  verdict: string;
  why: string;
  drivers: string[];
  confidence: "high" | "medium" | "low";
  support_level: "supported" | "cautious" | "playful";
}

interface ArchetypeContext {
  totalSent?: number | null;
  threadCount?: number | null;
  topPeople?: { count?: number }[] | null;
  reactionRate?: number | null;
}

export function deriveWorstGhost(group: any): { name: string; messages: number; userSent: number } | null {
  let pick = group?.worst_offender;
  if (!pick) {
    const threads = group?.per_thread ?? [];
    if (!threads.length) return null;
    const zero = threads.filter((t: any) => (t.user_count ?? 1) === 0);
    const pool = zero.length ? zero : threads;
    pick = pool.reduce((best: any, t: any) => {
      if (!best) return t;
      const bt = best.total ?? 0, tt = t.total ?? 0;
      if (tt !== bt) return tt > bt ? t : best;
      return -(t.user_count ?? 0) > -(best.user_count ?? 0) ? t : best;
    }, null);
  }
  return { name: pick.thread_label ?? "a group", messages: pick.total ?? 0, userSent: pick.user_count ?? 0 };
}

// Priority-ordered: first match wins, most distinctive first. Verdict/why use
// the user's REAL numbers; verdicts roast the USER only, never a third party.
//
// Semantics (matches analyze's ball block): `ball` = % of threads where the
// USER sent the last substantive message. High ball → you served and they went
// quiet; LOW ball → most threads are parked on YOUR reply.
//
// `emojiPct` is null when no emoji pass ran — the emoji-keyed archetypes only
// fire when the signal actually exists (a missing block is not 0%).
//
// PARITY: this is a line-for-line port of derive_archetype in
// skills/texting-analytics/wrapped/build_wrapped.py — keep the threshold table
// and strings identical in both.
export function deriveArchetype(
  median: number, mean: number, fastPct: number, ball: number,
  groupPct: number, silent: number, totalGroups: number, emojiPct: number | null = null,
  context: ArchetypeContext = {},
): Archetype {
  const slowTail = mean >= Math.max(4 * Math.max(median, 0.1), median + 20);
  const groupsKnown = totalGroups >= 3;
  const silentRatio = totalGroups ? silent / totalGroups : 0;
  const activeGroups = Math.max(totalGroups - silent, 0);
  const totalSent = context.totalSent ?? null;
  const threadCount = context.threadCount ?? null;
  const topCount = context.topPeople?.[0]?.count ?? null;
  const topShare = totalSent && topCount != null ? (100 * topCount) / totalSent : null;
  const reactionRate = context.reactionRate ?? 0;
  const sentStr = (n: number) => Math.trunc(n).toLocaleString("en-US");
  const A = (
    name: string,
    short: string,
    verdict: string,
    why: string,
    drivers: string[],
    confidence: Archetype["confidence"] = "medium",
    supportLevel: Archetype["support_level"] = "supported",
  ): Archetype => ({ name, short, verdict, why, drivers, confidence, support_level: supportLevel });

  if (groupsKnown && groupPct < 3 && silentRatio >= 0.5)
    return A("The Group Chat Ghost", "Ghost", "present in name, absent in spirit.",
      `${f1(groupPct)}% group share, silent in ${silent} of ${totalGroups} groups.`,
      [`${f1(groupPct)}% group share`, `silent in ${silent} of ${totalGroups} groups`, `last word in ${ball}% of threads`],
      "low", "playful");
  if (groupsKnown && groupPct >= 45)
    return A("The Town Crier", "Crier", "you don't have a group chat. the group chat has you.",
      `you sent ${f1(groupPct)}% of every group message — the others are an audience.`,
      [`${f1(groupPct)}% group share`, `active in ${activeGroups} of ${totalGroups} groups`, `${pyG(median)} min median reply`],
      "high", "supported");
  if (median <= 1.5 && fastPct >= 70)
    return A("The Lightning Round", "Lightning", "replying this fast is legally a reflex.",
      `median reply ${pyG(median)} min, ${fastPct}% inside five minutes.`,
      [`${pyG(median)} min median reply`, `${fastPct}% within five`, `last word in ${ball}% of threads`],
      "high", "supported");
  if (ball <= 18)
    return A("Left-on-Read Royalty", "Royalty", "everyone's favorite person to wait on.",
      `you had the last word in only ${ball}% of threads — the other ${100 - ball}% are parked on your reply.`,
      [`last word in ${ball}% of threads`, `${pyG(median)} min median reply`, `${f1(groupPct)}% group share`],
      "low", "playful");
  if (ball >= 80)
    return A("The Last Word", "Last Word", "you simply must close every thread. the silence after is on them.",
      `you sent the final message in ${ball}% of your threads.`,
      [`last word in ${ball}% of threads`, `${pyG(median)} min median reply`, `${fastPct}% within five`],
      "low", "playful");
  if (ball >= 55 && fastPct >= 55 && median <= 5)
    return A("The Ping-Pong Pro", "Ping-Pong", "every serve comes back. every single one.",
      `median ${pyG(median)} min, ${fastPct}% within five, last word in ${ball}% of threads.`,
      [`${pyG(median)} min median reply`, `${fastPct}% within five`, `last word in ${ball}% of threads`],
      "medium", "cautious");
  if (groupsKnown && groupPct >= 28)
    return A("The Group MVP", "MVP", "the group chat would flatline without you. you've checked.",
      `you send ${f1(groupPct)}% of all group messages — far above an even share.`,
      [`${f1(groupPct)}% group share`, `active in ${activeGroups} of ${totalGroups} groups`, `last word in ${ball}% of threads`],
      "high", "supported");
  if (emojiPct != null && emojiPct >= 45)
    return A("The Emoji Maximalist", "Maximalist", "why use words when a tiny face says it worse.",
      `${f0(emojiPct)}% of your texts carry at least one emoji.`,
      [`${f0(emojiPct)}% emoji-bearing texts`, `${pyG(median)} min median reply`, `${f1(groupPct)}% group share`],
      "medium", "supported");
  if (emojiPct != null && emojiPct <= 2)
    return A("The Deadpan", "Deadpan", "every message delivered at room temperature.",
      `only ${f1(emojiPct)}% of your texts contain an emoji.`,
      [`${f1(emojiPct)}% emoji-bearing texts`, `${pyG(median)} min median reply`, `${f1(groupPct)}% group share`],
      "medium", "supported");
  if (median >= 45 && slowTail)
    return A("The Sorry-Just-Saw-This", "Sorry", "'sorry, just saw this.' you saw it. everyone knows you saw it.",
      `median reply ${pyG(median)} min, and the slow ones stretch the average to ${pyG(mean)}.`,
      [`${pyG(median)} min median reply`, `${pyG(mean)} min mean reply`, `${fastPct}% within five`],
      "medium", "supported");
  if (median >= 60)
    return A("The Slow Burn", "Slow Burn", "replies measured in business days.",
      `half your replies take longer than ${pyG(median)} minutes.`,
      [`${pyG(median)} min median reply`, `${fastPct}% within five`, `last word in ${ball}% of threads`],
      "medium", "supported");
  if (slowTail && median <= 10)
    return A("The Fast Starter", "Fast Starter", "quick on the draw, slow on the follow-through.",
      `median reply ${pyG(median)} min, but the mean is ${pyG(mean)} min — the long tail tells on you.`,
      [`${pyG(median)} min median reply`, `${pyG(mean)} min mean reply`, `${fastPct}% within five`],
      "medium", "supported");
  if (median <= 3)
    return A("The Quick Draw", "Quick Draw", "replies before the typing bubble fades.",
      `median reply ${pyG(median)} min, ${fastPct}% within five.`,
      [`${pyG(median)} min median reply`, `${fastPct}% within five`, `last word in ${ball}% of threads`],
      "high", "supported");
  if (groupsKnown && silentRatio >= 0.5 && median <= 8)
    return A("The VIP Room", "VIP", "fast for the chosen few. the group chat didn't make the list.",
      `median reply ${pyG(median)} min in your threads, yet silent in ${silent} of ${totalGroups} groups.`,
      [`${pyG(median)} min median reply`, `silent in ${silent} of ${totalGroups} groups`, `${f1(groupPct)}% group share`],
      "medium", "cautious");
  if (groupsKnown && groupPct < 5)
    return A("The Quiet Lurker", "Lurker", "sees everything. says nothing. knows all.",
      `just ${f1(groupPct)}% of group messages, silent in ${silent} of ${totalGroups} groups.`,
      [`${f1(groupPct)}% group share`, `silent in ${silent} of ${totalGroups} groups`, `${pyG(median)} min median reply`],
      "medium", "cautious");
  if (groupsKnown && ball <= 35 && groupPct >= 15)
    return A("The Main Stage", "Main Stage", "electric in the group chat, bankrupt in the DMs.",
      `${f1(groupPct)}% group share while ${100 - ball}% of threads wait on your reply.`,
      [`${f1(groupPct)}% group share`, `last word in ${ball}% of threads`, `${pyG(median)} min median reply`],
      "medium", "cautious");
  if (groupsKnown && reactionRate >= 45)
    return A("The Reaction Regular", "Reactor", "keeps the thread warm without writing a novel.",
      `${f0(reactionRate)}% of your group-chat activity is reactions.`,
      [`${f0(reactionRate)}% reaction rate`, `active in ${activeGroups} of ${totalGroups} groups`, `${f1(groupPct)}% group share`],
      "medium", "supported");
  if (totalSent != null && threadCount != null && topShare != null && totalSent >= 9000 && threadCount >= 60 && topShare <= 20)
    return A("The Social Connector", "Connector", "many threads, no single lane.",
      `${sentStr(totalSent)} texts across ${threadCount} active threads, with your top contact at ${f1(topShare)}% of sends.`,
      [`${sentStr(totalSent)} texts sent`, `${threadCount} active threads`, `${f1(topShare)}% to top contact`],
      "high", "supported");
  if (topShare != null && totalSent != null && totalSent >= 1500 && topShare >= 28)
    return A("The Inner-Circle Texter", "Inner Circle", "small circle, strong signal.",
      `${f1(topShare)}% of your sent texts go to your top contact.`,
      [`${f1(topShare)}% to top contact`, `${sentStr(totalSent)} texts sent`, `${pyG(median)} min median reply`],
      "high", "supported");
  if (totalSent != null && totalSent >= 15000)
    return A("The High-Volume Texter", "High Volume", "the conversation engine is always on.",
      `${sentStr(totalSent)} sent texts in this window.`,
      [`${sentStr(totalSent)} texts sent`, `${pyG(median)} min median reply`, `${f1(groupPct)}% group share`],
      "medium", "supported");
  if (ball >= 45 && ball <= 60 && median >= 5 && median <= 30)
    return A("The Diplomat", "Diplomat", "balanced, measured, suspiciously reasonable.",
      `median ${pyG(median)} min, last word in ${ball}% of threads — even on both sides of the net.`,
      [`${pyG(median)} min median reply`, `last word in ${ball}% of threads`, `${f1(groupPct)}% group share`],
      "medium", "cautious");
  return A("The Steady Hand", "Steady", "consistent, present, hard to rattle.",
    `median ${pyG(median)} min, ${ball}% last-word rate, ${f1(groupPct)}% group share.`,
    [`${pyG(median)} min median reply`, `${ball}% last-word rate`, `${f1(groupPct)}% group share`],
    "medium", "cautious");
}

export interface BuildDataOptions { year?: number; totalSent?: number | null; showPeople?: boolean }

export function buildData(analysis: any, opts: BuildDataOptions = {}): any {
  // Year drives the HTML <title> only (visible cards use windowLabel). Derive
  // it from the analysis window end so a wrap built in 2027 isn't titled "2026";
  // fall back to the current year if filters are missing (never in practice —
  // analyze always sets until_ts_ms). opts.year still overrides (tests pin it).
  const untilForYear = analysis.filters?.until_ts_ms;
  const year = opts.year ?? (untilForYear ? new Date(untilForYear).getFullYear() : new Date().getFullYear());
  const totalSent = opts.totalSent ?? null;
  const showPeople = opts.showPeople ?? true;

  const lat = analysis.latency ?? {};
  const bic = analysis.ball_in_court ?? {};
  const grp = analysis.group_contribution ?? {};

  const median = Number(lat.median_minutes ?? 0);
  const mean = Number(lat.mean_minutes ?? 0);
  const fastPct = Math.trunc(pyRound(lat.pct_within_5min ?? 0, 0));
  const ball = Math.trunc(pyRound(bic.pct_ball_in_court ?? 0, 0));
  const groupPct = Number(grp.user_contribution_pct ?? 0);
  const silent = Math.trunc(grp.groups_where_user_silent ?? 0);
  const totalGroups = Math.trunc(grp.total_groups_analyzed ?? 0);
  // null (not 0) when the emoji pass didn't run — keeps the emoji-keyed
  // archetypes from firing off a missing block.
  const emojiPct = analysis.emoji ? Number(analysis.emoji.pct_messages_with_emoji ?? 0) : null;

  const archetype = deriveArchetype(median, mean, fastPct, ball, groupPct, silent, totalGroups, emojiPct, {
    totalSent,
    threadCount: lat.thread_count ?? null,
    topPeople: analysis.top_people ?? null,
    reactionRate: grp.user_reaction_rate_pct ?? null,
  });
  const worstGhost = deriveWorstGhost(grp);

  const cards: string[] = ["cover"];
  if (totalSent) cards.push("volume");
  const topPeople = showPeople ? analysis.top_people : null;
  const topPeopleL30 = showPeople ? analysis.top_people_l30 : null;
  const talkListen = showPeople ? analysis.talk_listen : null;
  if (topPeople) cards.push("people");
  if (topPeopleL30) cards.push("people_l30");
  const hasTalk = talkListen && talkListen.you_words && talkListen.them_words;
  if (hasTalk) cards.push("talk_listen");
  cards.push("latency", "ballincourt", "groups");
  const emoji = analysis.emoji;
  if (emoji) cards.push("emoji");
  const age = shouldShowAge(analysis.age) ? analysis.age : null;
  if (age) cards.push("age");
  cards.push("archetype", "share");

  // Window label from the analysis filters (local tz, like Python fromtimestamp).
  const filters = analysis.filters ?? {};
  const sinceMs = filters.since_ts_ms;
  const untilMs = filters.until_ts_ms;
  const windowDays = filters.window_days;
  let windowLabel: string;
  if (windowDays === 0 || sinceMs == null || sinceMs === 0) {
    windowLabel = "All time";
  } else if (untilMs) {
    const s = new Date(sinceMs), e = new Date(untilMs);
    const spanDays = (untilMs - sinceMs) / (86400 * 1000);
    windowLabel = spanDays <= 62
      ? `${dayLabel(s)} — ${dayLabel(e)}`
      : `${MONTHS[s.getMonth()]} ${s.getFullYear()} — ${MONTHS[e.getMonth()]} ${e.getFullYear()}`;
  } else {
    windowLabel = String(year);
  }

  const data: any = {
    year,
    windowLabel,
    windowDays: windowDays ?? 365,
    median: pyRound(median, 1),
    mean: pyRound(mean, 1),
    fastPct,
    ballInCourt: ball,
    groupContribPct: pyRound(groupPct, 1),
    silentGroups: silent,
    totalGroups,
    worstGhost,
    archetype,
    cards,
  };
  if (totalSent) data.totalSent = Math.trunc(totalSent);
  if (topPeople) data.topPeople = topPeople;
  if (topPeopleL30) data.topPeopleL30 = topPeopleL30;
  if (hasTalk) data.talkListen = talkListen;
  if (emoji) data.emoji = emoji;
  if (analysis.style) data.style = analysis.style;
  if (age) data.age = age;
  return data;
}

function shouldShowAge(age: any): boolean {
  if (!age) return false;
  const sampleSize = age.sample_size;
  const evidenceCount = age.evidence_count;
  const drivers = Array.isArray(age.drivers) ? age.drivers : [];
  return (
    age.estimated_age != null &&
    sampleSize != null && sampleSize >= 500 &&
    age.active_days != null && age.active_days >= 30 &&
    evidenceCount != null && evidenceCount >= 3 &&
    drivers.length >= 3
  );
}

export interface BuildAnalyticsReportOptions extends BuildDataOptions {
  generatedAtMs?: number;
}

export function buildAnalyticsReport(analysis: any, opts: BuildAnalyticsReportOptions = {}): any {
  const data = buildData(analysis, opts);
  const showPeople = opts.showPeople ?? true;
  return {
    schema_version: "1.0",
    generated_at_ms: opts.generatedAtMs ?? Date.now(),
    window_label: data.windowLabel,
    window_days: data.windowDays,
    total_sent: data.totalSent ?? null,
    archetype: data.archetype ?? null,
    latency: analysis.latency ?? null,
    ball_in_court: analysis.ball_in_court ?? null,
    group_contribution: analysis.group_contribution ?? null,
    top_people: showPeople ? (analysis.top_people ?? []) : [],
    top_people_l30: showPeople ? (analysis.top_people_l30 ?? []) : [],
    top_people_by_chars: showPeople ? (analysis.top_people_by_chars ?? []) : [],
    talk_listen: showPeople ? (analysis.talk_listen ?? null) : null,
    emoji: analysis.emoji ?? null,
    style: analysis.style ?? null,
    age: analysis.age ?? null,
    filters: analysis.filters ?? null,
  };
}

function inlineScript(source: string): string {
  return `<script>\n${source.replace(/<\/script/gi, "<\\/script")}\n</script>`;
}

const HEAD = (year: number) => `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Texting Wrapped ${year}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Instrument+Serif:ital@0;1&family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  html, body { margin: 0; padding: 0; height: 100%; background: #0a0a0c;
    font-family: 'Inter', system-ui, sans-serif; -webkit-font-smoothing: antialiased;
    text-rendering: geometricPrecision; }
  #root { width: 100%; height: 100%; }
  * { box-sizing: border-box; }
  button { font: inherit; }
</style>
</head>
<body>
<div id="root"></div>
<script src="https://unpkg.com/react@18.3.1/umd/react.production.min.js" crossorigin></script>
<script src="https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js" crossorigin></script>
<script src="https://unpkg.com/@babel/standalone@7.29.0/babel.min.js" crossorigin></script>
${inlineScript(html2canvasSource)}
`;

export interface WrappedAssets { ios: string; treatments: string; app: string }
export interface BuildWrappedOptions extends BuildDataOptions {
  // All-time companion dataset. When present, the generated HTML embeds BOTH
  // metric sets and the presentation UI shows an in-page "All time" toggle
  // (default view: past year).
  allTimeAnalysis?: any | null;
  allTimeTotalSent?: number | null;
}

export interface BuildWrappedResult { html: string; data: any; allTimeData: any | null }

// Serialize a value for embedding inside an inline <script>. JSON.stringify does
// NOT escape the substring "</script>", and the HTML tokenizer closes the script
// element at the first literal "</script>" regardless of JS string context — so a
// chat.db-derived value (a group renamed to "</script><img src=x onerror=…>", a
// contact name) reaching WRAPPED_DATA would break out of the script and execute
// when the user opens the generated file. Replacing "<" with the JSON escape
// < (which JSON.parse restores to "<") makes the embedded data round-trip
// byte-identically (no parity impact) while no "</script>" / "<!--" can ever
// reach the HTML tokenizer.
function safeJson(value: unknown): string {
  return JSON.stringify(value).replace(/</g, "\\u003c");
}

export function buildWrapped(analysis: any, assets: WrappedAssets, opts: BuildWrappedOptions = {}): BuildWrappedResult {
  const data = buildData(analysis, opts);
  const allTimeData = opts.allTimeAnalysis
    ? buildData(opts.allTimeAnalysis, {
        year: opts.year,
        totalSent: opts.allTimeTotalSent ?? null,
        showPeople: opts.showPeople,
      })
    : null;

  const datasets = { past_year: data, all_time: allTimeData };
  const parts = [
    HEAD(data.year),
    `<script>window.WRAPPED_DATASETS = ${safeJson(datasets)};</script>`,
    `<script type="text/babel">\n${assets.ios}\n</script>`,
    `<script type="text/babel">\n${assets.treatments}\n</script>`,
    `<script type="text/babel">\n${assets.app}\n</script>`,
    "</body>\n</html>\n",
  ];
  return { html: parts.join("\n"), data, allTimeData };
}
