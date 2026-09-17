import { expect, test } from "bun:test";
import { describeScope, filterToolList, grantScope, OAUTH_SCOPE, requiredScope, scopeAllows, TOOL_SCOPES } from "./scopes.ts";
import { MESSAGE_LINK_TOOL_NAME } from "./message-opener.ts";
import { readFileSync } from "node:fs";
import { join } from "node:path";

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
  expect(requiredScope("approve_message_draft")).toBeUndefined();
  expect(requiredScope("")).toBeUndefined();
  for (const name of ["constructor", "__proto__", "toString", "hasOwnProperty"]) expect(requiredScope(name)).toBeUndefined();
  expect(scopeAllows("messages:read", "messages:draft")).toBe(false);
  const listed = { jsonrpc: "2.0", id: 1, result: { tools: [{ name: "get_message_thread" }, { name: "stage_message_draft" }, { name: "ghostie_create_messages_link" }, { name: "approve_message_draft" }, { name: 7 }] } };
  expect((filterToolList(listed, "messages:read") as any).result.tools.map((t: any) => t.name)).toEqual(["get_message_thread"]);
  expect((filterToolList(listed, OAUTH_SCOPE) as any).result.tools.map((t: any) => t.name)).toEqual(["get_message_thread", "stage_message_draft", "ghostie_create_messages_link"]);
  expect(filterToolList({ jsonrpc: "2.0", id: 1, error: { code: -32601 } }, "messages:read")).toEqual({ jsonrpc: "2.0", id: 1, error: { code: -32601 } });
});

test("consent phrasing lists granted permissions in canonical order", () => {
  expect(describeScope("messages:read")).toBe("read messages");
  expect(describeScope("messages:draft messages:read")).toBe("read messages and stage drafts for your review");
  expect(describeScope(OAUTH_SCOPE)).toBe("read messages, stage drafts for your review, and create public Messages compose links");
});

test("the relay allowlist is exactly the Mac's remote allowlist plus the relay-owned link tool", () => {
  // Read the Mac policy as text: this package must not depend on the Mac package's modules or node_modules.
  const source = readFileSync(join(import.meta.dir, "../../ghostie/src/remote-policy.ts"), "utf8");
  const literal = /export const remoteSchemas = \{([\s\S]*?)\} as const;/.exec(source)?.[1] ?? "";
  const macTools = [...literal.matchAll(/^\s*([a-z_]+):/gm)].map(match => match[1]!);
  expect(macTools.length).toBeGreaterThan(0);
  expect(Object.keys(TOOL_SCOPES).sort()).toEqual([...macTools, MESSAGE_LINK_TOOL_NAME].sort());
});
