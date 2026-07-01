// User-controllable settings shared between the MCP server and the
// companion menu bar app. Single-key file today (require_approval), but
// the schema is open-ended so we can add more knobs without breaking
// older builds — unknown keys are ignored, missing keys fall back to
// safe defaults.
//
// File: ~/.messages-mcp/settings.json (mode 0600).
//
// Reads happen on every MCP send so toggling the flag in the menu bar
// app takes effect immediately, no MCP-client restart needed. Writes
// happen only from the menu bar app; the MCP server is read-only.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface Settings {
  // When true (default), the MCP `send_draft` tool refuses to
  // send and instructs the caller to use the menu bar app instead. This
  // is the strongest enforcement of the draft-review property:
  // every send must pass through human eyes.
  require_approval: boolean;
}

const DEFAULTS: Settings = {
  require_approval: true,
};

function settingsDirPath(): string {
  return testDirOverride ?? join(homedir(), ".messages-mcp");
}

function settingsFilePath(): string {
  return join(settingsDirPath(), "settings.json");
}

let testDirOverride: string | null = null;

export function _setSettingsDirForTesting(dir: string | null): void {
  testDirOverride = dir;
}

function ensureDir(): void {
  const d = settingsDirPath();
  if (!existsSync(d)) mkdirSync(d, { recursive: true });
}

// Load with graceful fallback. A missing or corrupt file returns the
// safe defaults — important because the MCP server runs before the
// menu bar app has had a chance to write the file on a fresh install.
//
// FAIL-CLOSED (issue #78): `require_approval` is the approval gate, so it is
// read fail-closed — ANY ambiguity (missing key, wrong type, non-object JSON,
// corrupt file) resolves to `true` (approval required). The ONLY way to get
// `false` is an explicit boolean `false` in a well-formed settings object;
// there is no path where a malformed/partial file silently disables the gate.
export function loadSettings(): Settings {
  const path = settingsFilePath();
  if (!existsSync(path)) return { ...DEFAULTS };
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
    // Guard against the file parsing to a non-object (null, array, number,
    // string). Property access on those wouldn't throw, but would yield
    // `undefined` and skip the boolean check — be explicit so the fail-closed
    // contract is obvious and can't be eroded by a refactor.
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return { ...DEFAULTS };
    }
    const raw = parsed as Partial<Settings>;
    return {
      // Only an explicit boolean is honored; everything else → fail-closed default (true).
      require_approval: typeof raw.require_approval === "boolean" ? raw.require_approval : DEFAULTS.require_approval,
    };
  } catch {
    return { ...DEFAULTS };
  }
}

// Convenience: just the one boolean. Read fresh from disk each call —
// no caching — so toggling in the menu bar takes effect on the next
// send without restarting any process.
export function requireApproval(): boolean {
  return loadSettings().require_approval;
}

// Used from tests; production writes happen from the Swift menu bar app.
export function _saveSettingsForTesting(settings: Settings): void {
  ensureDir();
  writeFileSync(settingsFilePath(), JSON.stringify(settings, null, 2), { mode: 0o600 });
}
