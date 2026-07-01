import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  _setVoiceRootForTesting,
  getVoiceProfile,
  listVoiceProfiles,
} from "./voice.ts";

const tmp = join(tmpdir(), `imessage-drafts-mcp-voice-test-${process.pid}`);

beforeAll(() => {
  _setVoiceRootForTesting(tmp);
});

afterAll(() => {
  _setVoiceRootForTesting(null);
  rmSync(tmp, { recursive: true, force: true });
});

beforeEach(() => {
  rmSync(tmp, { recursive: true, force: true });
  mkdirSync(join(tmp, "base"), { recursive: true });
});

describe("voice profile storage", () => {
  test("lists generated profiles", () => {
    writeFileSync(join(tmp, "base", "VOICE.md"), "# Base texting style\n", { mode: 0o600 });
    writeFileSync(join(tmp, "base", "fingerprint.json"), JSON.stringify({ profile_id: "base" }), { mode: 0o600 });

    const profiles = listVoiceProfiles();
    expect(profiles).toHaveLength(1);
    expect(profiles[0]?.profile).toBe("base");
    expect(profiles[0]?.has_voice_md).toBe(true);
    expect(profiles[0]?.has_fingerprint).toBe(true);
  });

  test("reads voice markdown and fingerprint JSON", () => {
    writeFileSync(join(tmp, "base", "VOICE.md"), "# Base texting style\n", { mode: 0o600 });
    writeFileSync(join(tmp, "base", "fingerprint.json"), JSON.stringify({ sample_size: 42 }), { mode: 0o600 });

    const profile = getVoiceProfile("base");
    expect(profile.voice_md).toContain("Base texting style");
    expect(profile.fingerprint).toEqual({ sample_size: 42 });
    expect(profile.paths.guide_md).toContain("GUIDE.md");
  });

  test("scrubs raw handle fields from fingerprint JSON", () => {
    writeFileSync(join(tmp, "base", "VOICE.md"), "# Base texting style\n", { mode: 0o600 });
    writeFileSync(
      join(tmp, "base", "fingerprint.json"),
      JSON.stringify({
        sample_size: 42,
        participant_handles: ["+12155551212", "person@example.com"],
        nested: { raw_handle: "+14155550123", keep: "ok" },
      }),
      { mode: 0o600 }
    );

    const profile = getVoiceProfile("base");
    expect(profile.fingerprint).toEqual({ sample_size: 42, nested: { keep: "ok" } });
  });

  test("prefers the AI-enhanced guide markdown when present", () => {
    writeFileSync(join(tmp, "base", "VOICE.md"), "# Local fingerprint fallback\n", { mode: 0o600 });
    writeFileSync(join(tmp, "base", "GUIDE.md"), "# AI-enhanced texting style\n", { mode: 0o600 });

    const profile = getVoiceProfile("base");
    expect(profile.voice_md).toContain("AI-enhanced texting style");
    expect(profile.voice_md).not.toContain("Local fingerprint fallback");
  });

  test("rejects path traversal profile ids", () => {
    expect(() => getVoiceProfile("../base")).toThrow("profile must be a simple profile id");
    expect(() => getVoiceProfile("base/other")).toThrow("profile must be a simple profile id");
  });
});
