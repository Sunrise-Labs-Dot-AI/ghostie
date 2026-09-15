import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { zodToJsonSchema } from "zod-to-json-schema";
import { registerGeneralizedTools } from "./facade.ts";
import { remoteSchemas, sanitizeRemote, validateRemoteCall } from "./remote-policy.ts";

export async function createRemoteExecutor(register = registerGeneralizedTools) {
  const server = new McpServer({ name: "ghostie-local", version: "1.0.0" });
  register(server);
  const client = new Client({ name: "ghostie-remote-boundary", version: "1.0.0" });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  await client.connect(b);
  const { tools } = await client.listTools();
  const advertised = tools.filter(tool => Object.hasOwn(remoteSchemas, tool.name)).map(tool => {
    const schema = zodToJsonSchema(remoteSchemas[tool.name as keyof typeof remoteSchemas], { target: "jsonSchema7", $refStrategy: "none" });
    return { ...tool, inputSchema: schema,
      description: tool.name === "stage_message_draft" ? "Stage a text-only draft on your Mac for human review. Never sends, schedules, or approves. If a request times out, inspect the local queue before retrying." : tool.description,
      annotations: { readOnlyHint: tool.name !== "stage_message_draft", destructiveHint: false, idempotentHint: tool.name !== "stage_message_draft", openWorldHint: false },
    };
  });
  let busy = false;
  let stages: number[] = [];
  return {
    close: async () => { await client.close(); await server.close(); },
    async execute(input: unknown): Promise<unknown> {
      if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("Invalid request");
      const request = input as Record<string, unknown>;
      const id = request.id;
      const error = (code: number, message: string) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });
      if (request.jsonrpc !== "2.0" || !(typeof id === "string" || typeof id === "number")) return error(-32600, "Invalid request");
      const result = (value: unknown) => ({ jsonrpc: "2.0", id, result: value });
      if (request.method === "initialize") {
        const requested = (request.params as Record<string, unknown> | undefined)?.protocolVersion;
        const protocolVersion = typeof requested === "string" && ["2025-03-26", "2025-06-18", "2025-11-25"].includes(requested) ? requested : "2025-11-25";
        return result({ protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "ghostie-remote", version: "1.0.0" }, instructions: "Read messages and stage text drafts. Sending requires local human review. Authentication content is filtered on the Mac. The Mac must be awake with Ghostie hosting." });
      }
      if (request.method === "ping") return result({});
      if (request.method === "tools/list") return result({ tools: advertised });
      if (request.method !== "tools/call") return error(-32601, "Method unavailable");
      if (busy) return error(-32000, "Mac is busy. Inspect the draft queue before retrying a draft.");
      const params = request.params as Record<string, unknown> | undefined;
      if (!params || typeof params.name !== "string") return error(-32602, "Invalid tool call");
      let args: Record<string, unknown>;
      try { args = validateRemoteCall(params.name, params.arguments ?? {}); } catch { return error(-32602, "Tool or arguments not permitted remotely"); }
      if (params.name === "stage_message_draft") {
        stages = stages.filter(t => t > Date.now() - 60_000);
        if (stages.length >= 6) return error(-32000, "Remote draft rate limit reached");
        stages.push(Date.now());
        args.source = "ghostie-remote";
      }
      busy = true;
      try {
        const response = await client.callTool({ name: params.name, arguments: args });
        if (response.isError) return result({ isError: true, content: [{ type: "text", text: "The Mac could not complete this request. Check its connections and draft queue before retrying." }] });
        return result(sanitizeRemote(response));
      } catch { return error(-32603, "Host request failed. Inspect the Mac draft queue before retrying."); }
      finally { busy = false; }
    },
  };
}
