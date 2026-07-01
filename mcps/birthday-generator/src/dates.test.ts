import { describe, test, expect } from "bun:test";
import {
  parseBirthday,
  nextOccurrence,
  civilDaysBetween,
  parseTodayArg,
  isoCivilDate,
  enrichDates,
} from "./dates.ts";

// Parity with skills/birthday-reminder/tests/test_birthdays.py plus the JS-only
// rollover/DST traps the Python port doesn't have.

describe("parseBirthday", () => {
  test("MM-DD", () => expect(parseBirthday("07-12")).toEqual({ month: 7, day: 12, year: null }));
  test("YYYY-MM-DD", () => expect(parseBirthday("1990-06-04")).toEqual({ month: 6, day: 4, year: 1990 }));
  test("rejects garbage", () => expect(() => parseBirthday("not-a-date")).toThrow());
  test("rejects single field", () => expect(() => parseBirthday("0612")).toThrow());
});

describe("nextOccurrence", () => {
  test("birthday today is included (days_until 0)", () => {
    const today = parseTodayArg("2026-03-15");
    const next = nextOccurrence(today, 3, 15);
    expect(isoCivilDate(next)).toBe("2026-03-15");
    expect(civilDaysBetween(today, next)).toBe(0);
  });

  test("rolls to next year when the date has passed", () => {
    const today = parseTodayArg("2026-12-31");
    const next = nextOccurrence(today, 1, 1);
    expect(isoCivilDate(next)).toBe("2027-01-01");
    expect(civilDaysBetween(today, next)).toBe(1);
  });

  test("leap day slides to Feb 28 in a non-leap year (matches Python)", () => {
    const today = parseTodayArg("2027-02-25");
    expect(isoCivilDate(nextOccurrence(today, 2, 29))).toBe("2027-02-28");
  });

  test("leap day stays Feb 29 in a leap year", () => {
    const today = parseTodayArg("2028-02-25");
    expect(isoCivilDate(nextOccurrence(today, 2, 29))).toBe("2028-02-29");
  });

  test("impossible-but-wellformed date (06-31) throws (caller skips)", () => {
    const today = parseTodayArg("2026-01-01");
    expect(() => nextOccurrence(today, 6, 31)).toThrow();
  });
});

describe("civilDaysBetween (DST-safe)", () => {
  test("spans US spring-forward without off-by-one", () => {
    // 2026-03-08 is the US DST start (a 23-hour local day).
    const a = parseTodayArg("2026-03-07");
    const b = parseTodayArg("2026-03-09");
    expect(civilDaysBetween(a, b)).toBe(2);
  });
  test("spans US fall-back without off-by-one", () => {
    // 2026-11-01 is the US DST end (a 25-hour local day).
    const a = parseTodayArg("2026-10-31");
    const b = parseTodayArg("2026-11-02");
    expect(civilDaysBetween(a, b)).toBe(2);
  });
});

describe("enrichDates", () => {
  test("age_turning when year is known", () => {
    const d = enrichDates("1990-06-04", parseTodayArg("2026-06-01"));
    expect(d).not.toBeNull();
    expect(d!.next_occurrence).toBe("2026-06-04");
    expect(d!.age_turning).toBe(36);
    expect(d!.days_until).toBe(3);
  });

  test("age_turning is null when no year", () => {
    const d = enrichDates("07-12", parseTodayArg("2026-01-01"));
    expect(d!.age_turning).toBeNull();
  });

  test("weekday label is the C-locale English abbreviation", () => {
    // 2026-06-04 is a Thursday.
    const d = enrichDates("2026-06-04", parseTodayArg("2026-06-01"));
    expect(d!.weekday).toBe("Thu");
  });

  test("returns null for an impossible date instead of throwing", () => {
    expect(enrichDates("06-31", parseTodayArg("2026-01-01"))).toBeNull();
  });
});
