import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Same env seam as drafts.test.ts: PATHS resolves WHATSAPP_MCP_HOME lazily
// per access, so setting it before the dynamic import routes every storage
// call into this tmp dir even though Bun's test runner shares one process
// across .test.ts files.
const tmp = mkdtempSync(join(tmpdir(), "whatsapp-mcp-priorities-"));
process.env.WHATSAPP_MCP_HOME = tmp;

const {
  clearThreadPriority,
  listThreadPriorities,
  loadThreadPriorities,
  setThreadPriority,
  threadPrioritiesFile,
  MAX_PRIORITY_REASON_LENGTH,
  THREAD_PRIORITIES_SCHEMA_VERSION,
} = await import("./priorities.ts");

const prioritiesPath = join(tmp, "thread-priorities.json");
const JID = "12025550001@s.whatsapp.net";
const GROUP_JID = "120363041234567890@g.us";

afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

beforeEach(() => {
  // Tests in this file share the tmp home with PATHS consumers; only reset
  // the priorities file itself between tests.
  process.env.WHATSAPP_MCP_HOME = tmp;
  rmSync(prioritiesPath, { force: true });
});

describe("setThreadPriority / listThreadPriorities", () => {
  test("set → list roundtrip keyed by thread_jid", () => {
    const { key, entry } = setThreadPriority(JID, 1, "boss is waiting");
    expect(key).toBe(JID);
    expect(entry.level).toBe(1);
    expect(entry.reason).toBe("boss is waiting");
    expect(entry.set_by).toBe("agent");
    expect(Number.isNaN(Date.parse(entry.set_at))).toBe(false);

    const listed = listThreadPriorities();
    expect(Object.keys(listed)).toEqual([JID]);
    expect(listed[JID]!.level).toBe(1);
  });

  test("on-disk file matches the load-bearing Swift contract exactly", () => {
    setThreadPriority(GROUP_JID, 2, "trip planning deadline");
    const raw = JSON.parse(readFileSync(prioritiesPath, "utf8"));
    expect(raw.schema_version).toBe(1);
    expect(raw.schema_version).toBe(THREAD_PRIORITIES_SCHEMA_VERSION);
    expect(Object.keys(raw)).toEqual(["schema_version", "priorities"]);
    expect(Object.keys(raw.priorities)).toEqual([GROUP_JID]);
    const e = raw.priorities[GROUP_JID];
    expect(Object.keys(e).sort()).toEqual(["level", "reason", "set_at", "set_by"]);
    expect(e.level).toBe(2);
    expect(e.set_by).toBe("agent");
  });

  test("reason is omitted from the JSON when not provided", () => {
    setThreadPriority(JID, 3);
    const raw = JSON.parse(readFileSync(prioritiesPath, "utf8"));
    expect("reason" in raw.priorities[JID]).toBe(false);
  });

  test("reason is capped at 200 chars", () => {
    const { entry } = setThreadPriority(JID, 2, "x".repeat(500));
    expect(entry.reason!.length).toBe(MAX_PRIORITY_REASON_LENGTH);
  });

  test("re-setting a thread replaces its existing entry", () => {
    setThreadPriority(JID, 3, "first");
    setThreadPriority(JID, 1, "now urgent");
    const listed = listThreadPriorities();
    expect(Object.keys(listed)).toEqual([JID]);
    expect(listed[JID]!.level).toBe(1);
    expect(listed[JID]!.reason).toBe("now urgent");
  });

  test("rejects levels outside 1–3 and non-integer levels", () => {
    expect(() => setThreadPriority(JID, 0)).toThrow(/level must be an integer between 1 and 3/);
    expect(() => setThreadPriority(JID, 4)).toThrow(/level must be an integer between 1 and 3/);
    expect(() => setThreadPriority(JID, 1.5)).toThrow(/level must be an integer between 1 and 3/);
    expect(listThreadPriorities()).toEqual({});
  });

  test("rejects an empty thread_jid", () => {
    expect(() => setThreadPriority("", 1)).toThrow(/thread_jid must be a non-empty string/);
  });

  test("file is written 0600 with no .tmp leftovers", () => {
    setThreadPriority(JID, 2);
    const mode = statSync(prioritiesPath).mode & 0o777;
    expect(mode).toBe(0o600);
    const leftovers = readdirSync(tmp).filter((f) => f.includes("thread-priorities.json.tmp-"));
    expect(leftovers).toEqual([]);
  });
});

describe("clearThreadPriority", () => {
  test("clear removes the entry and is idempotent", () => {
    setThreadPriority(JID, 1);
    expect(clearThreadPriority(JID)).toBe(true);
    expect(listThreadPriorities()).toEqual({});
    expect(clearThreadPriority(JID)).toBe(false);
  });

  test("clear on a never-set jid returns false", () => {
    expect(clearThreadPriority("unknown@s.whatsapp.net")).toBe(false);
  });
});

describe("corrupt / hostile file tolerance", () => {
  test("missing file reads as empty", () => {
    expect(loadThreadPriorities()).toEqual({ schema_version: 1, priorities: {} });
  });

  test("malformed JSON reads as empty and set() recovers the file", () => {
    mkdirSync(tmp, { recursive: true });
    writeFileSync(prioritiesPath, "{not json!!", { mode: 0o600 });
    expect(listThreadPriorities()).toEqual({});
    setThreadPriority(JID, 2);
    expect(JSON.parse(readFileSync(prioritiesPath, "utf8")).schema_version).toBe(1);
  });

  test("unknown schema_version reads as empty", () => {
    writeFileSync(
      prioritiesPath,
      JSON.stringify({ schema_version: 99, priorities: { [JID]: { level: 1, set_at: "2026-06-09T00:00:00Z", set_by: "agent" } } }),
      { mode: 0o600 },
    );
    expect(listThreadPriorities()).toEqual({});
  });

  test("individually malformed entries are dropped, valid ones kept", () => {
    writeFileSync(
      prioritiesPath,
      JSON.stringify({
        schema_version: 1,
        priorities: {
          [JID]: { level: 2, set_at: "2026-06-09T00:00:00Z", set_by: "agent" },
          [GROUP_JID]: { level: 9, set_at: "2026-06-09T00:00:00Z", set_by: "agent" }, // bad level
          "bad@x": "garbage", // not an object
        },
      }),
      { mode: 0o600 },
    );
    const listed = listThreadPriorities();
    expect(Object.keys(listed)).toEqual([JID]);
  });
});

describe("symlink guards", () => {
  test("refuses to write through a symlinked priorities file", () => {
    const decoy = join(tmp, "decoy.json");
    writeFileSync(decoy, "untouched", { mode: 0o600 });
    symlinkSync(decoy, prioritiesPath);
    expect(() => setThreadPriority(JID, 1)).toThrow(/symlink/);
    expect(readFileSync(decoy, "utf8")).toBe("untouched");
  });

  test("refuses to read through a symlinked priorities file", () => {
    const decoy = join(tmp, "decoy-read.json");
    writeFileSync(decoy, JSON.stringify({ schema_version: 1, priorities: {} }), { mode: 0o600 });
    symlinkSync(decoy, prioritiesPath);
    expect(() => listThreadPriorities()).toThrow(/symlink/);
  });

  test("refuses if the parent ~/.whatsapp-mcp is a symlink", () => {
    const malRoot = mkdtempSync(join(tmpdir(), "whatsapp-mcp-priorities-malhome-"));
    const symlinkedHome = join(malRoot, "home-link");
    symlinkSync(join(malRoot, "real-home"), symlinkedHome);
    process.env.WHATSAPP_MCP_HOME = symlinkedHome;
    try {
      expect(() => setThreadPriority(JID, 1)).toThrow(/parent directory is a symlink/);
    } finally {
      process.env.WHATSAPP_MCP_HOME = tmp;
      rmSync(malRoot, { recursive: true, force: true });
    }
  });
});

describe("set_by provenance back-compat", () => {
  function writeRaw(priorities: Record<string, unknown>): void {
    mkdirSync(tmp, { recursive: true });
    writeFileSync(prioritiesPath, JSON.stringify({ schema_version: 1, priorities }), { mode: 0o600 });
  }

  test("preserves a 'keep-tabs' entry instead of rewriting it to 'agent'", () => {
    writeRaw({ [JID]: { level: 3, set_at: "2026-06-10T00:00:00.000Z", set_by: "keep-tabs" } });
    expect(loadThreadPriorities().priorities[JID]!.set_by).toBe("keep-tabs");
  });

  test("preserves a 'user' entry", () => {
    writeRaw({ [JID]: { level: 2, set_at: "2026-06-10T00:00:00.000Z", set_by: "user" } });
    expect(loadThreadPriorities().priorities[JID]!.set_by).toBe("user");
  });

  test("legacy entry with no set_by normalizes to 'agent'", () => {
    writeRaw({ [JID]: { level: 1, set_at: "2026-06-10T00:00:00.000Z" } });
    expect(loadThreadPriorities().priorities[JID]!.set_by).toBe("agent");
  });

  test("unknown set_by value normalizes to 'agent'", () => {
    writeRaw({ [JID]: { level: 1, set_at: "2026-06-10T00:00:00.000Z", set_by: "martian" } });
    expect(loadThreadPriorities().priorities[JID]!.set_by).toBe("agent");
  });

  test("the agent write path still emits 'agent'", () => {
    setThreadPriority(JID, 1, "agent set");
    expect(listThreadPriorities()[JID]!.set_by).toBe("agent");
  });
});

describe("threadPrioritiesFile", () => {
  test("reports the active path (env seam)", () => {
    expect(threadPrioritiesFile()).toBe(prioritiesPath);
  });
});
