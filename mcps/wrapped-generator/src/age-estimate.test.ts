import { test, expect } from "bun:test";
import { ageEstimate, NoAgeFeaturesError, type AgeRubric } from "./age-estimate.ts";

const RUBRIC: AgeRubric = {
  age_bands: {
    gen_z: { label: "Gen Z", approx_age_2025: "13-27" },
    millennial: { label: "Millennial", approx_age_2025: "28-43" },
    gen_x: { label: "Gen X", approx_age_2025: "44-59" },
    boomer_plus: { label: "Boomer+", approx_age_2025: "60+" },
  },
  scoring_logic: { weight_values: { high: 3, medium: 2, low: 1 } },
  features: [
    { id: "laugh_lol_nonironic", label: "Uses 'lol' non-ironically", weight: "medium", points: { gen_z: 0, millennial: 1, gen_x: 2, boomer_plus: 3 } },
    { id: "proper_caps", label: "Proper capitalization", weight: "medium", points: { gen_z: 0, millennial: 1, gen_x: 2, boomer_plus: 3 } },
    { id: "period_end_short", label: "Period ending a short single-sentence text", weight: "medium", points: { gen_z: 0, millennial: 1, gen_x: 2, boomer_plus: 3 } },
    { id: "all_lowercase", label: "All-lowercase typing", weight: "high", points: { gen_z: 4, millennial: 2, gen_x: 0, boomer_plus: 0 } },
    { id: "no_period", label: "No period even on multi-sentence messages", weight: "low", points: { gen_z: 2, millennial: 2, gen_x: 1, boomer_plus: 0 } },
    { id: "emoji_as_punctuation", label: "Uses emoji as sentence-final punctuation", weight: "medium", points: { gen_z: 4, millennial: 2, gen_x: 1, boomer_plus: 0 } },
    { id: "inline_emoji_heavy", label: "High inline emoji rate", weight: "medium", points: { gen_z: 3, millennial: 2, gen_x: 1, boomer_plus: 0 } },
  ],
};

test("ageEstimate: older-leaning style → Gen X with honest drivers", () => {
  const analysis = {
    latency: { median_minutes: 5 },
    emoji: { pct_messages_with_emoji: 4 },
    style: {
      dominant_laugh: "lol",
      pct_all_lowercase: 6, // → proper_caps
      pct_end_period: 35,
      aging_slang_breakdown: {},
      genz_slang_breakdown: {},
      sample_size: 1000,
      active_days: 90,
    },
  };
  const out = ageEstimate(analysis, RUBRIC, { totalSent: 8000 });
  expect(out.band).toBe("gen_x");
  expect(out.generation_band).toBe("gen_x");
  expect(out.label).toBe("Gen X");
  expect(out.drivers).toContain("Uses 'lol' non-ironically");
  expect(out.drivers).toContain("Proper capitalization");
  expect(out.drivers).toContain("Period ending a short single-sentence text");
  expect(out.sample_size).toBe(1000);
  expect(out.active_days).toBe(90);
  expect(out.evidence_count).toBeGreaterThanOrEqual(3);
  expect(out.generation_scores.boomer_plus!).toBeGreaterThan(out.generation_scores.gen_z!);
});

test("ageEstimate: ignores slang and reply latency for age", () => {
  const analysis = {
    latency: { median_minutes: 0.2 },
    style: {
      dominant_laugh: null,
      pct_all_lowercase: null,
      pct_end_period: null,
      aging_slang_breakdown: {},
      genz_slang_breakdown: { rizz: 100, "no cap": 90 },
      sample_size: 1000,
      active_days: 90,
    },
  };
  expect(() => ageEstimate(analysis, RUBRIC, {})).toThrow(NoAgeFeaturesError);
});

test("ageEstimate: throws when nothing fires", () => {
  expect(() => ageEstimate({ latency: {}, style: {} }, RUBRIC, {})).toThrow(NoAgeFeaturesError);
});

test("ageEstimate: throws when sample/evidence is too thin for a playful age card", () => {
  expect(() => ageEstimate({
    latency: {},
    style: {
      dominant_laugh: "lol",
      pct_all_lowercase: null,
      pct_end_period: null,
      aging_slang_breakdown: {},
      genz_slang_breakdown: {},
      sample_size: 20,
      active_days: 2,
    },
  }, RUBRIC, {})).toThrow(NoAgeFeaturesError);
});
