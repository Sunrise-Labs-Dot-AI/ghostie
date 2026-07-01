import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const MAX_PROFILE_FILE_BYTES = 200_000;

export interface VoiceProfileListEntry {
  profile: string;
  has_voice_md: boolean;
  has_fingerprint: boolean;
  updated_at: string | null;
}

export interface VoiceProfileRead {
  profile: string;
  voice_md: string | null;
  fingerprint: unknown | null;
  paths: {
    directory: string;
    guide_md: string;
    voice_md: string;
    fingerprint: string;
  };
}

let voiceRootOverride: string | null = null;

export function _setVoiceRootForTesting(dir: string | null): void {
  voiceRootOverride = dir;
}

export function voiceRoot(): string {
  return voiceRootOverride ?? join(homedir(), ".messages-mcp", "voice");
}

function assertProfileID(profile: string): void {
  if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(profile)) {
    throw new Error("profile must be a simple profile id");
  }
}

function profileDir(profile: string): string {
  assertProfileID(profile);
  return join(voiceRoot(), profile);
}

function readSmallTextFile(path: string): string | null {
  if (!existsSync(path)) return null;
  const st = statSync(path);
  if (st.size > MAX_PROFILE_FILE_BYTES) {
    throw new Error(`${path} is too large to read as a texting style profile`);
  }
  return readFileSync(path, "utf8");
}

function readSmallJSONFile(path: string): unknown | null {
  const text = readSmallTextFile(path);
  if (text == null) return null;
  return scrubFingerprint(JSON.parse(text));
}

function scrubFingerprint(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(scrubFingerprint);
  }
  if (value == null || typeof value !== "object") {
    return value;
  }
  const out: Record<string, unknown> = {};
  for (const [key, child] of Object.entries(value)) {
    if (key.toLowerCase().includes("handle")) continue;
    out[key] = scrubFingerprint(child);
  }
  return out;
}

export function listVoiceProfiles(): VoiceProfileListEntry[] {
  const root = voiceRoot();
  if (!existsSync(root)) return [];

  return readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^[a-z0-9][a-z0-9-]{0,63}$/.test(entry.name))
    .map((entry) => {
      const dir = join(root, entry.name);
      const guidePath = join(dir, "GUIDE.md");
      const voicePath = join(dir, "VOICE.md");
      const fingerprintPath = join(dir, "fingerprint.json");
      const hasVoice = existsSync(guidePath) || existsSync(voicePath);
      const hasFingerprint = existsSync(fingerprintPath);
      const mtimes = [guidePath, voicePath, fingerprintPath]
        .filter((path) => existsSync(path))
        .map((path) => statSync(path).mtimeMs);
      return {
        profile: entry.name,
        has_voice_md: hasVoice,
        has_fingerprint: hasFingerprint,
        updated_at: mtimes.length > 0 ? new Date(Math.max(...mtimes)).toISOString() : null,
      };
    })
    .filter((entry) => entry.has_voice_md || entry.has_fingerprint)
    .sort((a, b) => {
      if (a.profile === "base") return -1;
      if (b.profile === "base") return 1;
      return a.profile.localeCompare(b.profile);
    });
}

export function getVoiceProfile(profile = "base"): VoiceProfileRead {
  const dir = profileDir(profile);
  const guidePath = join(dir, "GUIDE.md");
  const voicePath = join(dir, "VOICE.md");
  const fingerprintPath = join(dir, "fingerprint.json");
  return {
    profile,
    voice_md: readSmallTextFile(guidePath) ?? readSmallTextFile(voicePath),
    fingerprint: readSmallJSONFile(fingerprintPath),
    paths: {
      directory: dir,
      guide_md: guidePath,
      voice_md: voicePath,
      fingerprint: fingerprintPath,
    },
  };
}
