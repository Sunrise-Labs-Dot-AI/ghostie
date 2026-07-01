import { beforeAll, afterAll, describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";

// Force test-key mode BEFORE importing the module under test.
const testKey = randomBytes(32).toString("base64");
const originalTestKey = process.env.WHATSAPP_MCP_TEST_KEY;
process.env.WHATSAPP_MCP_TEST_KEY = testKey;

const { wrap, unwrap, _resetKeyCache } = await import("./crypto.ts");

beforeAll(() => { _resetKeyCache(); });
afterAll(() => {
  if (originalTestKey == null) delete process.env.WHATSAPP_MCP_TEST_KEY;
  else process.env.WHATSAPP_MCP_TEST_KEY = originalTestKey;
  _resetKeyCache();
});

describe("session crypto", () => {
  test("wrap/unwrap roundtrip", () => {
    const plain = "hello, whatsapp";
    const blob = wrap(plain);
    // AES-GCM has zero plaintext expansion → blob = 12-byte nonce +
    // 16-byte tag + plaintext bytes.
    expect(blob.byteLength).toBe(plain.length + 12 + 16);
    expect(unwrap(blob)).toBe(plain);
  });

  test("nonce is random — same plaintext yields different ciphertext", () => {
    const a = wrap("same");
    const b = wrap("same");
    expect(Buffer.compare(a, b)).not.toBe(0);
    expect(unwrap(a)).toBe("same");
    expect(unwrap(b)).toBe("same");
  });

  test("auth tag rejects tampering", () => {
    const blob = wrap("legitimate");
    // Flip a bit in the ciphertext portion.
    const tampered = Buffer.from(blob);
    tampered[tampered.length - 1] = (tampered[tampered.length - 1] ?? 0) ^ 0x01;
    expect(() => unwrap(tampered)).toThrow();
  });

  test("auth tag rejects nonce tampering", () => {
    const blob = wrap("legitimate");
    const tampered = Buffer.from(blob);
    tampered[0] = (tampered[0] ?? 0) ^ 0x01;
    expect(() => unwrap(tampered)).toThrow();
  });

  test("rejects blobs shorter than nonce + tag", () => {
    expect(() => unwrap(Buffer.alloc(10))).toThrow();
    expect(() => unwrap(Buffer.alloc(27))).toThrow();
  });

  test("handles unicode + binary-ish JSON cleanly", () => {
    const plain = JSON.stringify({ keys: [1, 2, 3], note: "café — 你好 🎉" });
    expect(unwrap(wrap(plain))).toBe(plain);
  });

  test("handles large payloads", () => {
    const plain = "x".repeat(100_000);
    expect(unwrap(wrap(plain))).toBe(plain);
  });
});
