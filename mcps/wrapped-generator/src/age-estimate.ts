// Phase A2 — playful "texting age" estimate. Port of age_estimate.py.
// PROBABILISTIC, NOT an identity claim. Reads only the aggregate style/emoji/
// latency blocks (+ optional total-sent); scores them against the rubric.

import { pyRound } from "./analyze.ts";

const MIDPOINTS: Record<string, number> = { gen_z: 20, millennial: 35, gen_x: 51, boomer_plus: 72 };
const MIN_AGE_SAMPLE_SIZE = 500;
const MIN_ACTIVE_DAYS = 30;
const MIN_AGE_EVIDENCE = 3;

export interface AgeRubric {
  age_bands: Record<string, { label: string; approx_age_2025: string }>;
  scoring_logic: { weight_values: Record<string, number> };
  features: { id: string; label: string; weight: string; points: Record<string, number> }[];
}

export interface AgeBlock {
  estimated_age: number;
  band: string;
  generation_band: string;
  generation_scores: Record<string, number>;
  label: string;
  approx_age: string;
  confidence: "high" | "medium" | "low";
  drivers: string[];
  sample_size: number | null;
  active_days: number | null;
  evidence_count: number;
  suppressed_reason?: string;
}

export class NoAgeFeaturesError extends Error {
  constructor(message: string, public suppressedReason = message) {
    super(message);
  }
}

function bandForAge(rubric: AgeRubric, age: number, fallback: string): string {
  for (const [bid, b] of Object.entries(rubric.age_bands)) {
    const rng = b.approx_age_2025;
    let lo: number, hi: number;
    if (rng.endsWith("+")) {
      lo = parseInt(rng.slice(0, -1), 10);
      hi = 200;
    } else {
      const [a, c] = rng.split("-").map((x) => parseInt(x, 10));
      lo = a!;
      hi = c!;
    }
    if (age >= lo && age <= hi) return bid;
  }
  return fallback;
}

function firedFeatures(analysis: any, totalSent: number | null | undefined): string[] {
  const style = analysis.style ?? {};
  const emoji = analysis.emoji ?? {};
  const fired: string[] = [];

  const dom = (style.dominant_laugh ?? "").toLowerCase();
  if (dom === "skull" || dom === "sob") fired.push("laugh_skull_or_sob");
  else if (dom === "joy") fired.push("laugh_joy_nonironic");
  else if (dom === "lol") fired.push("laugh_lol_nonironic");
  else if (dom === "haha" || dom === "hehe") fired.push("laugh_haha");

  const low = style.pct_all_lowercase;
  if (low != null) {
    if (low >= 40) fired.push("all_lowercase");
    else if (low <= 12) fired.push("proper_caps");
  }

  const per = style.pct_end_period;
  if (per != null) {
    if (per >= 25) fired.push("period_end_short");
    else if (per <= 12) fired.push("no_period");
  }

  if ((style.pct_ellipsis ?? 0) >= 10) fired.push("ellipsis_connector");
  if ((style.pct_repeated_exclaim ?? 0) >= 8) fired.push("repeated_exclaim");
  if ((style.pct_emoji_ending ?? 0) >= 15) fired.push("emoji_as_punctuation");

  const emojiPct = emoji.pct_messages_with_emoji;
  if (emojiPct != null) {
    if (emojiPct >= 30) fired.push("inline_emoji_heavy");
    else if (emojiPct <= 5) fired.push("inline_emoji_sparse");
  }

  const activeDays = style.active_days;
  if (totalSent && activeDays) {
    const perDay = totalSent / activeDays;
    if (perDay < 10) fired.push("low_volume");
    else if (perDay >= 45) fired.push("high_volume");
  }

  return fired;
}

export function ageEstimate(analysis: any, rubric: AgeRubric, opts: { totalSent?: number | null } = {}): AgeBlock {
  const weightValues = rubric.scoring_logic.weight_values;
  const byId = new Map(rubric.features.map((f) => [f.id, f]));
  const bands = Object.keys(rubric.age_bands); // insertion order (parity-critical for ties)
  const style = analysis.style ?? {};
  const sampleSize = style.sample_size ?? null;
  const activeDays = style.active_days ?? null;
  const language = (style.language ?? style.dominant_language ?? "en").toLowerCase();

  if (!language.startsWith("en")) {
    throw new NoAgeFeaturesError("texting age calibrated for English-language corpora", "non_english_corpus");
  }
  if (sampleSize == null || sampleSize < MIN_AGE_SAMPLE_SIZE) {
    throw new NoAgeFeaturesError("not enough outbound texts for a playful age card", "sample_size_too_small");
  }
  if (activeDays == null || activeDays < MIN_ACTIVE_DAYS) {
    throw new NoAgeFeaturesError("not enough active texting days for a playful age card", "active_days_too_small");
  }

  const fired = firedFeatures(analysis, opts.totalSent ?? null).filter((fid) => byId.has(fid));
  if (fired.length < MIN_AGE_EVIDENCE) throw new NoAgeFeaturesError("not enough observable age features", "not_enough_age_features");

  const totals: Record<string, number> = Object.fromEntries(bands.map((b) => [b, 0]));
  let sumWeights = 0;
  for (const fid of fired) {
    const feat = byId.get(fid);
    if (!feat) continue;
    const w = weightValues[feat.weight] ?? 1;
    sumWeights += w;
    for (const b of bands) totals[b]! += (feat.points[b] ?? 0) * w;
  }

  const scores: Record<string, number> = Object.fromEntries(bands.map((b) => [b, sumWeights ? totals[b]! / sumWeights : 0]));
  // sort bands by score desc, stable (ties keep band insertion order)
  const ranked = bands.map((b) => [b, scores[b]!] as [string, number]).sort((a, b) => b[1] - a[1]);
  const [topId, topS] = ranked[0]!;
  const [, secondS] = ranked[1]!;

  let scoreSum = 0;
  for (const b of bands) scoreSum += scores[b]!;
  if (scoreSum === 0) scoreSum = 1;
  let blend = 0;
  for (const b of bands) blend += scores[b]! * (MIDPOINTS[b] ?? 40);
  const estimatedAge = pyRound(blend / scoreSum, 0);

  const numBand = bandForAge(rubric, estimatedAge, topId);
  let confidence: "high" | "medium" | "low";
  if (secondS === 0 || topS >= 2 * secondS) confidence = "high";
  else if ((topS - secondS) / topS <= 0.2) confidence = "low";
  else confidence = "medium";

  const specificity = (feat: { weight: string; points: Record<string, number> }) => {
    const w = weightValues[feat.weight] ?? 1;
    const target = feat.points[numBand] ?? 0;
    let avg = 0;
    for (const b of bands) avg += feat.points[b] ?? 0;
    avg /= bands.length;
    return (target - avg) * w;
  };

  const firedFeats = fired.map((f) => byId.get(f)).filter((f): f is NonNullable<typeof f> => !!f);
  const driverLabels = firedFeats
    .filter((f) => specificity(f) > 0)
    .sort((a, b) => specificity(b) - specificity(a))
    .slice(0, 3)
    .map((feat) => feat.label);

  if (driverLabels.length < MIN_AGE_EVIDENCE) {
    throw new NoAgeFeaturesError("not enough explainable age evidence", "not_enough_age_drivers");
  }

  return {
    estimated_age: estimatedAge,
    band: numBand,
    generation_band: numBand,
    generation_scores: scores,
    label: rubric.age_bands[numBand]!.label,
    approx_age: rubric.age_bands[numBand]!.approx_age_2025,
    confidence,
    drivers: driverLabels,
    sample_size: sampleSize,
    active_days: activeDays,
    evidence_count: fired.length,
  };
}
