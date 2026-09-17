import { expect, test } from "bun:test";
import { describeScope, filterToolList, grantScope, OAUTH_SCOPE, requiredScope, scopeAllows } from "./scopes.ts";

test("grants canonical subsets, ignores offline_access, refuses unknown or empty scopes", () => {
  expect(grantScope(undefined)).toBe(OAUTH_SCOPE);
  expect(grantScope("messages:read messages:draft")).toBe("messages:read messages:draft");
  expect(grantScope("messages:draft   messages:read")).toBe("messages:read messages:draft");
  expect(grantScope("messages:link messages:read offline_access")).toBe("messages:read messages:link");
  expect(grantScope(`${OAUTH_SCOPE} offline_access`)).toBe(OAUTH_SCOPE);
  for (const bad of ["", "   ", "offline_access", "messages:send", "messages:read admin", "messages:read,messages:draft"]) expect(() => grantScope(bad)).toThrow("invalid_scope");
});

test("a refresh may narrow a grant but never widen it", () => {
  expect(grantScope(undefined, "messages:read messages:draft")).toBe("messages:read messages:draft");
  expect(grantScope("messages:read", "messages:read messages:draft")).toBe("messages:read");
  expect(() => grantScope("messages:read messages:link", "messages:read messages:draft")).toThrow("invalid_scope");
});

test("tool scope requirements and list filtering follow the grant", () => {
  expect(requiredScope("stage_message_draft")).toBe("messages:draft");
  expect(requiredScope("ghostie_create_messages_link")).toBe("messages:link");
  expect(requiredScope("get_message_thread")).toBe("messages:read");
  expect(scopeAllows("messages:read", "messages:draft")).toBe(false);
  const listed = { jsonrpc: "2.0", id: 1, result: { tools: [{ name: "get_message_thread" }, { name: "stage_message_draft" }, { name: "ghostie_create_messages_link" }, { name: 7 }] } };
  expect((filterToolList(listed, "messages:read") as any).result.tools.map((t: any) => t.name)).toEqual(["get_message_thread"]);
  expect((filterToolList(listed, OAUTH_SCOPE) as any).result.tools.map((t: any) => t.name)).toEqual(["get_message_thread", "stage_message_draft", "ghostie_create_messages_link"]);
  expect(filterToolList({ jsonrpc: "2.0", id: 1, error: { code: -32601 } }, "messages:read")).toEqual({ jsonrpc: "2.0", id: 1, error: { code: -32601 } });
});

test("consent phrasing lists granted permissions in canonical order", () => {
  expect(describeScope("messages:read")).toBe("read messages");
  expect(describeScope("messages:draft messages:read")).toBe("read messages and stage drafts for your review");
  expect(describeScope(OAUTH_SCOPE)).toBe("read messages, stage drafts for your review, and create public Messages compose links");
});
