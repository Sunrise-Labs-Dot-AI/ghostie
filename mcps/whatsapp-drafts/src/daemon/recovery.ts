// The "this session needs a re-pair" sentinel.
//
// One file, `~/.whatsapp-mcp/LOGGED_OUT`, gates daemon startup: when it exists,
// index.ts keeps the RPC server listening but never constructs Baileys, so the
// menu bar can call `unlinkAndReset` instead of watching the daemon crash-loop.
//
// WHY REUSE `LOGGED_OUT` RATHER THAN ADD A SECOND SENTINEL
//
// There are now two distinct reasons to park — a remote unlink, and auth rows
// that no longer decrypt. A separate `SESSION_UNREADABLE` file would have been
// tidier, but it is not downgrade-safe: an older daemon knows nothing about it,
// would sail past the gate into the same unreadable session, and would resume
// crash-looping with no recovery route in its UI. Older builds DO understand
// `LOGGED_OUT` (they check existence only, and ignore the contents), so writing
// the reason INTO that file degrades correctly: an old build parks and offers
// its existing Reconnect flow, a new build additionally explains the real cause.
//
// Format — line 1 is the original ISO timestamp so nothing about the legacy
// shape changes; subsequent `key=value` lines are additive and optional:
//
//   2026-08-03T04:35:31.000Z
//   reason=session_unreadable
//   detail=6398 of 6399 stored WhatsApp auth rows could not be decrypted...

import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";

import { PATHS } from "../paths.ts";

/** Why the daemon is parked. `logged_out` is also the assumed reason for a
 *  legacy timestamp-only sentinel written by an older build. */
export type RecoveryReason = "logged_out" | "session_unreadable";

export interface RecoveryState {
  reason: RecoveryReason;
  /** Human-readable elaboration for the UI. Empty when unknown (legacy file). */
  detail: string;
}

/** Write (or overwrite) the sentinel. Mode 0600, same as every other file the
 *  daemon owns under `~/.whatsapp-mcp/`. */
export function writeRecoverySentinel(reason: RecoveryReason, detail = ""): void {
  const body =
    `${new Date().toISOString()}\n` +
    `reason=${reason}\n` +
    (detail.length > 0 ? `detail=${detail.replace(/\r?\n/g, " ")}\n` : "");
  writeFileSync(PATHS.loggedOutSentinel, body, { mode: 0o600 });
}

/** Parse the sentinel, or null when the daemon is not parked. */
export function readRecoverySentinel(): RecoveryState | null {
  if (!existsSync(PATHS.loggedOutSentinel)) return null;
  let raw = "";
  try {
    raw = readFileSync(PATHS.loggedOutSentinel, "utf8");
  } catch {
    // Unreadable but present: still parked. Fall back to the legacy meaning
    // rather than pretending the session is healthy.
    return { reason: "logged_out", detail: "" };
  }
  return parseRecoverySentinel(raw);
}

/** Pure parser — exported for tests. A legacy timestamp-only file (no `reason=`
 *  line) means `logged_out`, which is exactly what older builds wrote. */
export function parseRecoverySentinel(raw: string): RecoveryState {
  let reason: RecoveryReason = "logged_out";
  let detail = "";
  for (const line of raw.split("\n")) {
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    const value = line.slice(eq + 1).trim();
    if (key === "reason" && (value === "logged_out" || value === "session_unreadable")) {
      reason = value;
    } else if (key === "detail") {
      detail = value;
    }
  }
  return { reason, detail };
}

/**
 * Remove the sentinel. Throws if the file exists and cannot be removed.
 *
 * The caller MUST NOT proceed to re-pair on a throw: leaving a stale sentinel
 * behind is recoverable (the user retries), but clearing the gate while the
 * underlying state is still broken puts the daemon straight back into the
 * crash-loop this whole mechanism exists to prevent.
 */
export function clearRecoverySentinel(): void {
  if (!existsSync(PATHS.loggedOutSentinel)) return;
  unlinkSync(PATHS.loggedOutSentinel);
}
