import { describe, test, expect } from "bun:test";
import { suggest, suggestedMessage, firstName } from "./suggest.ts";

const NONE = { relationship: null, pinned: false, muted: false, textsALot: false, callsALot: false, wishedBefore: false };

describe("suggest", () => {
  test("suggested when texted a lot", () => {
    const s = suggest({ ...NONE, textsALot: true });
    expect(s.suggested).toBe(true);
    expect(s.reasons).toContain("You text them a lot");
  });
  test("suggested when called a lot (the call-only contact, e.g. a parent)", () => {
    const s = suggest({ ...NONE, callsALot: true });
    expect(s.suggested).toBe(true);
    expect(s.reasons).toContain("You call them a lot");
  });
  test("suggested when wished before", () => {
    const s = suggest({ ...NONE, wishedBefore: true });
    expect(s.suggested).toBe(true);
    expect(s.reasons).toContain("You've wished them before");
  });
  test("pinned always suggested with reason", () => {
    const s = suggest({ ...NONE, pinned: true });
    expect(s.suggested).toBe(true);
    expect(s.reasons).toContain("On your list");
  });
  test("muted is never suggested even with strong signals", () => {
    const s = suggest({ ...NONE, pinned: true, muted: true, textsALot: true, callsALot: true, wishedBefore: true });
    expect(s.suggested).toBe(false);
  });
  test("no signals → not suggested", () => {
    const s = suggest(NONE);
    expect(s.suggested).toBe(false);
    expect(s.reasons).toEqual([]);
  });
});

describe("firstName", () => {
  test("takes the first token", () => expect(firstName("Allison Wonderland")).toBe("Allison"));
  test("falls back to the whole string", () => expect(firstName("Mom")).toBe("Mom"));
});

describe("suggestedMessage", () => {
  test("generic default", () => expect(suggestedMessage("Sam Lee", null)).toBe("Happy birthday, Sam! Hope you have a great one."));
  test("tiers on known relationship", () => {
    expect(suggestedMessage("Mom", "family")).toContain("wonderful day");
    expect(suggestedMessage("Bff", "friend")).toContain("🎉");
  });
});
