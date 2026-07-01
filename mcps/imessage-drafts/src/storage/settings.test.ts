import { describe, test, expect, beforeAll, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as settings from "./settings.ts";

const tmp = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-settings-test-"));

beforeAll(() => {
  settings._setSettingsDirForTesting(tmp);
});

afterAll(() => {
  settings._setSettingsDirForTesting(null);
  rmSync(tmp, { recursive: true, force: true });
});

beforeEach(() => {
  // Clear any settings.json between tests.
  const file = join(tmp, "settings.json");
  try { rmSync(file); } catch { /* ignore */ }
});

describe("loadSettings", () => {
  test("returns safe defaults when file is missing (require_approval = true)", () => {
    const s = settings.loadSettings();
    expect(s.require_approval).toBe(true);
  });

  test("reads require_approval=false when written explicitly", () => {
    settings._saveSettingsForTesting({ require_approval: false });
    expect(settings.loadSettings().require_approval).toBe(false);
  });

  test("reads require_approval=true when written explicitly", () => {
    settings._saveSettingsForTesting({ require_approval: true });
    expect(settings.loadSettings().require_approval).toBe(true);
  });

  test("falls back to default when file is malformed JSON", () => {
    writeFileSync(join(tmp, "settings.json"), "{not valid json", { mode: 0o600 });
    expect(settings.loadSettings().require_approval).toBe(true);
  });

  test("falls back to default when require_approval field is missing", () => {
    writeFileSync(join(tmp, "settings.json"), JSON.stringify({}), { mode: 0o600 });
    expect(settings.loadSettings().require_approval).toBe(true);
  });

  test("falls back to default when require_approval is the wrong type", () => {
    writeFileSync(join(tmp, "settings.json"), JSON.stringify({ require_approval: "yes" }), { mode: 0o600 });
    expect(settings.loadSettings().require_approval).toBe(true);
  });

  test("fail-closed: file parsing to a non-object (null) → require_approval true (issue #78)", () => {
    writeFileSync(join(tmp, "settings.json"), "null", { mode: 0o600 });
    expect(settings.loadSettings().require_approval).toBe(true);
  });

  test("fail-closed: file parsing to an array → require_approval true (issue #78)", () => {
    writeFileSync(join(tmp, "settings.json"), JSON.stringify([{ require_approval: false }]), { mode: 0o600 });
    expect(settings.loadSettings().require_approval).toBe(true);
  });

  test("fail-closed: file parsing to a bare number → require_approval true (issue #78)", () => {
    writeFileSync(join(tmp, "settings.json"), "42", { mode: 0o600 });
    expect(settings.loadSettings().require_approval).toBe(true);
  });

  test("fail-closed: require_approval=null reads as true (issue #78)", () => {
    writeFileSync(join(tmp, "settings.json"), JSON.stringify({ require_approval: null }), { mode: 0o600 });
    expect(settings.loadSettings().require_approval).toBe(true);
  });

  test("ignores extra unknown keys (forward compat)", () => {
    writeFileSync(
      join(tmp, "settings.json"),
      JSON.stringify({ require_approval: false, future_field: "ignored" }),
      { mode: 0o600 }
    );
    expect(settings.loadSettings().require_approval).toBe(false);
  });
});

describe("requireApproval", () => {
  test("reflects current on-disk state without caching", () => {
    settings._saveSettingsForTesting({ require_approval: true });
    expect(settings.requireApproval()).toBe(true);
    settings._saveSettingsForTesting({ require_approval: false });
    expect(settings.requireApproval()).toBe(false);
    settings._saveSettingsForTesting({ require_approval: true });
    expect(settings.requireApproval()).toBe(true);
  });
});

describe("_saveSettingsForTesting", () => {
  test("writes the file with mode 0600", () => {
    settings._saveSettingsForTesting({ require_approval: true });
    const file = join(tmp, "settings.json");
    const mode = statSync(file).mode & 0o777;
    expect(mode).toBe(0o600);
  });
});
