import { describe, expect, test } from "bun:test";

import { getPeerStartTime } from "./peer-pid.ts";

const NON_MACOS = process.platform !== "darwin" || process.env.GHOSTIE_FORCE_NON_DARWIN === "1";

// Issue #79: PID-reuse detection reads the peer process's kernel start time
// (proc_pidinfo / pbi_start_tvsec) before and after the codesign check; a
// changed value means the PID was recycled mid-auth. These tests exercise the
// FFI read against this very test process (a PID we know exists).
describe.skipIf(NON_MACOS)("getPeerStartTime (PID-reuse detection — issue #79)", () => {
  test("returns a stable, non-null start time for the current process", () => {
    const a = getPeerStartTime(process.pid);
    expect(a).not.toBeNull();
    // Stable across calls for the same incarnation — this is the property the
    // before/after recheck relies on.
    const b = getPeerStartTime(process.pid);
    expect(b).toBe(a);
  });

  test("the start time looks like '<sec>.<usec>' with a plausible epoch second", () => {
    const s = getPeerStartTime(process.pid)!;
    expect(s).toMatch(/^\d+\.\d+$/);
    const sec = Number(s.split(".")[0]);
    // Process started after 2015 and not in the future — sanity bound that the
    // struct offset is right (a wrong offset reads garbage, not ~1.7e9).
    expect(sec).toBeGreaterThan(1_400_000_000);
    expect(sec).toBeLessThan(Math.floor(Date.now() / 1000) + 5);
  });

  test("returns null for a PID that doesn't exist", () => {
    // PID 0 is the kernel/swapper; proc_pidinfo(PROC_PIDTBSDINFO) can't return
    // a normal bsdinfo struct for it, so we expect a null (fail-closed) read.
    expect(getPeerStartTime(0)).toBeNull();
  });
});
