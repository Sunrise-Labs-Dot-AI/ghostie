import { afterEach, beforeEach, describe, expect, test } from "bun:test";

import {
  refuseDevModeInProduction,
  _peerIdentityCacheStatsForTesting,
  _resetPeerIdentityCacheForTesting,
  _setRealSignednessForTesting,
  _verifyPeerIdentityForTesting,
} from "./peer-auth.ts";

const NON_MACOS = process.platform !== "darwin" || process.env.GHOSTIE_FORCE_NON_DARWIN === "1";

// WHATSAPP_MCP_DEV is read at CALL time (devModeActive), so we can set it
// per-test deterministically regardless of import order in a shared process.
const savedDev = process.env.WHATSAPP_MCP_DEV;
const savedAssume = process.env.WHATSAPP_MCP_ASSUME_PRODUCTION;

beforeEach(() => {
  process.env.WHATSAPP_MCP_DEV = "1"; // dev mode requested → safeguard consulted
  delete process.env.WHATSAPP_MCP_ASSUME_PRODUCTION;
  _setRealSignednessForTesting(null);
});

afterEach(() => {
  _setRealSignednessForTesting(null);
  _resetPeerIdentityCacheForTesting();
  if (savedDev == null) delete process.env.WHATSAPP_MCP_DEV;
  else process.env.WHATSAPP_MCP_DEV = savedDev;
  if (savedAssume == null) delete process.env.WHATSAPP_MCP_ASSUME_PRODUCTION;
  else process.env.WHATSAPP_MCP_ASSUME_PRODUCTION = savedAssume;
});

describe("refuseDevModeInProduction env override hardening (#79)", () => {
  test("not in dev mode → always allowed (safeguard not consulted)", () => {
    process.env.WHATSAPP_MCP_DEV = "0";
    _setRealSignednessForTesting(true);
    expect(refuseDevModeInProduction().allow).toBe(true);
  });

  test("a genuinely-signed binary REFUSES dev mode even with ASSUME_PRODUCTION=0", () => {
    _setRealSignednessForTesting(true); // real codesign says: production-signed
    process.env.WHATSAPP_MCP_ASSUME_PRODUCTION = "0"; // attacker tries to relax
    const r = refuseDevModeInProduction();
    expect(r.allow).toBe(false); // override CANNOT weaken a real prod binary
    expect(r.reason).toContain("signed for production");
  });

  test("a genuinely-signed binary REFUSES dev mode with the env var ABSENT", () => {
    _setRealSignednessForTesting(true);
    const r = refuseDevModeInProduction();
    expect(r.allow).toBe(false);
  });

  test("an UNSIGNED binary may relax dev mode (ASSUME absent → allowed)", () => {
    _setRealSignednessForTesting(false); // genuinely unsigned (dev build)
    expect(refuseDevModeInProduction().allow).toBe(true); // dev/test keeps working
  });

  test("an UNSIGNED binary with ASSUME_PRODUCTION=1 still refuses (safeguard asserts)", () => {
    _setRealSignednessForTesting(false);
    process.env.WHATSAPP_MCP_ASSUME_PRODUCTION = "1";
    expect(refuseDevModeInProduction().allow).toBe(false);
  });

  test("an UNSIGNED binary with ASSUME_PRODUCTION=0 relaxes (explicit dev opt-out)", () => {
    _setRealSignednessForTesting(false);
    process.env.WHATSAPP_MCP_ASSUME_PRODUCTION = "0";
    expect(refuseDevModeInProduction().allow).toBe(true);
  });
});

describe.skipIf(NON_MACOS)("peer identity cache (#100)", () => {
  test("reuses a codesign verdict while the peer executable metadata is unchanged", () => {
    _resetPeerIdentityCacheForTesting();

    const first = _verifyPeerIdentityForTesting("/usr/bin/codesign");
    const afterFirst = _peerIdentityCacheStatsForTesting();
    const second = _verifyPeerIdentityForTesting("/usr/bin/codesign");
    const afterSecond = _peerIdentityCacheStatsForTesting();

    expect(first.valid).toBe(true);
    expect(second).toEqual(first);
    expect(afterFirst).toEqual({ size: 1, hits: 0, misses: 1 });
    expect(afterSecond).toEqual({ size: 1, hits: 1, misses: 1 });
  });
});
