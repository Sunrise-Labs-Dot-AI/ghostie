import { afterAll, beforeAll, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { startProbe, resultText, tool } from './probe.ts';
let dir: string;
let probe: ReturnType<typeof startProbe>;
let ca: string;
let url: URL;
beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), 'ghostie-probe-'));
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(dir, 'key.pem'), '-out', join(dir, 'cert.pem'), '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'], { stdio: 'ignore' });
  ca = readFileSync(join(dir, 'cert.pem'), 'utf8');
  probe = startProbe({ cert: ca, key: readFileSync(join(dir, 'key.pem'), 'utf8') });
  url = new URL(`https://localhost:${probe.server.port}/mcp`);
});
afterAll(() => { probe?.server.stop(true); if (dir) rmSync(dir, { recursive: true, force: true }); });
const verifiedFetch: typeof fetch = ((input: RequestInfo | URL, init?: RequestInit) => fetch(input, { ...init, tls: { ca } })) as typeof fetch;
const request = (body: unknown) => verifiedFetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const call = (method: string, params?: unknown) => request({ jsonrpc: '2.0', id: 1, method, params });
test('standard MCP client lists and calls only synthetic status through verified TLS on a nonstandard port', async () => {
  const client = new Client({ name: 'fixture-test', version: '1' });
  try {
    await client.connect(new StreamableHTTPClientTransport(url, { fetch: verifiedFetch }));
    expect((await client.listTools()).tools.map(t => t.name)).toEqual([tool.name]);
    const result = await client.callTool({ name: tool.name, arguments: {} });
    expect(result.content).toEqual([{ type: 'text', text: resultText }]);
    expect(probe.events).toContain('tools/call');
  } finally { await client.close(); }
});
test('untrusted certificate is rejected', async () => { await expect(fetch(url)).rejects.toThrow(); });
test('hostname mismatch is rejected even with the test CA', async () => {
  await expect(verifiedFetch(new URL(`https://127.0.0.1:${probe.server.port}/mcp`))).rejects.toThrow();
});
test('no real tools or arbitrary arguments', async () => {
  for (const params of [{ name: 'send_message' }, { name: tool.name, arguments: { command: 'do something' } }, { name: tool.name, arguments: [] }]) {
    expect((await (await call('tools/call', params)).json()).error.code).toBe(-32602);
  }
  expect((await (await call('resources/list')).json()).error.code).toBe(-32601);
});
test('rejects malformed and oversized input without echoing bodies', async () => {
  expect((await request([])).status).toBe(400);
  expect((await request({ payload: 'x'.repeat(5000) })).status).toBe(413);
  const response = await request({ jsonrpc: '2.0', id: 1, method: 'sensitive-canary-not-a-method' });
  expect(await response.text()).not.toContain('sensitive-canary');
  expect(probe.events).not.toContain('sensitive-canary-not-a-method');
});
test('no OAuth claims or unexpected HTTP endpoints', async () => {
  expect((await verifiedFetch(new URL('/.well-known/oauth-authorization-server', url))).status).toBe(404);
  expect((await verifiedFetch(url)).status).toBe(405);
  expect((await request({ jsonrpc: '2.0', method: 'notifications/initialized' })).status).toBe(202);
});
test('partial TLS configuration fails closed', () => { expect(() => startProbe({ cert: ca })).toThrow(); });
