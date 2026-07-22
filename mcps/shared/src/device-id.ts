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

import {
  closeSync,
  constants as fsConstants,
  fstatSync,
  linkSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeSync,
  fsyncSync,
  existsSync,
} from "node:fs";
import { homedir, hostname, userInfo } from "node:os";
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

/** Read the id through a verified descriptor rather than a path.
 *
 *  `device.json` decides which drafts this machine may send, so a local process
 *  that can swap it for a symlink to attacker-controlled JSON could make this
 *  Mac answer to another Mac's id and duplicate-send its drafts. Path-following
 *  reads (`readFileSync`) walk that symlink happily. So: O_NOFOLLOW, then
 *  fstat the descriptor we actually opened and require a regular file owned by
 *  us with no group/other access. The parent is checked the same way, mirroring
 *  the existing `ensureDir` symlink guard in the iMessage drafts storage.
 *  (Second-lane review, finding 7.) */
function readExisting(): string | null {
  const root = stateRoot();
  try {
    if (lstatSync(root).isSymbolicLink()) return null;
  } catch {
    return null; // missing parent: nothing to read, and creation will make it
  }

  let fd: number;
  try {
    fd = openSync(deviceFilePath(), fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  } catch {
    return null;
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile()) return null;
    if (st.uid !== userInfo().uid) return null;
    if ((st.mode & 0o077) !== 0) return null; // group/other access → not ours to trust
    const parsed = JSON.parse(readFileSync(fd, "utf8")) as {
      device_id?: unknown;
      schema_version?: unknown;
    };
    if (parsed.schema_version !== DEVICE_SCHEMA_VERSION) return null;
    return isValidDeviceId(parsed.device_id) ? parsed.device_id : null;
  } catch {
    return null;
  } finally {
    closeSync(fd);
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

  // Write-then-publish rather than create-then-fill.
  //
  // `O_CREAT|O_EXCL` alone stops two successful creates, but it publishes the
  // final path BEFORE the contents exist: a racing reader sees an empty file,
  // and a crash mid-write leaves a permanently empty `device.json` that every
  // future create refuses to replace, wedging stamped sends forever. So build a
  // complete, fsynced private file first, then publish it with `link`, which is
  // atomic and fails if the name already exists. The loser of the race unlinks
  // its temp and reads the winner's file. (Second-lane review, finding 8.)
  const finalPath = deviceFilePath();
  const tempPath = join(root, `.device.json.${process.pid}.${randomUUID()}.tmp`);

  let fd: number;
  try {
    fd = openSync(tempPath, "wx", 0o600);
  } catch {
    return null;
  }
  try {
    const payload = Buffer.from(body, "utf8");
    let written = 0;
    while (written < payload.length) {
      // Short writes are legal; ignoring the byte count can publish a truncated
      // identity that parses as valid-looking garbage.
      const n = writeSync(fd, payload, written, payload.length - written);
      if (n <= 0) throw new Error("short write");
      written += n;
    }
    fsyncSync(fd);
  } catch {
    closeSync(fd);
    rmSync(tempPath, { force: true });
    return null;
  }
  closeSync(fd);

  try {
    linkSync(tempPath, finalPath);
  } catch {
    // Lost the race, or cannot publish. Either way the authority is whatever is
    // on disk now.
    rmSync(tempPath, { force: true });
    const raced = readExisting();
    if (raced != null) cached = raced;
    return raced;
  }
  try {
    unlinkSync(tempPath);
  } catch {
    /* temp already gone; the published file is what matters */
  }

  cached = id;
  return cached;
}

/** Why this machine may not execute this draft, or null when it may.
 *
 *  One rule, shared by both MCPs and mirrored EXACTLY by
 *  `Draft.executorRefusal` in Swift. A divergence between the two is a
 *  duplicate send, so the case table is written out explicitly:
 *
 *    absent / JSON null      → allowed. The legacy shape: every draft written
 *                              before this field existed, and every draft the
 *                              relay has not routed.
 *    present but unusable    → REFUSED. Wrong JSON type, empty, whitespace, or
 *                              outside the device-id alphabet. Routing data we
 *                              cannot parse is a reason to stop, not to guess.
 *    local id unreadable     → REFUSED. "I can't prove I own this" must never
 *                              resolve to "so I'll send it".
 *    stamp != local id       → REFUSED. Belongs to another Mac.
 *    stamp == local id       → allowed.
 *
 *  The earlier version of this function coerced every non-string to "" and
 *  treated that as unstamped, so `"relay_executor": 42` FAILED OPEN on both MCP
 *  paths while Swift refused the same file. Second-lane review, finding 6.
 */
export function executorRefusal(relayExecutor: unknown, local: string | null): string | null {
  if (relayExecutor === undefined || relayExecutor === null) return null;

  if (typeof relayExecutor !== "string") {
    return (
      "WRONG_EXECUTOR: this draft's executor assignment is not a string, so it cannot be " +
      "verified. Refusing the send rather than treating unparseable routing data as unrouted."
    );
  }
  const stamped = relayExecutor.trim();
  if (stamped.length === 0 || !isValidDeviceId(stamped)) {
    return (
      "WRONG_EXECUTOR: this draft's executor assignment is present but malformed, so it " +
      "cannot be verified. Refusing the send rather than guessing which Mac owns it."
    );
  }
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
