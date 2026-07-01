import { describe, test, expect } from "bun:test";
import { appleDateToIsoUtc, isoUtcToAppleDateNs } from "./open.ts";

describe("Apple-epoch conversions", () => {
  test("appleDateToIsoUtc handles nanoseconds (High Sierra and later)", () => {
    // The ns/seconds discriminator is `n > 1e15`. Real ns values for modern
    // messages are ~8e17 (25 years past Apple epoch). Using a clearly-modern
    // value: 2020-01-01T00:00:00Z in ns form.
    const ns_2020 = isoUtcToAppleDateNs("2020-01-01T00:00:00.000Z");
    expect(appleDateToIsoUtc(ns_2020)).toBe("2020-01-01T00:00:00.000Z");
  });

  test("appleDateToIsoUtc handles legacy seconds (pre-High-Sierra rows)", () => {
    // ~6 hours past the epoch, in seconds. (Well below the 1e15 threshold.)
    expect(appleDateToIsoUtc(21_600)).toBe("2001-01-01T06:00:00.000Z");
  });

  test("appleDateToIsoUtc treats small values as seconds, not ns", () => {
    // Property of the discriminator: a value of 1e9 is legacy-format
    // (1 billion seconds past Apple epoch ≈ 2032), not 1 second in ns.
    // Bare-int values from chat.db are unambiguous in practice — the
    // magnitude tells you the unit.
    expect(appleDateToIsoUtc(1_000_000_000)).toBe("2032-09-09T01:46:40.000Z");
  });

  test("appleDateToIsoUtc returns null for null/zero/negative", () => {
    expect(appleDateToIsoUtc(null)).toBeNull();
    expect(appleDateToIsoUtc(0)).toBeNull();
    expect(appleDateToIsoUtc(-1)).toBeNull();
  });

  test("isoUtcToAppleDateNs round-trips through appleDateToIsoUtc", () => {
    const iso = "2026-05-13T12:34:56.000Z";
    const ns = isoUtcToAppleDateNs(iso);
    expect(appleDateToIsoUtc(ns)).toBe(iso);
  });

  test("isoUtcToAppleDateNs returns the correct ns offset", () => {
    // 2001-01-01T00:00:00Z + 1 second
    expect(isoUtcToAppleDateNs("2001-01-01T00:00:01.000Z")).toBe(1_000_000_000n);
  });

  test("isoUtcToAppleDateNs throws on garbage input", () => {
    expect(() => isoUtcToAppleDateNs("not a date")).toThrow();
  });
});
