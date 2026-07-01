import { describe, test, expect, beforeAll, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, existsSync, writeFileSync, readFileSync, readdirSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as lock from "./send-lock.ts";
import { LOCK_TTL_MS } from "./send-lock.ts";

const tmpDir = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-lock-test-"));

beforeAll(() => {
  lock._setLockDirForTesting(tmpDir);
});

afterAll(() => {
  lock._setLockDirForTesting(null);
  rmSync(tmpDir, { recursive: true, force: true });
});

beforeEach(() => {
  // Clear any lockfiles between tests.
  for (const f of existsSync(tmpDir) ? readdirSync(tmpDir) : []) {
    rmSync(join(tmpDir, f), { force: true });
  }
});

describe("acquireSendLock (issue #88)", () => {
  test("first acquire wins; second acquire on the same key returns null", () => {
    const a = lock.acquireSendLock("draft-1");
    expect(a).not.toBeNull();
    const b = lock.acquireSendLock("draft-1");
    expect(b).toBeNull();
    a!.release();
  });

  test("different keys don't serialize", () => {
    const a = lock.acquireSendLock("draft-A");
    const b = lock.acquireSendLock("draft-B");
    expect(a).not.toBeNull();
    expect(b).not.toBeNull();
    a!.release();
    b!.release();
  });

  test("after release, the key can be acquired again", () => {
    const a = lock.acquireSendLock("draft-2");
    a!.release();
    const b = lock.acquireSendLock("draft-2");
    expect(b).not.toBeNull();
    b!.release();
  });

  test("release is idempotent and doesn't throw on double-release", () => {
    const a = lock.acquireSendLock("draft-3");
    expect(() => { a!.release(); a!.release(); }).not.toThrow();
  });

  test("a stale lock (dead PID) is reclaimed", () => {
    // Hand-write a lockfile owned by a PID that doesn't exist. PID 999999 is
    // almost certainly not running.
    const lockFile = join(tmpDir, "draft-stale.lock");
    writeFileSync(lockFile, JSON.stringify({ pid: 999999, acquired_at: Date.now() }), { mode: 0o600 });
    const a = lock.acquireSendLock("draft-stale");
    expect(a).not.toBeNull(); // reclaimed
    a!.release();
  });

  test("a stale lock (old timestamp, live PID) is reclaimed", () => {
    // Our own PID is alive, but the lock is way past TTL — treat as orphaned.
    const lockFile = join(tmpDir, "draft-old.lock");
    writeFileSync(
      lockFile,
      JSON.stringify({ pid: process.pid, acquired_at: Date.now() - 10 * 60_000 }),
      { mode: 0o600 }
    );
    const a = lock.acquireSendLock("draft-old");
    expect(a).not.toBeNull();
    a!.release();
  });

  // Issue #88 round 2: a corrupt/empty lockfile is NO LONGER reclaimed on
  // sight. Only an AGED-OUT corrupt file is reclaimable; a young one is the
  // just-created-not-yet-written window and must be respected.
  test("a YOUNG corrupt lockfile is NOT reclaimed (empty-file race window)", () => {
    const lockFile = join(tmpDir, "draft-corrupt-young.lock");
    writeFileSync(lockFile, "{not json", { mode: 0o600 });
    // mtime is now → within TTL → must be respected, not stolen.
    const a = lock.acquireSendLock("draft-corrupt-young");
    expect(a).toBeNull();
  });

  test("a YOUNG empty lockfile is NOT reclaimed (just-created, metadata pending)", () => {
    // Exactly the race the fix targets: a contender hits the lockfile in the
    // microsecond window between O_EXCL create and the metadata write. The
    // file is empty and young → the contender must back off.
    const lockFile = join(tmpDir, "draft-empty-young.lock");
    writeFileSync(lockFile, "", { mode: 0o600 });
    const a = lock.acquireSendLock("draft-empty-young");
    expect(a).toBeNull();
  });

  test("an AGED-OUT corrupt lockfile IS reclaimed (genuine orphan)", () => {
    const lockFile = join(tmpDir, "draft-corrupt-old.lock");
    writeFileSync(lockFile, "{not json", { mode: 0o600 });
    // Backdate the mtime well past TTL so the age-only branch reclaims it.
    const past = new Date(Date.now() - 10 * LOCK_TTL_MS);
    utimesSync(lockFile, past, past);
    const a = lock.acquireSendLock("draft-corrupt-old");
    expect(a).not.toBeNull();
    a!.release();
  });

  test("an AGED-OUT empty lockfile IS reclaimed (genuine orphan)", () => {
    const lockFile = join(tmpDir, "draft-empty-old.lock");
    writeFileSync(lockFile, "", { mode: 0o600 });
    const past = new Date(Date.now() - 10 * LOCK_TTL_MS);
    utimesSync(lockFile, past, past);
    const a = lock.acquireSendLock("draft-empty-old");
    expect(a).not.toBeNull();
    a!.release();
  });

  test("a fresh lock held by a LIVE PID is NOT reclaimed", () => {
    // Simulate another live holder (our own PID, recent timestamp). The second
    // acquire must fail — this is the real concurrent-send case.
    const lockFile = join(tmpDir, "draft-held.lock");
    writeFileSync(
      lockFile,
      JSON.stringify({ pid: process.pid, acquired_at: Date.now() }),
      { mode: 0o600 }
    );
    const a = lock.acquireSendLock("draft-held");
    expect(a).toBeNull();
  });

  test("release only removes the lock if it's still ours", () => {
    const a = lock.acquireSendLock("draft-owner");
    expect(a).not.toBeNull();
    // A different process reclaims it (overwrites with a new owner).
    const lockFile = join(tmpDir, "draft-owner.lock");
    writeFileSync(lockFile, JSON.stringify({ pid: 999998, acquired_at: Date.now() }), { mode: 0o600 });
    a!.release();
    // Our release must NOT have deleted the other owner's lock.
    expect(existsSync(lockFile)).toBe(true);
    const meta = JSON.parse(readFileSync(lockFile, "utf8")) as { pid: number };
    expect(meta.pid).toBe(999998);
  });
});

describe("withSendLock (issue #88)", () => {
  test("runs fn while holding the lock, then releases", async () => {
    let ranInside = false;
    await lock.withSendLock("draft-w1", async () => {
      ranInside = true;
      // Inside the section, a re-acquire must fail.
      expect(lock.acquireSendLock("draft-w1")).toBeNull();
    });
    expect(ranInside).toBe(true);
    // After, it's free again.
    const a = lock.acquireSendLock("draft-w1");
    expect(a).not.toBeNull();
    a!.release();
  });

  test("releases even when fn throws", async () => {
    await expect(
      lock.withSendLock("draft-w2", async () => { throw new Error("boom"); })
    ).rejects.toThrow("boom");
    const a = lock.acquireSendLock("draft-w2");
    expect(a).not.toBeNull();
    a!.release();
  });

  test("a concurrent withSendLock on the same key throws SendLockHeldError", async () => {
    let resolveOuter: () => void = () => {};
    const outerHolding = new Promise<void>((r) => { resolveOuter = r; });
    const outer = lock.withSendLock("draft-w3", async () => {
      // Hold the lock until the inner attempt has run.
      await outerHolding;
    });
    // While outer holds it, an inner acquire must be refused.
    await expect(
      lock.withSendLock("draft-w3", async () => { /* unreachable */ })
    ).rejects.toBeInstanceOf(lock.SendLockHeldError);
    resolveOuter();
    await outer;
  });
});

// The integration property the issue cares about: two concurrent "send"
// attempts for ONE draft, where the side-effect (an AppleScript fire) is
// modeled by an incrementing counter. Only ONE must fire.
describe("concurrent single-draft send simulation (issue #88)", () => {
  test("only one of two concurrent sends performs the side effect", async () => {
    let fires = 0;
    let sentAt: string | null = null;

    // Models the send_draft critical section: read sent_at → (if null) fire →
    // mark sent. Without the lock, two interleaved runners both see null and
    // both fire. With the lock, the second runner is refused.
    async function attemptSend(): Promise<"fired" | "refused" | "already-sent"> {
      const acquired = lock.acquireSendLock("the-draft");
      if (acquired == null) return "refused";
      try {
        if (sentAt != null) return "already-sent";
        // simulate AppleScript latency so the two attempts genuinely overlap
        await new Promise((r) => setTimeout(r, 20));
        fires++;
        sentAt = new Date().toISOString();
        return "fired";
      } finally {
        acquired.release();
      }
    }

    const results = await Promise.all([attemptSend(), attemptSend()]);
    expect(fires).toBe(1);
    expect(results.filter((r) => r === "fired").length).toBe(1);
    // The loser is either refused (lock held) or already-sent (acquired after
    // the winner released, then saw sentAt set) — both are safe outcomes.
    expect(results.filter((r) => r === "fired" ? false : true).length).toBe(1);
  });
});
