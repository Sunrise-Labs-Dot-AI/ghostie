#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));

const servers = [
  { key: "ghostie", cwd: "mcps/ghostie", expectedName: "ghostie-mcp" },
  { key: "imessage-drafts", cwd: "mcps/imessage-drafts", expectedName: "imessage-drafts-mcp" },
  { key: "whatsapp-drafts", cwd: "mcps/whatsapp-drafts", expectedName: "whatsapp-mcp" },
];

const agentChoiceCases = [
  {
    name: "cross-transport thread listing",
    prompt: "List my recent message threads across iMessage and WhatsApp since yesterday.",
    expected: "ghostie.list_message_threads",
    discouraged: ["imessage-drafts.list_threads", "whatsapp-drafts.list_whatsapp_threads"],
  },
  {
    name: "cross-transport search",
    prompt: "Search both transports for dinner since yesterday.",
    expected: "ghostie.search_message_history",
    discouraged: ["imessage-drafts.search_messages", "whatsapp-drafts.search_whatsapps"],
  },
  {
    name: "general reply draft",
    prompt: "Find the right message thread and draft a reply for approval.",
    expected: "ghostie.stage_message_draft",
    discouraged: ["imessage-drafts.stage_draft", "whatsapp-drafts.stage_whatsapp_draft"],
  },
  {
    name: "iMessage voice/style",
    prompt: "Use my texting voice profile before drafting an iMessage.",
    expected: "imessage-drafts.get_texting_voice",
    discouraged: ["ghostie.stage_message_draft"],
  },
  {
    name: "WhatsApp full-body hydration",
    prompt: "Retrieve the full body of this truncated WhatsApp message.",
    expected: "whatsapp-drafts.get_whatsapp_message_full",
    discouraged: ["ghostie.get_message_thread"],
  },
  {
    name: "send now safety boundary",
    prompt: "Send the staged message now.",
    expected: null,
    safetyBoundary: "Facade cannot send; transport send tools must remain explicitly approval-gated.",
    discouraged: [
      "ghostie.send_message_draft",
      "ghostie.send_draft",
      "ghostie.send_whatsapp_draft",
    ],
  },
];

function fail(message) {
  throw new Error(message);
}

function readTools(server) {
  const home = mkdtempSync(resolve(tmpdir(), "mfa-agent-choice-"));
  try {
    const input = [
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"agent-choice-contract","version":"0"}}}',
      '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}',
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
      "",
    ].join("\n");
    const env = {
      ...process.env,
      HOME: home,
      MESSAGES_MCP_HOME: resolve(home, ".messages-mcp"),
      WHATSAPP_MCP_HOME: resolve(home, ".whatsapp-mcp"),
    };
    const result = spawnSync("bun", ["run", "src/index.ts"], {
      cwd: resolve(root, server.cwd),
      input,
      env,
      encoding: "utf8",
      timeout: 10_000,
    });
    if (result.status !== 0) {
      fail(`${server.key} exited ${result.status}: ${result.stderr}`);
    }
    const rows = result.stdout.split("\n").filter(Boolean).map((line) => JSON.parse(line));
    const init = rows.find((row) => row.id === 1);
    const actualName = init?.result?.serverInfo?.name;
    if (actualName !== server.expectedName) {
      fail(`${server.key} server name mismatch: ${actualName} !== ${server.expectedName}`);
    }
    return rows.find((row) => row.id === 2)?.result?.tools ?? [];
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

function splitRef(ref) {
  const idx = ref.indexOf(".");
  if (idx < 0) fail(`bad tool ref ${ref}`);
  return [ref.slice(0, idx), ref.slice(idx + 1)];
}

const catalog = new Map();
for (const server of servers) {
  const tools = readTools(server);
  for (const tool of tools) {
    const ref = `${server.key}.${tool.name}`;
    catalog.set(ref, { ...tool, server: server.key });
  }
}

const nameOwners = new Map();
for (const [ref, tool] of catalog.entries()) {
  const owners = nameOwners.get(tool.name) ?? [];
  owners.push(ref);
  nameOwners.set(tool.name, owners);
}
for (const [name, owners] of nameOwners.entries()) {
  if (owners.length > 1) {
    fail(`tool name ${name} is exposed by multiple MCPs: ${owners.join(", ")}`);
  }
}

function hasTool(ref) {
  return catalog.has(ref);
}

function description(ref) {
  return String(catalog.get(ref)?.description ?? "");
}

function expectTool(ref) {
  if (!hasTool(ref)) fail(`missing expected tool ${ref}`);
}

function expectNoTool(ref) {
  if (hasTool(ref)) fail(`unexpected tool exists: ${ref}`);
}

function expectDescription(ref, re) {
  expectTool(ref);
  const text = description(ref);
  if (!re.test(text)) fail(`${ref} description does not match ${re}: ${text}`);
}

for (const entry of agentChoiceCases) {
  if (entry.expected != null) expectTool(entry.expected);
  for (const ref of entry.discouraged) {
    const [server, tool] = splitRef(ref);
    if (server === "ghostie" && tool.includes("send")) {
      expectNoTool(ref);
    } else {
      expectTool(ref);
    }
  }
}

expectDescription("ghostie.list_message_threads", /across iMessage and\/or WhatsApp|across one or all transports/i);
expectDescription("ghostie.search_message_history", /across iMessage and\/or WhatsApp|across one or all transports/i);
expectDescription("ghostie.stage_message_draft", /Does NOT send|human approval/i);
expectDescription("imessage-drafts.send_draft", /approval|confirmation|refuses/i);
expectDescription("whatsapp-drafts.send_whatsapp_draft", /approval-gate|PENDING_APPROVAL|approved/i);

for (const ref of catalog.keys()) {
  const [server, tool] = splitRef(ref);
  if (server === "ghostie" && tool.includes("send")) {
    fail(`generalized facade must not expose send-like tool ${ref}`);
  }
}

console.log(`ok MCP all-tools agent-choice contract: ${agentChoiceCases.length} cases, ${catalog.size} tools`);
