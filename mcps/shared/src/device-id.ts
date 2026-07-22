// Stable per-machine identity for the cross-device relay (SUN-613).
//
// Ghostie runs on more than one Mac, and every Mac runs TWO independent send
// paths: the Swift `DraftSender` in the menu bar app, and this MCP's
// `send_draft` / `send_whatsapp_draft` tool. Across two Macs that is four
// executor processes, interlocked today only by the per-HOST advisory lock in
// `~/.messages-mcp/locks/` — nothing stops the M1's MCP and the M4's menu bar
// from both firing the same draft.
//
// The relay pins one machine per draft via `relay_executor` on the draft JSON.
// Every send path compares it to the id read here and refuses on a mismatch.
// A gate that covered only the Swift path would not deliver at-most-once, which
// is why this module exists on the TypeScript side at all.
//
// CANONICAL CONTRACT — mirrored byte-for-byte by
// `menubar/Sources/MessagesForAIMenu/DeviceIdentity.swift`:
//   dir   : <home>/.messages-mcp            (0700)
//   file  : device.json                     (0600)
//   body  : {"schema_version":1,"device_id":"<uuid>","label":"<host>"}
//   id    : [A-Za-z0-9-]{8,64}
//
// This is NOT a secret and NOT an authorization token. It says which machine a
// draft belongs to, never that anyone approved it — approval provenance stays
// with the menu bar's Keychain-backed ApprovalAuthenticator.

import { closeSync, existsSync, mkdirSync, openSync, readFileSync, writeSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

export const DEVICE_SCHEMA_VERSION = 1;

/** Test seam mirroring the other storage modules' `MESSAGES_MCP_HOME` override. */
function stateRoot(): string {
  return process.env.MESSAGES_MCP_HOME ?? join(homedir(), ".messages-mcp");
}

function deviceFilePath(): string {
  return join(stateRoot(), "device.json");
}

/** Shape-check an id read off disk. Values outside the alphabet are corrupt,
 *  not coerced: the value is compared against a field another process wrote and
 *  is echoed into error copy. */
export function isValidDeviceId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9-]{8,64}$/.test(value);
}

let cached: string | null = null;

function readExisting(): string | null {
  try {
    const raw = readFileSync(deviceFilePath(), "utf8");
    const parsed = JSON.parse(raw) as { device_id?: unknown };
    return isValidDeviceId(parsed.device_id) ? parsed.device_id : null;
  } catch {
    return null;
  }
}

/** This machine's device id, creating `device.json` on first use.
 *
 *  Returns null when the id can neither be read nor created. Callers MUST treat
 *  null as "cannot prove I am the executor" and fail closed — see
 *  `executorRefusal`. */
export function localDeviceId(): string | null {
  if (cached != null) return cached;

  const existing = readExisting();
  if (existing != null) {
    cached = existing;
    return cached;
  }

  const root = stateRoot();
  try {
    if (!existsSync(root)) mkdirSync(root, { recursive: true, mode: 0o700 });
  } catch {
    return null;
  }

  const id = randomUUID();
  const body = JSON.stringify(
    { schema_version: DEVICE_SCHEMA_VERSION, device_id: id, label: hostname() },
    null,
    2,
  );

  // O_CREAT|O_EXCL so two processes racing on first launch cannot mint two ids
  // for one machine: the loser's create throws EEXIST and it re-reads the
  // winner's file. Matches DeviceIdentity.createIfAbsent on the Swift side.
  let fd: number;
  try {
    fd = openSync(deviceFilePath(), "wx", 0o600);
  } catch {
    const raced = readExisting();
    if (raced != null) cached = raced;
    return raced;
  }
  try {
    writeSync(fd, body);
  } catch {
    return null;
  } finally {
    closeSync(fd);
  }
  cached = id;
  return cached;
}

/** Why this machine may not execute this draft, or null when it may.
 *
 *  One rule, shared by both MCPs and mirrored by `Draft.executorRefusal` in
 *  Swift:
 *    - no stamp             → allowed (every draft that exists today)
 *    - stamp, id unreadable → REFUSED, fail closed
 *    - stamp != local id    → REFUSED, belongs to another Mac
 */
export function executorRefusal(relayExecutor: unknown, local: string | null): string | null {
  const stamped = typeof relayExecutor === "string" ? relayExecutor.trim() : "";
  if (stamped.length === 0) return null;
  if (local == null || !isValidDeviceId(local)) {
    return (
      "WRONG_EXECUTOR: this draft names an executor device, but this machine's device id " +
      "could not be read, so the send is refused rather than risking a duplicate delivery."
    );
  }
  if (stamped !== local) {
    return (
      `WRONG_EXECUTOR: this draft is assigned to device ${stamped}, not this machine ` +
      `(${local}). Only the assigned Mac may send it; approve it there.`
    );
  }
  return null;
}

/** Test seam: drop the memoized id so a case can repoint MESSAGES_MCP_HOME. */
export function resetDeviceIdCacheForTesting(): void {
  cached = null;
}
