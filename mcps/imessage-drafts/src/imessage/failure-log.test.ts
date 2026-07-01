import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  makeEntry,
  encodeLine,
  record,
  _setFailureLogPathForTesting,
  type SendFailureEntry,
} from "./failure-log.ts";

// The send-failure log shares an EXACT on-disk shape with the Swift menu-bar
// send path: keys ts, platform, handle, route, error, duration_ms, source in
// that order. These tests pin the pure builder/encoder shape and the best-
// effort never-throw contract. No real sends, no osascript.

describe("makeEntry — shape + invariants", () => {
  const fixedTs = new Date("2026-06-22T21:00:00.000Z");

  test("produces the exact key set the Swift side writes", () => {
    const entry = makeEntry({
      handle: "+14155551234",
      route: "chat-id",
      error: "boom",
      duration_ms: 1234,
      ts: fixedTs,
    });
    expect(Object.keys(entry)).toEqual([
      "ts",
      "platform",
      "handle",
      "route",
      "error",
      "duration_ms",
      "source",
    ]);
  });

  test("platform is always 'imessage' and source defaults to 'ts-send_draft'", () => {
    const entry = makeEntry({ handle: "+1555", route: "buddy-cascade", error: "x", duration_ms: 0, ts: fixedTs });
    expect(entry.platform).toBe("imessage");
    expect(entry.source).toBe("ts-send_draft");
  });

  test("ts is ISO-8601 with milliseconds", () => {
    const entry = makeEntry({ handle: "+1555", route: "chat-id", error: "x", duration_ms: 5, ts: fixedTs });
    expect(entry.ts).toBe("2026-06-22T21:00:00.000Z");
    expect(entry.ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  });

  test("duration_ms is floored to a non-negative integer", () => {
    expect(makeEntry({ handle: "h", route: "chat-id", error: "e", duration_ms: 1234.9, ts: fixedTs }).duration_ms).toBe(1234);
    expect(makeEntry({ handle: "h", route: "chat-id", error: "e", duration_ms: -7, ts: fixedTs }).duration_ms).toBe(0);
  });

  test("route passes through verbatim (chat-id | buddy-cascade | group)", () => {
    for (const route of ["chat-id", "buddy-cascade", "group"] as const) {
      expect(makeEntry({ handle: "h", route, error: "e", duration_ms: 1, ts: fixedTs }).route).toBe(route);
    }
  });

  test("source is always the TS send_draft value", () => {
    const entry = makeEntry({ handle: "h", route: "group", error: "e", duration_ms: 1, ts: fixedTs });
    expect(entry.source).toBe("ts-send_draft");
  });
});

describe("encodeLine — on-disk serialization", () => {
  test("emits one JSON object with the canonical key order and a trailing newline", () => {
    const entry = makeEntry({
      handle: "+14155551234",
      route: "chat-id",
      error: "send failed: buddy unreachable",
      duration_ms: 42,
      ts: new Date("2026-06-22T21:00:00.000Z"),
    });
    const line = encodeLine(entry);
    expect(line.endsWith("\n")).toBe(true);
    // Exact byte shape: Swift JSONEncoder uses `.sortedKeys`.
    expect(line).toBe(
      '{"duration_ms":42,"error":"send failed: buddy unreachable","handle":"+14155551234","platform":"imessage","route":"chat-id","source":"ts-send_draft","ts":"2026-06-22T21:00:00.000Z"}\n'
    );
    // Round-trips back to the same object.
    expect(JSON.parse(line) as SendFailureEntry).toEqual(entry);
  });
});

describe("record — best-effort append", () => {
  let tmpRoot: string;
  let logFile: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "imessage-drafts-failure-log-test-"));
    logFile = join(tmpRoot, "logs", "send-failures.log");
    _setFailureLogPathForTesting(logFile);
  });

  afterEach(() => {
    _setFailureLogPathForTesting(null);
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("creates the logs dir and appends a JSON line", () => {
    const entry = record({
      handle: "+14155551234",
      route: "buddy-cascade",
      error: "iMessage=unreachable; SMS=unreachable",
      duration_ms: 1200,
      ts: new Date("2026-06-22T21:00:00.000Z"),
    });
    expect(entry).not.toBeNull();
    expect(existsSync(logFile)).toBe(true);
    const raw = readFileSync(logFile, "utf8");
    expect(raw.trimEnd()).toBe(encodeLine(entry!).trimEnd());
    expect(JSON.parse(raw.trim())).toMatchObject({
      platform: "imessage",
      handle: "+14155551234",
      route: "buddy-cascade",
      source: "ts-send_draft",
    });
  });

  test("appends (does not truncate) across multiple failures", () => {
    record({ handle: "+1555", route: "chat-id", error: "a", duration_ms: 1 });
    record({ handle: "+1666", route: "buddy-cascade", error: "b", duration_ms: 2 });
    const lines = readFileSync(logFile, "utf8").trim().split("\n");
    expect(lines.length).toBe(2);
    expect(JSON.parse(lines[0]!).handle).toBe("+1555");
    expect(JSON.parse(lines[1]!).handle).toBe("+1666");
  });

  test("writes the log file mode 0600 (recipient handle is in cleartext)", () => {
    record({ handle: "+1555", route: "chat-id", error: "a", duration_ms: 1 });
    const { statSync } = require("node:fs");
    const mode = statSync(logFile).mode & 0o777;
    expect(mode).toBe(0o600);
  });

  test("never throws and returns null when the target dir cannot be created", () => {
    // Point at a path under a *file* so mkdir/append must fail — record() must
    // swallow it (a logging failure must never affect the send result).
    const filePath = join(tmpRoot, "a-regular-file");
    require("node:fs").writeFileSync(filePath, "x");
    _setFailureLogPathForTesting(join(filePath, "nested", "send-failures.log"));
    let out: SendFailureEntry | null = null;
    expect(() => {
      out = record({ handle: "+1555", route: "chat-id", error: "a", duration_ms: 1 });
    }).not.toThrow();
    expect(out).toBeNull();
  });
});
