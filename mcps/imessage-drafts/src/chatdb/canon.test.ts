import { describe, test, expect } from "bun:test";
import { canonHandle } from "./canon.ts";
import { canonHandlePublic } from "./contacts.ts";

// This rule is mirrored in three places that must agree:
//   - canonHandle (this file) — used by contacts.ts
//   - canonChatHandle (queries.ts) — now an alias import of canonHandle
//   - ContactsExporter.canonHandle (Swift) — cross-language mirror
// These vectors are the auditable contract. The Swift copy must produce the
// same output for the same inputs (see ROOT_CAUSE-contact-filter.md #1).
const VECTORS: Array<[string, string]> = [
  // phones: digits only, last 10
  ["+1 (404) 555-0147", "4045550147"], // formatted E.164 w/ country code
  ["+14045550147", "4045550147"], // E.164
  ["14045550147", "4045550147"], // 11-digit no plus
  ["4045550147", "4045550147"], // bare 10-digit
  ["(404) 555-0147", "4045550147"], // formatted, no country code
  ["911", "911"], // short code: fewer than 10 digits → kept as-is
  ["12345", "12345"], // short number kept
  // emails: lowercased, never digit-stripped
  ["Avery@Example.COM", "avery@example.com"],
  ["jose+tag@Example.com", "jose+tag@example.com"], // +tag preserved (has '@')
  ["plain@domain.io", "plain@domain.io"],
];

describe("canonHandle", () => {
  for (const [input, expected] of VECTORS) {
    test(`${input} → ${expected}`, () => {
      expect(canonHandle(input)).toBe(expected);
    });
  }

  test("is idempotent (canon of canon == canon)", () => {
    for (const [input] of VECTORS) {
      const once = canonHandle(input);
      expect(canonHandle(once)).toBe(once);
    }
  });

  test("canonHandlePublic re-exports the same implementation", () => {
    for (const [input, expected] of VECTORS) {
      expect(canonHandlePublic(input)).toBe(expected);
    }
  });
});
