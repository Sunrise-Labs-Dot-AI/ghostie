/** Browser OAuth + official desktop SDK, fixed synthetic host only. Never print tokens. */
import { strict as assert } from 'node:assert';
import { hash, secret } from '../src/store.ts';
import { Client } from '../../ghostie/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
import { StreamableHTTPClientTransport } from '../../ghostie/node_modules/@modelcontextprotocol/sdk/dist/esm/client/streamableHttp.js';
const resource = process.env.GHOSTIE_SYNTHETIC_MCP_URL;
if (!resource || !/^https:\/\/connect\.messagesfor\.ai\/mcp\/hosts\/[A-Za-z0-9_-]{43}$/.test(resource)) throw Error('Explicit synthetic MCP URL required');
const origin = new URL(resource).origin;
const verifier = secret(), state = secret();
const redirect = 'http://127.0.0.1:18764/callback';
let received = false;
let complete!: (code: string) => void;
const callback = new Promise<string>(resolve => { complete = resolve; });
const server = Bun.serve({ hostname: '127.0.0.1', port: 18764, fetch(request) {
  const url = new URL(request.url);
  if (received || request.method !== 'GET' || url.pathname !== '/callback' || url.searchParams.get('state') !== state || !url.searchParams.get('code')) return new Response('Invalid callback', { status: 400 });
  received = true; complete(url.searchParams.get('code')!);
  return new Response('Ghostie synthetic connection approved. You can close this tab.', { headers: { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' } });
} });
const timeout = setTimeout(() => { server.stop(true); process.exit(1); }, 300_000);
const params = new URLSearchParams({ client_id: 'ghostie-desktop', redirect_uri: redirect, response_type: 'code', code_challenge_method: 'S256', code_challenge: hash(verifier), state, resource, scope: 'messages:read messages:draft' });
console.log(`Synthetic desktop authorization: ${origin}/oauth/authorize?${params}`);
let token: string | undefined;
try {
  const code = await callback;
  const response = await fetch(`${origin}/oauth/token`, { method: 'POST', body: new URLSearchParams({ grant_type: 'authorization_code', code, code_verifier: verifier, client_id: 'ghostie-desktop', redirect_uri: redirect, resource }) });
  assert.equal(response.status, 200, 'OAuth exchange');
  token = (await response.json() as { access_token: string }).access_token;
  const client = new Client({ name: 'ghostie-live-acceptance', version: '1.0.0' });
  await client.connect(new StreamableHTTPClientTransport(new URL(resource), { requestInit: { headers: { Authorization: `Bearer ${token}` } } }));
  const listed = await client.listTools();
  assert.deepEqual(listed.tools.map(t => t.name), ['ghostie_connection_check']);
  const result = await client.callTool({ name: 'ghostie_connection_check', arguments: {} });
  assert(JSON.stringify(result).includes('Ghostie synthetic connection works. No messages are available.'));
  await client.close();
  console.log('PASS: live Clerk OAuth, PKCE, desktop SDK initialization/list/call.');
} finally {
  if (token) {
    const response = await fetch(`${origin}/oauth/revoke`, { method: 'POST', body: new URLSearchParams({ token }) });
    assert.equal(response.status, 200);
    assert.equal((await fetch(resource, { method: 'POST', headers: { Authorization: `Bearer ${token}` } })).status, 401);
    console.log('PASS: revoked desktop capability refused.');
  }
  clearTimeout(timeout); server.stop(true);
}
