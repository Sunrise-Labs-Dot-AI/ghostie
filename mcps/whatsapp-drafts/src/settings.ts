// User-editable settings at ~/.whatsapp-mcp/settings.json.
//
// Validated by Zod on EVERY read (no cache). Fail-closed: a corrupt or
// missing-but-permission-denied settings file → sends refused. A
// genuinely missing file → defaults written and used (first run is fine).
//
// Why no cache: the user may toggle `require_approval` mid-session.
// Re-reading on every send is cheap (one small JSON file) and the
// surprise factor of caching is worse than the cost.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { z } from "zod";

import { PATHS } from "./paths.ts";

// SECURITY (issue #78): the stage→send handoff window (min_staged_age_ms) is a
// load-bearing part of the approval model — it forces a multi-turn gap between
// staging and sending so a single injected agent turn can't stage + immediately
// send. settings.json is a same-UID-writable file, so an attacker (or an
// injected agent with shell access) must NOT be able to set this floor to 0 and
// remove the gate. The schema below accepts >=0 (so a legacy `0` doesn't
// fail-closed and brick all sends), and readSettings() clamps the EFFECTIVE
// value UP to HARD_MIN_STAGED_AGE_MS: `0` (and any sub-floor value) means "use
// the floor", NEVER "disabled". Mirrors the iMessage hardening in
// imessage-drafts/src/tools/drafts.ts (minDraftAgeMs) + audit.ts (dailySendCap).
//
// The daily_cap below stays `.positive()` (>= 1) so a `0` is rejected outright
// (fail-closed: sends refused), which is strictly safer than "disabled" — it
// can only ever tighten the breaker, never turn it off. `.max(10_000)` caps the
// ceiling so an attacker can't raise it to effectively-infinite. Both bounds
// are enforced by Zod; a value outside them throws SettingsError (fail-closed).
const HARD_MIN_STAGED_AGE_MS = 1000;

export const SettingsSchema = z.object({
  /** When true, MCP-side send is blocked entirely; only the menu bar
   *  app's hold-to-fire path can flip a draft to `approved`. */
  require_approval: z.boolean().default(true),

  /** Max sends per UTC day. `.positive()` (>= 1) makes this non-disablable:
   *  a `0` or negative throws (fail-closed), never disables the breaker. */
  daily_cap: z.number().int().positive().max(10_000).default(50),

  /** Minimum age (ms) a draft must be before it can be sent. Forces a
   *  multi-turn hand-off; defeats single-turn stage+send attacks. The schema
   *  accepts >=0, but readSettings() clamps the effective value up to
   *  HARD_MIN_STAGED_AGE_MS — `0` means "use the floor", not "disabled". */
  min_staged_age_ms: z.number().int().min(0).max(60 * 60 * 1000).default(5000),

  /** Minimum delay between consecutive sends (ms), with ±500ms jitter
   *  applied at send time. Defeats bursty automated-client patterns. */
  min_inter_send_ms: z.number().int().min(0).max(60 * 1000).default(2000),

  /** Max sends in any rolling 60s window. */
  max_burst_in_60s: z.number().int().positive().max(1000).default(5),

  /** Drafts older than this are swept by the daemon's hourly cron. */
  draft_ttl_days: z.number().int().positive().max(365).default(7),

  /** Messages in messages.db older than this are swept daily at 03:00. */
  message_retention_days: z.number().int().positive().max(3650).default(90),
}).strict();

export type Settings = z.infer<typeof SettingsSchema>;

/** Defaults — exported so callers can reason about what 'fresh' looks like. */
export const DEFAULT_SETTINGS: Settings = SettingsSchema.parse({});

export class SettingsError extends Error {
  constructor(message: string, public path: string) {
    super(message);
    this.name = "SettingsError";
  }
}

/**
 * Read settings. Returns parsed object or throws SettingsError.
 *
 * - File missing → write defaults, return them
 * - File present but unreadable (perm denied, IO error) → throw
 * - File present but malformed JSON → throw
 * - File present, valid JSON, schema mismatch → throw with detail
 */
export function readSettings(): Settings {
  const path = PATHS.settingsJson;
  if (!existsSync(path)) {
    writeFileSync(path, JSON.stringify(DEFAULT_SETTINGS, null, 2), { mode: 0o600 });
    return DEFAULT_SETTINGS;
  }
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (e) {
    throw new SettingsError(`could not read ${path}: ${(e as Error).message}`, path);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    throw new SettingsError(`${path}: invalid JSON — ${(e as Error).message}`, path);
  }
  const result = SettingsSchema.safeParse(parsed);
  if (!result.success) {
    const messages = result.error.errors
      .map((e) => `${e.path.join(".")}: ${e.message}`)
      .join("; ");
    throw new SettingsError(`${path}: schema validation failed — ${messages}`, path);
  }
  return clampFloors(result.data);
}

/**
 * Clamp the security-critical send floors to their hard minimums (issue #78).
 * Currently only min_staged_age_ms: `0` (or any sub-floor value) collapses to
 * HARD_MIN_STAGED_AGE_MS so the stage→send handoff window can never be removed
 * by a settings.json write. daily_cap / max_burst are already non-disablable
 * via their `.positive()` schema bound, so they need no clamp here.
 */
function clampFloors(s: Settings): Settings {
  return {
    ...s,
    min_staged_age_ms: Math.max(HARD_MIN_STAGED_AGE_MS, s.min_staged_age_ms),
  };
}

/** Test seam: tests may pre-write a settings file in a temp dir. */
export function writeSettings(s: Settings): void {
  writeFileSync(PATHS.settingsJson, JSON.stringify(s, null, 2), { mode: 0o600 });
}
