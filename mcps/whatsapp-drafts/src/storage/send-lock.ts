// Cross-process advisory lock for the send-draft critical section.
//
// Issue #88: the duplicate-send guard (read sent_at==null → approve → check
// caps → fire send → mark sent) is a non-atomic read-modify-write shared
// across THREE processes: the WhatsApp MCP server, the Swift menu bar app
// (hold-to-fire), and any second MCP instance (Claude Desktop + Claude Code
// both load the MCP). All of those funnel a send for the SAME draft into the
// daemon's `sendDraft`; two that race can both observe sent_at==null and both
// fire Baileys → duplicate delivery + rate-limit overrun.
//
// This module provides a file-based mutex (O_CREAT|O_EXCL) so the
// approve→send→mark sequence becomes a single atomic transition per draft.
// The lock is acquired by the *initiators* (the MCP send tool and the Swift
// menu-bar send) BEFORE they call the daemon — NOT inside the daemon — so the
// Swift and Node initiators serialize against each other without the daemon
// also grabbing the file (which would deadlock against a Swift holder). The
// lock is:
//   - per-draft (keyed on draft id) so unrelated sends don't serialize;
//   - cross-process (a plain on-disk file, visible to Node and Swift);
//   - self-healing (a stale lock from a crashed holder is reclaimed via a
//     PID-liveness + age check, so a crash mid-send can't wedge the draft
//     forever).
//
// IMPORTANT — the lock dir is the SHARED ~/.messages-mcp/locks, NOT the
// WhatsApp daemon's ~/.whatsapp-mcp home. Both the iMessage MCP
// (mcps/imessage-drafts/src/storage/send-lock.ts) and this WhatsApp MCP use
// the same directory + the same {pid, acquired_at} JSON payload + the same 60s
// TTL so a single canonical lockfile path serves all platforms. Draft ids are
// UUIDs, so iMessage and WhatsApp keys never collide. The Swift menu bar app
// (menubar/Sources/MessagesForAIMenu/SendLock.swift) mirrors this exact format
// — if the two ever diverge, duplicate sends become possible again.

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
// releasing). Generous relative to a send (Baileys send + daemon RPC) so a
// slow-but-live send is never stolen out from under itself. Must match
// LOCK_TTL_MS in the iMessage send-lock.ts and ttlMs in SendLock.swift.
const LOCK_TTL_MS = 60_000;

let testDirOverride: string | null = null;

/** @internal test seam — redirect the lock dir without touching $HOME. */
export function _setLockDirForTesting(dir: string | null): void {
  testDirOverride = dir;
}

function lockDirPath(): string {
  // Deliberately ~/.messages-mcp/locks (the shared dir), NOT ~/.whatsapp-mcp.
  return testDirOverride ?? join(homedir(), ".messages-mcp", "locks");
}

function ensureDir(): void {
  const d = lockDirPath();
  // Symlink defense, parallel to the iMessage side: refuse if the lock dir
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

// Age (ms) of a lockfile by mtime, or null if it can't be stat'd.
function lockFileAgeMs(path: string): number | null {
  try {
    const st = statSync(path);
    return Date.now() - st.mtimeMs;
  } catch {
    return null;
  }
}

// Try to reclaim a stale lock. Returns true if the existing lock was removed
// (caller should retry the O_EXCL create), false if it's genuinely held.
//
// #88 empty-file reclaim race: there's a window between the O_EXCL create and
// the metadata write where the lockfile is EMPTY (zero bytes / unparseable).
// The earlier code treated any unreadable/corrupt/empty lock as immediately
// reclaimable, so a contender could steal a lock the owner had JUST created but
// not yet written. Fix: a lock we can't parse is reclaimed ONLY if its file
// mtime age exceeds LOCK_TTL_MS — a genuinely abandoned corpse. A young
// unparseable lock is a just-created one mid-write, so we RESPECT it (return
// false). A parseable lock keeps the original pid-liveness + acquired_at TTL
// checks.
function tryReclaim(path: string): boolean {
  let meta: LockMeta | null = null;
  let parseable = false;
  try {
    const raw = readFileSync(path, "utf8");
    meta = JSON.parse(raw) as LockMeta;
    parseable = true;
  } catch {
    meta = null; // unreadable / corrupt / empty (mid-write) lock
    parseable = false;
  }

  let stale: boolean;
  if (!parseable || meta == null) {
    // Empty/corrupt: could be a lock created microseconds ago whose owner
    // hasn't written its metadata yet. Only reclaim if it's older than the TTL
    // by mtime; otherwise respect it (the owner is mid-create).
    const age = lockFileAgeMs(path);
    // If we can't stat it, it likely just vanished — let the caller's retry
    // re-attempt the O_EXCL create rather than unlinking blind.
    stale = age != null && age > LOCK_TTL_MS;
  } else {
    stale =
      !pidAlive(meta.pid) ||
      !Number.isFinite(meta.acquired_at) ||
      Date.now() - meta.acquired_at > LOCK_TTL_MS;
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
