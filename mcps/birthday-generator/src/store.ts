// Birthday data store: the Contacts-derived sidecar (read-only, written by the
// menu-bar app's ContactsExporter) merged with the hand-maintained birthdays.json
// (shared with the birthday-reminder Claude skill — the ONLY place relationship/
// notes and the user's pin/mute curation live). This binary owns all reads/writes
// of birthdays.json so the file format has a single tested implementation.

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
import { canonHandle } from "../../imessage-drafts/src/chatdb/canon.ts";

// Must match `birthdaysCacheSchemaVersion` in menubar ContactsExporter.swift.
export const BIRTHDAYS_CACHE_SCHEMA_VERSION = 1;

export interface CacheBirthday {
  name: string;
  birthday: string;
  handles: string[]; // canonical, for the signals join
  best_handle: string | null; // dispatchable (E.164 / email), for staging
}

// One entry of the hand-maintained birthdays.json. relationship/notes/pinned/
// muted are optional; unknown keys are preserved on rewrite (the skill may add
// fields). pinned/muted are additive — birthdays.py ignores them.
export interface HandEntry {
  name?: string;
  contact_handle?: string | null;
  birthday?: string;
  relationship?: string | null;
  notes?: string | null;
  last_year_skipped?: boolean;
  pinned?: boolean;
  muted?: boolean;
  [k: string]: unknown;
}

export interface MergedContact {
  name: string;
  birthday: string;
  handles: string[]; // canonical
  best_handle: string | null;
  relationship: string | null;
  notes: string | null;
  pinned: boolean;
  muted: boolean;
  source: "contacts" | "hand" | "both";
}

const HOME_DIR = ".messages-mcp";

export function defaultCachePath(): string {
  return join(homedir(), HOME_DIR, "birthdays-cache.json");
}
export function defaultHandPath(): string {
  return join(homedir(), HOME_DIR, "birthdays.json");
}
export function defaultContactsCachePath(): string {
  return join(homedir(), HOME_DIR, "contacts-cache.json");
}

// The full canon-handle → name map written by ContactsExporter
// (contacts-cache.json). Used by the gaps scan to name high-affinity contacts
// who have no birthday. Returns an empty map if missing/denied/unreadable.
export function readContactsNameMap(path = defaultContactsCachePath()): Map<string, string> {
  const out = new Map<string, string>();
  if (!existsSync(path)) return out;
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return out;
  }
  const obj = parsed as { handles?: unknown };
  if (!obj || typeof obj.handles !== "object" || obj.handles == null) return out;
  for (const [canon, name] of Object.entries(obj.handles as Record<string, unknown>)) {
    if (typeof name === "string" && name) out.set(canon, name);
  }
  return out;
}

// Diacritic- and case-insensitive name key (ROOT_CAUSE-contact-filter.md #2:
// String.toLowerCase() does not strip accents, so "José"/"Jose" must be NFD-
// normalized before comparison).
export function normName(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "") // strip combining diacritical marks
    .toLowerCase()
    .trim()
    .replace(/\s+/g, " ");
}

export function readCache(path = defaultCachePath()): CacheBirthday[] {
  if (!existsSync(path)) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    // Visible, not silent: a corrupt cache should be debuggable from the
    // captured stderr / daemon log rather than presenting as "no birthdays".
    process.stderr.write(`  warn: birthdays-cache unreadable (${String(e)})\n`);
    return [];
  }
  const obj = parsed as { version?: unknown; birthdays?: unknown };
  if (!obj || !Array.isArray(obj.birthdays)) return [];
  if (obj.version !== BIRTHDAYS_CACHE_SCHEMA_VERSION) {
    process.stderr.write(
      `  warn: birthdays-cache schema version ${String(obj.version)} != expected ${BIRTHDAYS_CACHE_SCHEMA_VERSION}; ignoring. ` +
        `Rebuild the menu-bar app and the binary together.\n`,
    );
    return [];
  }
  const out: CacheBirthday[] = [];
  for (const raw of obj.birthdays) {
    const b = raw as Record<string, unknown>;
    if (!b || typeof b.name !== "string" || typeof b.birthday !== "string") continue;
    const handles = Array.isArray(b.handles) ? b.handles.filter((h): h is string => typeof h === "string") : [];
    out.push({
      name: b.name,
      birthday: b.birthday,
      handles,
      best_handle: typeof b.best_handle === "string" ? b.best_handle : null,
    });
  }
  return out;
}

export function readHand(path = defaultHandPath()): HandEntry[] {
  if (!existsSync(path)) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    process.stderr.write(`  warn: birthdays.json unreadable (${String(e)})\n`);
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  return parsed.filter((e) => e && typeof e === "object") as HandEntry[];
}

function dedupe(arr: string[]): string[] {
  return [...new Set(arr.filter((s) => s.length > 0))];
}

// Merge Contacts birthdays ∪ hand birthdays. Contacts are the birthday source
// of truth when a matching Contacts card has a birthday; hand entries supply
// relationship/notes/pinned/muted and provide birthdays only for hand-only
// people. Match a hand entry to a Contacts entry by canonical handle first,
// then by normalized name.
export function mergeContacts(cache: CacheBirthday[], hand: HandEntry[]): MergedContact[] {
  const merged: MergedContact[] = [];
  const byCanon = new Map<string, MergedContact>();
  const byName = new Map<string, MergedContact>();

  // Names that appear on >1 distinct Contacts card are AMBIGUOUS — a hand entry
  // naming "John Smith" must not silently overlay an arbitrary one of two
  // different people (review S1). We index only unambiguous names for the
  // name-fallback match; ambiguous ones force a handle match or a new row.
  const nameCounts = new Map<string, number>();
  for (const cb of cache) {
    const nk = normName(cb.name);
    if (nk) nameCounts.set(nk, (nameCounts.get(nk) ?? 0) + 1);
  }
  const ambiguousNames = new Set([...nameCounts].filter(([, n]) => n > 1).map(([k]) => k));

  const index = (c: MergedContact) => {
    for (const h of c.handles) if (!byCanon.has(h)) byCanon.set(h, c);
    const nk = normName(c.name);
    if (nk && !ambiguousNames.has(nk) && !byName.has(nk)) byName.set(nk, c);
  };

  for (const cb of cache) {
    const handles = dedupe(cb.handles.map(canonHandle));
    const c: MergedContact = {
      name: cb.name,
      birthday: cb.birthday,
      handles,
      best_handle: cb.best_handle,
      relationship: null,
      notes: null,
      pinned: false,
      muted: false,
      source: "contacts",
    };
    merged.push(c);
    index(c);
  }

  for (const he of hand) {
    if (!he.birthday || typeof he.birthday !== "string") continue;
    const handle = typeof he.contact_handle === "string" ? he.contact_handle : null;
    const canon = handle ? canonHandle(handle) : null;
    const name = typeof he.name === "string" ? he.name : null;

    let target: MergedContact | undefined;
    if (canon) target = byCanon.get(canon);
    if (!target && name) target = byName.get(normName(name));

    if (target) {
      if (name) target.name = name;
      if (canon) target.handles = dedupe([...target.handles, canon]);
      if (!target.best_handle && handle) target.best_handle = handle;
      target.relationship = typeof he.relationship === "string" ? he.relationship : target.relationship;
      target.notes = typeof he.notes === "string" ? he.notes : target.notes;
      target.pinned = he.pinned === true;
      target.muted = he.muted === true;
      target.source = "both";
      // Re-index in case name/handles changed.
      index(target);
    } else {
      const c: MergedContact = {
        name: name ?? handle ?? "(unknown)",
        birthday: he.birthday,
        handles: canon ? [canon] : [],
        best_handle: handle,
        relationship: typeof he.relationship === "string" ? he.relationship : null,
        notes: typeof he.notes === "string" ? he.notes : null,
        pinned: he.pinned === true,
        muted: he.muted === true,
        source: "hand",
      };
      merged.push(c);
      index(c);
    }
  }

  return merged;
}

export interface CurationUpdate {
  handle: string | null; // dispatchable handle (used as contact_handle on new entries)
  name: string;
  birthday: string;
  relationship?: string | null;
  notes?: string | null;
  pinned?: boolean;
  muted?: boolean;
}

// Apply one curation update to an in-memory hand array: find the person (by
// canonical handle, then by normalized name) and either create a new entry or
// backfill+flag the existing one. Mutates `hand` in place; does NOT write — the
// callers own the write so a bulk import is a single atomic rewrite, not N.
// Returns whether it created a new entry or matched an existing one.
//
// relationship/notes are set only on CREATE (never overwrite the user's curated
// values), matching the original single-upsert semantics. An existing birthday
// is likewise preserved, not clobbered, so a re-import can't silently change a
// date the user already confirmed.
function applyCuration(hand: HandEntry[], update: CurationUpdate): "created" | "updated" {
  const canon = update.handle ? canonHandle(update.handle) : null;
  const nk = normName(update.name);

  // 1) Strongest match: same canonical handle. 2) Name fallback, but it must NOT
  // merge two DIFFERENT people who share a display name: if this update has a
  // handle and a name-matched entry has a *different* non-null handle, they're
  // distinct people (review S1 / seed.ts "do NOT de-dupe by name") — skip it so
  // a new entry is created. A name-only entry (no handle yet) still matches, so
  // a later import can enrich it with the handle we just learned. This matters
  // most for bulk --import of an affinity-sorted seed, where same-name
  // collisions are routine and a silent merge would drop a real person.
  let entry = hand.find((e) => {
    const ec = typeof e.contact_handle === "string" ? canonHandle(e.contact_handle) : null;
    return canon != null && ec != null && ec === canon;
  });
  if (!entry) {
    entry = hand.find((e) => {
      if (typeof e.name !== "string" || normName(e.name) !== nk) return false;
      const ec = typeof e.contact_handle === "string" ? canonHandle(e.contact_handle) : null;
      return !(canon != null && ec != null && ec !== canon); // different handle ⇒ different person
    });
  }

  let result: "created" | "updated";
  if (!entry) {
    entry = {
      name: update.name,
      contact_handle: update.handle,
      birthday: update.birthday,
    };
    if (update.relationship != null) entry.relationship = update.relationship;
    if (update.notes != null) entry.notes = update.notes;
    hand.push(entry);
    result = "created";
  } else {
    // Backfill identity fields if the existing entry was sparse.
    if (!entry.name) entry.name = update.name;
    if (!entry.birthday) entry.birthday = update.birthday;
    if (!entry.contact_handle && update.handle) entry.contact_handle = update.handle;
    result = "updated";
  }
  if (update.pinned !== undefined) entry.pinned = update.pinned;
  if (update.muted !== undefined) entry.muted = update.muted;
  return result;
}

// Apply a pin/mute change to birthdays.json, creating an entry if the person
// isn't there yet (e.g. a Contacts-only person being muted). Preserves existing
// entries and unknown fields; writes atomically (temp + rename, 0600).
export function upsertCuration(update: CurationUpdate, path = defaultHandPath()): HandEntry[] {
  const hand = readHand(path);
  applyCuration(hand, update);
  writeHandAtomic(path, hand);
  return hand;
}

export interface ImportResult {
  created: number;
  updated: number;
}

// Bulk-apply a list of curation updates (the LLM-built finalized birthday list,
// or the app's paste-import) into birthdays.json in a SINGLE atomic rewrite.
// Each update find-or-creates by handle/name (later updates can match entries an
// earlier update in the same batch just created, so duplicates within the input
// collapse onto one entry). Preserves existing entries + unknown keys. Callers
// are responsible for validating each update's birthday before passing it in.
export function importCuration(updates: CurationUpdate[], path = defaultHandPath()): ImportResult {
  const hand = readHand(path);
  let created = 0;
  let updated = 0;
  for (const u of updates) {
    if (applyCuration(hand, u) === "created") created++;
    else updated++;
  }
  writeHandAtomic(path, hand);
  return { created, updated };
}

function writeHandAtomic(path: string, hand: HandEntry[]): void {
  const dir = join(path, "..");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  if (existsSync(path) && lstatSync(path).isSymbolicLink()) {
    throw new Error(`birthdays.json is a symlink, refusing to overwrite: ${path}`);
  }
  const tmp = `${path}.tmp-${randomUUID()}`;
  writeFileSync(tmp, JSON.stringify(hand, null, 2), { mode: 0o600 });
  try {
    renameSync(tmp, path);
  } catch (err) {
    try { unlinkSync(tmp); } catch { /* best-effort */ }
    throw err;
  }
}
