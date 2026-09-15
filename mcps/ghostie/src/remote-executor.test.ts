import { afterEach, expect, test } from "bun:test";
import { z } from "zod";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { createRemoteExecutor } from "./remote-executor.ts";

const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanup.splice(0)) await close(); });
async function fixture() {
  const calls: Record<string, unknown>[] = [];
  const executor = await createRemoteExecutor(server => {
    server.tool("get_message_thread", { thread_ref: z.string(), limit: z.number().optional() }, async () => ({ content: [{ type: "text", text: JSON.stringify({ messages: [{ body: "Verification code 123456", reply_to: { body: "234567" } }, { body: "Dinner at 7?" }] }) }] }));
    server.tool("stage_message_draft", { platform: z.string(), to_handle: z.string(), body: z.string(), source: z.string().optional() }, async args => { calls.push(args); return { content: [{ type: "text", text: JSON.stringify({ draft_ref: "imessage:fixture", draft: args }) }] }; });
    server.tool("send_draft", {}, async () => { throw new Error("SEND MUST NOT RUN"); });
  });
  cleanup.push(executor.close);
  const client = new Client({ name: "integration-fixture", version: "1" });
  const transport = new StreamableHTTPClientTransport(new URL("https://relay.example.test/mcp/hosts/fixture"), {
    fetch: async (_url, init) => {
      if (init?.method !== "POST") return new Response(null, { status: 405 });
      const request = JSON.parse(String(init.body));
      if (request.method === "notifications/initialized") return new Response(null, { status: 202 });
      return Response.json(await executor.execute(request));
    },
  });
  await client.connect(transport);
  cleanup.unshift(() => client.close());
  return { client, executor, calls };
}

test("standard SDK HTTP client initializes and only sees permitted tools", async () => {
  const { client } = await fixture(); const { tools } = await client.listTools();
  expect(tools.map(t => t.name)).toEqual(["get_message_thread", "stage_message_draft"]);
  const draft = tools.find(t => t.name === "stage_message_draft")!;
  expect(draft.inputSchema.additionalProperties).toBe(false);
  expect(draft.inputSchema.properties).not.toHaveProperty("attachments");
  expect(draft.inputSchema.properties).not.toHaveProperty("source");
  expect(draft.annotations?.readOnlyHint).toBe(false);
});

test("HTTP results filter nested secrets and retain normal readable text", async () => {
  const { client } = await fixture();
  const response = await client.callTool({ name: "get_message_thread", arguments: { thread_ref: "imessage:1" } });
  const serialized = JSON.stringify(response);
  expect(serialized).not.toContain("123456"); expect(serialized).not.toContain("234567");
  expect(serialized).toContain("Dinner at 7?"); expect(serialized).toContain("Authentication content hidden");
});

test("HTTP rejects forbidden tools and unknown draft fields before staging", async () => {
  const { client, calls } = await fixture();
  await expect(client.callTool({ name: "send_draft", arguments: {} })).rejects.toThrow();
  for (const extra of [{ attachments: [{ path: "/private/secret" }] }, { schedule_approved: true }, { source: "pretend-local" }]) {
    await expect(client.callTool({ name: "stage_message_draft", arguments: { platform: "imessage", to_handle: "+12025550100", body: "hello", ...extra } })).rejects.toThrow();
  }
  expect(calls).toHaveLength(0);
  await client.callTool({ name: "stage_message_draft", arguments: { platform: "imessage", to_handle: "+12025550100", body: "hello" } });
  expect(calls).toEqual([{ platform: "imessage", to_handle: "+12025550100", body: "hello", source: "ghostie-remote" }]);
});

test("host limits remote staging independently of the relay", async () => {
  const { client, calls } = await fixture();
  for (let i = 0; i < 6; i++) await client.callTool({ name: "stage_message_draft", arguments: { platform: "whatsapp", to_handle: "12025550100@s.whatsapp.net", body: "fixture" } });
  await expect(client.callTool({ name: "stage_message_draft", arguments: { platform: "whatsapp", to_handle: "12025550100@s.whatsapp.net", body: "fixture" } })).rejects.toThrow();
  expect(calls).toHaveLength(6);
});
