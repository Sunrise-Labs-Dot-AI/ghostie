// The reset path has to guarantee ONE socket and ALWAYS settle.
//
// Both were broken in the first cut of this work:
//   - a reconnect queued before the reset fired after it, calling connect()
//     directly and bypassing the teardown, so two sockets shared one auth store;
//   - teardown awaited Baileys' end() with no timeout, and since the reset
//     promise is shared for coalescing, one lost close event would wedge every
//     future reset permanently.

import { describe, expect, test } from "bun:test";

import { performUnlinkAndReset } from "./server.ts";

/** Minimal stand-in with the surface performUnlinkAndReset touches. */
function makeConnection(opts: {
  prepareDelayMs?: number;
  prepareThrows?: boolean;
  startThrows?: boolean;
} = {}) {
  const calls: string[] = [];
  return {
    calls,
    async prepareForReset(): Promise<void> {
      calls.push("prepare");
      if (opts.prepareDelayMs != null) {
        await new Promise((r) => setTimeout(r, opts.prepareDelayMs));
      }
      if (opts.prepareThrows === true) throw new Error("teardown exploded");
    },
    async start(): Promise<void> {
      calls.push("start");
      if (opts.startThrows === true) throw new Error("connect exploded");
    },
  };
}

describe("performUnlinkAndReset ordering", () => {
  test("quiesces the socket BEFORE starting a new one", async () => {
    const conn = makeConnection();
    const result = await performUnlinkAndReset(conn as never);

    expect(result.ok).toBe(true);
    // deleteSession + sentinel clearing happen between these two, but the
    // relative order of prepare→start is what prevents a double socket.
    expect(conn.calls).toEqual(["prepare", "start"]);
  });

  test("a failed teardown aborts without starting a socket", async () => {
    const conn = makeConnection({ prepareThrows: true });
    const result = await performUnlinkAndReset(conn as never);

    expect(result.ok).toBe(false);
    expect(conn.calls).not.toContain("start");
  });

  test("reports a failure to reconnect rather than claiming success", async () => {
    const conn = makeConnection({ startThrows: true });
    const result = await performUnlinkAndReset(conn as never);

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatch(/reconnecting failed/i);
  });
});

describe("performUnlinkAndReset coalescing", () => {
  test("two concurrent resets run the work once", async () => {
    const conn = makeConnection({ prepareDelayMs: 25 });

    const [a, b] = await Promise.all([
      performUnlinkAndReset(conn as never),
      performUnlinkAndReset(conn as never),
    ]);

    expect(a).toEqual(b);
    expect(conn.calls.filter((c) => c === "start")).toHaveLength(1);
  });

  // The coalescing lock must clear on every path. If a failed reset left it
  // set, every later attempt would resolve to the same stale failure and
  // recovery would be permanently disabled.
  test("the lock clears after a failure, so a retry can succeed", async () => {
    const failing = makeConnection({ startThrows: true });
    const first = await performUnlinkAndReset(failing as never);
    expect(first.ok).toBe(false);

    const healthy = makeConnection();
    const second = await performUnlinkAndReset(healthy as never);
    expect(second.ok).toBe(true);
    expect(healthy.calls).toEqual(["prepare", "start"]);
  });

  test("the lock clears after success too", async () => {
    const conn = makeConnection();
    await performUnlinkAndReset(conn as never);
    await performUnlinkAndReset(conn as never);

    expect(conn.calls.filter((c) => c === "start")).toHaveLength(2);
  });
});
