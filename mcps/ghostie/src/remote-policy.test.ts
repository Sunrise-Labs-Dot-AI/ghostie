import { describe, expect, test } from "bun:test";
import { authenticationContent, REDACTED, sanitizeRemote, validateRemoteCall } from "./remote-policy.ts";

describe("remote authentication-content boundary", () => {
  for (const sample of [
    "Your Apple ID verification code is 123456", "654321 is your login code", "OTP: AB12CD",
    "Never share 234-567", "Your code is 123 456", "１２３４５６", "123\u200b456",
    "验证码 123456", "認証コード: 123456", "Su código es 123456", "Code de connexion: 123456",
    "Visit https://example.test/login?t=abc", "https://example.test/?code=abc", "Your password reset link",
    "Your code: 123456", "Use 123456 to log in.", "Code: AB12CD",
    "<untrusted_content>123456</untrusted_content>",
  ]) test(`hides fixture ${JSON.stringify(sample)}`, () => expect(authenticationContent(sample)).toBe(true));
  test("preserves ordinary conversation", () => {
    expect(sanitizeRemote({ body: "Dinner at 7?", sender: { name: "Avery Example" } })).toEqual({ body: "Dinner at 7?", sender: { name: "Avery Example" } });
  });
  test("covers previews, quotes, captions, draft context and nested MCP JSON", () => {
    const body = { last_message_preview: "OTP 123456", reply_to: { body: "Verification code 234567" }, context_messages: [{ body: "345678" }], media: [{ caption: "Security code 456789", path: "/private/secret" }], path: "/private/draft" };
    const sanitized = sanitizeRemote({ content: [{ type: "text", text: JSON.stringify(body) }] }) as { content: { type: string; text: string }[] };
    expect(sanitized.content[0]!.type).toBe("text");
    expect(() => JSON.parse(sanitized.content[0]!.text)).not.toThrow();
    const output = JSON.stringify(sanitized);
    for (const secret of ["123456", "234567", "345678", "456789", "/private/"]) expect(output).not.toContain(secret);
    expect(output).toContain(REDACTED);
  });
  test("a sibling context cannot leave a separate code field visible", () => {
    expect(sanitizeRemote({ label: "verification", value: "AB12-CD34" })).toEqual({ label: REDACTED, value: REDACTED });
  });
});

describe("remote tool boundary", () => {
  for (const name of ["send_draft", "schedule_draft", "discard_message_draft", "set_message_thread_priority", "__proto__", "constructor"]) {
    test(`rejects ${name}`, () => expect(() => validateRemoteCall(name, {})).toThrow());
  }
  test("text draft accepts only reviewable fields", () => {
    const draft = { platform: "imessage", to_handle: "+12025550100", body: "See you soon" };
    expect(validateRemoteCall("stage_message_draft", draft)).toEqual(draft);
    for (const key of ["attachments", "schedule_approved", "scheduled_send_at", "source", "send", "quoted_message_id"]) {
      expect(() => validateRemoteCall("stage_message_draft", { ...draft, [key]: true })).toThrow();
    }
  });
});
