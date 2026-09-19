import { afterEach, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { startRelay } from "./server.ts";
import { hash, secret, Store } from "./store.ts";
import { MESSAGE_LINK_TOOL_NAME, MessageLinkError, type MessageLinkCreator } from "./message-opener.ts";

const resources: { stop(): void; store: Store }[] = [];
afterEach(() => { for (const r of resources.splice(0)) { r.stop(); r.store.db.close(); } });
function fixture(timeoutMs = 500, messageLinks: MessageLinkCreator = {
  async create() { return { url: "https://ghostie.app/t/AbCdEf0123_-GhIj", expires_at: "2026-09-23T12:00:00.000Z" }; },
}, now = Date.now, queueWaitMs = 15_000) {
  const store = new Store(":memory:");
  const relay = startRelay({ origin: "https://relay.example.test", store, clients: [{ id: "client-a", name: "Fixture", redirects: ["https://client.example.test/callback"] }], publishableKey: "pk_test_fixture", clerkScriptURL: "https://clerk.example.test/script.js", messageLinks, sessionUser: async () => null, port: 0, timeoutMs, now, queueWaitMs });
  resources.push({ ...relay, store });
  const host = secret(), credential = secret();
  store.addHost({ id: host, user: "user-a", credential: hash(credential), created: Date.now() });
  const token = store.issueToken({ host, user: "user-a", client: "client-a", resource: relay.auth.resource(host), expires: Date.now() + 60_000 });
  const requestWith = (path: string, auth: string, body?: unknown, headers: Record<string, string> = {}) => fetch(`http://127.0.0.1:${relay.server.port}${path}`, { method: body === undefined ? "GET" : "POST", headers: { Host: "relay.example.test", Authorization: `Bearer ${auth}`, "Content-Type": "application/json", ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  const request = (path: string, body?: unknown, auth = token, headers: Record<string, string> = {}) => requestWith(path, auth, body, headers);
  const addAuthorizedHost = (user = `user-${secret()}`) => {
    const addedHost = secret(), addedCredential = secret();
    store.addHost({ id: addedHost, user, credential: hash(addedCredential), created: Date.now() });
    const addedToken = store.issueToken({ host: addedHost, user, client: "client-a", resource: relay.auth.resource(addedHost), expires: Date.now() + 60_000 });
    const addedPath = `/mcp/hosts/${addedHost}`;
    const addedConnect = () => new Promise<WebSocket>((resolve, reject) => {
      const socket = new WebSocket(`ws://127.0.0.1:${relay.server.port}/hosts/${addedHost}/connect`, { headers: { Host: "relay.example.test", Authorization: `Bearer ${addedCredential}` } });
      socket.onopen = () => resolve(socket); socket.onerror = reject;
    });
    return { host: addedHost, token: addedToken, path: addedPath, request: (body: unknown) => requestWith(addedPath, addedToken, body), connect: addedConnect };
  };
  const connect = () => new Promise<WebSocket>((resolve, reject) => {
    const socket = new WebSocket(`ws://127.0.0.1:${relay.server.port}/hosts/${host}/connect`, { headers: { Host: "relay.example.test", Authorization: `Bearer ${credential}` } });
    socket.onopen = () => resolve(socket); socket.onerror = reject;
  });
  const scopedToken = (scope: string) => store.issueToken({ host, user: "user-a", client: "client-a", resource: relay.auth.resource(host), expires: Date.now() + 60_000, scope });
  const echoHost = (socket: WebSocket, result: (request: any) => unknown = () => ({})) => { socket.onmessage = event => { const work = JSON.parse(String(event.data)); socket.send(JSON.stringify({ id: work.id, response: { jsonrpc: "2.0", id: work.request.id, result: result(work.request) } })); }; };
  return { ...relay, store, host, token, credential, request, connect, addAuthorizedHost, scopedToken, echoHost, path: `/mcp/hosts/${host}` };
}
test("requires resource auth, rejects foreign origins, reports offline", async () => {
  const f = fixture();
  const unauthorized = await f.request(f.path, {}, secret());
  expect(unauthorized.status).toBe(401);
  expect(unauthorized.headers.get("www-authenticate")).toContain(`/.well-known/oauth-protected-resource${f.path}`);
  expect(unauthorized.headers.get("www-authenticate")).toContain('error="invalid_token"');
  expect(unauthorized.headers.get("www-authenticate")).toContain('scope="messages:read messages:draft messages:link"');
  const anonymous = await fetch(`http://127.0.0.1:${f.server.port}${f.path}`, { method: "POST", headers: { Host: "relay.example.test", "Content-Type": "application/json" }, body: "{}" });
  expect(anonymous.status).toBe(401);
  expect(anonymous.headers.get("www-authenticate")).not.toContain("invalid_token");
  const malformed = await fetch(`http://127.0.0.1:${f.server.port}${f.path}`, { method: "POST", headers: { Host: "relay.example.test", "Content-Type": "application/json", Authorization: "Basic nope" }, body: "{}" });
  expect(malformed.status).toBe(401);
  expect(malformed.headers.get("www-authenticate")).toContain('error="invalid_token"');
  expect((await f.request(f.path, {}, f.token, { Origin: "https://evil.example.test" })).status).toBe(403);
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(503);
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 2, method: "initialize", params: { protocolVersion: "2025-11-25" } })).status).toBe(503);
});
test("routes one request to its authenticated host and never persists payloads", async () => {
  const f = fixture(); const socket = await f.connect();
  socket.onmessage = event => {
    const work = JSON.parse(String(event.data));
    socket.send(JSON.stringify({ id: work.id, response: { jsonrpc: "2.0", id: work.request.id, result: { content: [{ type: "text", text: "synthetic-message-body" }] } } }));
  };
  const response = await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_message_thread" } });
  expect(response.status).toBe(200); expect(await response.text()).toContain("synthetic-message-body");
  expect(JSON.stringify(f.store.db.query("SELECT * FROM hosts").all())).not.toContain("synthetic-message-body");
  expect(JSON.stringify(f.store.db.query("SELECT * FROM tokens").all())).not.toContain("synthetic-message-body");
  socket.close();
});
test("disconnect and timeout fail outstanding work without retry", async () => {
  const f = fixture(50); const socket = await f.connect(); let calls = 0;
  socket.onmessage = () => { calls++; };
  const response = await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_message_thread" } });
  expect(response.status).toBe(503); expect(calls).toBe(1);
  socket.onmessage = () => socket.close();
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 2, method: "ping" })).status).toBe(503);
});
test("batch and unknown notification cannot bypass host validation", async () => {
  const f = fixture(); const socket = await f.connect();
  expect((await f.request(f.path, [{ jsonrpc: "2.0", id: 1, method: "ping" }])).status).toBe(400);
  expect((await f.request(f.path, { jsonrpc: "2.0", method: "notifications/initialized" })).status).toBe(202);
  socket.close();
});

test("browser approvals require exact origin and a verified Clerk session", async () => {
  const f = fixture();
  const body = { id: secret(), code: "12345678" };
  expect((await f.request("/api/pair/approve", body)).status).toBe(401);
  expect((await f.request("/api/pair/approve", body, f.token, { Origin: "https://relay.example.test" })).status).toBe(401);
});

test("account page retains browser isolation and no-store headers", async () => {
  const f = fixture();
  const page = await f.request('/account');
  expect(page.status).toBe(200);
  expect(page.headers.get('cache-control')).toBe('no-store');
  expect(page.headers.get('referrer-policy')).toBe('no-referrer');
  expect(page.headers.get('content-security-policy')).toContain("frame-ancestors 'none'");
  expect(page.headers.get('content-security-policy')).toContain('https://clerk.example.test');
  const html = await page.text();
  expect(html).toContain('openUserProfile');
  expect(html).toContain('encrypted ciphertext for seven days');
  expect(html).toContain('public seven-day compose links');
  expect((await f.request('/account', undefined, f.token, { Origin: 'https://evil.example.test' })).status).toBe(403);
});

test("OAuth metadata publishes the dedicated link scope, refresh grants, and offline_access", async () => {
  const f = fixture();
  const authorization = await f.request("/.well-known/oauth-authorization-server");
  const metadata = await authorization.json() as any;
  expect(metadata.scopes_supported).toEqual(["messages:read", "messages:draft", "messages:link", "offline_access"]);
  expect(metadata.grant_types_supported).toEqual(["authorization_code", "refresh_token"]);
  const resource = await f.request(`/.well-known/oauth-protected-resource${f.path}`);
  expect((await resource.json() as any).scopes_supported).toEqual(["messages:read", "messages:draft", "messages:link"]);
});

test("a live connection keeps its slot, a silent one is replaced by the newer authenticated connection", async () => {
  let current = Date.now();
  const f = fixture(500, undefined, () => current); const first = await f.connect();
  const refused = await f.connect().then(other => { other.close(); return false; }, () => true);
  expect(refused).toBe(true);
  expect(f.connections.size).toBe(1);
  current += 20_001;
  const firstClosed = new Promise<number>(resolve => { first.onclose = event => resolve(event.code); });
  const second = await f.connect();
  expect(await firstClosed).toBe(1012);
  expect(f.connections.size).toBe(1);
  f.echoHost(second, () => ({ served_by: "second" }));
  const response = await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" });
  expect(response.status).toBe(200);
  expect(await response.text()).toContain("second");
  second.close();
  await Bun.sleep(20);
  expect(f.connections.size).toBe(0);
});

test("replacing a stale connection fails its outstanding work without retry", async () => {
  let current = Date.now();
  const f = fixture(200, undefined, () => current); const first = await f.connect(); let received!: () => void;
  const ready = new Promise<void>(resolve => { received = resolve; });
  first.onmessage = () => received();
  const inflight = f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" });
  await ready;
  current += 20_001;
  const second = await f.connect();
  expect((await inflight).status).toBe(503);
  second.close();
});

test("heartbeats and responses keep a connection live; two concurrent connects settle on the later one", async () => {
  let current = Date.now();
  const f = fixture(500, undefined, () => current); const first = await f.connect();
  current += 15_000; first.send(JSON.stringify({ heartbeat: 1 })); await Bun.sleep(20);
  current += 15_000;
  expect(await f.connect().then(other => { other.close(); return false; }, () => true)).toBe(true);
  current += 20_001;
  const codes: number[] = [];
  first.onclose = event => { codes.push(event.code); };
  // Two attempts racing for the same slot: exactly one survives, the silent socket is the one evicted,
  // and the loser is either refused before the upgrade (409) or closed right after it (1008).
  const results = await Promise.allSettled([f.connect(), f.connect()]);
  await Bun.sleep(30);
  const opened = results.filter(result => result.status === "fulfilled").map(result => result.value);
  expect(opened.filter(ws => ws.readyState === WebSocket.OPEN).length).toBe(1);
  expect(f.connections.size).toBe(1);
  // The survivor is always the attempt that was authorized last, whichever socket finished its handshake first.
  expect(f.connections.get(f.host)!.data.sequence).toBe(f.sequence());
  expect(f.sequence()).toBeGreaterThanOrEqual(2);
  expect(codes).toEqual([1012]);
  for (const ws of opened) ws.close();
});

test("discovery and pings run concurrently while tool calls reach the Mac one at a time", async () => {
  const f = fixture(2_000); const socket = await f.connect();
  let inflight = 0, peak = 0; const seen: string[] = [];
  socket.onmessage = async event => {
    const work = JSON.parse(String(event.data)); seen.push(work.request.method);
    inflight++; peak = Math.max(peak, inflight);
    await Bun.sleep(work.request.method === "tools/call" ? 60 : 20);
    inflight--;
    socket.send(JSON.stringify({ id: work.id, response: { jsonrpc: "2.0", id: work.request.id, result: { order: seen.length } } }));
  };
  const parallel = await Promise.all([1, 2, 3, 4].map(id => f.request(f.path, { jsonrpc: "2.0", id, method: id % 2 ? "ping" : "tools/list" })));
  expect(parallel.map(r => r.status)).toEqual([200, 200, 200, 200]);
  expect(peak).toBeGreaterThan(1);
  inflight = 0; peak = 0;
  const calls = await Promise.all([10, 11, 12].map(id => f.request(f.path, { jsonrpc: "2.0", id, method: "tools/call", params: { name: "get_message_thread" } })));
  expect(calls.map(r => r.status)).toEqual([200, 200, 200]);
  expect(peak).toBe(1);
  expect(seen.filter(m => m === "tools/call").length).toBe(3);
  socket.close();
});

test("tool call queue is bounded and a waiter that times out gets a busy error, not a dropped request", async () => {
  const f = fixture(5_000, undefined, Date.now, 100); const socket = await f.connect();
  let release!: () => void; const held = new Promise<void>(resolve => { release = resolve; }); let started!: () => void; const began = new Promise<void>(resolve => { started = resolve; });
  socket.onmessage = async event => {
    const work = JSON.parse(String(event.data)); started(); await held;
    socket.send(JSON.stringify({ id: work.id, response: { jsonrpc: "2.0", id: work.request.id, result: {} } }));
  };
  const call = (id: number) => f.request(f.path, { jsonrpc: "2.0", id, method: "tools/call", params: { name: "get_message_thread" } });
  const first = call(1); await began;
  const waiters = Array.from({ length: 8 }, (_, index) => call(index + 2));
  await Bun.sleep(10);
  expect((await call(99)).status).toBe(429);
  const timedOut = await Promise.all(waiters);
  expect(timedOut.map(r => r.status)).toEqual(Array(8).fill(200));
  for (const response of timedOut) expect(((await response.json()) as any).error.code).toBe(-32000);
  release();
  expect((await first).status).toBe(200);
  expect((await call(100)).status).toBe(200);
  socket.close();
});

test("per-host and per-account in-flight caps fail closed while another account is still served", async () => {
  const f = fixture(500); const socket = await f.connect();
  let count = 0; let full!: () => void; const eight = new Promise<void>(resolve => { full = resolve; });
  socket.onmessage = () => { if (++count === 8) full(); };
  const held = Array.from({ length: 8 }, (_, id) => f.request(f.path, { jsonrpc: "2.0", id, method: "ping" }));
  await eight;
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 9, method: "ping" })).status).toBe(429);
  // A second Mac of the same account fills the account budget of 16 ...
  const sibling = f.addAuthorizedHost("user-a"); const siblingSocket = await sibling.connect();
  let siblingCount = 0; let siblingFull!: () => void; const sixteen = new Promise<void>(resolve => { siblingFull = resolve; });
  siblingSocket.onmessage = () => { if (++siblingCount === 8) siblingFull(); };
  const siblingHeld = Array.from({ length: 8 }, (_, id) => sibling.request({ jsonrpc: "2.0", id, method: "ping" }));
  await sixteen;
  // ... so a third Mac of the same account is refused before the relay even looks for its socket (429, not 503) ...
  const third = f.addAuthorizedHost("user-a");
  expect((await third.request({ jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(429);
  // ... while another account with no socket still reaches the offline answer.
  const other = f.addAuthorizedHost("user-b");
  expect((await other.request({ jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(503);
  socket.close(); siblingSocket.close();
  expect((await Promise.all([...held, ...siblingHeld])).every(r => r.status === 503)).toBe(true);
});

test("per-host request limit admits a multi-persona burst, refuses the excess, and resets after a minute", async () => {
  let current = Date.now();
  const f = fixture(500, undefined, () => current); const socket = await f.connect(); f.echoHost(socket);
  const token = f.store.issueToken({ host: f.host, user: "user-a", client: "client-a", resource: f.auth.resource(f.host), expires: Date.now() + 600_000 });
  // Sixty personas initializing at once send four requests each; the old limit of 60 refused the first burst's second request.
  for (let i = 0; i < 240; i += 1) expect((await f.request(f.path, { jsonrpc: "2.0", method: "notifications/initialized" }, token)).status).toBe(202);
  const refused = await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" }, token);
  expect(refused.status).toBe(429);
  expect(((await refused.json()) as { error: string }).error).toBe("rate_limited");
  current += 60_001;
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 2, method: "ping" }, token)).status).toBe(200);
  socket.close();
});
test("removing a configured client invalidates already issued tokens", async () => {
  const f = fixture(); f.auth.clients.splice(0);
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(401);
});

test("relay advertises the link tool online and can execute a discovered link call after the Mac disconnects", async () => {
  const calls: unknown[] = [];
  const f = fixture(500, { async create(input) { calls.push(input); return { url: "https://ghostie.app/t/AbCdEf0123_-GhIj", expires_at: "2026-09-23T12:00:00.000Z" }; } });
  const socket = await f.connect();
  socket.onmessage = event => {
    const work = JSON.parse(String(event.data));
    socket.send(JSON.stringify({ id: work.id, response: { jsonrpc: "2.0", id: work.request.id, result: { tools: [{ name: "get_message_thread", inputSchema: { type: "object" } }] } } }));
  };
  const listed = await f.request(f.path, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
  const tools = ((await listed.json() as any).result.tools as { name: string }[]);
  expect(tools.map(tool => tool.name)).toEqual(["get_message_thread", MESSAGE_LINK_TOOL_NAME]);
  socket.close();
  await Bun.sleep(20);
  const response = await f.request(f.path, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body: "Synthetic hello" } } });
  expect(response.status).toBe(200);
  const payload = await response.json() as any;
  expect(payload.id).toBe(3);
  expect(payload.result.structuredContent.url).toBe("https://ghostie.app/t/AbCdEf0123_-GhIj");
  expect(calls).toEqual([{ phone: "+12155550123", body: "Synthetic hello" }]);
});

test("connected tool discovery replaces a host tool with the canonical relay tool", async () => {
  const f = fixture();
  const socket = await f.connect();
  socket.onmessage = event => {
    const work = JSON.parse(String(event.data));
    socket.send(JSON.stringify({ id: work.id, response: { jsonrpc: "2.0", id: work.request.id, result: { tools: [
      { name: "get_message_thread", inputSchema: { type: "object" } },
      { name: MESSAGE_LINK_TOOL_NAME, description: "untrusted host copy", inputSchema: {} },
    ] } } }));
  };
  const response = await f.request(f.path, { jsonrpc: "2.0", id: 4, method: "tools/list", params: {} });
  const tools = ((await response.json() as any).result.tools as { name: string; description?: string }[]);
  expect(tools.map(tool => tool.name)).toEqual(["get_message_thread", MESSAGE_LINK_TOOL_NAME]);
  expect(tools[1]!.description).toContain("never sends");
  socket.close();
});

test("link failures are protocol-valid, retain the request id, and do not expose inputs", async () => {
  const f = fixture(500, { async create() { throw new MessageLinkError("outcome_unknown", "Outcome unknown. Do not retry automatically."); } });
  const body = "private-body-canary";
  const response = await f.request(f.path, { jsonrpc: "2.0", id: "link-1", method: "tools/call", params: { name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body } } });
  expect(response.status).toBe(200);
  const text = await response.text();
  expect(text).toContain('"id":"link-1"');
  expect(text).toContain("Do not retry automatically");
  expect(text).not.toContain(body);
  expect(text).not.toContain("+12155550123");
});

test("link creation is limited per host before another upstream request", async () => {
  let calls = 0;
  const f = fixture(500, { async create() { calls += 1; return { url: "https://ghostie.app/t/AbCdEf0123_-GhIj", expires_at: "2026-09-23T12:00:00.000Z" }; } });
  const rpc = (id: number) => ({ jsonrpc: "2.0", id, method: "tools/call", params: { name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body: "Synthetic" } } });
  for (let id = 1; id <= 6; id += 1) expect((await f.request(f.path, rpc(id))).status).toBe(200);
  const limited = await f.request(f.path, rpc(7));
  expect(limited.status).toBe(200);
  const payload = await limited.json() as any;
  expect(payload.id).toBe(7);
  expect(payload.result.isError).toBe(true);
  expect(calls).toBe(6);
});

test("link creation enforces one in-flight call per host", async () => {
  let release!: () => void;
  let started!: () => void;
  const began = new Promise<void>(resolve => { started = resolve; });
  const held = new Promise<void>(resolve => { release = resolve; });
  const f = fixture(500, { async create() { started(); await held; return { url: "https://ghostie.app/t/AbCdEf0123_-GhIj", expires_at: "2026-09-23T12:00:00.000Z" }; } });
  const rpc = (id: number) => ({ jsonrpc: "2.0", id, method: "tools/call", params: { name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body: "Synthetic" } } });
  const first = f.request(f.path, rpc(1));
  await began;
  const blocked = await f.request(f.path, rpc(2));
  expect(blocked.status).toBe(200);
  expect((await blocked.json() as any).result.isError).toBe(true);
  release();
  expect((await first).status).toBe(200);
});

test("link creation enforces the global in-flight cap", async () => {
  let release!: () => void;
  const held = new Promise<void>(resolve => { release = resolve; });
  let calls = 0;
  let allStarted!: () => void;
  const began = new Promise<void>(resolve => { allStarted = resolve; });
  const f = fixture(500, { async create() { calls += 1; if (calls === 10) allStarted(); await held; return { url: "https://ghostie.app/t/AbCdEf0123_-GhIj", expires_at: "2026-09-23T12:00:00.000Z" }; } });
  const hosts = [{ request: (body: unknown) => f.request(f.path, body) }];
  for (let index = 1; index < 11; index += 1) hosts.push(f.addAuthorizedHost());
  const rpc = (id: number) => ({ jsonrpc: "2.0", id, method: "tools/call", params: { name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body: "Synthetic" } } });
  const active = hosts.slice(0, 10).map((host, index) => host.request(rpc(index + 1)));
  await began;
  const limited = await hosts[10]!.request(rpc(11));
  expect(limited.status).toBe(200);
  const limitedPayload = await limited.json() as any;
  expect(limitedPayload.id).toBe(11);
  expect(limitedPayload.result.isError).toBe(true);
  expect(calls).toBe(10);
  release();
  expect((await Promise.all(active)).every(response => response.status === 200)).toBe(true);
});

test("link creation rejects expired, revoked, wrong-resource, and unknown-client tokens", async () => {
  let calls = 0;
  const f = fixture(500, { async create() { calls += 1; return { url: "https://ghostie.app/t/AbCdEf0123_-GhIj", expires_at: "2026-09-23T12:00:00.000Z" }; } });
  const rpc = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body: "Synthetic" } } };
  const expired = f.store.issueToken({ host: f.host, user: "user-a", client: "client-a", resource: f.auth.resource(f.host), expires: Date.now() - 1 });
  const wrongResource = f.store.issueToken({ host: f.host, user: "user-a", client: "client-a", resource: "https://relay.example.test/mcp/hosts/wrong", expires: Date.now() + 60_000 });
  const unknownClient = f.store.issueToken({ host: f.host, user: "user-a", client: "unknown", resource: f.auth.resource(f.host), expires: Date.now() + 60_000 });
  const revoked = f.store.issueToken({ host: f.host, user: "user-a", client: "client-a", resource: f.auth.resource(f.host), expires: Date.now() + 60_000 });
  f.store.revoke(revoked);
  for (const token of [expired, wrongResource, unknownClient, revoked]) expect((await f.request(f.path, rpc, token)).status).toBe(401);
  expect(calls).toBe(0);
});

test("link limit is a rolling minute rather than a fixed window", async () => {
  let current = 0;
  let calls = 0;
  const f = fixture(500, { async create() { calls += 1; return { url: "https://ghostie.app/t/AbCdEf0123_-GhIj", expires_at: "2026-09-23T12:00:00.000Z" }; } }, () => current);
  const rpc = (id: number) => ({ jsonrpc: "2.0", id, method: "tools/call", params: { name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body: "Synthetic" } } });
  expect((await f.request(f.path, rpc(1))).status).toBe(200);
  current = 59_999;
  for (let id = 2; id <= 6; id += 1) expect((await f.request(f.path, rpc(id))).status).toBe(200);
  current = 60_001;
  expect((await (await f.request(f.path, rpc(7))).json() as any).result.isError).toBeUndefined();
  expect((await (await f.request(f.path, rpc(8))).json() as any).result.isError).toBe(true);
  expect(calls).toBe(7);
});

test("standard MCP SDK parses link rate limits as tool results", async () => {
  let calls = 0;
  const f = fixture(500, { async create() { calls += 1; return { url: "https://ghostie.app/t/AbCdEf0123_-GhIj", expires_at: "2026-09-23T12:00:00.000Z" }; } });
  const socket = await f.connect();
  socket.onmessage = event => {
    const work = JSON.parse(String(event.data));
    const result = work.request.method === "initialize"
      ? { protocolVersion: work.request.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } }
      : { tools: [{ name: "get_message_thread", inputSchema: { type: "object" } }] };
    socket.send(JSON.stringify({ id: work.id, response: { jsonrpc: "2.0", id: work.request.id, result } }));
  };
  const client = new Client({ name: "relay-test", version: "1" });
  const transport = new StreamableHTTPClientTransport(new URL(`https://relay.example.test${f.path}`), {
    fetch: async (_url, init) => {
      const headers = new Headers(init?.headers);
      headers.set("Host", "relay.example.test");
      headers.set("Authorization", `Bearer ${f.token}`);
      return fetch(`http://127.0.0.1:${f.server.port}${f.path}`, { ...init, headers });
    },
  });
  try {
    await client.connect(transport);
    expect((await client.listTools()).tools.map(tool => tool.name)).toEqual(["get_message_thread", MESSAGE_LINK_TOOL_NAME]);
    for (let count = 0; count < 6; count += 1) {
      const result = await client.callTool({ name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body: "Synthetic" } });
      expect(result.isError).not.toBe(true);
    }
    const limited = await client.callTool({ name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body: "Synthetic" } });
    expect(limited.isError).toBe(true);
    expect(JSON.stringify(limited)).toContain("after a minute");
    expect(calls).toBe(6);
  } finally {
    await client.close();
    socket.close();
  }
});

test("scope limits tool calls and trims discovery, with a step-up challenge on refusal", async () => {
  const f = fixture(); const socket = await f.connect();
  f.echoHost(socket, request => request.method === "tools/list"
    ? { tools: [{ name: "get_message_thread", inputSchema: { type: "object" } }, { name: "stage_message_draft", inputSchema: { type: "object" } }] }
    : { content: [{ type: "text", text: "ok" }] });
  const readOnly = f.scopedToken("messages:read");
  const listed = await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }, readOnly);
  expect(((await listed.json()) as any).result.tools.map((t: any) => t.name)).toEqual(["get_message_thread"]);
  const refused = await f.request(f.path, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "stage_message_draft", arguments: {} } }, readOnly);
  expect(refused.status).toBe(403);
  expect(refused.headers.get("www-authenticate")).toContain('error="insufficient_scope"');
  expect(refused.headers.get("www-authenticate")).toContain('scope="messages:draft"');
  for (const name of ["approve_message_draft", "", 7, undefined]) {
    const unknown = await f.request(f.path, { jsonrpc: "2.0", id: 9, method: "tools/call", params: { name, arguments: {} } });
    expect(unknown.status).toBe(200);
    expect(((await unknown.json()) as any).error.code).toBe(-32602);
  }
  const link = await f.request(f.path, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: MESSAGE_LINK_TOOL_NAME, arguments: { phone: "+12155550123", body: "Synthetic" } } }, readOnly);
  expect(link.status).toBe(403);
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "get_message_thread", arguments: {} } }, readOnly)).status).toBe(200);
  const full = await f.request(f.path, { jsonrpc: "2.0", id: 5, method: "tools/list", params: {} }, f.scopedToken("messages:read messages:draft messages:link"));
  expect(((await full.json()) as any).result.tools.map((t: any) => t.name)).toEqual(["get_message_thread", "stage_message_draft", MESSAGE_LINK_TOOL_NAME]);
  socket.close();
});

test("token endpoint exchanges a code, rotates refresh tokens, and rejects replay over HTTP", async () => {
  let current = Date.now();
  const f = fixture(500, undefined, () => current);
  const verifier = secret();
  const consent = { client_id: "client-a", redirect_uri: "https://client.example.test/callback", response_type: "code", code_challenge_method: "S256", code_challenge: hash(verifier), state: "s", resource: f.auth.resource(f.host), scope: "messages:read messages:draft" };
  const code = new URL(f.auth.approveConsent(consent, "user-a")).searchParams.get("code")!;
  const post = (body: Record<string, string>) => fetch(`http://127.0.0.1:${f.server.port}/oauth/token`, { method: "POST", headers: { Host: "relay.example.test", "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(body) });
  const issued = await post({ grant_type: "authorization_code", code, client_id: "client-a", redirect_uri: consent.redirect_uri, resource: consent.resource, code_verifier: verifier });
  expect(issued.status).toBe(200);
  const first = await issued.json() as any;
  expect(first.refresh_token).toBeTruthy(); expect(first.scope).toBe("messages:read messages:draft"); expect(first.expires_in).toBe(3600);
  const renewed = await post({ grant_type: "refresh_token", refresh_token: first.refresh_token, client_id: "client-a", resource: consent.resource });
  expect(renewed.status).toBe(200);
  const second = await renewed.json() as any;
  expect(second.refresh_token).not.toBe(first.refresh_token);
  expect(second.scope).toBe("messages:read messages:draft");
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" }, second.access_token)).status).toBe(503);
  const widened = await post({ grant_type: "refresh_token", refresh_token: second.refresh_token, client_id: "client-a", scope: "messages:read messages:draft messages:link" });
  expect(widened.status).toBe(400); expect((await widened.json() as any).error).toBe("invalid_grant");
  current += 30_001;
  const replay = await post({ grant_type: "refresh_token", refresh_token: first.refresh_token, client_id: "client-a" });
  expect(replay.status).toBe(400); expect((await replay.json() as any).error).toBe("invalid_grant");
  // Replay revoked the whole family, including the access token still in the client's hands.
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 2, method: "ping" }, second.access_token)).status).toBe(401);
  expect((await post({ grant_type: "refresh_token", refresh_token: second.refresh_token, client_id: "client-a" })).status).toBe(400);
  const again = new URL(f.auth.approveConsent({ ...consent, code_challenge: hash(verifier) }, "user-a")).searchParams.get("code")!;
  const third = await (await post({ grant_type: "authorization_code", code: again, client_id: "client-a", redirect_uri: consent.redirect_uri, resource: consent.resource, code_verifier: verifier })).json() as any;
  const revoke = await fetch(`http://127.0.0.1:${f.server.port}/oauth/revoke`, { method: "POST", headers: { Host: "relay.example.test", "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ token: third.refresh_token }) });
  expect(revoke.status).toBe(200);
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 3, method: "ping" }, third.access_token)).status).toBe(401);
  expect((await post({ grant_type: "refresh_token", refresh_token: third.refresh_token, client_id: "client-a" })).status).toBe(400);
});

test("relay echoes host heartbeats and ignores malformed ones", async () => {
  const f = fixture(); const socket = await f.connect();
  const replies: string[] = [];
  socket.onmessage = event => replies.push(String(event.data));
  socket.send(JSON.stringify({ heartbeat: 7 }));
  socket.send(JSON.stringify({ heartbeat: "7" }));
  socket.send(JSON.stringify({ heartbeat: 8, id: "x" }));
  await Bun.sleep(30);
  expect(replies).toEqual([JSON.stringify({ heartbeat: 7 })]);
  expect(f.connections.size).toBe(1);
  socket.close();
});

test("a connect request that is not a WebSocket upgrade leaves the live connection untouched", async () => {
  const f = fixture(); const socket = await f.connect();
  const plain = await fetch(`http://127.0.0.1:${f.server.port}/hosts/${f.host}/connect`, { headers: { Host: "relay.example.test", Authorization: `Bearer ${f.credential}` } });
  expect([409, 426]).toContain(plain.status);
  expect(f.connections.size).toBe(1);
  f.echoHost(socket);
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(200);
  socket.close();
});
