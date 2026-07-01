import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { generateKeyPairSync, sign, type KeyObject } from "node:crypto";

import {
  assertSendAllowed,
  ControlBlockedError,
  _setControlDirForTesting,
  _setPublicKeyForTesting,
} from "./control-gate.ts";

// A throwaway Ed25519 keypair: we hold the private half so we can mint VALID
// signatures, and inject the public half into the gate via the test seam. This
// stands in for the production SUPublicEDKey without needing the real private
// key.
let signingKey: KeyObject;
let rawPubKey: Buffer;

// A SECOND keypair, used to model a "wrong key" / attacker-signed manifest:
// the signature verifies under THIS key but not under the injected public key.
let wrongSigningKey: KeyObject;

function rawPublicFrom(pub: KeyObject): Buffer {
  // Last 32 bytes of the SPKI DER are the raw Ed25519 public key.
  return pub.export({ format: "der", type: "spki" }).subarray(-32);
}

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "wa-control-gate-"));
  _setControlDirForTesting(dir);

  const kp = generateKeyPairSync("ed25519");
  signingKey = kp.privateKey;
  rawPubKey = rawPublicFrom(kp.publicKey);
  _setPublicKeyForTesting(rawPubKey);

  const wrong = generateKeyPairSync("ed25519");
  wrongSigningKey = wrong.privateKey;
});

afterEach(() => {
  _setControlDirForTesting(null);
  _setPublicKeyForTesting(null);
  rmSync(dir, { recursive: true, force: true });
});

/** Write a manifest + a signature produced with `withKey` (defaults to the
 *  legitimate signing key). */
function writeManifest(manifest: unknown, withKey: KeyObject = signingKey): void {
  const bytes = Buffer.from(JSON.stringify(manifest), "utf8");
  const sig = sign(null, bytes, withKey);
  writeFileSync(join(dir, "control-manifest.json"), bytes);
  writeFileSync(join(dir, "control-manifest.json.sig"), sig.toString("base64"));
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

describe("control-gate assertSendAllowed (issue #76)", () => {
  test("no manifest and no sticky → allows", () => {
    expect(() => assertSendAllowed("whatsapp")).not.toThrow();
  });

  test("verified kill scope=all blocks", () => {
    writeManifest({ schema: 1, kill: { scope: "all", reason: "maintenance" }, issued_at: iso(Date.now()) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
    try {
      assertSendAllowed("whatsapp");
    } catch (e) {
      expect((e as ControlBlockedError).reason).toContain("maintenance");
      expect((e as ControlBlockedError).reason).toContain("all");
    }
  });

  test("verified kill scope=send blocks", () => {
    writeManifest({ schema: 1, kill: { scope: "send" }, issued_at: iso(Date.now()) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
  });

  test("verified kill scope=whatsapp blocks whatsapp", () => {
    writeManifest({ schema: 1, kill: { scope: "whatsapp" }, issued_at: iso(Date.now()) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
  });

  test("verified kill scope=imessage does NOT block whatsapp", () => {
    writeManifest({ schema: 1, kill: { scope: "imessage" }, issued_at: iso(Date.now()) });
    expect(() => assertSendAllowed("whatsapp")).not.toThrow();
  });

  test("verified kill scope=none allows", () => {
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: iso(Date.now()) });
    expect(() => assertSendAllowed("whatsapp")).not.toThrow();
  });

  test("tampered manifest bytes (sig no longer matches) is IGNORED → allows", () => {
    writeManifest({ schema: 1, kill: { scope: "all" }, issued_at: iso(Date.now()) });
    // Mutate the manifest after signing so the signature no longer verifies.
    const p = join(dir, "control-manifest.json");
    const orig = JSON.parse(readFileSync(p, "utf8"));
    orig.kill.reason = "injected directive";
    writeFileSync(p, JSON.stringify(orig));
    // Unsigned/invalid manifest is never honored, and there's no sticky kill.
    expect(() => assertSendAllowed("whatsapp")).not.toThrow();
  });

  test("manifest signed by the WRONG key is IGNORED → allows", () => {
    writeManifest(
      { schema: 1, kill: { scope: "all" }, issued_at: iso(Date.now()) },
      wrongSigningKey,
    );
    expect(() => assertSendAllowed("whatsapp")).not.toThrow();
  });

  test("garbage (non-base64-ish / short) signature is ignored → allows", () => {
    const bytes = Buffer.from(JSON.stringify({ schema: 1, kill: { scope: "all" }, issued_at: iso(Date.now()) }));
    writeFileSync(join(dir, "control-manifest.json"), bytes);
    writeFileSync(join(dir, "control-manifest.json.sig"), "not-a-real-signature");
    expect(() => assertSendAllowed("whatsapp")).not.toThrow();
  });

  test("a verified kill is STICKY: a later rollback (older, valid) manifest can't lift it", () => {
    const now = Date.now();
    // 1. Apply a valid kill → blocks + writes sticky.
    writeManifest({ schema: 1, kill: { scope: "all", reason: "killed" }, issued_at: iso(now) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);

    // 2. Attacker rolls back to an OLDER but validly-signed "all clear" manifest.
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: iso(now - 60_000) });
    // The older issued_at is a replay → ignored, sticky kill stays in force.
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
  });

  test("a NEWER valid manifest CAN lift a sticky kill (legit recovery)", () => {
    const now = Date.now();
    writeManifest({ schema: 1, kill: { scope: "all" }, issued_at: iso(now) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);

    // A strictly-newer, validly-signed all-clear manifest is honored.
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: iso(now + 60_000) });
    expect(() => assertSendAllowed("whatsapp")).not.toThrow();
  });

  test("sticky kill survives a read error (manifest file removed but sticky persists)", () => {
    const now = Date.now();
    writeManifest({ schema: 1, kill: { scope: "all" }, issued_at: iso(now) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);

    // Remove the on-disk manifest entirely (simulating a wiped/unreadable file).
    rmSync(join(dir, "control-manifest.json"), { force: true });
    rmSync(join(dir, "control-manifest.json.sig"), { force: true });
    // Sticky kill is still enforced.
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
  });

  test("min_supported_version above current MCP version blocks", () => {
    // package.json version is 0.5.1 (well below 99.0.0).
    writeManifest({ schema: 1, min_supported_version: "99.0.0", issued_at: iso(Date.now()) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
    try {
      assertSendAllowed("whatsapp");
    } catch (e) {
      expect((e as ControlBlockedError).reason).toContain("minimum supported version");
    }
  });

  test("min_supported_version at or below current MCP version allows", () => {
    writeManifest({ schema: 1, min_supported_version: "0.0.1", issued_at: iso(Date.now()) });
    expect(() => assertSendAllowed("whatsapp")).not.toThrow();
  });

  test("writes a sticky state sidecar on accepting a manifest", () => {
    writeManifest({ schema: 1, kill: { scope: "all" }, issued_at: iso(Date.now()) });
    try { assertSendAllowed("whatsapp"); } catch { /* expected block */ }
    expect(existsSync(join(dir, ".control-wa-state.json"))).toBe(true);
    const sticky = JSON.parse(readFileSync(join(dir, ".control-wa-state.json"), "utf8"));
    expect(sticky.kill_scope).toBe("all");
  });
});

describe("control-gate fail-safe UNION (adversarial review)", () => {
  // (a) An OLD, narrow-scope present kill must not DOWNGRADE a broader sticky
  //     kill. Sticky 'all' stays blocking WhatsApp even when a present signed
  //     'imessage' kill (older issued_at) is replayed against THIS gate.
  test("an older present 'imessage' kill does NOT downgrade a sticky 'all' kill — WhatsApp stays blocked", () => {
    const now = Date.now();

    // 1) Newer manifest activates a fleet-wide kill → sticky 'all'.
    writeManifest({ schema: 1, kill: { scope: "all", reason: "fleet" }, issued_at: iso(now) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);

    // 2) Attacker replays an OLDER, validly-signed kill scoped only to imessage,
    //    hoping present-kill-wins downgrades the sticky 'all' to 'imessage'
    //    (which would NOT block whatsapp). The UNION keeps WhatsApp blocked.
    writeManifest({ schema: 1, kill: { scope: "imessage", reason: "narrow" }, issued_at: iso(now - 60_000) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
  });

  // (b) An old signed kill with null/lower min_version must not LOWER the floor.
  test("an older manifest with null min_version does NOT lower a sticky min-version floor", () => {
    const now = Date.now();

    // 1) Newer manifest sets a floor far above this build (0.5.1).
    writeManifest({ schema: 1, min_supported_version: "99.0.0", issued_at: iso(now) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);

    // 2) Older replay with no min_version (and no kill) — floor must persist.
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: iso(now - 60_000) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
    const sticky = JSON.parse(readFileSync(join(dir, ".control-wa-state.json"), "utf8"));
    expect(sticky.min_version).toBe("99.0.0");
  });

  test("an older manifest with a LOWER min_version does NOT lower a sticky floor", () => {
    const now = Date.now();
    writeManifest({ schema: 1, min_supported_version: "99.0.0", issued_at: iso(now) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);

    writeManifest({ schema: 1, min_supported_version: "0.0.1", issued_at: iso(now - 60_000) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
    const sticky = JSON.parse(readFileSync(join(dir, ".control-wa-state.json"), "utf8"));
    expect(sticky.min_version).toBe("99.0.0");
  });

  // (c) Existing invariants still hold under the new model.
  test("a forged sticky 'none' still cannot suppress a present signed kill", () => {
    // Pre-seed an unauthenticated sticky claiming no kill with a far-future mark.
    writeFileSync(
      join(dir, ".control-wa-state.json"),
      JSON.stringify({ issued_at_ms: 8640000000000000, kill_scope: "none", min_version: null }),
    );
    // A real, validly-signed kill arrives with an OLDER issued_at.
    writeManifest({ schema: 1, kill: { scope: "all", reason: "incident" }, issued_at: "2026-01-01T00:00:00Z" });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);
  });

  test("a legit present 'none' newer-or-equal to the sticky still lifts the kill", () => {
    const now = Date.now();
    writeManifest({ schema: 1, kill: { scope: "all" }, issued_at: iso(now) });
    expect(() => assertSendAllowed("whatsapp")).toThrow(ControlBlockedError);

    // Equal-timestamp all-clear lifts (newer-OR-EQUAL).
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: iso(now) });
    expect(() => assertSendAllowed("whatsapp")).not.toThrow();
  });
});
