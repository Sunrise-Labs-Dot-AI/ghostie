import { expect, test } from "bun:test";
import {
  createMessageLinkCreator,
  MESSAGE_LINK_TOOL,
  MessageLinkError,
  messageLinkInputSchema,
  messageLinkInternals,
} from "./message-opener.ts";

const NOW = Date.parse("2026-09-16T12:00:00.000Z");
const EXPIRES_AT = new Date(NOW + 7 * 24 * 60 * 60 * 1_000).toISOString();
const LINK = "https://ghostie.app/t/AbCdEf0123_-GhIj";
const success = (value: unknown = { url: LINK, expires_at: EXPIRES_AT }, headers: Record<string, string> = {}) => new Response(JSON.stringify(value), {
  status: 201,
  headers: { "Content-Type": "application/json; charset=utf-8", ...headers },
});

test("creates a link with one authenticated, non-following request", async () => {
  const calls: { input: string | URL | Request; init?: RequestInit }[] = [];
  const creator = createMessageLinkCreator({
    token: "token-canary-that-must-stay-server-side",
    now: () => NOW,
    fetcher: async (input, init) => { calls.push({ input, init }); return success(); },
  });
  expect(await creator.create({ phone: "+12155550123", body: "Synthetic hello 👻" })).toEqual({ url: LINK, expires_at: EXPIRES_AT });
  expect(calls).toHaveLength(1);
  expect(String(calls[0]!.input)).toBe("https://ghostie.app/v1/links");
  expect(calls[0]!.init?.method).toBe("POST");
  expect(calls[0]!.init?.redirect).toBe("error");
  expect(new Headers(calls[0]!.init?.headers).get("authorization")).toBe("Bearer token-canary-that-must-stay-server-side");
  expect(JSON.parse(String(calls[0]!.init?.body))).toEqual({ phone: "+12155550123", body: "Synthetic hello 👻" });
});

test("matches the opener phone and Unicode input boundary", () => {
  const valid = [
    { phone: "+12155550123", body: "hello" },
    { phone: "+1234567", body: "x" },
    { phone: "+123456789012345", body: "👻".repeat(2_000) },
    { phone: "+12155550123", body: "line one\nline two\t& ? # \u202E" },
  ];
  for (const input of valid) expect(messageLinkInputSchema.safeParse(input).success).toBe(true);
  const invalid = [
    { phone: "12155550123", body: "hello" },
    { phone: "+1 (215) 555-0123", body: "hello" },
    { phone: "+١٢١٥٥٥٥٠١٢٣", body: "hello" },
    { phone: "+12155550123", body: "   \n\t" },
    { phone: "+12155550123", body: "\ud800" },
    { phone: "+12155550123", body: "👻".repeat(2_001) },
    { phone: "+12155550123", body: "hello", extra: true },
  ];
  for (const input of invalid) expect(messageLinkInputSchema.safeParse(input).success).toBe(false);
  expect(Array.from("👻".repeat(2_000))).toHaveLength(messageLinkInternals.MAX_BODY_SCALARS);
});

test("treats every malformed 201 response as an unknown outcome", async () => {
  const cases: Response[] = [
    new Response("not json", { status: 201, headers: { "Content-Type": "text/plain" } }),
    new Response("x".repeat(messageLinkInternals.MAX_RESPONSE_BYTES + 1), { status: 201, headers: { "Content-Type": "application/json" } }),
    success({ url: "https://evil.example/t/AbCdEf0123_-GhIj", expires_at: EXPIRES_AT }),
    success({ url: `${LINK}?leak=1`, expires_at: EXPIRES_AT }),
    success({ url: LINK, expires_at: new Date(NOW + messageLinkInternals.MIN_TTL_MS - 1).toISOString() }),
    success({ url: LINK, expires_at: new Date(NOW + messageLinkInternals.MAX_TTL_MS + 1).toISOString() }),
    success({ url: LINK, expires_at: "2026-09-23T12:00:00+00:00" }),
    success({ url: LINK, expires_at: EXPIRES_AT, extra: true }),
  ];
  for (const response of cases) {
    const creator = createMessageLinkCreator({ token: "x".repeat(32), now: () => NOW, fetcher: async () => response });
    await expect(creator.create({ phone: "+12155550123", body: "Synthetic" })).rejects.toMatchObject({ kind: "outcome_unknown" });
  }
});

test("a definite non-201 response is unavailable and safe to retry later", async () => {
  const creator = createMessageLinkCreator({
    token: "x".repeat(32),
    now: () => NOW,
    fetcher: async () => new Response("{}", { status: 500, headers: { "Content-Type": "application/json" } }),
  });
  await expect(creator.create({ phone: "+12155550123", body: "Synthetic" })).rejects.toMatchObject({ kind: "unavailable" });
});

test("caps a streamed response even without Content-Length", async () => {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode("x".repeat(5_000)));
      controller.enqueue(new TextEncoder().encode("y".repeat(5_000)));
      controller.close();
    },
  });
  const creator = createMessageLinkCreator({
    token: "x".repeat(32),
    now: () => NOW,
    fetcher: async () => new Response(stream, { status: 201, headers: { "Content-Type": "application/json" } }),
  });
  await expect(creator.create({ phone: "+12155550123", body: "Synthetic" })).rejects.toMatchObject({ kind: "outcome_unknown" });
});

test("timeout remains active while a successful response body stalls", async () => {
  let cancelled = 0;
  let calls = 0;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new TextEncoder().encode('{"url":"https://ghostie.app/')); },
    cancel() { cancelled += 1; },
  });
  const creator = createMessageLinkCreator({
    token: "x".repeat(32), timeoutMs: 20, now: () => NOW,
    fetcher: async () => { calls += 1; return new Response(stream, { status: 201, headers: { "Content-Type": "application/json" } }); },
  });
  await expect(creator.create({ phone: "+12155550123", body: "Synthetic" })).rejects.toMatchObject({ kind: "outcome_unknown" });
  expect(calls).toBe(1);
  expect(cancelled).toBe(1);
});

test("timeout aborts a stalled upstream request without retrying", async () => {
  let calls = 0;
  const creator = createMessageLinkCreator({
    token: "x".repeat(32), timeoutMs: 20, now: () => NOW,
    fetcher: async (_input, init) => {
      calls += 1;
      return await new Promise<Response>((_resolve, reject) => init?.signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true }));
    },
  });
  await expect(creator.create({ phone: "+12155550123", body: "Synthetic" })).rejects.toMatchObject({ kind: "outcome_unknown" });
  expect(calls).toBe(1);
});

test("network and timeout-style failures are outcome unknown with no automatic retry", async () => {
  const token = "private-token-canary".repeat(3);
  const phone = "+12155550123";
  const body = "private-body-canary";
  let calls = 0;
  const creator = createMessageLinkCreator({ token, now: () => NOW, fetcher: async () => { calls += 1; throw new TypeError("redirect or network failure"); } });
  let caught: unknown;
  try { await creator.create({ phone, body }); } catch (error) { caught = error; }
  expect(calls).toBe(1);
  expect(caught).toBeInstanceOf(MessageLinkError);
  expect(caught).toMatchObject({ kind: "outcome_unknown" });
  const serialized = String((caught as Error).message);
  expect(serialized).toContain("Do not retry automatically");
  for (const secret of [token, phone, body]) expect(serialized).not.toContain(secret);
});

test("client code emits no console output on success or failure", async () => {
  const original = { log: console.log, warn: console.warn, error: console.error };
  const captured: unknown[] = [];
  console.log = (...values) => { captured.push(values); };
  console.warn = (...values) => { captured.push(values); };
  console.error = (...values) => { captured.push(values); };
  try {
    const good = createMessageLinkCreator({ token: "x".repeat(32), now: () => NOW, fetcher: async () => success() });
    await good.create({ phone: "+12155550123", body: "Synthetic" });
    const bad = createMessageLinkCreator({ token: "x".repeat(32), now: () => NOW, fetcher: async () => { throw new Error("failure"); } });
    await bad.create({ phone: "+12155550123", body: "Synthetic" }).catch(() => undefined);
  } finally {
    console.log = original.log;
    console.warn = original.warn;
    console.error = original.error;
  }
  expect(captured).toEqual([]);
});

test("advertised tool is compose-only and accurately annotated", () => {
  expect(MESSAGE_LINK_TOOL.name).toBe("ghostie_create_messages_link");
  expect(MESSAGE_LINK_TOOL.description).toContain("never sends");
  expect(MESSAGE_LINK_TOOL.annotations).toEqual({ readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true });
  expect(MESSAGE_LINK_TOOL.inputSchema.additionalProperties).toBe(false);
  expect(MESSAGE_LINK_TOOL.inputSchema.properties.body).toMatchObject({ maxLength: 2_000, pattern: "\\S" });
});
