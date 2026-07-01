import { describe, test, expect, beforeAll, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, existsSync, readFileSync, chmodSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as audit from "./audit.ts";

const tmpRoot = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-audit-test-"));
const tmpLogPath = join(tmpRoot, "send-audit.log");

beforeAll(() => {
  audit._setAuditLogPathForTesting(tmpLogPath);
});

afterAll(() => {
  audit._setAuditLogPathForTesting(null);
  rmSync(tmpRoot, { recursive: true, force: true });
});

beforeEach(() => {
  if (existsSync(tmpLogPath)) rmSync(tmpLogPath);
  // Reset env between tests so cap-disabled / cap-default don't leak.
  delete process.env["IMESSAGE_DAILY_SEND_CAP"];
});

describe("appendAudit / readAudit", () => {
  test("appends a JSON line with hashed body", () => {
    audit.appendAudit({
      draft_id: "abc",
      to_handle: "+14155551234",
      body: "hello world",
      service: "iMessage",
    });
    const entries = audit.readAudit();
    expect(entries.length).toBe(1);
    expect(entries[0]!.draft_id).toBe("abc");
    expect(entries[0]!.to_handle).toBe("+14155551234");
    expect(entries[0]!.service).toBe("iMessage");
    // SHA-256 of "hello world" — verifies we're hashing the right thing.
    expect(entries[0]!.body_sha256).toBe(
      "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    );
  });

  test("multiple appends accumulate", () => {
    audit.appendAudit({ draft_id: "a", to_handle: "x", body: "1", service: "iMessage" });
    audit.appendAudit({ draft_id: "b", to_handle: "y", body: "2", service: "SMS" });
    audit.appendAudit({ draft_id: "c", to_handle: "z", body: "3", service: "iMessage" });
    expect(audit.readAudit().length).toBe(3);
  });

  test("file is mode 0600 (owner-only)", () => {
    audit.appendAudit({ draft_id: "a", to_handle: "x", body: "y", service: "iMessage" });
    const mode = statSync(tmpLogPath).mode & 0o777;
    expect(mode).toBe(0o600);
  });

  test("re-enforces mode 0600 on every append even if the file pre-existed with loose perms", () => {
    // Attacker pre-creates the log world-readable. Our first append must
    // tighten it to 0o600 (chmodSync after appendFileSync). Without the
    // re-chmod, appendFileSync's `mode` option is ignored on existing
    // files and the log silently stays world-readable, leaking recipient
    // handles on every line.
    audit.appendAudit({ draft_id: "a", to_handle: "x", body: "y", service: "iMessage" });
    chmodSync(tmpLogPath, 0o644);
    audit.appendAudit({ draft_id: "b", to_handle: "x", body: "y", service: "iMessage" });
    const mode = statSync(tmpLogPath).mode & 0o777;
    expect(mode).toBe(0o600);
  });
});

describe("wasSentInAudit", () => {
  test("returns true if the draft id appears in any audit entry", () => {
    audit.appendAudit({ draft_id: "draft-A", to_handle: "x", body: "1", service: "iMessage" });
    audit.appendAudit({ draft_id: "draft-B", to_handle: "y", body: "2", service: "SMS" });
    expect(audit.wasSentInAudit("draft-A")).toBe(true);
    expect(audit.wasSentInAudit("draft-B")).toBe(true);
  });

  test("returns false for an unknown draft id", () => {
    audit.appendAudit({ draft_id: "draft-A", to_handle: "x", body: "1", service: "iMessage" });
    expect(audit.wasSentInAudit("draft-Z")).toBe(false);
  });

  test("returns false when the log is empty", () => {
    expect(audit.wasSentInAudit("anything")).toBe(false);
  });

  test("malformed lines are skipped, not fatal", () => {
    // Hand-corrupt: write a valid entry, then a bad line, then another valid one.
    audit.appendAudit({ draft_id: "good1", to_handle: "x", body: "y", service: "iMessage" });
    Bun.write(tmpLogPath, readFileSync(tmpLogPath, "utf8") + "this isn't json\n");
    audit.appendAudit({ draft_id: "good2", to_handle: "x", body: "y", service: "iMessage" });
    const entries = audit.readAudit();
    expect(entries.length).toBe(2);
    expect(entries.map((e) => e.draft_id).sort()).toEqual(["good1", "good2"]);
  });
});

describe("countSendsInCurrentDay", () => {
  test("counts only entries within the current UTC day", () => {
    const now = new Date("2026-05-14T12:00:00Z");
    // Two within today, one yesterday.
    audit.appendAudit({ draft_id: "a", to_handle: "x", body: "1", service: "iMessage", ts: new Date("2026-05-13T23:59:00Z") });
    audit.appendAudit({ draft_id: "b", to_handle: "x", body: "1", service: "iMessage", ts: new Date("2026-05-14T00:00:01Z") });
    audit.appendAudit({ draft_id: "c", to_handle: "x", body: "1", service: "iMessage", ts: new Date("2026-05-14T11:00:00Z") });
    expect(audit.countSendsInCurrentDay(now)).toBe(2);
  });

  test("returns 0 when log is empty", () => {
    expect(audit.countSendsInCurrentDay()).toBe(0);
  });
});

describe("checkDailyCap", () => {
  test("returns null when under cap", () => {
    process.env["IMESSAGE_DAILY_SEND_CAP"] = "10";
    for (let i = 0; i < 5; i++) {
      audit.appendAudit({ draft_id: `d${i}`, to_handle: "x", body: "1", service: "iMessage" });
    }
    expect(audit.checkDailyCap()).toBeNull();
  });

  test("returns error when at/over cap", () => {
    process.env["IMESSAGE_DAILY_SEND_CAP"] = "3";
    for (let i = 0; i < 3; i++) {
      audit.appendAudit({ draft_id: `d${i}`, to_handle: "x", body: "1", service: "iMessage" });
    }
    const err = audit.checkDailyCap();
    expect(err).not.toBeNull();
    expect(err).toContain("daily send cap");
    expect(err).toContain("3/3");
  });

  test("cap=0 does NOT disable the check — collapses to the hard floor (issue #78)", () => {
    // `0` used to mean "disabled". It now means "use the hard floor" (>=1),
    // so the breaker can never be turned off via env. One send is enough to
    // trip a floor of 1.
    process.env["IMESSAGE_DAILY_SEND_CAP"] = "0";
    expect(audit.dailySendCap()).toBe(1);
    audit.appendAudit({ draft_id: "d0", to_handle: "x", body: "1", service: "iMessage" });
    const err = audit.checkDailyCap();
    expect(err).not.toBeNull();
    expect(err).toContain("daily send cap");
  });

  test("invalid env var falls back to default", () => {
    process.env["IMESSAGE_DAILY_SEND_CAP"] = "not-a-number";
    expect(audit.dailySendCap()).toBe(50);
  });
});

describe("dailySendCap hard floor + ceiling (issue #78)", () => {
  test("unset env → DEFAULT_CAP (50)", () => {
    delete process.env["IMESSAGE_DAILY_SEND_CAP"];
    expect(audit.dailySendCap()).toBe(50);
  });

  test("env can RAISE strictness (lower the cap) down to the hard floor", () => {
    process.env["IMESSAGE_DAILY_SEND_CAP"] = "5";
    expect(audit.dailySendCap()).toBe(5);
  });

  test("env value below the hard floor is clamped UP to the floor (>=1), never disabled", () => {
    // 0 → 1 (the floor). The breaker stays armed no matter what env requests.
    process.env["IMESSAGE_DAILY_SEND_CAP"] = "0";
    expect(audit.dailySendCap()).toBe(1);
  });

  test("env cannot raise the cap above the hard ceiling (1000)", () => {
    // An attacker who can set env must not be able to make the breaker
    // effectively infinite.
    process.env["IMESSAGE_DAILY_SEND_CAP"] = "1000000";
    expect(audit.dailySendCap()).toBe(1000);
  });

  test("negative env value falls back to default", () => {
    process.env["IMESSAGE_DAILY_SEND_CAP"] = "-10";
    expect(audit.dailySendCap()).toBe(50);
  });
});
