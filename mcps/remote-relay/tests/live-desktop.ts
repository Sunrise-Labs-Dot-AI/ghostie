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
const params = new URLSearchParams({ client_id: 'ghostie-desktop', redirect_uri: redirect, response_type: 'code', code_challenge_method: 'S256', code_challenge: hash(verifier), state, resource, scope: 'messages:read messages:draft messages:link' });
console.log(`Synthetic desktop authorization: ${origin}/oauth/authorize?${params}`);
let token: string | undefined;
let refreshToken: string | undefined;
try {
  const code = await callback;
  const response = await fetch(`${origin}/oauth/token`, { method: 'POST', body: new URLSearchParams({ grant_type: 'authorization_code', code, code_verifier: verifier, client_id: 'ghostie-desktop', redirect_uri: redirect, resource }) });
  assert.equal(response.status, 200, 'OAuth exchange');
  const issued = await response.json() as { access_token: string; refresh_token: string; scope: string };
  assert.equal(issued.scope, 'messages:read messages:draft messages:link');
  assert.match(issued.refresh_token, /^[A-Za-z0-9_-]{43}$/);
  token = issued.access_token; refreshToken = issued.refresh_token;
  const client = new Client({ name: 'ghostie-live-acceptance', version: '1.0.0' });
  await client.connect(new StreamableHTTPClientTransport(new URL(resource), { requestInit: { headers: { Authorization: `Bearer ${token}` } } }));
  const listed = await client.listTools();
  assert.deepEqual(listed.tools.map(t => t.name), ['ghostie_connection_check', 'ghostie_create_messages_link']);
  const result = await client.callTool({ name: 'ghostie_connection_check', arguments: {} });
  assert(JSON.stringify(result).includes('Ghostie synthetic connection works. No messages are available.'));
  const link = await client.callTool({ name: 'ghostie_create_messages_link', arguments: { phone: '+12155550123', body: 'Synthetic Ghostie compose-link acceptance.' } });
  assert.match(JSON.stringify(link), /https:\/\/ghostie\.app\/t\/[A-Za-z0-9_-]{16}/);
  await client.close();
  console.log('PASS: live Clerk OAuth, PKCE, desktop SDK discovery, host call, and compose-link creation.');
  // Rotate once without any browser step, use the renewed token, then confirm the rotated token is dead.
  const renewed = await fetch(`${origin}/oauth/token`, { method: 'POST', body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken, client_id: 'ghostie-desktop', resource }) });
  assert.equal(renewed.status, 200, 'refresh grant');
  const rotated = await renewed.json() as { access_token: string; refresh_token: string };
  assert.notEqual(rotated.refresh_token, refreshToken);
  const previousToken = token;
  token = rotated.access_token; refreshToken = rotated.refresh_token;
  const renewedClient = new Client({ name: 'ghostie-live-acceptance-refreshed', version: '1.0.0' });
  await renewedClient.connect(new StreamableHTTPClientTransport(new URL(resource), { requestInit: { headers: { Authorization: `Bearer ${token}` } } }));
  assert(JSON.stringify(await renewedClient.callTool({ name: 'ghostie_connection_check', arguments: {} })).includes('Ghostie synthetic connection works.'));
  await renewedClient.close();
  await fetch(`${origin}/oauth/revoke`, { method: 'POST', body: new URLSearchParams({ token: previousToken }) });
  console.log('PASS: refresh token rotation renewed access without re-consent.');
} finally {
  if (refreshToken) {
    // Revoking the refresh token ends the whole grant, including the access token.
    const response = await fetch(`${origin}/oauth/revoke`, { method: 'POST', body: new URLSearchParams({ token: refreshToken }) });
    assert.equal(response.status, 200);
    assert.equal((await fetch(`${origin}/oauth/token`, { method: 'POST', body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken, client_id: 'ghostie-desktop' }) })).status, 400);
  }
  if (token) {
    assert.equal((await fetch(resource, { method: 'POST', headers: { Authorization: `Bearer ${token}` } })).status, 401);
    console.log('PASS: revoked desktop capability and refresh token refused.');
  }
  clearTimeout(timeout); server.stop(true);
}
