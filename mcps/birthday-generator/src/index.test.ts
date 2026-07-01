import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Exercises the CLI entry — the integration seam the Swift controller depends
// on (the --list JSON field names are the cross-language contract). Runs the
// real source via `bun run`. We deliberately point --db at a nonexistent path
// so signals degrade (no chat.db read) and never test a successful --stage via
// the CLI (stageDraft writes to the real ~/.messages-mcp on macOS regardless of
// HOME — see storage/drafts.ts) — only its rejection paths.

let dir: string;
let cachePath: string;
let handPath: string;
const ENTRY = join(import.meta.dir, "index.ts");

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "bday-cli-"));
  cachePath = join(dir, "birthdays-cache.json");
  handPath = join(dir, "birthdays.json");
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

interface RunResult { code: number; stdout: string; stderr: string }
function run(...args: string[]): RunResult {
  // --no-calls + --no-cache keep tests hermetic (never read the real CallHistory
  // DB or the real ~/.messages-mcp/signals-cache.json).
  const p = Bun.spawnSync(["bun", "run", ENTRY, "--db", join(dir, "nope.db"), "--no-calls", "--no-cache", ...args], { cwd: dir });
  return {
    code: p.exitCode ?? -1,
    stdout: p.stdout.toString(),
    stderr: p.stderr.toString(),
  };
}

function writeCache(birthdays: unknown[]) {
  writeFileSync(
    cachePath,
    JSON.stringify({ version: 1, generated_at: "2026-06-02T00:00:00Z", source: "test", permission_status: "granted", count: birthdays.length, birthdays }),
  );
}

const LIST_FIELDS = [
  "name", "birthday", "next_occurrence", "days_until", "weekday", "age_turning",
  "relationship", "notes", "best_handle", "handles", "source", "pinned", "muted",
  "out_count", "text_rank", "call_count", "call_rank",
  "wished_before", "wished_years", "suggested", "reasons", "suggested_message",
];

describe("--list", () => {
  test("emits the exact snake_case field contract the Swift controller decodes", () => {
    writeCache([{ name: "Al", birthday: "1990-06-04", handles: ["5551234567"], best_handle: "+15551234567" }]);
    const r = run("--list", "--today", "2026-06-02", "--window-days", "30", "--cache-path", cachePath, "--hand-path", handPath);
    expect(r.code).toBe(0);
    const out = JSON.parse(r.stdout);
    expect(out.signals_available).toBe(false); // no chat.db
    expect(out.count).toBe(1);
    expect(Object.keys(out.upcoming[0]).sort()).toEqual([...LIST_FIELDS].sort());
    expect(out.upcoming[0].age_turning).toBe(36);
  });

  test("window boundary: a birthday exactly at the edge is included, one past is excluded", () => {
    writeCache([
      { name: "Edge", birthday: "06-09", handles: [], best_handle: null }, // 7 days from 06-02
      { name: "Past", birthday: "06-10", handles: [], best_handle: null }, // 8 days
    ]);
    const r = run("--list", "--today", "2026-06-02", "--window-days", "7", "--cache-path", cachePath, "--hand-path", handPath);
    const names = JSON.parse(r.stdout).upcoming.map((u: { name: string }) => u.name);
    expect(names).toContain("Edge");
    expect(names).not.toContain("Past");
  });

  test("dismissed (muted) contacts sink below non-muted", () => {
    writeCache([
      { name: "Soon Muted", birthday: "06-03", handles: ["5550000001"], best_handle: "+15550000001" },
      { name: "Later", birthday: "06-20", handles: ["5550000002"], best_handle: "+15550000002" },
    ]);
    writeFileSync(handPath, JSON.stringify([{ name: "Soon Muted", contact_handle: "+15550000001", birthday: "06-03", muted: true }]));
    const r = run("--list", "--today", "2026-06-02", "--window-days", "30", "--cache-path", cachePath, "--hand-path", handPath);
    const names = JSON.parse(r.stdout).upcoming.map((u: { name: string }) => u.name);
    // Even though "Soon Muted" is sooner, it sinks below the non-muted "Later".
    expect(names).toEqual(["Later", "Soon Muted"]);
  });

  test("pinned ('On your list') floats to the top, above a sooner non-pinned birthday", () => {
    // v2 sort: curation leads, then date — volume/`suggested` no longer drives the
    // top (that's the whole point; Claude does the real prioritization).
    writeCache([
      { name: "Sooner Sue", birthday: "06-05", handles: ["5550000003"], best_handle: "+15550000003" },
      { name: "Pinned Pat", birthday: "06-20", handles: ["5550000004"], best_handle: "+15550000004" },
    ]);
    writeFileSync(handPath, JSON.stringify([{ name: "Pinned Pat", contact_handle: "+15550000004", birthday: "06-20", pinned: true }]));
    const r = run("--list", "--today", "2026-06-02", "--window-days", "30", "--cache-path", cachePath, "--hand-path", handPath);
    const rows = JSON.parse(r.stdout).upcoming as { name: string; pinned: boolean }[];
    // Pat is pinned → leads, even though Sue's birthday is sooner.
    expect(rows.map((u) => u.name)).toEqual(["Pinned Pat", "Sooner Sue"]);
    expect(rows[0]?.pinned).toBe(true);
  });

  test("malformed birthday is skipped with a warning, not a crash", () => {
    writeCache([
      { name: "Bad", birthday: "06-31", handles: [], best_handle: null },
      { name: "Good", birthday: "06-05", handles: [], best_handle: null },
    ]);
    const r = run("--list", "--today", "2026-06-02", "--window-days", "30", "--cache-path", cachePath, "--hand-path", handPath);
    expect(r.code).toBe(0);
    const names = JSON.parse(r.stdout).upcoming.map((u: { name: string }) => u.name);
    expect(names).toEqual(["Good"]);
    expect(r.stderr).toContain("warn");
  });
});

describe("curation", () => {
  test("mute by handle writes the hand file; unmute round-trips", () => {
    writeCache([{ name: "Coworker", birthday: "08-20", handles: ["5551112222"], best_handle: "+15551112222" }]);
    const m = run("--mute", "--handle", "+15551112222", "--cache-path", cachePath, "--hand-path", handPath);
    expect(m.code).toBe(0);
    expect(readFileSync(handPath, "utf8")).toContain("\"muted\": true");
    const u = run("--unmute", "--handle", "+15551112222", "--cache-path", cachePath, "--hand-path", handPath);
    expect(u.code).toBe(0);
    expect(JSON.parse(readFileSync(handPath, "utf8"))[0].muted).toBe(false);
  });

  test("pin a handle-less contact by name (no phone/email)", () => {
    writeCache([{ name: "Grandpa", birthday: "12-25", handles: [], best_handle: null }]);
    const r = run("--pin", "--name", "Grandpa", "--cache-path", cachePath, "--hand-path", handPath);
    expect(r.code).toBe(0);
    const hand = JSON.parse(readFileSync(handPath, "utf8"));
    expect(hand[0].name).toBe("Grandpa");
    expect(hand[0].pinned).toBe(true);
    expect(hand[0].birthday).toBe("12-25"); // pulled from the cache
  });

  test("pinning a previously-dismissed contact clears the mute (re-adding un-dismisses)", () => {
    writeCache([{ name: "Carol", birthday: "07-10", handles: ["5553334444"], best_handle: "+15553334444" }]);
    // Carol was dismissed earlier.
    writeFileSync(handPath, JSON.stringify([{ name: "Carol", contact_handle: "+15553334444", birthday: "07-10", muted: true }]));
    const r = run("--pin", "--handle", "+15553334444", "--cache-path", cachePath, "--hand-path", handPath);
    expect(r.code).toBe(0);
    const hand = JSON.parse(readFileSync(handPath, "utf8"));
    expect(hand[0].pinned).toBe(true);
    expect(hand[0].muted).toBe(false); // pin un-dismisses so the row isn't hidden
  });

  test("rejects an invalid --birthday rather than corrupting the shared hand file", () => {
    const r = run("--pin", "--name", "X", "--birthday", "13-99", "--hand-path", handPath, "--cache-path", cachePath);
    expect(r.code).toBe(2);
    expect(existsSync(handPath)).toBe(false); // nothing written
  });
});

describe("--import", () => {
  function writeImport(entries: unknown): string {
    const p = join(dir, "import.json");
    writeFileSync(p, JSON.stringify(entries));
    return p;
  }

  test("imports a finalized list (JSON array) into birthdays.json, pinned by default", () => {
    const inPath = writeImport([
      { name: "Sam Sample", contact_handle: "samsample@example.com", birthday: "07-15", relationship: "friend" },
      { name: "Kristen", handle: "+15551234567", birthday: "1991-03-02" }, // `handle` (seed field) accepted
    ]);
    const r = run("--import", "--in", inPath, "--hand-path", handPath);
    expect(r.code).toBe(0);
    const out = JSON.parse(r.stdout);
    expect(out).toMatchObject({ status: "ok", created: 2, updated: 0, skipped: 0 });
    const hand = JSON.parse(readFileSync(handPath, "utf8"));
    expect(hand).toHaveLength(2);
    expect(hand.every((e: { pinned?: boolean }) => e.pinned === true)).toBe(true);
    expect(hand.find((e: { name: string }) => e.name === "Sam Sample").contact_handle).toBe("samsample@example.com");
  });

  test("skips invalid entries (bad/missing date, no identity) but imports the rest", () => {
    const inPath = writeImport([
      { name: "Good", contact_handle: "+15550000001", birthday: "05-05" },
      { name: "BadDate", contact_handle: "+15550000002", birthday: "13-99" },
      { name: "NoDate", contact_handle: "+15550000003" },
      { birthday: "01-01" }, // no name and no handle
      "not an object",
    ]);
    const r = run("--import", "--in", inPath, "--hand-path", handPath);
    expect(r.code).toBe(0);
    const out = JSON.parse(r.stdout);
    expect(out.created).toBe(1);
    expect(out.skipped).toBe(4);
    expect(out.skipped_detail).toHaveLength(4);
    const hand = JSON.parse(readFileSync(handPath, "utf8"));
    expect(hand.map((e: { name: string }) => e.name)).toEqual(["Good"]);
  });

  test("a fully-invalid import does not clobber an existing birthdays.json", () => {
    writeFileSync(handPath, JSON.stringify([{ name: "Keep Me", contact_handle: "+15559998888", birthday: "12-01", pinned: true }]));
    const inPath = writeImport([{ name: "Bad", birthday: "99-99" }]);
    const r = run("--import", "--in", inPath, "--hand-path", handPath);
    expect(r.code).toBe(0);
    expect(JSON.parse(r.stdout).created).toBe(0);
    const hand = JSON.parse(readFileSync(handPath, "utf8"));
    expect(hand).toHaveLength(1);
    expect(hand[0].name).toBe("Keep Me"); // untouched
  });

  test("a default-pin import over a previously-dismissed person clears the mute", () => {
    writeFileSync(handPath, JSON.stringify([{ name: "Back", contact_handle: "+15551239999", birthday: "06-06", muted: true }]));
    const inPath = writeImport([{ name: "Back", contact_handle: "+15551239999", birthday: "06-06" }]); // no explicit pinned/muted
    const r = run("--import", "--in", inPath, "--hand-path", handPath);
    expect(r.code).toBe(0);
    const hand = JSON.parse(readFileSync(handPath, "utf8"));
    expect(hand).toHaveLength(1);
    expect(hand[0].pinned).toBe(true);
    expect(hand[0].muted).toBe(false); // pin un-dismisses, like the GUI
  });

  test("missing --in exits 2", () => expect(run("--import", "--hand-path", handPath).code).toBe(2));
  test("non-array JSON exits 2", () => {
    const p = join(dir, "obj.json");
    writeFileSync(p, JSON.stringify({ not: "an array" }));
    expect(run("--import", "--in", p, "--hand-path", handPath).code).toBe(2);
  });
});

describe("--stage validation (rejection paths only — does not write real drafts)", () => {
  test("rejects an empty message", () => {
    expect(run("--stage", "--handle", "+15551234567", "--name", "Al", "--message", "").code).toBe(2);
  });
  test("rejects a whitespace-only message", () => {
    expect(run("--stage", "--handle", "+15551234567", "--name", "Al", "--message", "   ").code).toBe(2);
  });
  test("rejects a missing handle", () => {
    expect(run("--stage", "--name", "Al", "--message", "Happy birthday!").code).toBe(2);
  });
});

describe("arg validation", () => {
  test("unknown flag exits 2", () => expect(run("--list", "--bogus").code).toBe(2));
  test("negative window exits 2", () => expect(run("--list", "--window-days", "-1").code).toBe(2));
});
