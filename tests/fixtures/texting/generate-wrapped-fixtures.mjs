#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outPath = join(here, "wrapped-personas.json");
const since = Date.UTC(2025, 5, 1);
const until = Date.UTC(2026, 5, 1);

const topPeople = [
  { name: "Sample Contact A", count: 310 },
  { name: "Sample Contact B", count: 220 },
  { name: "Sample Contact C", count: 140 },
];

const styles = {
  genZ: {
    dominant_laugh: "sob",
    pct_all_lowercase: 78,
    pct_end_period: 4,
    pct_emoji_ending: 24,
    genz_slang_breakdown: {},
    aging_slang_breakdown: {},
    sample_size: 920,
    active_days: 120,
  },
  millennial: {
    dominant_laugh: "joy",
    pct_all_lowercase: 52,
    pct_end_period: 7,
    pct_emoji_ending: 17,
    genz_slang_breakdown: {},
    aging_slang_breakdown: {},
    sample_size: 870,
    active_days: 110,
  },
  genX: {
    dominant_laugh: "lol",
    pct_all_lowercase: 7,
    pct_end_period: 34,
    pct_repeated_exclaim: 10,
    genz_slang_breakdown: {},
    aging_slang_breakdown: {},
    sample_size: 760,
    active_days: 95,
  },
  boomerPlus: {
    dominant_laugh: "lol",
    pct_all_lowercase: 4,
    pct_end_period: 48,
    pct_ellipsis: 16,
    pct_repeated_exclaim: 13,
    genz_slang_breakdown: {},
    aging_slang_breakdown: {},
    sample_size: 640,
    active_days: 80,
  },
  thin: {
    dominant_laugh: "joy",
    pct_all_lowercase: null,
    pct_end_period: null,
    genz_slang_breakdown: {},
    aging_slang_breakdown: {},
    sample_size: 22,
    active_days: 2,
  },
};

function analysis({
  median,
  mean,
  fast,
  ball,
  groupPct,
  silent,
  totalGroups,
  emojiPct = 18,
  totalSent = 8000,
  style = styles.millennial,
  worstLabel = "Synthetic Crew",
  worstTotal = 120,
  worstUser = 3,
  threadCount = 48,
  topCounts = [310, 220, 140],
  reactionRate = 28,
  talkShare = null,
}) {
  const people = topPeople.map((p, i) => ({ ...p, count: topCounts[i] ?? p.count }));
  return {
    top_people: people,
    top_people_l30: people.slice(0, 2).map((p) => ({ ...p, count: Math.round(p.count / 4) })),
    ...(talkShare == null ? {} : {
      talk_listen: {
        you_words: 12000,
        them_words: Math.round(12000 * (100 - talkShare) / talkShare),
        your_share_pct: talkShare,
      },
    }),
    latency: {
      total_reply_pairs: 520,
      pct_within_5min: fast,
      pct_within_30min: Math.min(fast + 22, 96),
      pct_within_1hr: Math.min(fast + 31, 98),
      pct_within_4hr: Math.min(fast + 46, 99),
      mean_minutes: mean,
      median_minutes: median,
      thread_count: threadCount,
      window_label: "synthetic past year",
    },
    ball_in_court: {
      total_threads_sampled: 100,
      threads_with_ball_in_court: ball,
      pct_ball_in_court: ball,
      live_conversations_estimate: 37,
      snapshot_label: "synthetic now",
    },
    group_contribution: {
      total_groups_analyzed: totalGroups,
      total_messages_in_groups: 900,
      user_messages_in_groups: Math.round(900 * groupPct / 100),
      user_contribution_pct: groupPct,
      user_reaction_rate_pct: reactionRate,
      peer_reaction_rate_pct: 30,
      groups_where_user_silent: silent,
      groups_mostly_reactions: Math.min(silent, 4),
      per_thread: [
        { thread_label: worstLabel, total: worstTotal, user_count: worstUser, user_pct: 0, user_reaction_pct: 0 },
        { thread_label: "Synthetic Weekend Plans", total: 80, user_count: 18, user_pct: 22.5, user_reaction_pct: 10 },
      ],
      worst_offender: { thread_label: worstLabel, total: worstTotal, user_count: worstUser },
    },
    emoji: {
      pct_messages_with_emoji: emojiPct,
      emoji_per_message: Number((emojiPct / 56).toFixed(2)),
      top: [{ emoji: "😂", count: 140 }, { emoji: "❤️", count: 90 }, { emoji: "🔥", count: 40 }],
    },
    style,
    filters: { window_days: 365, since_ts_ms: since, until_ts_ms: until },
    fixture_total_sent: totalSent,
  };
}

const fixtures = [
  {
    id: "archetype_ghost_genz",
    family: "archetype",
    expected_archetype: "The Group Chat Ghost",
    expected_age_band: "gen_z",
    analysis: analysis({ median: 8, mean: 90, fast: 44, ball: 93, groupPct: 0.7, silent: 12, totalGroups: 15, style: styles.genZ, totalSent: 12400, worstUser: 0 }),
  },
  {
    id: "archetype_last_word_genx",
    family: "archetype",
    expected_archetype: "The Last Word",
    expected_age_band: "gen_x",
    analysis: analysis({ median: 18, mean: 35, fast: 20, ball: 82, groupPct: 12, silent: 3, totalGroups: 14, style: styles.genX, totalSent: 6200 }),
  },
  {
    id: "archetype_royalty_millennial",
    family: "archetype",
    expected_archetype: "Left-on-Read Royalty",
    expected_age_band: "millennial",
    analysis: analysis({ median: 10, mean: 20, fast: 45, ball: 12, groupPct: 15, silent: 2, totalGroups: 12, style: styles.millennial, totalSent: 8400 }),
  },
  {
    id: "archetype_mvp_genz",
    family: "archetype",
    expected_archetype: "The Group MVP",
    expected_age_band: "gen_z",
    analysis: analysis({ median: 6, mean: 15, fast: 50, ball: 45, groupPct: 38, silent: 0, totalGroups: 8, style: styles.genZ, totalSent: 11200 }),
  },
  {
    id: "archetype_maximalist_millennial",
    family: "archetype",
    expected_age_band: "millennial",
    expected_archetype: "The Emoji Maximalist",
    analysis: analysis({ median: 5, mean: 12, fast: 55, ball: 40, groupPct: 15, silent: 1, totalGroups: 10, emojiPct: 52, style: styles.millennial, totalSent: 9300 }),
  },
  {
    id: "archetype_fast_starter_millennial",
    family: "archetype",
    expected_archetype: "The Fast Starter",
    expected_age_band: "millennial",
    analysis: analysis({ median: 4, mean: 77, fast: 47, ball: 60, groupPct: 8.8, silent: 2, totalGroups: 19, style: styles.millennial, totalSent: 7800 }),
  },
  {
    id: "archetype_lightning_genz",
    family: "archetype",
    expected_archetype: "The Lightning Round",
    expected_age_band: "gen_z",
    analysis: analysis({ median: 0.8, mean: 8, fast: 72, ball: 45, groupPct: 18, silent: 1, totalGroups: 10, style: styles.genZ, totalSent: 7200 }),
  },
  {
    id: "archetype_slow_burn_boomer",
    family: "archetype",
    expected_archetype: "The Slow Burn",
    expected_age_band: "boomer_plus",
    analysis: analysis({ median: 70, mean: 96, fast: 8, ball: 55, groupPct: 4, silent: 8, totalGroups: 14, style: styles.boomerPlus, totalSent: 2100, worstUser: 0 }),
  },
  {
    id: "archetype_diplomat_genx",
    family: "archetype",
    expected_archetype: "The Diplomat",
    expected_age_band: "gen_x",
    analysis: analysis({ median: 18, mean: 30, fast: 22, ball: 50, groupPct: 22, silent: 1, totalGroups: 12, style: styles.genX, totalSent: 6500 }),
  },
  {
    id: "steady_deliberate_boomer",
    family: "same_archetype_different_reason",
    expected_archetype: "The Steady Hand",
    expected_age_band: "boomer_plus",
    analysis: analysis({ median: 54, mean: 64, fast: 9, ball: 52, groupPct: 18, silent: 3, totalGroups: 11, style: styles.boomerPlus, totalSent: 1900 }),
  },
  {
    id: "steady_group_regular_millennial",
    family: "same_archetype_different_reason",
    expected_archetype: "The Steady Hand",
    expected_age_band: "millennial",
    analysis: analysis({ median: 14, mean: 19, fast: 30, ball: 62, groupPct: 27, silent: 0, totalGroups: 9, style: styles.millennial, totalSent: 8200 }),
  },
  {
    id: "synthetic_user_a_like",
    family: "near_collision",
    expected_archetype: "The Fast Starter",
    expected_age_band: "millennial",
    analysis: analysis({ median: 3.5, mean: 65, fast: 54, ball: 58, groupPct: 12, silent: 2, totalGroups: 16, style: styles.millennial, totalSent: 8200 }),
  },
  {
    id: "synthetic_partner_like",
    family: "near_collision",
    expected_archetype: "The Emoji Maximalist",
    expected_age_band: "gen_z",
    analysis: analysis({ median: 7, mean: 12, fast: 48, ball: 42, groupPct: 16, silent: 1, totalGroups: 12, emojiPct: 55, style: styles.genZ, totalSent: 10100 }),
  },
  {
    id: "privacy_red_team_group_name",
    family: "privacy_red_team",
    expected_archetype: "The Group Chat Ghost",
    expected_age_band: "gen_z",
    analysis: analysis({
      median: 7,
      mean: 88,
      fast: 40,
      ball: 90,
      groupPct: 1.5,
      silent: 7,
      totalGroups: 9,
      style: styles.genZ,
      totalSent: 7000,
      worstLabel: "Synthetic </script> Crew",
      worstTotal: 700,
      worstUser: 0,
    }),
  },
  {
    id: "thin_age_evidence",
    family: "age_guardrail",
    expected_archetype: "The Diplomat",
    expected_age_band: null,
    analysis: analysis({ median: 16, mean: 22, fast: 28, ball: 48, groupPct: 18, silent: 1, totalGroups: 8, style: styles.thin, totalSent: 8000 }),
  },
  {
    id: "scale_large_history",
    family: "scale",
    expected_archetype: "The High-Volume Texter",
    expected_age_band: "gen_x",
    analysis: analysis({ median: 24, mean: 39, fast: 18, ball: 43, groupPct: 24, silent: 2, totalGroups: 24, style: styles.genX, totalSent: 42000, threadCount: 42, worstTotal: 2400 }),
  },
  {
    id: "reaction_regular_millennial",
    family: "reaction_heavy",
    expected_archetype: "The Reaction Regular",
    expected_age_band: "millennial",
    analysis: analysis({ median: 12, mean: 24, fast: 26, ball: 42, groupPct: 18, silent: 1, totalGroups: 10, style: styles.millennial, totalSent: 7600, reactionRate: 58 }),
  },
  {
    id: "social_connector_genz",
    family: "contact_breadth",
    expected_archetype: "The Social Connector",
    expected_age_band: "gen_z",
    analysis: analysis({ median: 8, mean: 18, fast: 48, ball: 46, groupPct: 18, silent: 1, totalGroups: 15, style: styles.genZ, totalSent: 12000, threadCount: 84, topCounts: [900, 760, 640] }),
  },
  {
    id: "inner_circle_genx",
    family: "contact_concentration",
    expected_archetype: "The Inner-Circle Texter",
    expected_age_band: "gen_x",
    analysis: analysis({ median: 22, mean: 34, fast: 16, ball: 44, groupPct: 12, silent: 2, totalGroups: 8, style: styles.genX, totalSent: 4200, threadCount: 18, topCounts: [1600, 500, 280] }),
  },
  {
    id: "balanced_talk_listen_millennial",
    family: "talk_listen",
    expected_archetype: "The Steady Hand",
    expected_age_band: "millennial",
    analysis: analysis({ median: 18, mean: 28, fast: 20, ball: 44, groupPct: 18, silent: 1, totalGroups: 9, style: styles.millennial, totalSent: 7200, talkShare: 49.2 }),
  },
];

const bundle = {
  schema_version: "1.0",
  description: "Public-safe synthetic aggregate fixtures for Texting Wrapped personalization evals. No real message bodies, handles, or contacts.",
  generated_by: "tests/fixtures/texting/generate-wrapped-fixtures.mjs",
  fixtures,
};

const serialized = `${JSON.stringify(bundle, null, 2)}\n`;
const mode = process.argv[2] ?? "--check";

if (mode === "--write") {
  writeFileSync(outPath, serialized);
} else if (mode === "--check") {
  let current = "";
  try {
    current = readFileSync(outPath, "utf8");
  } catch {
    process.stderr.write(`missing ${outPath}; run with --write\n`);
    process.exit(1);
  }
  if (current !== serialized) {
    process.stderr.write(`${outPath} is out of date; run with --write\n`);
    process.exit(1);
  }
} else {
  process.stderr.write("usage: generate-wrapped-fixtures.mjs [--check|--write]\n");
  process.exit(2);
}
