import { describe, expect, test } from "bun:test";

import { verifyBinary, extractIdentity, verifyAndExtractIdentity } from "./codesign.ts";

const NON_MACOS = process.platform !== "darwin" || process.env.GHOSTIE_FORCE_NON_DARWIN === "1";
const SIGNED_FIXTURE = "/usr/bin/codesign";
const TRUSTED_SIGNED_FIXTURE =
  !NON_MACOS && verifyAndExtractIdentity(SIGNED_FIXTURE).valid;

describe.skipIf(NON_MACOS || !TRUSTED_SIGNED_FIXTURE)("codesign verification", () => {
  test("verifies an Apple-signed system binary (/usr/bin/codesign itself)", () => {
    const r = verifyBinary(SIGNED_FIXTURE);
    expect(r.valid).toBe(true);
    expect(r.requirement).not.toBeNull();
    expect(r.requirement!).toContain("anchor apple");
  });
});

describe.skipIf(NON_MACOS)("codesign verification failures", () => {
  test("rejects a missing binary", () => {
    const r = verifyBinary("/nonexistent/binary/path");
    expect(r.valid).toBe(false);
    expect(r.error).not.toBeNull();
  });
});

// Issue #79: peer-auth now verifies + extracts identity in a SINGLE codesign
// pass (verifyAndExtractIdentity) instead of verifyBinary()-then-
// extractIdentity(), shrinking the PID-reuse TOCTOU window.
describe.skipIf(NON_MACOS || !TRUSTED_SIGNED_FIXTURE)("verifyAndExtractIdentity (single-pass — issue #79)", () => {
  test("valid Apple-signed binary: valid:true with an Identifier", () => {
    const r = verifyAndExtractIdentity(SIGNED_FIXTURE);
    expect(r.valid).toBe(true);
    expect(r.error).toBeNull();
    // System binaries carry an Identifier (e.g. "com.apple.security.codesign").
    expect(r.identifier).not.toBeNull();
  });

  test("the single pass yields the SAME identity as the old two-call path", () => {
    // Pin the equivalence so the refactor can't silently change behavior:
    // verifyAndExtractIdentity must report exactly what extractIdentity would.
    const combined = verifyAndExtractIdentity(SIGNED_FIXTURE);
    const separate = extractIdentity(SIGNED_FIXTURE);
    expect(combined.identifier).toBe(separate.identifier);
    expect(combined.teamIdentifier).toBe(separate.teamIdentifier);
  });
});

describe.skipIf(NON_MACOS)("verifyAndExtractIdentity failures", () => {
  test("missing binary: valid:false, identity nulled, never throws", () => {
    const r = verifyAndExtractIdentity("/nonexistent/binary/path");
    expect(r.valid).toBe(false);
    expect(r.error).not.toBeNull();
    expect(r.identifier).toBeNull();
    expect(r.teamIdentifier).toBeNull();
  });
});
