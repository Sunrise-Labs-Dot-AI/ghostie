import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

interface RpcRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: unknown;
}

interface ToolResult {
  isError?: boolean;
  content?: Array<{ text?: string }>;
}

interface FakeCall {
  method: string;
  params: unknown;
}

const RECENT_SINCE = "2026-06-01T00:00:00.000Z";
const WA_JID = "12025550001@s.whatsapp.net";
const WA_DRAFT_ID = "00000000-0000-4000-8000-000000000001";

function tempHome(): string {
  return mkdtempSync(join(tmpdir(), "ghostie-mcp-test-"));
}

function daemonPaths(home: string): { imessage: string; whatsapp: string } {
  return {
    imessage: join(home, ".messages-mcp", "daemon.sock"),
    whatsapp: join(home, ".whatsapp-mcp", "daemon.sock"),
  };
}

function witnessPath(home: string, transport: "imessage" | "whatsapp"): string {
  return join(home, ".messages-mcp", `last_invocation_${transport}.json`);
}

function readWitness(home: string, transport: "imessage" | "whatsapp"): { tool: string; ts: string; pid: number; writer_path: string } {
  return JSON.parse(readFileSync(witnessPath(home, transport), "utf8"));
}

function readActivity(home: string): Array<{ transport: string; tool: string }> {
  return readFileSync(join(home, ".messages-mcp", "mcp-activity.jsonl"), "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as { transport: string; tool: string });
}

async function startFakeDaemon(
  socketPath: string,
  handler: (method: string, params: unknown) => unknown | Promise<unknown>,
): Promise<{ calls: FakeCall[]; close(): Promise<void> }> {
  mkdirSync(dirname(socketPath), { recursive: true });
  if (existsSync(socketPath)) unlinkSync(socketPath);

  const calls: FakeCall[] = [];
  const server = createServer((sock) => {
    let buffered = "";
    sock.on("data", (chunk) => {
      buffered += chunk.toString("utf8");
      let idx: number;
      while ((idx = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, idx);
        buffered = buffered.slice(idx + 1);
        if (line.trim().length === 0) continue;
        const req = JSON.parse(line) as RpcRequest;
        calls.push({ method: req.method, params: req.params });
        void Promise.resolve(handler(req.method, req.params))
          .then((result) => {
            sock.write(JSON.stringify({ jsonrpc: "2.0", id: req.id ?? null, result }) + "\n");
          })
          .catch((e) => {
            sock.write(
              JSON.stringify({
                jsonrpc: "2.0",
                id: req.id ?? null,
                error: { code: -32000, message: (e as Error).message },
              }) + "\n",
            );
          });
      }
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      server.off("error", reject);
      resolve();
    });
  });

  return {
    calls,
    close: () => closeServer(server, socketPath),
  };
}

function closeServer(server: Server, socketPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((err) => {
      try {
        if (existsSync(socketPath)) unlinkSync(socketPath);
      } catch {
        // Best-effort cleanup only.
      }
      if (err) reject(err);
      else resolve();
    });
  });
}

async function runMcp(home: string, requests: Array<Record<string, unknown>>) {
  const proc = Bun.spawn(["bun", "run", "src/index.ts"], {
    cwd: join(import.meta.dir, ".."),
    env: {
      ...process.env,
      HOME: home,
      MESSAGES_MCP_HOME: join(home, ".messages-mcp"),
      WHATSAPP_MCP_HOME: join(home, ".whatsapp-mcp"),
    },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  proc.stdin.write(
    [
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}',
      '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}',
      ...requests.map((req) => JSON.stringify(req)),
    ].join("\n") + "\n",
  );
  proc.stdin.end();

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (exitCode !== 0) {
    throw new Error(`MCP exited ${exitCode}: ${stderr}`);
  }
  return stdout.split("\n").filter(Boolean).map((line) => JSON.parse(line) as Record<string, unknown>);
}

function toolCall(id: number, name: string, args: Record<string, unknown>): Record<string, unknown> {
  return {
    jsonrpc: "2.0",
    id,
    method: "tools/call",
    params: { name, arguments: args },
  };
}

function resultFor(rows: Array<Record<string, unknown>>, id: number): ToolResult {
  const row = rows.find((item) => item["id"] === id) as { result?: ToolResult } | undefined;
  if (!row?.result) throw new Error(`missing result id ${id}`);
  return row.result;
}

function payloadFor<T>(rows: Array<Record<string, unknown>>, id: number): T {
  const result = resultFor(rows, id);
  const text = result.content?.[0]?.text;
  if (!text) throw new Error(`missing text payload for id ${id}`);
  return JSON.parse(text) as T;
}

function errorText(rows: Array<Record<string, unknown>>, id: number): string {
  const result = resultFor(rows, id);
  expect(result.isError).toBe(true);
  return result.content?.[0]?.text ?? "";
}

function fakeIMessage(method: string): unknown {
  switch (method) {
    case "chatDbDiagnostic":
      return { open_status: "ok" };
    case "listThreads":
      return {
        threads: [
          {
            thread_id: 42,
            guid: "iMessage;-;+14045550100",
            display_name: "Alice <lead>",
            is_group: false,
            participants: [{ handle: "+14045550100", name: "Alice" }],
            last_message_at: "2026-06-10T18:00:00.000Z",
            last_message_from: { handle: "+14045550100", name: "Alice", from_me: false },
            last_message_preview: "iMessage preview",
          },
        ],
        oldest_at: "2026-06-10T18:00:00.000Z",
        has_more: false,
      };
    case "getThread":
    case "searchMessages":
      return [
        {
          message_id: 7001,
          thread_id: 42,
          sent_at: "2026-06-10T18:01:00.000Z",
          from_me: false,
          sender: { handle: "+14045550100", name: "Alice" },
          body: "Dinner at 7 <ok>",
          body_truncated: false,
          is_read: true,
          has_attachments: true,
          attachments: [
            {
              filename: "IMG_<script>.HEIC",
              path: "~/Library/Messages/Attachments/aa/00/IMG_0007.HEIC",
              mime_type: "image/heic",
              uti: "public.heic",
              total_bytes: 51234,
              is_sticker: false,
              kind: "image",
            },
          ],
          reply_to: null,
        },
      ];
    default:
      throw new Error(`unexpected iMessage method ${method}`);
  }
}

function fakeWhatsApp(method: string): unknown {
  switch (method) {
    case "getConnectionStatus":
      return { ok: true, state: "connected" };
    case "getThreads":
      return {
        threads: [
          {
            thread_jid: WA_JID,
            display_name: "WhatsApp Alice",
            is_group: false,
            last_message_ts: Date.parse("2026-06-10T18:02:00.000Z"),
            last_seen_at: null,
          },
        ],
      };
    case "getThread":
    case "searchMessages":
      return {
        messages: [
          {
            message_id: "wa-msg-1",
            thread_jid: WA_JID,
            sender_jid: WA_JID,
            sender_name: "WhatsApp Alice",
            from_me: false,
            ts: Date.parse("2026-06-10T18:03:00.000Z"),
            body: "Dinner works",
            body_sha256: "abc",
            message_type: "image",
            attachment_meta: { caption: "the <menu>", mime: "image/jpeg", filename: "menu.jpg" },
            reply_to_id: null,
            reply_to: null,
          },
        ],
      };
    case "stageDraft":
      return {
        draft: {
          id: WA_DRAFT_ID,
          schema_version: 1,
          platform: "whatsapp",
          approval_state: "pending",
          to_handle: WA_JID,
          to_handle_name: "WhatsApp Alice",
          body: "See you then",
          staged_at: "2026-06-10T18:04:00.000Z",
          sent_at: null,
          source: "ghostie-mcp",
          context_messages: [],
          context_diagnostic: null,
          induced_by_unknown_contact: false,
          quoted_message_id: null,
          quoted_preview: null,
        },
      };
    default:
      throw new Error(`unexpected WhatsApp method ${method}`);
  }
}

describe("ghostie MCP stdio contract", () => {
  test("initializes and exposes a flat generalized surface with no send tool", async () => {
    const home = tempHome();
    try {
      const rows = await runMcp(home, [{ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }]);
      const init = rows.find((row) => row["id"] === 1) as { result?: { serverInfo?: { name?: string } } } | undefined;
      expect(init?.result?.serverInfo?.name).toBe("ghostie-mcp");
      const listed = rows.find((row) => row["id"] === 2) as { result?: { tools?: Array<{ name?: string }> } } | undefined;
      const names = (listed?.result?.tools ?? []).map((tool) => tool.name).filter(Boolean);
      expect(names).toEqual([
        "get_message_current_time",
        "ghostie_health_check",
        "list_message_threads",
        "get_message_thread",
        "search_message_history",
        "stage_message_draft",
        "list_message_drafts",
        "get_message_draft",
        "discard_message_draft",
        "set_message_thread_priority",
        "clear_message_thread_priority",
        "list_message_thread_priorities",
      ]);
      expect(names.some((name) => name!.includes("send"))).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("routes generalized refs through the correct daemon and preserves stable refs", async () => {
    const home = tempHome();
    const paths = daemonPaths(home);
    const imessage = await startFakeDaemon(paths.imessage, fakeIMessage);
    const whatsapp = await startFakeDaemon(paths.whatsapp, fakeWhatsApp);
    try {
      const rows = await runMcp(home, [
        toolCall(2, "list_message_threads", { since: RECENT_SINCE, limit: 5 }),
        toolCall(3, "get_message_thread", { thread_ref: "imessage:42", limit: 5 }),
        toolCall(4, "get_message_thread", { thread_ref: `whatsapp:${WA_JID}`, limit: 5 }),
        toolCall(5, "search_message_history", { query: "dinner", since: RECENT_SINCE, limit: 5 }),
        toolCall(6, "stage_message_draft", {
          platform: "whatsapp",
          to_handle: WA_JID,
          in_reply_to_thread_ref: `whatsapp:${WA_JID}`,
          body: "See you then",
        }),
      ]);

      const listed = payloadFor<{ threads: Array<{ thread_ref: string }>; access_issues: unknown[] }>(rows, 2);
      expect(listed.threads.map((t) => t.thread_ref)).toEqual(["imessage:42", `whatsapp:${WA_JID}`]);
      expect(listed.access_issues).toEqual([]);

      const imessageThread = payloadFor<{ messages: Array<{ thread_ref: string; body: string; media: Array<{ kind: string; filename: string; path: string; caption: string | null }> }> }>(rows, 3);
      expect(imessageThread.messages[0]!.thread_ref).toBe("imessage:42");
      expect(imessageThread.messages[0]!.body).toContain("&lt;ok&gt;");
      // iMessage media: unified `media` array, local path present, caption null,
      // and the peer-supplied filename is HTML-escaped (untrusted-wrapped).
      const imAttach = imessageThread.messages[0]!.media[0]!;
      expect(imAttach.kind).toBe("image");
      expect(imAttach.path).toBe("~/Library/Messages/Attachments/aa/00/IMG_0007.HEIC");
      expect(imAttach.caption).toBeNull();
      expect(imAttach.filename).toContain("&lt;script&gt;");

      const whatsappThread = payloadFor<{ messages: Array<{ thread_ref: string; message_ref: string; media: Array<{ kind: string; caption: string; path: string | null }> }> }>(rows, 4);
      expect(whatsappThread.messages[0]!.thread_ref).toBe(`whatsapp:${WA_JID}`);
      expect(whatsappThread.messages[0]!.message_ref).toBe("whatsapp:wa-msg-1");
      // WhatsApp media: metadata-only (no path), caption wrapped untrusted.
      const waAttach = whatsappThread.messages[0]!.media[0]!;
      expect(waAttach.kind).toBe("image");
      expect(waAttach.path).toBeNull();
      expect(waAttach.caption).toContain("&lt;menu&gt;");

      const search = payloadFor<{ hits: Array<{ platform: string }> }>(rows, 5);
      expect(search.hits.map((hit) => hit.platform)).toEqual(["imessage", "whatsapp"]);

      const staged = payloadFor<{ draft_ref: string; draft: { approval_state: string } }>(rows, 6);
      expect(staged.draft_ref).toBe(`whatsapp:${WA_DRAFT_ID}`);
      expect(staged.draft.approval_state).toBe("pending");

      // The facade boots a chatDbDiagnostic probe refresh (witness FDA
      // signal) alongside the tool-driven reads.
      expect(imessage.calls.map((call) => call.method).sort()).toEqual([
        "chatDbDiagnostic",
        "getThread",
        "listThreads",
        "searchMessages",
      ]);
      expect(whatsapp.calls.map((call) => call.method).sort()).toEqual([
        "getThread",
        "getThreads",
        "searchMessages",
        "stageDraft",
      ]);

      // Witness contract: every successful tool call lands a per-touched-
      // transport witness record in the exact files the menubar watches.
      // Pipelined tool calls resolve concurrently, so assert membership,
      // not completion order.
      const imessageTouching = ["list_message_threads", "get_message_thread", "search_message_history"];
      const whatsappTouching = [...imessageTouching, "stage_message_draft"];
      const imessageWitness = readWitness(home, "imessage");
      expect(imessageTouching).toContain(imessageWitness.tool);
      expect(imessageWitness.pid).toBeGreaterThan(0);
      expect(imessageWitness.writer_path.length).toBeGreaterThan(0);
      const whatsappWitness = readWitness(home, "whatsapp");
      expect(whatsappTouching).toContain(whatsappWitness.tool);
      const activity = readActivity(home);
      expect(activity.filter((entry) => entry.transport === "imessage").map((entry) => entry.tool).sort()).toEqual(
        [...imessageTouching].sort(),
      );
      expect(activity.filter((entry) => entry.transport === "whatsapp").map((entry) => entry.tool).sort()).toEqual(
        [...whatsappTouching].sort(),
      );
    } finally {
      await Promise.all([imessage.close(), whatsapp.close()]);
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("reports partial access issues for all-platform reads and errors for platform-specific reads", async () => {
    const home = tempHome();
    const imessage = await startFakeDaemon(daemonPaths(home).imessage, fakeIMessage);
    try {
      const rows = await runMcp(home, [
        toolCall(2, "list_message_threads", { since: RECENT_SINCE, limit: 5 }),
        toolCall(3, "list_message_threads", { platform: "whatsapp", since: RECENT_SINCE, limit: 5 }),
      ]);

      const partial = payloadFor<{ threads: Array<{ platform: string }>; access_issues: Array<{ platform: string; error: string }> }>(rows, 2);
      expect(partial.threads.map((thread) => thread.platform)).toEqual(["imessage"]);
      expect(partial.access_issues).toEqual([{ platform: "whatsapp", error: "whatsapp daemon unavailable" }]);

      expect(errorText(rows, 3)).toContain("whatsapp daemon unavailable");

      // Witness contract under partial failure: the healthy transport is
      // witnessed; the dead transport must NOT be (a whatsapp witness here
      // would false-green the walkthrough's WhatsApp verification).
      expect(readWitness(home, "imessage").tool).toBe("list_message_threads");
      expect(existsSync(witnessPath(home, "whatsapp"))).toBe(false);
    } finally {
      await imessage.close();
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("pins schema parity and generalized ref validation before daemon calls", async () => {
    const home = tempHome();
    try {
      const rows = await runMcp(home, [
        toolCall(2, "stage_message_draft", {
          platform: "imessage",
          to_handle: "not a handle",
          body: "hello",
        }),
        toolCall(3, "stage_message_draft", {
          platform: "whatsapp",
          to_handle: "+14045550100",
          body: "hello",
        }),
        toolCall(4, "stage_message_draft", {
          platform: "imessage",
          to_handle: "+14045550100",
          body: "x".repeat(20_001),
        }),
        toolCall(5, "stage_message_draft", {
          platform: "whatsapp",
          to_handle: WA_JID,
          in_reply_to_thread_ref: "imessage:42",
          body: "hello",
        }),
        toolCall(6, "get_message_thread", { thread_ref: "slack:42" }),
        toolCall(7, "get_message_draft", { draft_ref: "imessage:not-a-uuid" }),
      ]);

      expect(errorText(rows, 2)).toContain("iMessage to_handle must look like an email address or phone number");
      expect(errorText(rows, 3)).toContain("WhatsApp to_handle must look like a JID");
      expect(errorText(rows, 4)).toContain("iMessage draft body must be at most 20000 characters");
      expect(errorText(rows, 5)).toContain("ref platform imessage does not match requested platform whatsapp");
      expect(errorText(rows, 6)).toContain("ref platform must be 'imessage' or 'whatsapp'");
      expect(errorText(rows, 7)).toContain("draft_ref id must be a UUID");

      // None of the rejected calls touched a transport — no witness may
      // exist (an error-path witness would false-green the walkthrough).
      expect(existsSync(witnessPath(home, "imessage"))).toBe(false);
      expect(existsSync(witnessPath(home, "whatsapp"))).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("rejects `before` whenever WhatsApp is in scope instead of silently mispaging", async () => {
    const home = tempHome();
    const paths = daemonPaths(home);
    const imessage = await startFakeDaemon(paths.imessage, fakeIMessage);
    const whatsapp = await startFakeDaemon(paths.whatsapp, fakeWhatsApp);
    try {
      const rows = await runMcp(home, [
        toolCall(2, "list_message_threads", { since: RECENT_SINCE, before: "2026-06-11T00:00:00.000Z" }),
        toolCall(3, "list_message_threads", { platform: "whatsapp", since: RECENT_SINCE, before: "2026-06-11T00:00:00.000Z" }),
        toolCall(4, "list_message_threads", { platform: "imessage", since: RECENT_SINCE, before: "2026-06-11T00:00:00.000Z" }),
      ]);

      // platform=all and platform=whatsapp with `before` → clear refusal,
      // and the WhatsApp daemon is never asked to mispage.
      expect(errorText(rows, 2)).toContain("`before` is only supported with platform=imessage");
      expect(errorText(rows, 3)).toContain("`before` is only supported with platform=imessage");
      expect(whatsapp.calls.filter((call) => call.method === "getThreads")).toEqual([]);

      // platform=imessage keeps full `before` pagination.
      const ok = payloadFor<{ threads: Array<{ platform: string }> }>(rows, 4);
      expect(ok.threads.map((thread) => thread.platform)).toEqual(["imessage"]);
      const listCall = imessage.calls.find((call) => call.method === "listThreads");
      expect((listCall?.params as { beforeIso?: string }).beforeIso).toBe("2026-06-11T00:00:00.000Z");
    } finally {
      await Promise.all([imessage.close(), whatsapp.close()]);
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("rejects quoted_message_id for iMessage drafts instead of silently dropping it", async () => {
    const home = tempHome();
    try {
      const rows = await runMcp(home, [
        toolCall(2, "stage_message_draft", {
          platform: "imessage",
          to_handle: "+14045550100",
          body: "hello",
          quoted_message_id: "p2s-abc",
        }),
      ]);
      expect(errorText(rows, 2)).toContain("quoted_message_id is WhatsApp-only");
      expect(existsSync(witnessPath(home, "imessage"))).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("local transport-scoped ops witness exactly the transport they touched", async () => {
    const home = tempHome();
    try {
      const rows = await runMcp(home, [
        toolCall(2, "set_message_thread_priority", { thread_ref: "imessage:42", level: 1, reason: "urgent" }),
      ]);
      const set = payloadFor<{ ok: boolean; priority: { platform: string } }>(rows, 2);
      expect(set.ok).toBe(true);
      expect(set.priority.platform).toBe("imessage");

      expect(readWitness(home, "imessage").tool).toBe("set_message_thread_priority");
      expect(existsSync(witnessPath(home, "whatsapp"))).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});
