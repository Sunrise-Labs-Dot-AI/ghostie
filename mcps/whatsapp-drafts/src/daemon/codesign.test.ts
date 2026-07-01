import { describe, expect, test } from "bun:test";

import { verifyBinary, verifyAgainstAllowlist, verifyAndExtractIdentity, extractIdentity } from "./codesign.ts";

const NON_MACOS = process.platform !== "darwin" || process.env.GHOSTIE_FORCE_NON_DARWIN === "1";

describe.skipIf(NON_MACOS)("codesign verification", () => {
  test("verifies an Apple-signed system binary (/usr/bin/codesign itself)", () => {
    const r = verifyBinary("/usr/bin/codesign");
    expect(r.valid).toBe(true);
    expect(r.requirement).not.toBeNull();
    expect(r.requirement!).toContain("anchor apple");
  });

  test("rejects a missing binary", () => {
    const r = verifyBinary("/nonexistent/binary/path");
    expect(r.valid).toBe(false);
    expect(r.error).not.toBeNull();
  });

  test("allowlist match returns ok:true", () => {
    const v = verifyBinary("/usr/bin/codesign");
    const r = verifyAgainstAllowlist("/usr/bin/codesign", [v.requirement!]);
    expect(r.ok).toBe(true);
  });

  test("allowlist mismatch returns ok:false with reason", () => {
    const r = verifyAgainstAllowlist("/usr/bin/codesign", [`identifier "fake.id"`]);
    expect(r.ok).toBe(false);
    expect(r.reason).toContain("not in allowlist");
  });

  test("missing binary fails closed in allowlist check", () => {
    const r = verifyAgainstAllowlist("/nope", ["whatever"]);
    expect(r.ok).toBe(false);
    expect(r.reason).toContain("codesign --verify failed");
  });
});

// Issue #79: peer-auth now verifies + extracts identity in a SINGLE codesign
// pass (verifyAndExtractIdentity) instead of verifyBinary()-then-
// extractIdentity(), shrinking the PID-reuse TOCTOU window.
describe.skipIf(NON_MACOS)("verifyAndExtractIdentity (single-pass — issue #79)", () => {
  test("valid Apple-signed binary: valid:true with an Identifier", () => {
    const r = verifyAndExtractIdentity("/usr/bin/codesign");
    expect(r.valid).toBe(true);
    expect(r.error).toBeNull();
    // System binaries carry an Identifier (e.g. "com.apple.security.codesign").
    expect(r.identifier).not.toBeNull();
  });

  test("the single pass yields the SAME identity as the old two-call path", () => {
    // Pin the equivalence so the refactor can't silently change behavior:
    // verifyAndExtractIdentity must report exactly what extractIdentity would.
    const combined = verifyAndExtractIdentity("/usr/bin/codesign");
    const separate = extractIdentity("/usr/bin/codesign");
    expect(combined.identifier).toBe(separate.identifier);
    expect(combined.teamIdentifier).toBe(separate.teamIdentifier);
  });

  test("missing binary: valid:false, identity nulled, never throws", () => {
    const r = verifyAndExtractIdentity("/nonexistent/binary/path");
    expect(r.valid).toBe(false);
    expect(r.error).not.toBeNull();
    expect(r.identifier).toBeNull();
    expect(r.teamIdentifier).toBeNull();
  });
});
