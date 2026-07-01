import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  readCache,
  readHand,
  mergeContacts,
  upsertCuration,
  importCuration,
  normName,
  BIRTHDAYS_CACHE_SCHEMA_VERSION,
  type CacheBirthday,
  type HandEntry,
} from "./store.ts";

let dir: string;
let cachePath: string;
let handPath: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "bday-store-"));
  cachePath = join(dir, "birthdays-cache.json");
  handPath = join(dir, "birthdays.json");
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

function writeCache(birthdays: CacheBirthday[], status = "granted") {
  writeFileSync(
    cachePath,
    JSON.stringify({
      version: BIRTHDAYS_CACHE_SCHEMA_VERSION,
      generated_at: "2026-06-02T00:00:00Z",
      source: "menubar-cnContactStore",
      permission_status: status,
      count: birthdays.length,
      birthdays,
    }),
  );
}

describe("readCache", () => {
  test("returns [] when missing", () => expect(readCache(cachePath)).toEqual([]));
  test("rejects a wrong schema version", () => {
    writeFileSync(cachePath, JSON.stringify({ version: 999, birthdays: [{ name: "X", birthday: "01-01" }] }));
    expect(readCache(cachePath)).toEqual([]);
  });
  test("parses granted birthdays", () => {
    writeCache([{ name: "Al", birthday: "1990-06-04", handles: ["4045550147"], best_handle: "+14045550147" }]);
    expect(readCache(cachePath)).toHaveLength(1);
  });
});

describe("mergeContacts", () => {
  test("hand entry overlays a Contacts entry matched by handle (Contacts birthday + hand metadata win)", () => {
    const cache: CacheBirthday[] = [
      { name: "Allison", birthday: "06-04", handles: ["5551234567"], best_handle: "+15551234567" },
    ];
    const hand: HandEntry[] = [
      { name: "Allison", contact_handle: "+15551234567", birthday: "1990-06-04", relationship: "partner", notes: "tiramisu" },
    ];
    const merged = mergeContacts(cache, hand);
    expect(merged).toHaveLength(1);
    expect(merged[0]!.birthday).toBe("06-04"); // Contacts wins
    expect(merged[0]!.relationship).toBe("partner");
    expect(merged[0]!.best_handle).toBe("+15551234567");
    expect(merged[0]!.source).toBe("both");
  });

  test("updated Contacts birthday wins over stale pinned hand entry", () => {
    const cache: CacheBirthday[] = [
      { name: "Jordan Sample", birthday: "09-21", handles: ["8565550104"], best_handle: "(856) 555-0104" },
    ];
    const hand: HandEntry[] = [
      { name: "Jordan Sample", contact_handle: "(856) 555-0104", birthday: "09-20", pinned: true },
    ];
    const merged = mergeContacts(cache, hand);
    expect(merged).toHaveLength(1);
    expect(merged[0]!.birthday).toBe("09-21");
    expect(merged[0]!.pinned).toBe(true);
    expect(merged[0]!.source).toBe("both");
  });

  test("matches by diacritic-normalized name when no handle match", () => {
    const cache: CacheBirthday[] = [{ name: "José Díaz", birthday: "03-15", handles: [], best_handle: null }];
    const hand: HandEntry[] = [{ name: "Jose Diaz", birthday: "1988-03-15", relationship: "friend" }];
    const merged = mergeContacts(cache, hand);
    expect(merged).toHaveLength(1); // merged, not duplicated
    expect(merged[0]!.relationship).toBe("friend");
    expect(merged[0]!.birthday).toBe("03-15");
  });

  test("hand-only person (not in Contacts) is added", () => {
    const merged = mergeContacts([], [{ name: "Uncle Bob", contact_handle: "+15550000000", birthday: "12-25" }]);
    expect(merged).toHaveLength(1);
    expect(merged[0]!.source).toBe("hand");
    expect(merged[0]!.best_handle).toBe("+15550000000");
  });

  test("ambiguous name (two distinct Contacts cards share a name) is NOT mis-merged", () => {
    // Two different "John Smith" people, each with their own handle + birthday.
    const cache: CacheBirthday[] = [
      { name: "John Smith", birthday: "01-01", handles: ["5550000001"], best_handle: "+15550000001" },
      { name: "John Smith", birthday: "02-02", handles: ["5550000002"], best_handle: "+15550000002" },
    ];
    // A hand entry naming "John Smith" with NO handle must not silently overlay
    // an arbitrary one of the two — it becomes its own row instead.
    const hand: HandEntry[] = [{ name: "John Smith", birthday: "1990-03-03", relationship: "friend" }];
    const merged = mergeContacts(cache, hand);
    // Both Contacts cards survive untouched; the ambiguous hand entry is separate.
    expect(merged).toHaveLength(3);
    const overlaid = merged.filter((m) => m.relationship === "friend");
    expect(overlaid).toHaveLength(1);
    expect(overlaid[0]!.source).toBe("hand"); // not merged onto a Contacts card
    // Neither Contacts card got the hand birthday.
    expect(merged.filter((m) => m.source === "contacts").map((m) => m.birthday).sort()).toEqual(["01-01", "02-02"]);
  });

  test("a hand entry WITH a matching handle still merges even when the name is ambiguous", () => {
    const cache: CacheBirthday[] = [
      { name: "John Smith", birthday: "01-01", handles: ["5550000001"], best_handle: "+15550000001" },
      { name: "John Smith", birthday: "02-02", handles: ["5550000002"], best_handle: "+15550000002" },
    ];
    const hand: HandEntry[] = [{ name: "John Smith", contact_handle: "+15550000002", birthday: "1990-02-02", muted: true }];
    const merged = mergeContacts(cache, hand);
    expect(merged).toHaveLength(2); // handle match disambiguates → no extra row
    const muted = merged.filter((m) => m.muted);
    expect(muted).toHaveLength(1);
    expect(muted[0]!.handles).toContain("5550000002");
  });

  test("pinned/muted flags propagate from the hand file", () => {
    const cache: CacheBirthday[] = [{ name: "Mute Me", birthday: "01-01", handles: ["5559999999"], best_handle: "+15559999999" }];
    const hand: HandEntry[] = [{ name: "Mute Me", contact_handle: "+15559999999", birthday: "01-01", muted: true }];
    const merged = mergeContacts(cache, hand);
    expect(merged[0]!.muted).toBe(true);
    expect(merged[0]!.pinned).toBe(false);
  });
});

describe("upsertCuration", () => {
  test("creates a hand entry to mute a Contacts-only person", () => {
    writeCache([{ name: "Coworker", birthday: "08-20", handles: ["5551112222"], best_handle: "+15551112222" }]);
    upsertCuration({ handle: "+15551112222", name: "Coworker", birthday: "08-20", muted: true }, handPath);
    const hand = readHand(handPath);
    expect(hand).toHaveLength(1);
    expect(hand[0]!.muted).toBe(true);
    expect(hand[0]!.contact_handle).toBe("+15551112222");
  });

  test("updates an existing entry without duplicating, preserving unknown fields", () => {
    writeFileSync(
      handPath,
      JSON.stringify([{ name: "Mom", contact_handle: "mom@example.com", birthday: "1960-02-01", notes: "call her", custom_field: 42 }]),
    );
    upsertCuration({ handle: "mom@example.com", name: "Mom", birthday: "1960-02-01", pinned: true }, handPath);
    const hand = readHand(handPath);
    expect(hand).toHaveLength(1);
    expect(hand[0]!.pinned).toBe(true);
    expect(hand[0]!.notes).toBe("call her");
    expect((hand[0] as any).custom_field).toBe(42); // unknown key preserved
  });

  test("unpin sets pinned:false and persists", () => {
    upsertCuration({ handle: "+15553334444", name: "Pal", birthday: "04-01", pinned: true }, handPath);
    upsertCuration({ handle: "+15553334444", name: "Pal", birthday: "04-01", pinned: false }, handPath);
    const hand = readHand(handPath);
    expect(hand).toHaveLength(1);
    expect(hand[0]!.pinned).toBe(false);
  });

  test("written file is valid JSON the skill can read", () => {
    upsertCuration({ handle: "+15550001111", name: "Test", birthday: "05-05", muted: true }, handPath);
    expect(existsSync(handPath)).toBe(true);
    expect(() => JSON.parse(readFileSync(handPath, "utf8"))).not.toThrow();
  });
});

describe("importCuration", () => {
  test("bulk-creates new entries in one write, all pinned by default", () => {
    const res = importCuration(
      [
        { handle: "+15550000001", name: "Ann", birthday: "1990-01-02", relationship: "friend", pinned: true },
        { handle: "samsample@example.com", name: "Sam", birthday: "07-15", pinned: true },
      ],
      handPath,
    );
    expect(res).toEqual({ created: 2, updated: 0 });
    const hand = readHand(handPath);
    expect(hand).toHaveLength(2);
    expect(hand.every((e) => e.pinned === true)).toBe(true);
    expect(hand.find((e) => e.name === "Ann")!.relationship).toBe("friend");
  });

  test("preserves existing entries + unknown keys; matches by handle to update, not duplicate", () => {
    writeFileSync(
      handPath,
      JSON.stringify([{ name: "Mom", contact_handle: "mom@example.com", birthday: "1960-02-01", notes: "call her", custom_field: 7 }]),
    );
    const res = importCuration(
      [
        { handle: "mom@example.com", name: "Mom", birthday: "1960-02-01", pinned: true }, // matches existing
        { handle: "+15551110000", name: "New Pal", birthday: "03-03", pinned: true }, // new
      ],
      handPath,
    );
    expect(res).toEqual({ created: 1, updated: 1 });
    const hand = readHand(handPath);
    expect(hand).toHaveLength(2);
    const mom = hand.find((e) => e.name === "Mom")!;
    expect(mom.pinned).toBe(true);
    expect(mom.notes).toBe("call her"); // existing curated note preserved
    expect((mom as any).custom_field).toBe(7); // unknown key preserved
  });

  test("does not overwrite an existing birthday (a re-import can't silently change a confirmed date)", () => {
    writeFileSync(handPath, JSON.stringify([{ name: "Al", contact_handle: "+15554443333", birthday: "1990-06-15" }]));
    importCuration([{ handle: "+15554443333", name: "Al", birthday: "06-16", pinned: true }], handPath);
    expect(readHand(handPath)[0]!.birthday).toBe("1990-06-15"); // unchanged
  });

  test("duplicates within one import collapse onto a single entry", () => {
    const res = importCuration(
      [
        { handle: "+15557778888", name: "Dup", birthday: "08-08", pinned: true },
        { handle: "+15557778888", name: "Dup", birthday: "08-08", relationship: "colleague", pinned: true },
      ],
      handPath,
    );
    // First creates, second matches it by handle → one entry, one created.
    expect(res).toEqual({ created: 1, updated: 1 });
    expect(readHand(handPath)).toHaveLength(1);
  });

  test("two DIFFERENT people who share a name but have different handles do NOT merge", () => {
    // The data-loss hazard of bulk-importing an affinity-sorted seed: two real
    // "John Smith"s must both survive, each with their own handle + birthday.
    const res = importCuration(
      [
        { handle: "+15550000001", name: "John Smith", birthday: "01-01", pinned: true },
        { handle: "+15550000002", name: "John Smith", birthday: "02-02", pinned: true },
      ],
      handPath,
    );
    expect(res).toEqual({ created: 2, updated: 0 });
    const hand = readHand(handPath);
    expect(hand).toHaveLength(2);
    expect(hand.map((e) => e.birthday).sort()).toEqual(["01-01", "02-02"]);
  });

  test("enriches a name-only entry with a newly-found handle (no duplicate)", () => {
    // A hand-added handle-less "Grandpa"; a later import learns his number.
    writeFileSync(handPath, JSON.stringify([{ name: "Grandpa", birthday: "12-25" }]));
    const res = importCuration([{ handle: "+15551230000", name: "Grandpa", birthday: "12-25", pinned: true }], handPath);
    expect(res).toEqual({ created: 0, updated: 1 }); // matched the name-only entry
    const hand = readHand(handPath);
    expect(hand).toHaveLength(1); // not duplicated
    expect(hand[0]!.contact_handle).toBe("+15551230000"); // handle backfilled
    expect(hand[0]!.pinned).toBe(true);
  });

  test("can import a mute (pinned:false, muted:true) — not everything is on-the-list", () => {
    importCuration([{ handle: "+15559990000", name: "Nope", birthday: "01-01", pinned: false, muted: true }], handPath);
    const hand = readHand(handPath);
    expect(hand[0]!.pinned).toBe(false);
    expect(hand[0]!.muted).toBe(true);
  });
});

describe("normName", () => {
  test("strips diacritics and collapses whitespace", () => {
    expect(normName("  José   Díaz ")).toBe("jose diaz");
  });
});
