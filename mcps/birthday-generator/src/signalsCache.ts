// On-disk cache of the chat.db/call-db signals computed by signals.ts.
//
// Why: `computeSignals` opens chat.db, scans every 1:1 chat's outbound volume +
// recency, reads call history, and runs the wished-before scan. With the v2
// direction the volume signals are no longer a "who matters" verdict — they're a
// cheap binary STARTING POINT (the "Suggested" group) + a net-new-people signal,
// and Claude does the real prioritization over the threads. So we deliberately do
// NOT want to recompute on every new message: the cache is a stable baseline that
// refreshes only a few times a year (a long TTL) or when the user taps Refresh
// (--refresh-signals). This makes reopening the Birthday tab instant and keeps the
// list from "generating every time".
//
// Freshness (v2): TTL-based, NOT chat.db-mtime-based. The cache is valid iff
//   (a) it was computed within STARTING_POINT_TTL_DAYS, AND
//   (b) every current candidate is present under a stable fingerprint.
// A new/changed candidate (added contact, edited birthday, changed handles) misses
// and forces a full recompute; a removed candidate just leaves an unused entry,
// dropped on the next write. chat.db changing does NOT invalidate the cache.
//
// Privacy: the cache stores ONLY ContactSignals (counts / booleans / years) —
// never a message body. computeSignals already runs the body-leak guard at
// creation; writeSignalsCache adds a structural guard so a FUTURE text-bearing
// field fails loudly here too.

import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  readFileSync,
  writeFileSync,
  lstatSync,
  renameSync,
  unlinkSync,
  mkdirSync,
} from "node:fs";
import { PrivacyGuardError, type ContactSignals, type SignalCandidate } from "./signals.ts";

// Bumped 1 → 2 for the TTL-based cache file shape (computed_at_ms replaces the
// chatdb/calldb mtime + as_of keys). Old v1 caches are ignored and rebuilt.
export const SIGNALS_CACHE_SCHEMA_VERSION = 2;
// "A few times a year." The signals are a stable starting point, not live state;
// the user can always force a recompute via the Refresh button (--refresh-signals).
export const STARTING_POINT_TTL_DAYS = 90;
const DAY_MS = 86_400_000;
const HOME_DIR = ".messages-mcp";

export function defaultSignalsCachePath(): string {
  return join(homedir(), HOME_DIR, "signals-cache.json");
}

interface CacheEntry {
  id: string; // stable candidate fingerprint
  signals: ContactSignals;
}

interface CacheFile {
  version: number;
  computed_at_ms: number; // wall-clock ms when the signals were computed (TTL anchor)
  entries: CacheEntry[];
}

// Stable per-candidate identity. The run key (`c${i}`) is positional and
// unstable across runs, so the cache re-keys on birthday (month/day) + sorted
// canonical handles — the exact inputs a candidate's signals depend on.
// JSON.stringify (not join) so a handle containing the delimiter can't collide
// (["a,b","c"] vs ["a","b,c"] would otherwise share a fingerprint).
export function candidateFingerprint(c: SignalCandidate): string {
  return `${c.month}-${c.day}:${JSON.stringify([...c.handles].sort())}`;
}

export function readSignalsCache(path = defaultSignalsCachePath()): CacheFile | null {
  if (!existsSync(path)) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    // Visible, not silent (mirrors store.ts): a corrupt cache should be
    // debuggable from stderr / the daemon log, not present as "no signals".
    process.stderr.write(`  warn: signals-cache unreadable (${String(e)})\n`);
    return null;
  }
  const obj = parsed as Partial<CacheFile> | null;
  if (!obj || !Array.isArray(obj.entries)) return null;
  if (obj.version !== SIGNALS_CACHE_SCHEMA_VERSION) {
    process.stderr.write(
      `  warn: signals-cache schema version ${String(obj.version)} != expected ${SIGNALS_CACHE_SCHEMA_VERSION}; ignoring. ` +
        `It will be rebuilt on this run.\n`,
    );
    return null;
  }
  if (typeof obj.computed_at_ms !== "number") return null;
  return obj as CacheFile;
}

export interface LoadFreshOpts {
  nowMs: number;
  // Override the default TTL (mainly for tests). ms.
  ttlMs?: number;
}

// The per-candidate signals (re-keyed to the current run keys) IFF the cache is
// fresh (computed within the TTL) AND every candidate is present. Otherwise null
// → the caller must recompute and rewrite. chat.db mtime is intentionally NOT a
// freshness input (see the file header).
export function loadFreshSignals(
  candidates: SignalCandidate[],
  opts: LoadFreshOpts,
  path = defaultSignalsCachePath(),
): Map<string, ContactSignals> | null {
  const cache = readSignalsCache(path);
  if (!cache) return null;
  const ttlMs = opts.ttlMs ?? STARTING_POINT_TTL_DAYS * DAY_MS;
  const ageMs = opts.nowMs - cache.computed_at_ms;
  // Stale past the TTL, or a future-dated cache (clock moved backwards) → recompute.
  if (ageMs < 0 || ageMs > ttlMs) return null;
  const byFp = new Map(cache.entries.map((e) => [e.id, e.signals]));
  const byKey = new Map<string, ContactSignals>();
  for (const c of candidates) {
    const sig = byFp.get(candidateFingerprint(c));
    if (!sig) return null; // a candidate was added / changed → stale
    byKey.set(c.key, sig);
  }
  return byKey;
}

// Structural privacy guard for the cache layer: cached signals must be
// metadata-only. Every value (recursively) must be number | boolean | null, or
// an array of those — NO strings and NO nested objects anywhere. A string would
// be a smuggled message body; a nested object is a place one could hide. This
// is recursive (not just top-level + immediate array items) so a future nested
// field can't bypass it (review: Codex med-severity finding).
function assertMetadataOnly(value: unknown, path: string): void {
  if (typeof value === "string") {
    throw new PrivacyGuardError(`signals-cache guard: string value at ${path}; cache must be metadata-only`);
  }
  if (Array.isArray(value)) {
    value.forEach((v, i) => assertMetadataOnly(v, `${path}[${i}]`));
    return;
  }
  if (value !== null && typeof value === "object") {
    throw new PrivacyGuardError(`signals-cache guard: unexpected nested object at ${path}`);
  }
  // number | boolean | null are the only remaining types — all fine.
}

function assertNoStringSignals(entries: CacheEntry[]): void {
  for (const e of entries) {
    for (const [k, v] of Object.entries(e.signals as unknown as Record<string, unknown>)) {
      assertMetadataOnly(v, `entry.signals.${k}`);
    }
  }
}

export interface WriteCacheOpts {
  nowMs: number;
}

export function writeSignalsCache(
  candidates: SignalCandidate[],
  byKey: Map<string, ContactSignals>,
  opts: WriteCacheOpts,
  path = defaultSignalsCachePath(),
): void {
  const entries: CacheEntry[] = [];
  for (const c of candidates) {
    const sig = byKey.get(c.key);
    if (sig) entries.push({ id: candidateFingerprint(c), signals: sig });
  }
  assertNoStringSignals(entries);

  const file: CacheFile = {
    version: SIGNALS_CACHE_SCHEMA_VERSION,
    computed_at_ms: opts.nowMs,
    entries,
  };

  const dir = join(path, "..");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  if (existsSync(path) && lstatSync(path).isSymbolicLink()) {
    throw new Error(`signals-cache.json is a symlink, refusing to overwrite: ${path}`);
  }
  const tmp = `${path}.tmp-${randomUUID()}`;
  writeFileSync(tmp, JSON.stringify(file, null, 2), { mode: 0o600 });
  try {
    renameSync(tmp, path);
  } catch (err) {
    try {
      unlinkSync(tmp);
    } catch {
      /* best-effort cleanup */
    }
    throw err;
  }
}
