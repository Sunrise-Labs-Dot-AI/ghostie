import { afterEach, expect, test } from "bun:test";
import { startRelay } from "./server.ts";
import { hash, secret, Store } from "./store.ts";

const resources: { stop(): void; store: Store }[] = [];
afterEach(() => { for (const r of resources.splice(0)) { r.stop(); r.store.db.close(); } });
function fixture(timeoutMs = 500) {
  const store = new Store(":memory:");
  const relay = startRelay({ origin: "https://relay.example.test", store, clients: [{ id: "client-a", name: "Fixture", redirects: ["https://client.example.test/callback"] }], publishableKey: "pk_test_fixture", clerkScriptURL: "https://clerk.example.test/script.js", sessionUser: async () => null, port: 0, timeoutMs });
  resources.push({ ...relay, store });
  const host = secret(), credential = secret();
  store.addHost({ id: host, user: "user-a", credential: hash(credential), created: Date.now() });
  const token = store.issueToken({ host, user: "user-a", client: "client-a", resource: relay.auth.resource(host), expires: Date.now() + 60_000 });
  const request = (path: string, body?: unknown, auth = token, headers: Record<string, string> = {}) => fetch(`http://127.0.0.1:${relay.server.port}${path}`, { method: body === undefined ? "GET" : "POST", headers: { Host: "relay.example.test", Authorization: `Bearer ${auth}`, "Content-Type": "application/json", ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  const connect = () => new Promise<WebSocket>((resolve, reject) => {
    const socket = new WebSocket(`ws://127.0.0.1:${relay.server.port}/hosts/${host}/connect`, { headers: { Host: "relay.example.test", Authorization: `Bearer ${credential}` } });
    socket.onopen = () => resolve(socket); socket.onerror = reject;
  });
  return { ...relay, store, host, token, credential, request, connect, path: `/mcp/hosts/${host}` };
}
test("requires resource auth, rejects foreign origins, reports offline", async () => {
  const f = fixture();
  const unauthorized = await f.request(f.path, {}, secret());
  expect(unauthorized.status).toBe(401);
  expect(unauthorized.headers.get("www-authenticate")).toContain(`/.well-known/oauth-protected-resource${f.path}`);
  expect((await f.request(f.path, {}, f.token, { Origin: "https://evil.example.test" })).status).toBe(403);
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(503);
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
  const response = await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "tools/call" });
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
  expect(await page.text()).toContain('openUserProfile');
  expect((await f.request('/account', undefined, f.token, { Origin: 'https://evil.example.test' })).status).toBe(403);
});

test("duplicate host cannot replace an existing connection", async () => {
  const f = fixture(); const socket = await f.connect();
  const refused = await f.connect().then(other => { other.close(); return false; }, () => true);
  expect(refused).toBe(true);
  expect(f.connections.size).toBe(1);
  socket.onmessage = event => { const work = JSON.parse(String(event.data)); socket.send(JSON.stringify({ id: work.id, response: { jsonrpc: "2.0", id: 1, result: {} } })); };
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(200);
  socket.close();
});

test("per-host in-flight limit fails closed", async () => {
  const f = fixture(200); const socket = await f.connect();
  let received!: () => void; const ready = new Promise<void>(resolve => { received = resolve; });
  socket.onmessage = () => received();
  const first = f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" });
  await ready;
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 2, method: "ping" })).status).toBe(429);
  socket.close(); expect((await first).status).toBe(503);
});

test("removing a configured client invalidates already issued tokens", async () => {
  const f = fixture(); f.auth.clients.splice(0);
  expect((await f.request(f.path, { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(401);
});
