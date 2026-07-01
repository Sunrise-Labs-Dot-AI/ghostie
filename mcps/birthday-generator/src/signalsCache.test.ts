import { test, expect, describe, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  candidateFingerprint,
  readSignalsCache,
  writeSignalsCache,
  loadFreshSignals,
  SIGNALS_CACHE_SCHEMA_VERSION,
  STARTING_POINT_TTL_DAYS,
} from "./signalsCache.ts";
import { PrivacyGuardError, type ContactSignals, type SignalCandidate } from "./signals.ts";

const DAY_MS = 86_400_000;
// Fixed wall clock for deterministic TTL math.
const NOW = 1_900_000_000_000;
const WRITE = { nowMs: NOW };

const tmps: string[] = [];
function tmp(): string {
  const d = mkdtempSync(join(tmpdir(), "sigcache-"));
  tmps.push(d);
  return d;
}
afterEach(() => {
  while (tmps.length) {
    try {
      rmSync(tmps.pop()!, { recursive: true, force: true });
    } catch {
      /* best-effort */
    }
  }
});

function sig(over: Partial<ContactSignals> = {}): ContactSignals {
  return {
    out_count: 0,
    text_rank: null,
    call_count: 0,
    call_rank: null,
    last_texted_days: null,
    last_call_days: null,
    wished_before: false,
    wished_years: [],
    ...over,
  };
}
function cand(key: string, handles: string[], month: number, day: number): SignalCandidate {
  return { key, handles, month, day };
}

describe("candidateFingerprint", () => {
  test("is independent of run key and handle order", () => {
    const a = cand("c0", ["b@x.com", "4045551212"], 3, 14);
    const b = cand("c99", ["4045551212", "b@x.com"], 3, 14);
    expect(candidateFingerprint(a)).toBe(candidateFingerprint(b));
  });
  test("differs when birthday or handles differ", () => {
    const base = cand("c0", ["4045551212"], 3, 14);
    expect(candidateFingerprint(base)).not.toBe(candidateFingerprint(cand("c0", ["4045551212"], 3, 15)));
    expect(candidateFingerprint(base)).not.toBe(candidateFingerprint(cand("c0", ["4045559999"], 3, 14)));
  });
});

describe("write → loadFreshSignals round trip", () => {
  test("hit re-keys cached signals onto the current run keys", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    const cands = [cand("c0", ["4045551212"], 1, 1), cand("c1", ["b@x.com"], 2, 2)];
    const byKey = new Map<string, ContactSignals>([
      ["c0", sig({ out_count: 42, text_rank: 3 })],
      ["c1", sig({ wished_before: true, wished_years: [2024] })],
    ]);
    writeSignalsCache(cands, byKey, WRITE, path);

    // Next run assigns DIFFERENT positional keys to the same people.
    const next = [cand("c0", ["b@x.com"], 2, 2), cand("c1", ["4045551212"], 1, 1)];
    const loaded = loadFreshSignals(next, { nowMs: NOW }, path);
    expect(loaded).not.toBeNull();
    expect(loaded!.get("c0")!.wished_before).toBe(true); // b@x.com person, now key c0
    expect(loaded!.get("c1")!.out_count).toBe(42); // phone person, now key c1
  });

  test("fresh within the TTL even when chat.db changed (mtime no longer matters)", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    const cands = [cand("c0", ["4045551212"], 1, 1)];
    writeSignalsCache(cands, new Map([["c0", sig({ out_count: 9 })]]), WRITE, path);
    // 89 days later (chat.db has surely changed many times) → still a hit.
    const loaded = loadFreshSignals(cands, { nowMs: NOW + (STARTING_POINT_TTL_DAYS - 1) * DAY_MS }, path);
    expect(loaded).not.toBeNull();
    expect(loaded!.get("c0")!.out_count).toBe(9);
  });

  test("miss when older than the TTL (refreshes a few times a year)", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    const cands = [cand("c0", ["4045551212"], 1, 1)];
    writeSignalsCache(cands, new Map([["c0", sig()]]), WRITE, path);
    expect(loadFreshSignals(cands, { nowMs: NOW + (STARTING_POINT_TTL_DAYS + 1) * DAY_MS }, path)).toBeNull();
  });

  test("miss when the cache is future-dated (clock moved backwards)", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    const cands = [cand("c0", ["4045551212"], 1, 1)];
    writeSignalsCache(cands, new Map([["c0", sig()]]), WRITE, path);
    expect(loadFreshSignals(cands, { nowMs: NOW - DAY_MS }, path)).toBeNull();
  });

  test("ttlMs override governs freshness", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    const cands = [cand("c0", ["4045551212"], 1, 1)];
    writeSignalsCache(cands, new Map([["c0", sig()]]), WRITE, path);
    expect(loadFreshSignals(cands, { nowMs: NOW + 3, ttlMs: 5 }, path)).not.toBeNull();
    expect(loadFreshSignals(cands, { nowMs: NOW + 10, ttlMs: 5 }, path)).toBeNull();
  });

  test("miss when a candidate is added (fingerprint absent)", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    writeSignalsCache([cand("c0", ["4045551212"], 1, 1)], new Map([["c0", sig()]]), WRITE, path);
    const withNew = [cand("c0", ["4045551212"], 1, 1), cand("c1", ["new@x.com"], 5, 5)];
    expect(loadFreshSignals(withNew, { nowMs: NOW }, path)).toBeNull();
  });

  test("hit when a candidate is removed (extra cached entry ignored)", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    const cands = [cand("c0", ["4045551212"], 1, 1), cand("c1", ["b@x.com"], 2, 2)];
    writeSignalsCache(cands, new Map([["c0", sig({ out_count: 7 })], ["c1", sig()]]), WRITE, path);
    const fewer = [cand("c0", ["4045551212"], 1, 1)];
    const loaded = loadFreshSignals(fewer, { nowMs: NOW }, path);
    expect(loaded).not.toBeNull();
    expect(loaded!.get("c0")!.out_count).toBe(7);
    expect(loaded!.size).toBe(1);
  });

  test("miss when cache file is absent", () => {
    const dir = tmp();
    expect(loadFreshSignals([cand("c0", ["x"], 1, 1)], { nowMs: NOW }, join(dir, "nope.json"))).toBeNull();
  });
});

describe("readSignalsCache hardening", () => {
  test("corrupt JSON returns null, does not throw", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    writeFileSync(path, "{ not valid json");
    expect(readSignalsCache(path)).toBeNull();
  });

  test("schema-version mismatch returns null", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    writeFileSync(
      path,
      JSON.stringify({ version: SIGNALS_CACHE_SCHEMA_VERSION + 1, computed_at_ms: NOW, entries: [] }),
    );
    expect(readSignalsCache(path)).toBeNull();
  });

  test("missing computed_at_ms returns null (can't TTL-check)", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    writeFileSync(path, JSON.stringify({ version: SIGNALS_CACHE_SCHEMA_VERSION, entries: [] }));
    expect(readSignalsCache(path)).toBeNull();
  });
});

describe("writeSignalsCache guards", () => {
  test("refuses to overwrite a symlink", () => {
    const dir = tmp();
    const real = join(dir, "real.json");
    const link = join(dir, "signals-cache.json");
    writeFileSync(real, "{}");
    symlinkSync(real, link);
    expect(() => writeSignalsCache([cand("c0", ["x"], 1, 1)], new Map([["c0", sig()]]), WRITE, link)).toThrow(/symlink/);
  });

  test("privacy guard trips when a signals field holds a string", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    // A future field that smuggles a message body into ContactSignals.
    const leaky = { ...sig(), notes: "happy birthday!" } as unknown as ContactSignals;
    expect(() => writeSignalsCache([cand("c0", ["x"], 1, 1)], new Map([["c0", leaky]]), WRITE, path)).toThrow(
      PrivacyGuardError,
    );
  });

  test("privacy guard trips on a string inside an array field", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    const leaky = sig({ wished_years: ["happy bday" as unknown as number] });
    expect(() => writeSignalsCache([cand("c0", ["x"], 1, 1)], new Map([["c0", leaky]]), WRITE, path)).toThrow(
      PrivacyGuardError,
    );
  });

  test("privacy guard trips on a nested object field (recursive)", () => {
    const dir = tmp();
    const path = join(dir, "signals-cache.json");
    // A future field that nests text inside an object would bypass a shallow guard.
    const leaky = { ...sig(), meta: { preview: "happy birthday!" } } as unknown as ContactSignals;
    expect(() => writeSignalsCache([cand("c0", ["x"], 1, 1)], new Map([["c0", leaky]]), WRITE, path)).toThrow(
      PrivacyGuardError,
    );
  });
});
