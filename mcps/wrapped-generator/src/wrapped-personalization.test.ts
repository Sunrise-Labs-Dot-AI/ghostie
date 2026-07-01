import { test, expect } from "bun:test";
import { buildData } from "./build-wrapped.ts";
import { ageEstimate, NoAgeFeaturesError, type AgeRubric } from "./age-estimate.ts";
import fixturesBundle from "../../../tests/fixtures/texting/wrapped-personas.json" with { type: "json" };
import ageRubric from "../../../skills/texting-analytics/data/age_rubric.json" with { type: "json" };

type Fixture = {
  id: string;
  family: string;
  expected_archetype: string;
  expected_age_band: string | null;
  analysis: any;
};

const fixtures = fixturesBundle.fixtures as Fixture[];
const rubric = ageRubric as AgeRubric;

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value));
}

function collectStrings(value: unknown, out: string[] = []): string[] {
  if (typeof value === "string") out.push(value);
  else if (Array.isArray(value)) value.forEach((v) => collectStrings(v, out));
  else if (value && typeof value === "object") Object.values(value).forEach((v) => collectStrings(v, out));
  return out;
}

function withAge(fixture: Fixture): any {
  const analysis = clone(fixture.analysis);
  analysis.age = ageEstimate(analysis, rubric, { totalSent: analysis.fixture_total_sent });
  return analysis;
}

test("Wrapped persona fixtures are public-safe aggregate data", () => {
  const strings = collectStrings(fixturesBundle);
  const joined = strings.join("\n");
  expect(joined).not.toContain("James");
  expect(joined).not.toContain("james");
  expect(joined).not.toMatch(/\b\+?1?\d{10,}\b/);
  expect(joined).not.toMatch(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
  expect(fixtures.length).toBeGreaterThanOrEqual(15);
});

test("Wrapped persona fixtures cover supported and playful archetype spread", () => {
  const expected = new Set([
    "The Group Chat Ghost",
    "The Last Word",
    "Left-on-Read Royalty",
    "The Group MVP",
    "The Emoji Maximalist",
    "The Fast Starter",
    "The Lightning Round",
    "The Slow Burn",
    "The Diplomat",
    "The Steady Hand",
    "The High-Volume Texter",
    "The Reaction Regular",
    "The Social Connector",
    "The Inner-Circle Texter",
  ]);

  const observed = new Set<string>();
  for (const fixture of fixtures) {
    const data = buildData(fixture.analysis, { totalSent: fixture.analysis.fixture_total_sent });
    expect(data.archetype.name).toBe(fixture.expected_archetype);
    expect(data.archetype.drivers.length).toBeGreaterThanOrEqual(2);
    expect(new Set(data.archetype.drivers).size).toBe(data.archetype.drivers.length);
    expect(data.archetype.why).toEqual(expect.any(String));
    expect(data.archetype.confidence).toMatch(/^(high|medium|low)$/);
    expect(data.archetype.support_level).toMatch(/^(supported|cautious|playful)$/);
    observed.add(data.archetype.name);
  }

  expect(observed).toEqual(expected);
});

test("Wrapped age fixtures span bands and fail closed when evidence is thin", () => {
  const observedBands = new Set<string>();

  for (const fixture of fixtures) {
    const analysis = clone(fixture.analysis);
    if (fixture.expected_age_band == null) {
      expect(() => ageEstimate(analysis, rubric, { totalSent: analysis.fixture_total_sent }))
        .toThrow(NoAgeFeaturesError);
      analysis.age = {
        estimated_age: 35,
        band: "millennial",
        label: "Millennial",
        approx_age: "28-43",
        confidence: "low",
        drivers: [],
        sample_size: 22,
        active_days: 2,
        evidence_count: 1,
      };
      expect(buildData(analysis, { totalSent: analysis.fixture_total_sent }).cards).not.toContain("age");
      continue;
    }

    const age = ageEstimate(analysis, rubric, { totalSent: analysis.fixture_total_sent });
    expect(age.band).toBe(fixture.expected_age_band);
    expect(age.sample_size ?? 0).toBeGreaterThanOrEqual(500);
    expect(age.active_days ?? 0).toBeGreaterThanOrEqual(30);
    expect(age.evidence_count).toBeGreaterThanOrEqual(3);
    expect(age.drivers.length).toBeGreaterThanOrEqual(3);
    expect(age.generation_band).toBe(age.band);
    expect(Object.keys(age.generation_scores)).toEqual(["gen_z", "millennial", "gen_x", "boomer_plus"]);
    observedBands.add(age.band);
  }

  expect(observedBands).toEqual(new Set(["gen_z", "millennial", "gen_x", "boomer_plus"]));
});

test("age fixtures do not depend on slang or reply latency", () => {
  for (const fixture of fixtures.filter((f) => f.expected_age_band != null)) {
    const analysis = clone(fixture.analysis);
    analysis.latency = { ...analysis.latency, median_minutes: 0.1 };
    analysis.style = {
      ...analysis.style,
      genz_slang_breakdown: { rizz: 100, "no cap": 100 },
      aging_slang_breakdown: { tbh: 100, ngl: 100 },
    };
    const withNoise = ageEstimate(analysis, rubric, { totalSent: analysis.fixture_total_sent });

    const clean = ageEstimate(fixture.analysis, rubric, { totalSent: fixture.analysis.fixture_total_sent });
    expect(withNoise.band).toBe(clean.band);
    expect(withNoise.drivers.join(" ")).not.toMatch(/\b(?:rizz|no cap|tbh|ngl|reply)\b/i);
  }
});

test("same archetype fixtures keep different personalized reasons", () => {
  const steady = fixtures.filter((f) => f.family === "same_archetype_different_reason");
  expect(steady).toHaveLength(2);

  const [a, b] = steady.map((f) => buildData(withAge(f), { totalSent: f.analysis.fixture_total_sent }));
  expect(a.archetype.name).toBe("The Steady Hand");
  expect(b.archetype.name).toBe("The Steady Hand");
  expect(a.archetype.why).not.toBe(b.archetype.why);
  expect(a.archetype.drivers).not.toEqual(b.archetype.drivers);
  expect(a.age.band).not.toBe(b.age.band);
});

test("near-collision personas do not collapse to identical age or archetype explanations", () => {
  const near = fixtures.filter((f) => f.family === "near_collision");
  expect(near).toHaveLength(2);

  const [a, b] = near.map((f) => buildData(withAge(f), { totalSent: f.analysis.fixture_total_sent }));
  expect(a.archetype.name).not.toBe(b.archetype.name);
  expect(a.archetype.why).not.toBe(b.archetype.why);
  expect(a.archetype.drivers).not.toEqual(b.archetype.drivers);
  expect(a.age.estimated_age).not.toBe(b.age.estimated_age);
  expect(a.age.drivers).not.toEqual(b.age.drivers);
});
