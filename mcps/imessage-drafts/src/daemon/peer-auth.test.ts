// Tests for dev-mode refusal on a production-signed daemon (issue #79, round 2).
//
// The round-1 gap: MESSAGES_MCP_ASSUME_PRODUCTION=0 + MESSAGES_MCP_DEV=1 would
// disable peer-auth even on a genuinely signed binary, because the production
// signal short-circuited to `false` on ASSUME_PRODUCTION=0. The real signature
// must dominate. We can't sign the test runner, so we use the
// _setSignedForProductionForTesting seam to model "this binary IS genuinely
// signed for production" and assert the env override can't talk it out of it.

import { describe, test, expect, afterEach } from "bun:test";

import {
  verifyAndExtractIdentity,
} from "./codesign.ts";
import {
  refuseDevModeInProduction,
  isDevMode,
  _setSignedForProductionForTesting,
  _peerIdentityCacheStatsForTesting,
  _resetPeerIdentityCacheForTesting,
  _verifyPeerIdentityForTesting,
} from "./peer-auth.ts";

const NON_MACOS = process.platform !== "darwin" || process.env.GHOSTIE_FORCE_NON_DARWIN === "1";
const SIGNED_FIXTURE = "/usr/bin/codesign";
const TRUSTED_SIGNED_FIXTURE =
  !NON_MACOS && verifyAndExtractIdentity(SIGNED_FIXTURE).valid;

const prevDev = process.env.MESSAGES_MCP_DEV;
const prevAssume = process.env.MESSAGES_MCP_ASSUME_PRODUCTION;

afterEach(() => {
  _setSignedForProductionForTesting(null);
  _resetPeerIdentityCacheForTesting();
  if (prevDev === undefined) delete process.env.MESSAGES_MCP_DEV;
  else process.env.MESSAGES_MCP_DEV = prevDev;
  if (prevAssume === undefined) delete process.env.MESSAGES_MCP_ASSUME_PRODUCTION;
  else process.env.MESSAGES_MCP_ASSUME_PRODUCTION = prevAssume;
});

describe("refuseDevModeInProduction (issue #79 round 2)", () => {
  test("genuinely-signed binary refuses dev mode even with ASSUME_PRODUCTION=0", () => {
    _setSignedForProductionForTesting(true); // model a real production signature
    process.env.MESSAGES_MCP_DEV = "1";
    process.env.MESSAGES_MCP_ASSUME_PRODUCTION = "0"; // the attempted bypass

    const r = refuseDevModeInProduction();
    expect(r.allow).toBe(false);
    expect(r.reason).toContain("signed for production");
  });

  test("genuinely-signed binary refuses dev mode regardless of ASSUME_PRODUCTION being unset", () => {
    _setSignedForProductionForTesting(true);
    process.env.MESSAGES_MCP_DEV = "1";
    delete process.env.MESSAGES_MCP_ASSUME_PRODUCTION;

    expect(refuseDevModeInProduction().allow).toBe(false);
  });

  test("UNSIGNED binary may run dev mode (the legitimate dev path)", () => {
    _setSignedForProductionForTesting(false); // model an unsigned dev binary
    process.env.MESSAGES_MCP_DEV = "1";
    delete process.env.MESSAGES_MCP_ASSUME_PRODUCTION;

    const r = refuseDevModeInProduction();
    expect(r.allow).toBe(true);
  });

  test("UNSIGNED binary with ASSUME_PRODUCTION=1 is forced to production and refuses dev mode", () => {
    _setSignedForProductionForTesting(false);
    process.env.MESSAGES_MCP_DEV = "1";
    process.env.MESSAGES_MCP_ASSUME_PRODUCTION = "1"; // escalate unsigned → production

    expect(refuseDevModeInProduction().allow).toBe(false);
  });

  test("no dev mode requested → always allowed to start", () => {
    _setSignedForProductionForTesting(true);
    delete process.env.MESSAGES_MCP_DEV;
    expect(refuseDevModeInProduction().allow).toBe(true);
  });

  test("isDevMode reflects the env dynamically", () => {
    process.env.MESSAGES_MCP_DEV = "1";
    expect(isDevMode()).toBe(true);
    delete process.env.MESSAGES_MCP_DEV;
    expect(isDevMode()).toBe(false);
  });
});

describe.skipIf(NON_MACOS || !TRUSTED_SIGNED_FIXTURE)("peer identity cache (#100)", () => {
  test("reuses a codesign verdict while the peer executable metadata is unchanged", () => {
    _resetPeerIdentityCacheForTesting();

    const first = _verifyPeerIdentityForTesting(SIGNED_FIXTURE);
    const afterFirst = _peerIdentityCacheStatsForTesting();
    const second = _verifyPeerIdentityForTesting(SIGNED_FIXTURE);
    const afterSecond = _peerIdentityCacheStatsForTesting();

    expect(first.valid).toBe(true);
    expect(second).toEqual(first);
    expect(afterFirst).toEqual({ size: 1, hits: 0, misses: 1 });
    expect(afterSecond).toEqual({ size: 1, hits: 1, misses: 1 });
  });
});
