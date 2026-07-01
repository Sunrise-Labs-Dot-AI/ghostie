import { describe, test, expect } from "bun:test";

import { isAddressableChatGUID, serviceFromChatGUID } from "./chat-guid.ts";

// The addressability allowlist is load-bearing: `send … to chat id` only works
// for iMessage/SMS/RCS GUIDs. An unbound `any;-;…` guid fails with -1728, so it
// must NOT be treated as addressable (mirrors Swift
// IMessageDirectChatResolver.isAddressableChatGUID, which is deliberately
// stricter than serviceFromChatGUID's iMessage-default behavior).

describe("isAddressableChatGUID", () => {
  test("accepts iMessage / SMS / RCS prefixes", () => {
    expect(isAddressableChatGUID("iMessage;-;+14155551234")).toBe(true);
    expect(isAddressableChatGUID("SMS;-;+14155551234")).toBe(true);
    expect(isAddressableChatGUID("RCS;-;+14155551234")).toBe(true);
  });

  test("is case-insensitive on the service prefix", () => {
    expect(isAddressableChatGUID("imessage;-;x")).toBe(true);
    expect(isAddressableChatGUID("sms;-;x")).toBe(true);
    expect(isAddressableChatGUID("Rcs;-;x")).toBe(true);
  });

  test("rejects the unbound 'any;-;…' aggregate guid", () => {
    expect(isAddressableChatGUID("any;-;+14155551234")).toBe(false);
  });

  test("rejects unknown prefixes (strict allowlist, not iMessage-default)", () => {
    expect(isAddressableChatGUID("Telepathy;-;x")).toBe(false);
    expect(isAddressableChatGUID("")).toBe(false);
    expect(isAddressableChatGUID("+14155551234")).toBe(false);
  });
});

describe("serviceFromChatGUID", () => {
  test("extracts the service token preserving chat.db casing", () => {
    expect(serviceFromChatGUID("iMessage;-;+14155551234")).toBe("iMessage");
    expect(serviceFromChatGUID("SMS;-;+14155551234")).toBe("SMS");
    expect(serviceFromChatGUID("any;-;+14155551234")).toBe("any");
  });

  test("returns null when there is no prefix token", () => {
    expect(serviceFromChatGUID("")).toBeNull();
  });

  test("returns the whole string when there is no ';' separator", () => {
    expect(serviceFromChatGUID("iMessage")).toBe("iMessage");
  });
});
