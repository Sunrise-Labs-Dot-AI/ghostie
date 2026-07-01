// Cross-process advisory lock for the send-draft critical section.
//
// Issue #88: the duplicate-send guard (read sent_at==null → check daily cap →
// fire AppleScript → mark sent → append audit) is a non-atomic read-modify-
// write shared between TWO processes — the Node MCP server and the Swift menu
// bar app (hold-to-fire). Two concurrent sends of the SAME draft can both read
// sent_at==null and both pass the cap check, then both fire AppleScript →
// duplicate delivery + cap overrun.
//
// This module provides a file-based mutex (O_CREAT|O_EXCL) so the read→fire→
// mark sequence becomes a single atomic transition per draft. The lock is:
//   - per-draft (keyed on draft id) so unrelated sends don't serialize;
//   - cross-process (a plain on-disk file, visible to both Node and Swift);
//   - self-healing (a stale lock from a crashed holder is reclaimed via a
//     PID-liveness + age check, so a crash mid-send can't wedge the draft
//     forever).
//
// The lockfile stores the holder's PID + acquisition time as JSON so a
// reclaiming process can decide whether the lock is genuinely held or orphaned.
//
// NOTE on the Swift side: the menu bar app must acquire the SAME lockfile
// (same path, same O_CREAT|O_EXCL semantics) before its hold-to-fire send for
// the cross-process guarantee to hold. The Swift change is out of scope for
// this MCP-only fix; this module defines the canonical path + format the Swift
// app should mirror. Until then, this still fully serializes concurrent sends
// originating within the Node MCP (the common MCP + MCP race).

import { openSync, closeSync, writeSync, readFileSync, unlinkSync, existsSync, mkdirSync, lstatSync, statSync, constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// O_CREAT|O_EXCL|O_WRONLY — the atomic "create-or-fail" combination. Use the
// platform's real fcntl values from node:fs `constants` rather than hardcoded
// Darwin numbers, so the O_EXCL create semantics are correct off macOS too
// (e.g. Linux CI). On macOS these resolve to the identical bitmask as before.
const O_CREAT = constants.O_CREAT;
const O_EXCL = constants.O_EXCL;
const O_WRONLY = constants.O_WRONLY;

// A lock older than this is considered stale (its holder crashed without
// releasing). Generous relative to a send (AppleScript send timeout is 20s) so
// a slow-but-live send is never stolen out from under itself.
export const LOCK_TTL_MS = 60_000;

let testDirOverride: string | null = null;

/** @internal test seam — redirect the lock dir without touching $HOME. */
export function _setLockDirForTesting(dir: string | null): void {
  testDirOverride = dir;
}

function lockDirPath(): string {
  return testDirOverride ?? join(homedir(), ".messages-mcp", "locks");
}

function ensureDir(): void {
  const d = lockDirPath();
  // Symlink defense, parallel to storage/drafts.ts: refuse if the lock dir
  // itself is a symlink (a same-UID attacker could redirect our O_EXCL create
  // elsewhere). We don't walk past the immediate dir.
  if (existsSync(d)) {
    if (lstatSync(d).isSymbolicLink()) {
      throw new Error(`lock directory is a symlink, refusing to use: ${d}`);
    }
    return;
  }
  mkdirSync(d, { recursive: true });
}

function lockPath(key: string): string {
  // Sanitize the key into a filename. Draft ids are UUIDs, but be defensive.
  const safe = key.replace(/[^a-zA-Z0-9._-]/g, "_");
  return join(lockDirPath(), `${safe}.lock`);
}

interface LockMeta {
  pid: number;
  acquired_at: number; // epoch ms
}

// Is a process with this PID alive? `process.kill(pid, 0)` throws ESRCH if not,
// EPERM if it exists but we can't signal it (still "alive" for our purposes).
function pidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

// Age of the lockfile on disk (ms since its mtime), or null if it can't be
// stat'd (already gone / racing unlink). Used as the fallback staleness signal
// when the metadata is missing/corrupt.
function fileAgeMs(path: string): number | null {
  try {
    return Date.now() - statSync(path).mtimeMs;
  } catch {
    return null;
  }
}

// Try to reclaim a stale lock. Returns true if the existing lock was removed
// (caller should retry the O_EXCL create), false if it's genuinely held.
//
// Issue #88 (round 2): there is a window between the O_EXCL create and the
// metadata write where the lockfile exists but is EMPTY (or partially written /
// unparseable). The old code treated any unreadable/corrupt/empty lock as
// IMMEDIATELY reclaimable, so a contender could steal a lock the winner had
// just created microseconds earlier — re-opening the duplicate-send race the
// lock exists to close. Fix: a lock with valid metadata is reclaimed only when
// its holder PID is dead OR its acquired_at is past TTL (unchanged). A lock
// WITHOUT usable metadata (empty/corrupt/unreadable) is NOT reclaimed on sight;
// it is reclaimed ONLY if the file's mtime age exceeds LOCK_TTL_MS. A genuine
// holder writes its metadata within microseconds, so a corrupt-but-young file
// is respected (we lose the lock to the live holder, which is correct), and a
// genuinely-orphaned corrupt file is still eventually reclaimed once it ages out.
function tryReclaim(path: string): boolean {
  let meta: LockMeta | null = null;
  try {
    const raw = readFileSync(path, "utf8");
    // An empty file is the just-created-but-not-yet-written state; treat it as
    // "no usable metadata" so it falls into the age-only branch below rather
    // than being parsed (JSON.parse("") throws anyway).
    meta = raw.trim().length === 0 ? null : (JSON.parse(raw) as LockMeta);
  } catch {
    meta = null; // unreadable/corrupt lock — fall to the age-only check
  }

  let stale: boolean;
  if (meta == null || !Number.isFinite(meta.acquired_at) || !Number.isInteger(meta.pid)) {
    // No usable metadata. Do NOT reclaim immediately — that's the empty-file
    // race. Only reclaim if the file itself has aged past TTL.
    const age = fileAgeMs(path);
    stale = age != null && age > LOCK_TTL_MS;
  } else {
    // Valid metadata: dead holder or past-TTL acquisition → stale.
    stale = !pidAlive(meta.pid) || Date.now() - meta.acquired_at > LOCK_TTL_MS;
  }

  if (!stale) return false;
  try {
    unlinkSync(path);
    return true;
  } catch {
    // Someone else unlinked/replaced it between our read and unlink — let the
    // caller's retry sort it out.
    return false;
  }
}

export interface SendLock {
  release(): void;
}

/**
 * Acquire the per-key send lock, or return null if it's currently held by a
 * live holder. Non-blocking: the send path treats "held" as "another send is
 * already in flight for this draft" and refuses rather than queuing.
 */
export function acquireSendLock(key: string): SendLock | null {
  ensureDir();
  const path = lockPath(key);
  const meta: LockMeta = { pid: process.pid, acquired_at: Date.now() };

  for (let attempt = 0; attempt < 2; attempt++) {
    let fd: number;
    try {
      fd = openSync(path, O_CREAT | O_EXCL | O_WRONLY, 0o600);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "EEXIST") {
        // Someone holds it (or it's stale). Try to reclaim once, then retry.
        if (attempt === 0 && tryReclaim(path)) continue;
        return null;
      }
      throw e;
    }
    try {
      writeSync(fd, JSON.stringify(meta));
    } finally {
      closeSync(fd);
    }
    let released = false;
    return {
      release(): void {
        if (released) return;
        released = true;
        try {
          // Only remove the lock if it's still OURS — guard against deleting a
          // lock a different process reclaimed after we (somehow) overran TTL.
          const cur = JSON.parse(readFileSync(path, "utf8")) as LockMeta;
          if (cur.pid !== process.pid || cur.acquired_at !== meta.acquired_at) return;
        } catch {
          // Unreadable/already gone — fall through to best-effort unlink.
        }
        try { unlinkSync(path); } catch { /* best-effort */ }
      },
    };
  }
  return null;
}

/**
 * Run `fn` while holding the per-key send lock. Throws SendLockHeldError if the
 * lock can't be acquired (a concurrent send is in flight). Always releases in a
 * finally.
 */
export async function withSendLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const lock = acquireSendLock(key);
  if (lock == null) {
    throw new SendLockHeldError(key);
  }
  try {
    return await fn();
  } finally {
    lock.release();
  }
}

export class SendLockHeldError extends Error {
  constructor(public readonly key: string) {
    super(
      `a send is already in flight for draft ${key} (cross-process send lock held) — ` +
      `refusing a concurrent send to avoid duplicate delivery`
    );
    this.name = "SendLockHeldError";
  }
}
