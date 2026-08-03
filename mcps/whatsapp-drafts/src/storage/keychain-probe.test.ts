// The Keychain probe used to be two-state (`exitCode === 0`), which folded
// "locked", "access denied" and "security is missing" into "no key stored".
// getOrCreateMasterKey answered that by MINTING A REPLACEMENT, and writeKey
// deletes the existing item before adding the new one — so a single transient
// read failure permanently destroyed the real wrap key, taking the WhatsApp
// session and every encrypted message body with it.
//
// These tests pin the tri-state contract: 0 = present, 44 = absent, anything
// else throws and must never reach delete/add.

import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

const savedTestKey = process.env.WHATSAPP_MCP_TEST_KEY;
delete process.env.WHATSAPP_MCP_TEST_KEY;

const {
  getOrCreateMasterKey,
  KeychainAccessError,
  _setSecurityRunnerForTesting,
  _setMigrationMarkerPathForTesting,
} = await import("./keychain.ts");

const markerDir = mkdtempSync(join(tmpdir(), "whatsapp-mcp-probe-marker-"));
let markerSeq = 0;

interface Result { exitCode: number; stdout: Uint8Array; stderr: Uint8Array }
const enc = (s: string) => new TextEncoder().encode(s);

/**
 * A tiny stateful stand-in for the login keychain.
 *
 * `probeExit` is the status `find-generic-password` reports while the item is
 * ABSENT: 44 models a genuine first run (and a later `add` makes the item
 * readable, so the write-then-verify round-trip completes), while any other
 * code models an access failure that persists.
 *
 * Every subcommand is recorded so a test can assert that nothing destructive
 * was attempted.
 */
function makeRunner(probeExit: number, storedKeyB64?: string) {
  const subcommands: string[] = [];
  let stored: string | null = storedKeyB64 ?? null;

  const runner = (_bin: string, args: string[]): Result => {
    const sub = args[0] ?? "";
    subcommands.push(sub);
    switch (sub) {
      case "find-generic-password": {
        if (stored == null) {
          return { exitCode: probeExit, stdout: new Uint8Array(), stderr: enc("boom") };
        }
        const wantsSecret = args.includes("-w");
        return {
          exitCode: 0,
          stdout: enc(wantsSecret ? stored : "attributes"),
          stderr: new Uint8Array(),
        };
      }
      case "add-generic-password": {
        const wIdx = args.indexOf("-w");
        stored = wIdx >= 0 ? (args[wIdx + 1] ?? null) : null;
        return { exitCode: 0, stdout: new Uint8Array(), stderr: new Uint8Array() };
      }
      case "delete-generic-password": {
        const had = stored != null;
        stored = null;
        return { exitCode: had ? 0 : 44, stdout: new Uint8Array(), stderr: new Uint8Array() };
      }
      default:
        return { exitCode: 0, stdout: new Uint8Array(), stderr: new Uint8Array() };
    }
  };
  return { runner, subcommands };
}

function install(probeExit: number, storedKeyB64?: string) {
  const { runner, subcommands } = makeRunner(probeExit, storedKeyB64);
  _setSecurityRunnerForTesting(runner);
  // Fresh marker path => the one-time ACL migration is "not yet done", which is
  // the state in which a bad probe is most dangerous.
  _setMigrationMarkerPathForTesting(join(markerDir, `marker-${markerSeq++}`));
  return subcommands;
}

afterAll(() => {
  _setSecurityRunnerForTesting(null);
  _setMigrationMarkerPathForTesting(null);
  if (savedTestKey == null) delete process.env.WHATSAPP_MCP_TEST_KEY;
  else process.env.WHATSAPP_MCP_TEST_KEY = savedTestKey;
  rmSync(markerDir, { recursive: true, force: true });
});

describe("Keychain probe is tri-state", () => {
  test("exit 44 (item not found) mints a fresh key — the real first-run path", () => {
    const subcommands = install(44);
    expect(() => getOrCreateMasterKey()).not.toThrow();
    expect(subcommands).toContain("add-generic-password");
  });

  test("exit 0 returns the stored key without rewriting it", () => {
    const stored = randomBytes(32).toString("base64");
    const subcommands = install(0, stored);
    const key = getOrCreateMasterKey();
    expect(key.toString("base64")).toBe(stored);
  });

  for (const [label, code] of [
    ["keychain locked", 36],
    ["user denied access", 51],
    ["generic failure", 1],
    ["security binary missing", -1],
  ] as const) {
    test(`${label} (exit ${code}) throws instead of minting a replacement`, () => {
      const subcommands = install(code);

      expect(() => getOrCreateMasterKey()).toThrow(KeychainAccessError);

      // The whole point: no delete, no add. The existing item is untouched, so
      // the session and message history remain decryptable once access returns.
      expect(subcommands).not.toContain("delete-generic-password");
      expect(subcommands).not.toContain("add-generic-password");
    });
  }

  test("the access error explains why it refused, for the daemon log", () => {
    install(51);
    try {
      getOrCreateMasterKey();
      throw new Error("expected a throw");
    } catch (e) {
      expect(e).toBeInstanceOf(KeychainAccessError);
      expect((e as Error).message).toMatch(/destroy the existing session/i);
    }
  });

  // Minting a fresh key must also record that its ACL is already correct.
  // Otherwise the NEXT start runs the legacy migration against it, and that
  // migration deletes before it re-adds — a failure in that window destroys a
  // brand-new key and orphans the session just paired under it.
  test("a freshly minted key is marked migrated so it is never re-written", () => {
    const marker = join(markerDir, `marker-fresh-${markerSeq++}`);
    const { runner } = makeRunner(44);
    _setSecurityRunnerForTesting(runner);
    _setMigrationMarkerPathForTesting(marker);

    getOrCreateMasterKey();

    expect(existsSync(marker)).toBe(true);
  });
});

describe("deleteSession leaves the wrap key alone", () => {
  // This is the invariant that keeps message history readable: messages.db
  // content is wrapped with the same key. Asserted here rather than in
  // session-recovery.test.ts because that file sets WHATSAPP_MCP_TEST_KEY,
  // which makes deleteMasterKey() a no-op — so the assertion there would pass
  // even if the call were reintroduced. Here the Keychain seam is live, so a
  // regression shows up as a real `delete-generic-password`.
  test("no delete-generic-password is issued while wiping the session", async () => {
    const home = mkdtempSync(join(tmpdir(), "whatsapp-mcp-delete-session-"));
    const savedHome = process.env.WHATSAPP_MCP_HOME;
    process.env.WHATSAPP_MCP_HOME = home;

    const stored = randomBytes(32).toString("base64");
    const { runner, subcommands } = makeRunner(0, stored);
    _setSecurityRunnerForTesting(runner);
    _setMigrationMarkerPathForTesting(join(markerDir, `marker-del-${markerSeq++}`));

    const { deleteSession, _resetForTesting } = await import("./session.ts");
    const { _resetKeyCache } = await import("./crypto.ts");
    _resetForTesting();
    _resetKeyCache();

    try {
      deleteSession();
      expect(subcommands).not.toContain("delete-generic-password");
    } finally {
      _resetForTesting();
      _resetKeyCache();
      if (savedHome == null) delete process.env.WHATSAPP_MCP_HOME;
      else process.env.WHATSAPP_MCP_HOME = savedHome;
      rmSync(home, { recursive: true, force: true });
    }
  });
});
