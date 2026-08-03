import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Point PATHS at a scratch home BEFORE importing the module under test.
const home = mkdtempSync(join(tmpdir(), "whatsapp-mcp-recovery-"));
const savedHome = process.env.WHATSAPP_MCP_HOME;
process.env.WHATSAPP_MCP_HOME = home;

const {
  clearRecoverySentinel,
  parseRecoverySentinel,
  readRecoverySentinel,
  writeRecoverySentinel,
} = await import("./recovery.ts");

const sentinel = join(home, "LOGGED_OUT");

beforeEach(() => {
  if (existsSync(sentinel)) rmSync(sentinel);
});

afterAll(() => {
  if (savedHome == null) delete process.env.WHATSAPP_MCP_HOME;
  else process.env.WHATSAPP_MCP_HOME = savedHome;
  rmSync(home, { recursive: true, force: true });
});

describe("recovery sentinel", () => {
  test("absent sentinel reads as not-parked", () => {
    expect(readRecoverySentinel()).toBeNull();
  });

  test("round-trips a session_unreadable reason with detail", () => {
    writeRecoverySentinel("session_unreadable", "6398 of 6399 rows failed");
    expect(readRecoverySentinel()).toEqual({
      reason: "session_unreadable",
      detail: "6398 of 6399 rows failed",
    });
  });

  test("round-trips a logged_out reason", () => {
    writeRecoverySentinel("logged_out", "unlinked from Linked Devices");
    expect(readRecoverySentinel()?.reason).toBe("logged_out");
  });

  // The whole reason we reuse LOGGED_OUT instead of adding a second file: an
  // older daemon writes a bare timestamp and checks existence only. Both
  // directions have to keep working across a downgrade.
  test("a legacy timestamp-only sentinel is read as logged_out", () => {
    writeFileSync(sentinel, "2026-07-20T19:45:00.000Z\n", { mode: 0o600 });
    expect(readRecoverySentinel()).toEqual({ reason: "logged_out", detail: "" });
  });

  test("keeps an ISO timestamp on line 1 so older builds see the shape they wrote", () => {
    writeRecoverySentinel("session_unreadable", "x");
    const firstLine = readFileSync(sentinel, "utf8").split("\n")[0] ?? "";
    expect(new Date(firstLine).toString()).not.toBe("Invalid Date");
  });

  test("an unknown reason value falls back to logged_out rather than throwing", () => {
    expect(parseRecoverySentinel("2026-01-01T00:00:00Z\nreason=martian\n").reason).toBe("logged_out");
  });

  test("a multi-line detail is flattened so it can't forge extra keys", () => {
    writeRecoverySentinel("session_unreadable", "line one\nreason=logged_out");
    // The injected newline must not be re-parsed as its own key=value line.
    expect(readRecoverySentinel()?.reason).toBe("session_unreadable");
  });

  test("clear removes the sentinel and is a no-op when already absent", () => {
    writeRecoverySentinel("logged_out");
    clearRecoverySentinel();
    expect(existsSync(sentinel)).toBe(false);
    expect(() => clearRecoverySentinel()).not.toThrow();
  });

  test("sentinel is written 0600", () => {
    writeRecoverySentinel("logged_out");
    const { statSync } = require("node:fs") as typeof import("node:fs");
    expect(statSync(sentinel).mode & 0o777).toBe(0o600);
  });
});
