import { describe, test, expect, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  _setThreadPrioritiesPathForTesting,
  clearThreadPriority,
  listThreadPriorities,
  loadThreadPriorities,
  setThreadPriority,
  threadPrioritiesFile,
  MAX_PRIORITY_REASON_LENGTH,
  THREAD_PRIORITIES_SCHEMA_VERSION,
} from "./priorities.ts";

// Use the explicit test seam (`_setThreadPrioritiesPathForTesting`) — the
// same pattern as automations.test.ts. Overriding process.env.HOME does NOT
// work on macOS (os.homedir() ignores the JS-level override) and would leak
// writes into the real ~/.messages-mcp.
const tmpHome = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-priorities-test-"));
const prioritiesPath = join(tmpHome, ".messages-mcp", "thread-priorities.json");

beforeEach(() => {
  _setThreadPrioritiesPathForTesting(prioritiesPath);
  rmSync(join(tmpHome, ".messages-mcp"), { recursive: true, force: true });
});

afterAll(() => {
  _setThreadPrioritiesPathForTesting(null);
  rmSync(tmpHome, { recursive: true, force: true });
});

describe("setThreadPriority / listThreadPriorities", () => {
  test("set → list roundtrip with the contract key and entry shape", () => {
    const { key, entry } = setThreadPriority(42, 1, "boss is waiting");
    expect(key).toBe("42");
    expect(entry.level).toBe(1);
    expect(entry.reason).toBe("boss is waiting");
    expect(entry.set_by).toBe("agent");
    expect(Number.isNaN(Date.parse(entry.set_at))).toBe(false);

    const listed = listThreadPriorities();
    expect(Object.keys(listed)).toEqual(["42"]);
    expect(listed["42"]!.level).toBe(1);
    expect(listed["42"]!.reason).toBe("boss is waiting");
  });

  test("on-disk file matches the load-bearing Swift contract exactly", () => {
    setThreadPriority(7, 2, "follow up today");
    const raw = JSON.parse(readFileSync(prioritiesPath, "utf8"));
    expect(raw.schema_version).toBe(1);
    expect(raw.schema_version).toBe(THREAD_PRIORITIES_SCHEMA_VERSION);
    expect(Object.keys(raw)).toEqual(["schema_version", "priorities"]);
    expect(Object.keys(raw.priorities)).toEqual(["7"]);
    const e = raw.priorities["7"];
    expect(Object.keys(e).sort()).toEqual(["level", "reason", "set_at", "set_by"]);
    expect(e.level).toBe(2);
    expect(e.set_by).toBe("agent");
  });

  test("reason is omitted from the JSON when not provided", () => {
    setThreadPriority(9, 3);
    const raw = JSON.parse(readFileSync(prioritiesPath, "utf8"));
    expect("reason" in raw.priorities["9"]).toBe(false);
    expect(listThreadPriorities()["9"]!.reason).toBeUndefined();
  });

  test("reason is capped at 200 chars", () => {
    const long = "x".repeat(500);
    const { entry } = setThreadPriority(11, 2, long);
    expect(entry.reason!.length).toBe(MAX_PRIORITY_REASON_LENGTH);
    expect(listThreadPriorities()["11"]!.reason!.length).toBe(200);
  });

  test("re-setting a thread replaces its existing entry", () => {
    setThreadPriority(5, 3, "first");
    setThreadPriority(5, 1, "now urgent");
    const listed = listThreadPriorities();
    expect(Object.keys(listed)).toEqual(["5"]);
    expect(listed["5"]!.level).toBe(1);
    expect(listed["5"]!.reason).toBe("now urgent");
  });

  test("rejects levels outside 1–3 and non-integer levels", () => {
    expect(() => setThreadPriority(1, 0)).toThrow(/level must be an integer between 1 and 3/);
    expect(() => setThreadPriority(1, 4)).toThrow(/level must be an integer between 1 and 3/);
    expect(() => setThreadPriority(1, 1.5)).toThrow(/level must be an integer between 1 and 3/);
    expect(() => setThreadPriority(1, -2)).toThrow(/level must be an integer between 1 and 3/);
    // Nothing was written.
    expect(listThreadPriorities()).toEqual({});
  });

  test("rejects non-positive / non-integer thread ids", () => {
    expect(() => setThreadPriority(0, 1)).toThrow(/thread_id must be a positive integer/);
    expect(() => setThreadPriority(-3, 1)).toThrow(/thread_id must be a positive integer/);
    expect(() => setThreadPriority(2.5, 1)).toThrow(/thread_id must be a positive integer/);
  });

  test("file is written 0600 with no .tmp leftovers", () => {
    setThreadPriority(3, 2);
    const mode = statSync(prioritiesPath).mode & 0o777;
    expect(mode).toBe(0o600);
    const leftovers = readdirSync(join(tmpHome, ".messages-mcp")).filter((f) => f.includes(".tmp-"));
    expect(leftovers).toEqual([]);
  });
});

describe("clearThreadPriority", () => {
  test("clear removes the entry and is idempotent", () => {
    setThreadPriority(42, 1);
    expect(clearThreadPriority(42)).toBe(true);
    expect(listThreadPriorities()).toEqual({});
    // Second clear is a no-op that reports nothing was removed.
    expect(clearThreadPriority(42)).toBe(false);
  });

  test("clear on a never-set thread returns false without creating spurious state", () => {
    expect(clearThreadPriority(999)).toBe(false);
    expect(listThreadPriorities()).toEqual({});
  });
});

describe("corrupt / hostile file tolerance", () => {
  test("missing file reads as empty", () => {
    expect(loadThreadPriorities()).toEqual({ schema_version: 1, priorities: {} });
  });

  test("malformed JSON reads as empty and set() recovers the file", () => {
    mkdirSync(join(tmpHome, ".messages-mcp"), { recursive: true });
    writeFileSync(prioritiesPath, "{not json!!", { mode: 0o600 });
    expect(listThreadPriorities()).toEqual({});
    const { entry } = setThreadPriority(1, 2);
    expect(entry.level).toBe(2);
    expect(JSON.parse(readFileSync(prioritiesPath, "utf8")).schema_version).toBe(1);
  });

  test("non-object root (array / string) reads as empty", () => {
    mkdirSync(join(tmpHome, ".messages-mcp"), { recursive: true });
    writeFileSync(prioritiesPath, JSON.stringify([1, 2, 3]), { mode: 0o600 });
    expect(listThreadPriorities()).toEqual({});
    writeFileSync(prioritiesPath, JSON.stringify("hello"), { mode: 0o600 });
    expect(listThreadPriorities()).toEqual({});
  });

  test("unknown schema_version reads as empty", () => {
    mkdirSync(join(tmpHome, ".messages-mcp"), { recursive: true });
    writeFileSync(
      prioritiesPath,
      JSON.stringify({ schema_version: 99, priorities: { "1": { level: 1, set_at: "2026-06-09T00:00:00Z", set_by: "agent" } } }),
      { mode: 0o600 },
    );
    expect(listThreadPriorities()).toEqual({});
  });

  test("individually malformed entries are dropped, valid ones kept", () => {
    mkdirSync(join(tmpHome, ".messages-mcp"), { recursive: true });
    writeFileSync(
      prioritiesPath,
      JSON.stringify({
        schema_version: 1,
        priorities: {
          "1": { level: 2, set_at: "2026-06-09T00:00:00Z", set_by: "agent" },
          "2": { level: 7, set_at: "2026-06-09T00:00:00Z", set_by: "agent" }, // bad level
          "3": { level: 1, set_at: "not-a-date", set_by: "agent" }, // bad set_at
          "4": "garbage", // not an object
        },
      }),
      { mode: 0o600 },
    );
    const listed = listThreadPriorities();
    expect(Object.keys(listed)).toEqual(["1"]);
    expect(listed["1"]!.level).toBe(2);
  });
});

describe("symlink guards", () => {
  test("refuses to write through a symlinked priorities file", () => {
    setThreadPriority(1, 1);
    const decoy = join(tmpHome, "decoy.json");
    writeFileSync(decoy, "untouched", { mode: 0o600 });
    rmSync(prioritiesPath);
    symlinkSync(decoy, prioritiesPath);
    expect(() => setThreadPriority(2, 1)).toThrow(/symlink/);
    // Decoy target untouched — our JSON did NOT clobber it.
    expect(readFileSync(decoy, "utf8")).toBe("untouched");
  });

  test("refuses to read through a symlinked priorities file", () => {
    const decoy = join(tmpHome, "decoy-read.json");
    writeFileSync(decoy, JSON.stringify({ schema_version: 1, priorities: {} }), { mode: 0o600 });
    mkdirSync(join(tmpHome, ".messages-mcp"), { recursive: true });
    symlinkSync(decoy, prioritiesPath);
    expect(() => listThreadPriorities()).toThrow(/symlink/);
  });

  test("refuses if the parent ~/.messages-mcp is a symlink", () => {
    const malHome = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-priorities-malhome-"));
    const decoyTarget = join(malHome, "real-dir");
    const symlinkedParent = join(malHome, ".messages-mcp");
    symlinkSync(decoyTarget, symlinkedParent);
    _setThreadPrioritiesPathForTesting(join(symlinkedParent, "thread-priorities.json"));
    try {
      expect(() => setThreadPriority(1, 1)).toThrow(/parent directory is a symlink/);
    } finally {
      _setThreadPrioritiesPathForTesting(prioritiesPath);
      rmSync(malHome, { recursive: true, force: true });
    }
  });
});

describe("set_by provenance back-compat", () => {
  // Write a priorities file straight to disk, then assert load behavior. The
  // Keep Tabs auto-clear logic depends on these markers surviving a read.
  function writeRaw(priorities: Record<string, unknown>): void {
    mkdirSync(join(tmpHome, ".messages-mcp"), { recursive: true });
    writeFileSync(prioritiesPath, JSON.stringify({ schema_version: 1, priorities }), { mode: 0o600 });
  }

  test("preserves a 'keep-tabs' entry instead of rewriting it to 'agent'", () => {
    writeRaw({ "10": { level: 3, set_at: "2026-06-10T00:00:00.000Z", set_by: "keep-tabs" } });
    expect(loadThreadPriorities().priorities["10"]!.set_by).toBe("keep-tabs");
  });

  test("preserves a 'user' entry", () => {
    writeRaw({ "11": { level: 2, set_at: "2026-06-10T00:00:00.000Z", set_by: "user" } });
    expect(loadThreadPriorities().priorities["11"]!.set_by).toBe("user");
  });

  test("legacy entry with no set_by normalizes to 'agent'", () => {
    writeRaw({ "12": { level: 1, set_at: "2026-06-10T00:00:00.000Z" } });
    expect(loadThreadPriorities().priorities["12"]!.set_by).toBe("agent");
  });

  test("unknown set_by value normalizes to 'agent'", () => {
    writeRaw({ "13": { level: 1, set_at: "2026-06-10T00:00:00.000Z", set_by: "martian" } });
    expect(loadThreadPriorities().priorities["13"]!.set_by).toBe("agent");
  });

  test("the agent write path still emits 'agent'", () => {
    setThreadPriority(99, 1, "agent set");
    expect(listThreadPriorities()["99"]!.set_by).toBe("agent");
  });
});

describe("threadPrioritiesFile", () => {
  test("reports the active path (test seam)", () => {
    expect(threadPrioritiesFile()).toBe(prioritiesPath);
  });
});
