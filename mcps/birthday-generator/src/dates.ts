// Birthday date math — parity port of skills/birthday-reminder/scripts/birthdays.py.
//
// Two traps this guards against vs. a naive JS port:
//   - `new Date(2027, 1, 29)` silently ROLLS OVER to Mar 1; Python's date()
//     raises. We validate by round-tripping the components and apply the
//     Feb-29 → Feb-28 fallback explicitly (matches Python `safe_date`).
//   - day-count must be in LOCAL CIVIL days (midnight-to-midnight), not
//     86_400_000-ms arithmetic, or DST transitions shift it by ±1. We diff
//     UTC-normalized civil day numbers to stay exact (matches Python `.days`).

export const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

export interface ParsedBirthday {
  month: number;
  day: number;
  year: number | null;
}

function intStrict(s: string): number {
  const t = s.trim();
  if (!/^\d+$/.test(t)) throw new Error(`not an integer: ${JSON.stringify(s)}`);
  return parseInt(t, 10);
}

// "MM-DD" or "YYYY-MM-DD" → {month, day, year|null}. Mirrors parse_birthday.
export function parseBirthday(s: string): ParsedBirthday {
  const parts = s.split("-");
  if (parts.length === 2) {
    return { month: intStrict(parts[0]!), day: intStrict(parts[1]!), year: null };
  }
  if (parts.length === 3) {
    return { month: intStrict(parts[1]!), day: intStrict(parts[2]!), year: intStrict(parts[0]!) };
  }
  throw new Error(`unrecognized birthday format: ${JSON.stringify(s)}`);
}

// Local-midnight Date for (year, m, d) iff it's a real calendar date, else null.
// Catches JS's silent overflow rollover (June 31 → July 1, Feb 29 in a
// non-leap year → Mar 1) by verifying the constructed Date round-trips.
function makeCivilDate(year: number, m: number, d: number): Date | null {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  const dt = new Date(year, m - 1, d);
  if (dt.getFullYear() !== year || dt.getMonth() !== m - 1 || dt.getDate() !== d) return null;
  return dt;
}

// date(year, m, d), with Feb-29 sliding to Feb-28 in non-leap years. Mirrors
// the Python `safe_date` nested helper — any other impossible date throws.
function safeDate(year: number, m: number, d: number): Date {
  const dt = makeCivilDate(year, m, d);
  if (dt) return dt;
  if (m === 2 && d === 29) {
    const feb28 = makeCivilDate(year, 2, 28);
    if (feb28) return feb28;
  }
  throw new RangeError(`invalid date: ${year}-${m}-${d}`);
}

// Next date >= today with the given month/day (today itself counts). Mirrors
// next_occurrence.
export function nextOccurrence(today: Date, month: number, day: number): Date {
  let candidate = safeDate(today.getFullYear(), month, day);
  if (civilDaysBetween(today, candidate) < 0) {
    candidate = safeDate(today.getFullYear() + 1, month, day);
  }
  return candidate;
}

// Civil-day difference b - a (DST-safe). Both args are treated by their local
// (year, month, day) only.
export function civilDaysBetween(a: Date, b: Date): number {
  const au = Date.UTC(a.getFullYear(), a.getMonth(), a.getDate());
  const bu = Date.UTC(b.getFullYear(), b.getMonth(), b.getDate());
  return Math.round((bu - au) / 86_400_000);
}

// Local-midnight Date for "today" (or an injected clock).
export function civilToday(now: Date = new Date()): Date {
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

// Parse a --today override (YYYY-MM-DD) into a local-midnight Date.
export function parseTodayArg(s: string): Date {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s.trim());
  if (!m) throw new Error(`--today must be YYYY-MM-DD`);
  const dt = makeCivilDate(intStrict(m[1]!), intStrict(m[2]!), intStrict(m[3]!));
  if (!dt) throw new Error(`--today is not a real date: ${s}`);
  return dt;
}

// "YYYY-MM-DD" for a local-midnight Date (mirrors date.isoformat()).
export function isoCivilDate(dt: Date): string {
  const y = String(dt.getFullYear()).padStart(4, "0");
  const m = String(dt.getMonth() + 1).padStart(2, "0");
  const d = String(dt.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

export interface BirthdayInput {
  name: string;
  birthday: string;
}

export interface UpcomingDates {
  next_occurrence: string;
  days_until: number;
  weekday: string;
  age_turning: number | null;
  // The parsed month/day, surfaced so callers (index.ts) reuse this single
  // parse for the signals candidate instead of calling parseBirthday again
  // (which would be a second un-guarded throw site — see review S3).
  month: number;
  day: number;
}

// Compute the next-occurrence enrichment for a single entry, or null if its
// birthday is malformed/impossible (caller skips with a warning, matching the
// Python loop's per-entry skip).
export function enrichDates(birthday: string, today: Date): UpcomingDates | null {
  let parsed: ParsedBirthday;
  let next: Date;
  try {
    parsed = parseBirthday(birthday);
    next = nextOccurrence(today, parsed.month, parsed.day);
  } catch {
    return null;
  }
  return {
    next_occurrence: isoCivilDate(next),
    days_until: civilDaysBetween(today, next),
    weekday: WEEKDAYS[next.getDay()]!,
    age_turning: parsed.year != null ? next.getFullYear() - parsed.year : null,
    month: parsed.month,
    day: parsed.day,
  };
}
