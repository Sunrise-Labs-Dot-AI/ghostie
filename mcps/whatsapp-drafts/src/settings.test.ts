import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const tmp = mkdtempSync(join(tmpdir(), "whatsapp-mcp-settings-"));
process.env.WHATSAPP_MCP_HOME = tmp;

const { readSettings, writeSettings, DEFAULT_SETTINGS, SettingsError } = await import("./settings.ts");
const settingsPath = join(tmp, "settings.json");

afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

beforeEach(() => {
  try { rmSync(settingsPath, { force: true }); } catch { /* ignore */ }
});

describe("settings.json", () => {
  test("first read seeds defaults", () => {
    const s = readSettings();
    expect(s).toEqual(DEFAULT_SETTINGS);
    // Subsequent read should also work.
    expect(readSettings()).toEqual(DEFAULT_SETTINGS);
  });

  test("respects user overrides", () => {
    writeSettings({ ...DEFAULT_SETTINGS, require_approval: false, daily_cap: 25 });
    const s = readSettings();
    expect(s.require_approval).toBe(false);
    expect(s.daily_cap).toBe(25);
  });

  test("malformed JSON throws SettingsError", () => {
    writeFileSync(settingsPath, "not json at all", "utf8");
    expect(() => readSettings()).toThrow(SettingsError);
  });

  test("schema violation throws with field detail", () => {
    writeFileSync(settingsPath, JSON.stringify({ daily_cap: -1 }), "utf8");
    expect(() => readSettings()).toThrow(/daily_cap/);
  });

  test("unknown extra fields fail strict parse", () => {
    writeFileSync(settingsPath, JSON.stringify({ ...DEFAULT_SETTINGS, evil_knob: true }), "utf8");
    expect(() => readSettings()).toThrow(/evil_knob/);
  });

  test("max_burst_in_60s and min_inter_send_ms validate", () => {
    writeFileSync(settingsPath, JSON.stringify({ ...DEFAULT_SETTINGS, max_burst_in_60s: 0 }), "utf8");
    expect(() => readSettings()).toThrow(/max_burst_in_60s/);
    writeFileSync(settingsPath, JSON.stringify({ ...DEFAULT_SETTINGS, min_inter_send_ms: -1 }), "utf8");
    expect(() => readSettings()).toThrow(/min_inter_send_ms/);
  });
});

// SECURITY (issue #78): the stage→send handoff window can't be disabled to 0,
// and the daily-cap breaker can't be turned off — mirrors the iMessage
// hardening (minDraftAgeMs hard floor + dailySendCap non-disablable).
describe("send-floor hardening (issue #78)", () => {
  test("min_staged_age_ms: 0 collapses to the hard floor (>=1000ms), never disabled", () => {
    writeFileSync(settingsPath, JSON.stringify({ ...DEFAULT_SETTINGS, min_staged_age_ms: 0 }), "utf8");
    expect(readSettings().min_staged_age_ms).toBe(1000);
  });

  test("a sub-floor min_staged_age_ms is clamped UP to the floor", () => {
    writeFileSync(settingsPath, JSON.stringify({ ...DEFAULT_SETTINGS, min_staged_age_ms: 500 }), "utf8");
    expect(readSettings().min_staged_age_ms).toBe(1000);
  });

  test("a min_staged_age_ms above the floor is honored verbatim (env can only raise strictness)", () => {
    writeFileSync(settingsPath, JSON.stringify({ ...DEFAULT_SETTINGS, min_staged_age_ms: 30_000 }), "utf8");
    expect(readSettings().min_staged_age_ms).toBe(30_000);
  });

  test("daily_cap cannot be disabled to 0 — it fails closed (sends refused), not 'disabled'", () => {
    writeFileSync(settingsPath, JSON.stringify({ ...DEFAULT_SETTINGS, daily_cap: 0 }), "utf8");
    expect(() => readSettings()).toThrow(/daily_cap/);
  });

  test("daily_cap cannot be raised above the hard ceiling (10000)", () => {
    writeFileSync(settingsPath, JSON.stringify({ ...DEFAULT_SETTINGS, daily_cap: 50_000 }), "utf8");
    expect(() => readSettings()).toThrow(/daily_cap/);
  });
});
