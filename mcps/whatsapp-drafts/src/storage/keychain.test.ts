import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Ensure the test-key short-circuit is OFF so getOrCreateMasterKey exercises
// the real `security` argv-building path (through the injected runner). Saved
// and restored so other test files that rely on it aren't disturbed.
const savedTestKey = process.env.WHATSAPP_MCP_TEST_KEY;
delete process.env.WHATSAPP_MCP_TEST_KEY;

const {
  getOrCreateMasterKey,
  deleteMasterKey,
  migrateKeychainAcl,
  _setSecurityRunnerForTesting,
  _setMigrationMarkerPathForTesting,
} = await import("./keychain.ts");

// A fresh marker dir per file so the one-time ACL migration (#82) is
// deterministic — each test controls whether the marker is "already migrated".
const markerDir = mkdtempSync(join(tmpdir(), "whatsapp-mcp-keychain-marker-"));
function freshMarker(): string {
  return join(markerDir, `marker-${Math.random().toString(36).slice(2)}`);
}

interface Call {
  bin: string;
  args: string[];
  stdin?: string;
}

function makeRunner(opts: {
  existing?: Buffer | null;
}) {
  const calls: Call[] = [];
  // A tiny in-memory keychain keyed by service+account.
  let stored: Buffer | null = opts.existing ?? null;

  const runner = (bin: string, args: string[], stdin?: string) => {
    calls.push({ bin, args, stdin });
    const sub = args[0];
    const ok = (out = ""): { exitCode: number; stdout: Uint8Array; stderr: Uint8Array } => ({
      exitCode: 0,
      stdout: new TextEncoder().encode(out),
      stderr: new Uint8Array(),
    });
    const fail = (code: number) => ({
      exitCode: code,
      stdout: new Uint8Array(),
      stderr: new TextEncoder().encode("err"),
    });
    switch (sub) {
      case "find-generic-password": {
        if (stored == null) return fail(44); // item not found
        // -w → print the secret (base64)
        if (args.includes("-w")) return ok(stored.toString("base64"));
        return ok();
      }
      case "delete-generic-password": {
        if (stored == null) return fail(44);
        stored = null;
        return ok();
      }
      case "add-generic-password": {
        const wIdx = args.indexOf("-w");
        const b64 = wIdx >= 0 ? args[wIdx + 1]! : "";
        stored = Buffer.from(b64, "base64");
        return ok();
      }
      default:
        return fail(1);
    }
  };
  return { runner, calls, getStored: () => stored };
}

beforeEach(() => {
  _setSecurityRunnerForTesting(null);
  // Default: a fresh (absent) marker, so a present item would trigger the
  // one-time ACL migration unless a test marks it done first.
  _setMigrationMarkerPathForTesting(freshMarker());
});
afterEach(() => {
  _setSecurityRunnerForTesting(null);
  _setMigrationMarkerPathForTesting(null);
});

afterEach(() => {
  // Restore env for the rest of the suite.
  if (savedTestKey == null) delete process.env.WHATSAPP_MCP_TEST_KEY;
  else process.env.WHATSAPP_MCP_TEST_KEY = savedTestKey;
});
beforeEach(() => { delete process.env.WHATSAPP_MCP_TEST_KEY; });

afterAll(() => {
  rmSync(markerDir, { recursive: true, force: true });
});

describe("keychain ACL + absolute path (#82)", () => {
  test("invokes security by absolute path /usr/bin/security, never via PATH", () => {
    const h = makeRunner({ existing: null });
    _setSecurityRunnerForTesting(h.runner);
    getOrCreateMasterKey();
    expect(h.calls.length).toBeGreaterThan(0);
    for (const c of h.calls) {
      expect(c.bin).toBe("/usr/bin/security");
    }
  });

  test("creates the item with a -T ACL scoped to the daemon binary (process.execPath)", () => {
    const h = makeRunner({ existing: null });
    _setSecurityRunnerForTesting(h.runner);
    getOrCreateMasterKey();
    const add = h.calls.find((c) => c.args[0] === "add-generic-password");
    expect(add).toBeDefined();
    const args = add!.args;
    const tIdx = args.indexOf("-T");
    expect(tIdx).toBeGreaterThanOrEqual(0);
    expect(args[tIdx + 1]).toBe(process.execPath);
    // Exactly one -T → only the daemon binary is whitelisted.
    expect(args.filter((a) => a === "-T")).toHaveLength(1);
  });

  test("fresh keychain: generates, writes, and round-trips a 32-byte key", () => {
    const h = makeRunner({ existing: null });
    _setSecurityRunnerForTesting(h.runner);
    const key = getOrCreateMasterKey();
    expect(key.byteLength).toBe(32);
    expect(h.getStored()!.equals(key)).toBe(true);
  });

  test("existing item (already migrated): returns the stored key without rewriting", () => {
    const existing = Buffer.alloc(32, 7);
    const h = makeRunner({ existing });
    _setSecurityRunnerForTesting(h.runner);
    // Mark the ACL migration as already done so the read path short-circuits.
    const marker = freshMarker();
    writeFileSync(marker, "migrated\n");
    _setMigrationMarkerPathForTesting(marker);
    const key = getOrCreateMasterKey();
    expect(key.equals(existing)).toBe(true);
    // hasKey() found it + migration already done → no add-generic-password call.
    expect(h.calls.some((c) => c.args[0] === "add-generic-password")).toBe(false);
  });

  test("write path deletes a pre-existing item before re-adding so the -T ACL applies", () => {
    // Simulate: hasKey()=false initially (so we take the write path), but
    // a stale no-ACL item exists from a prior version. The writeKey delete
    // must precede the add.
    const h = makeRunner({ existing: null });
    _setSecurityRunnerForTesting(h.runner);
    getOrCreateMasterKey();
    const order = h.calls.map((c) => c.args[0]);
    const delIdx = order.indexOf("delete-generic-password");
    const addIdx = order.indexOf("add-generic-password");
    expect(delIdx).toBeGreaterThanOrEqual(0);
    expect(addIdx).toBeGreaterThanOrEqual(0);
    expect(delIdx).toBeLessThan(addIdx);
  });

  test("deleteMasterKey uses the absolute security path too", () => {
    const existing = Buffer.alloc(32, 3);
    const h = makeRunner({ existing });
    _setSecurityRunnerForTesting(h.runner);
    deleteMasterKey();
    const del = h.calls.find((c) => c.args[0] === "delete-generic-password");
    expect(del).toBeDefined();
    expect(del!.bin).toBe("/usr/bin/security");
    expect(h.getStored()).toBeNull();
  });
});

describe("one-time keychain ACL migration (#82)", () => {
  test("a pre-existing item is rewritten WITH the -T ACL (delete then add), key preserved", () => {
    const existing = Buffer.alloc(32, 9);
    const h = makeRunner({ existing });
    _setSecurityRunnerForTesting(h.runner);
    const marker = freshMarker(); // absent → migration runs
    _setMigrationMarkerPathForTesting(marker);

    const did = migrateKeychainAcl();
    expect(did).toBe(true);

    // It deleted then re-added (writeKey path), and the add carried -T.
    const order = h.calls.map((c) => c.args[0]);
    const delIdx = order.indexOf("delete-generic-password");
    const addIdx = order.indexOf("add-generic-password");
    expect(delIdx).toBeGreaterThanOrEqual(0);
    expect(addIdx).toBeGreaterThanOrEqual(0);
    expect(delIdx).toBeLessThan(addIdx);
    const add = h.calls.find((c) => c.args[0] === "add-generic-password")!;
    const tIdx = add.args.indexOf("-T");
    expect(tIdx).toBeGreaterThanOrEqual(0);
    expect(add.args[tIdx + 1]).toBe(process.execPath);
    // The SAME key bytes survive the rewrite.
    expect(h.getStored()!.equals(existing)).toBe(true);
    // Marker now present.
    expect(existsSync(marker)).toBe(true);
  });

  test("migration is idempotent: a second run is a no-op once the marker exists", () => {
    const existing = Buffer.alloc(32, 5);
    const h = makeRunner({ existing });
    _setSecurityRunnerForTesting(h.runner);
    const marker = freshMarker();
    _setMigrationMarkerPathForTesting(marker);

    expect(migrateKeychainAcl()).toBe(true);
    const callsAfterFirst = h.calls.length;
    // Second run: marker present → no-op, no further security calls.
    expect(migrateKeychainAcl()).toBe(false);
    expect(h.calls.length).toBe(callsAfterFirst);
  });

  test("no item present → migration is a no-op (fresh install)", () => {
    const h = makeRunner({ existing: null });
    _setSecurityRunnerForTesting(h.runner);
    _setMigrationMarkerPathForTesting(freshMarker());
    expect(migrateKeychainAcl()).toBe(false);
  });

  test("fail-closed: if the re-add silently fails the round-trip, migration throws", () => {
    // A runner that accepts delete but drops the re-add (stays empty), so the
    // verify read comes back missing → round-trip can't succeed → throw.
    const existing = Buffer.alloc(32, 1);
    let stored: Buffer | null = existing;
    const runner = (_bin: string, args: string[]) => {
      const sub = args[0];
      const ok = (out = ""): { exitCode: number; stdout: Uint8Array; stderr: Uint8Array } => ({
        exitCode: 0, stdout: new TextEncoder().encode(out), stderr: new Uint8Array(),
      });
      const fail = (code: number) => ({
        exitCode: code, stdout: new Uint8Array(), stderr: new TextEncoder().encode("err"),
      });
      switch (sub) {
        case "find-generic-password":
          if (stored == null) return fail(44);
          return args.includes("-w") ? ok(stored.toString("base64")) : ok();
        case "delete-generic-password":
          if (stored == null) return fail(44);
          stored = null;
          return ok();
        case "add-generic-password":
          // Simulate a silent failure: report success but DON'T store.
          return ok();
        default:
          return fail(1);
      }
    };
    _setSecurityRunnerForTesting(runner);
    _setMigrationMarkerPathForTesting(freshMarker());
    expect(() => migrateKeychainAcl()).toThrow();
  });

  test("getOrCreateMasterKey runs the migration when an un-migrated item exists", () => {
    const existing = Buffer.alloc(32, 4);
    const h = makeRunner({ existing });
    _setSecurityRunnerForTesting(h.runner);
    _setMigrationMarkerPathForTesting(freshMarker()); // absent → migrate

    const key = getOrCreateMasterKey();
    expect(key.equals(existing)).toBe(true);
    // The migration path ran a delete+add (vs the already-migrated test above).
    expect(h.calls.some((c) => c.args[0] === "add-generic-password")).toBe(true);
  });
});
