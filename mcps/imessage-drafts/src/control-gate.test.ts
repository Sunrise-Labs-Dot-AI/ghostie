// Tests for the cloud kill switch / forced-upgrade gate (issue #76).
//
// We can't sign manifests with the real operator private key (it's not in the
// repo), so we override the embedded public key via the test seam and sign with
// a throwaway ed25519 keypair. This exercises the full verify path: a manifest
// signed with the matching private key verifies; one signed with a DIFFERENT
// key (the real embedded key, or a second throwaway) is ignored.

import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { generateKeyPairSync, sign, type KeyObject } from "node:crypto";

import {
  assertSendAllowed,
  effectiveControlState,
  ControlBlockedError,
  _setControlPubkeyForTesting,
} from "./control-gate.ts";

const tmpHome = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-control-test-"));
const prevHome = process.env.MESSAGES_MCP_HOME;

// Throwaway signing keypair; its raw public key replaces the embedded one.
let priv: KeyObject;
let rawPubB64: string;
// A SECOND keypair, used to forge a "wrong key" manifest.
let wrongPriv: KeyObject;

beforeAll(() => {
  process.env.MESSAGES_MCP_HOME = tmpHome;
  const kp = generateKeyPairSync("ed25519");
  priv = kp.privateKey;
  const rawPub = kp.publicKey.export({ format: "der", type: "spki" }).subarray(12);
  rawPubB64 = Buffer.from(rawPub).toString("base64");
  _setControlPubkeyForTesting(rawPubB64);

  wrongPriv = generateKeyPairSync("ed25519").privateKey;
});

afterAll(() => {
  _setControlPubkeyForTesting(null);
  if (prevHome === undefined) delete process.env.MESSAGES_MCP_HOME;
  else process.env.MESSAGES_MCP_HOME = prevHome;
  rmSync(tmpHome, { recursive: true, force: true });
});

beforeEach(() => {
  // Wipe manifest + sticky between tests so each starts from a clean client.
  for (const f of ["control-manifest.json", "control-manifest.json.sig", ".control-imsg-state.json"]) {
    const p = join(tmpHome, f);
    if (existsSync(p)) rmSync(p, { force: true });
  }
});

function writeManifest(manifest: object, signer: KeyObject = priv): void {
  const bytes = Buffer.from(JSON.stringify(manifest), "utf8");
  writeFileSync(join(tmpHome, "control-manifest.json"), bytes);
  const sig = sign(null, bytes, signer);
  writeFileSync(join(tmpHome, "control-manifest.json.sig"), sig.toString("base64"));
}

describe("control-gate kill switch (issue #76)", () => {
  test("no manifest, no sticky → send allowed (clean client)", () => {
    expect(() => assertSendAllowed("imessage")).not.toThrow();
    const s = effectiveControlState();
    expect(s.source).toBe("none");
    expect(s.kill_scope).toBe("none");
  });

  test("a forged sticky 'none' cannot suppress a present, validly-signed kill (#76)", () => {
    // Attacker pre-seeds the (unauthenticated) sticky file claiming no kill with a
    // far-future high-water mark, hoping every real kill looks like a rollback.
    writeFileSync(
      join(tmpHome, ".control-imsg-state.json"),
      JSON.stringify({ issued_at_ms: 8640000000000000, kill_scope: "none", min_version: null }),
    );
    // A real, validly-signed kill arrives with an OLDER issued_at.
    writeManifest({ schema: 1, kill: { scope: "all", reason: "incident" }, issued_at: "2026-01-01T00:00:00Z" });
    // Present kill wins regardless of the forged mark (fail safe toward blocking).
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
    expect(effectiveControlState().kill_scope).toBe("all");
  });

  test("valid kill scope 'all' blocks the send", () => {
    writeManifest({ schema: 1, kill: { scope: "all", reason: "incident-123" }, issued_at: new Date().toISOString() });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
    try {
      assertSendAllowed("imessage");
    } catch (e) {
      expect((e as ControlBlockedError).blockReason).toContain("incident-123");
    }
  });

  test("valid kill scope 'send' blocks the send", () => {
    writeManifest({ schema: 1, kill: { scope: "send", reason: "stop" }, issued_at: new Date().toISOString() });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
  });

  test("valid kill scope 'imessage' blocks the send", () => {
    writeManifest({ schema: 1, kill: { scope: "imessage", reason: "imsg-only" }, issued_at: new Date().toISOString() });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
  });

  test("kill scope 'whatsapp' does NOT block an iMessage send", () => {
    writeManifest({ schema: 1, kill: { scope: "whatsapp", reason: "wa-only" }, issued_at: new Date().toISOString() });
    expect(() => assertSendAllowed("imessage")).not.toThrow();
  });

  test("kill scope 'none' allows the send", () => {
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: new Date().toISOString() });
    expect(() => assertSendAllowed("imessage")).not.toThrow();
  });

  test("a manifest signed with the WRONG key is ignored (send allowed)", () => {
    writeManifest({ schema: 1, kill: { scope: "all", reason: "forged" }, issued_at: new Date().toISOString() }, wrongPriv);
    expect(() => assertSendAllowed("imessage")).not.toThrow();
    expect(effectiveControlState().source).toBe("none");
  });

  test("a tampered manifest (body changed after signing) is ignored", () => {
    const issued = new Date().toISOString();
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: issued });
    // Overwrite the manifest body WITHOUT re-signing → signature no longer matches.
    writeFileSync(
      join(tmpHome, "control-manifest.json"),
      Buffer.from(JSON.stringify({ schema: 1, kill: { scope: "all", reason: "tamper" }, issued_at: issued }), "utf8")
    );
    expect(() => assertSendAllowed("imessage")).not.toThrow();
    expect(effectiveControlState().source).toBe("none");
  });

  test("an unsigned manifest (sig file missing) is ignored", () => {
    writeFileSync(
      join(tmpHome, "control-manifest.json"),
      Buffer.from(JSON.stringify({ schema: 1, kill: { scope: "all", reason: "no-sig" }, issued_at: new Date().toISOString() }), "utf8")
    );
    // No .sig file written.
    expect(() => assertSendAllowed("imessage")).not.toThrow();
  });
});

describe("control-gate rollback resistance (issue #76)", () => {
  test("an OLDER (validly-signed) manifest cannot lift a sticky kill", () => {
    const newer = new Date().toISOString();
    const older = new Date(Date.now() - 60 * 60 * 1000).toISOString();

    // 1) Newer manifest activates a kill → sticky high-water mark recorded.
    writeManifest({ schema: 1, kill: { scope: "all", reason: "active" }, issued_at: newer });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
    expect(existsSync(join(tmpHome, ".control-imsg-state.json"))).toBe(true);

    // 2) Attacker drops an OLDER, validly-signed "all clear" manifest.
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: older });

    // The rollback must be ignored: the sticky kill still blocks.
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
    const s = effectiveControlState();
    expect(s.source).toBe("sticky");
    expect(s.kill_scope).toBe("all");
  });

  test("a NEWER manifest lifting the kill is honored (and advances sticky)", () => {
    const t1 = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const t2 = new Date().toISOString();

    writeManifest({ schema: 1, kill: { scope: "all", reason: "active" }, issued_at: t1 });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);

    // A genuinely newer all-clear lifts the kill.
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: t2 });
    expect(() => assertSendAllowed("imessage")).not.toThrow();
    const sticky = JSON.parse(readFileSync(join(tmpHome, ".control-imsg-state.json"), "utf8")) as { kill_scope: string };
    expect(sticky.kill_scope).toBe("none");
  });

  test("after a kill, deleting the manifest leaves the sticky kill in force (fail-closed)", () => {
    writeManifest({ schema: 1, kill: { scope: "all", reason: "active" }, issued_at: new Date().toISOString() });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
    // Remove the manifest files entirely; sticky state remains.
    rmSync(join(tmpHome, "control-manifest.json"), { force: true });
    rmSync(join(tmpHome, "control-manifest.json.sig"), { force: true });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
    expect(effectiveControlState().source).toBe("sticky");
  });
});

describe("control-gate fail-safe UNION (adversarial review)", () => {
  // (a) An OLD, narrow-scope present kill must not DOWNGRADE a broader sticky
  //     kill. A sticky `all` kill stays blocking even when a present signed
  //     `whatsapp` kill (older issued_at) is replayed against this gate.
  test("an older present 'whatsapp' kill does NOT downgrade a sticky 'all' kill — iMessage stays blocked", () => {
    const newer = new Date().toISOString();
    const older = new Date(Date.now() - 60 * 60 * 1000).toISOString();

    // 1) Newer manifest activates a fleet-wide kill → sticky 'all' recorded.
    writeManifest({ schema: 1, kill: { scope: "all", reason: "fleet" }, issued_at: newer });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);

    // 2) Attacker replays an OLDER, validly-signed kill scoped only to whatsapp,
    //    hoping the present-kill-wins logic downgrades the sticky 'all' to
    //    'whatsapp' (which would NOT block iMessage). The UNION must keep the
    //    sticky 'all' block in force for iMessage.
    writeManifest({ schema: 1, kill: { scope: "whatsapp", reason: "narrow" }, issued_at: older });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);

    // Effective scope is still 'all' (sticky 'all' unioned with present 'whatsapp').
    expect(effectiveControlState().kill_scope).toBe("all");
  });

  // (b) An old signed kill carrying a null (or lower) min_version must not LOWER
  //     a sticky min-version floor.
  test("an older manifest with null min_version does NOT lower a sticky min-version floor", () => {
    const newer = new Date().toISOString();
    const older = new Date(Date.now() - 60 * 60 * 1000).toISOString();

    // 1) Newer manifest sets a forced-upgrade floor far above this build.
    writeManifest({ schema: 1, min_supported_version: "999.0.0", issued_at: newer });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);

    // 2) Attacker replays an OLDER, validly-signed manifest with NO min_version
    //    (and no kill), hoping to drop the floor and let the build send.
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: older });
    // The floor must persist (sticky high-water mark wins on the older replay).
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
    expect(effectiveControlState().min_version).toBe("999.0.0");
  });

  test("an older manifest with a LOWER min_version does NOT lower a sticky floor", () => {
    const newer = new Date().toISOString();
    const older = new Date(Date.now() - 60 * 60 * 1000).toISOString();

    writeManifest({ schema: 1, min_supported_version: "999.0.0", issued_at: newer });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);

    // Older replay with a much lower floor — must keep the more-restrictive one.
    writeManifest({ schema: 1, min_supported_version: "0.0.1", issued_at: older });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
    expect(effectiveControlState().min_version).toBe("999.0.0");
  });

  // (c) The existing invariants still hold under the new model.
  test("a forged sticky 'none' still cannot suppress a present signed kill", () => {
    writeFileSync(
      join(tmpHome, ".control-imsg-state.json"),
      JSON.stringify({ issued_at_ms: 8640000000000000, kill_scope: "none", min_version: null }),
    );
    writeManifest({ schema: 1, kill: { scope: "all", reason: "incident" }, issued_at: "2026-01-01T00:00:00Z" });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
    expect(effectiveControlState().kill_scope).toBe("all");
  });

  test("a legit present 'none' newer-or-equal to the sticky still lifts the kill", () => {
    const t1 = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const t2 = new Date().toISOString();

    writeManifest({ schema: 1, kill: { scope: "all", reason: "active" }, issued_at: t1 });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);

    // A genuinely newer all-clear lifts the kill AND drops the floor.
    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: t2 });
    expect(() => assertSendAllowed("imessage")).not.toThrow();
    expect(effectiveControlState().kill_scope).toBe("none");
  });

  test("an equal-timestamp present 'none' lifts a sticky kill (newer-OR-EQUAL)", () => {
    const t = new Date().toISOString();
    writeManifest({ schema: 1, kill: { scope: "all", reason: "active" }, issued_at: t });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);

    writeManifest({ schema: 1, kill: { scope: "none" }, issued_at: t });
    expect(() => assertSendAllowed("imessage")).not.toThrow();
    expect(effectiveControlState().kill_scope).toBe("none");
  });
});

describe("control-gate min-version gate (issue #76)", () => {
  test("a min_supported_version ABOVE the current build blocks the send", () => {
    // package.json version is 0.x; require a far-future version.
    writeManifest({ schema: 1, min_supported_version: "999.0.0", issued_at: new Date().toISOString() });
    expect(() => assertSendAllowed("imessage")).toThrow(ControlBlockedError);
  });

  test("a min_supported_version at/below the current build allows the send", () => {
    writeManifest({ schema: 1, min_supported_version: "0.0.1", issued_at: new Date().toISOString() });
    expect(() => assertSendAllowed("imessage")).not.toThrow();
  });
});
