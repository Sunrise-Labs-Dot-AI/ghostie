/** Opt-in production acceptance using only a fixed synthetic MCP. No messaging imports. */
import { chmodSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { hash, secret } from '../src/store.ts';
import { startProbe } from '../../../tests/remote-tunnel/probe.ts';

const origin = process.env.GHOSTIE_RELAY_ORIGIN;
if (!origin || new URL(origin).protocol !== 'https:') throw Error('Explicit HTTPS test origin required');
const credential = secret();
const dir = mkdtempSync(join(tmpdir(), 'ghostie-live-acceptance-'));
chmodSync(dir, 0o700);
const proof = { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json' };
const request = async (path: string, body: object, headers = { 'Content-Type': 'application/json' }) => {
  const response = await fetch(`${origin}${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
  if (!response.ok) throw Error(`Acceptance request failed (${response.status})`);
  return response.json() as Promise<Record<string, string>>;
};
const pair = await request('/api/pair/start', { digest: hash(credential) });
await Bun.write(join(dir, 'cleanup.json'), JSON.stringify({ origin, credential, pair: pair.id }));
chmodSync(join(dir, 'cleanup.json'), 0o600);
console.log(`Synthetic pairing URL: ${pair.url}\nMac code: ${pair.code}\nPrivate cleanup state: ${dir}`);
let host: string | undefined;
let socket: WebSocket | undefined;
const probe = startProbe();
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  socket?.close(); probe.server.stop(true);
  try {
    if (host) {
      const response = await fetch(`${origin}/hosts/${host}`, { method: 'DELETE', headers: proof });
      if (!response.ok) throw Error('Revocation failed');
    } else await request('/api/pair/cancel', { id: pair.id }, proof);
    rmSync(dir, { recursive: true });
    console.log('Synthetic host and capabilities revoked.');
  } catch { console.log('Cleanup needs retry using private cleanup state.'); }
  process.exit(0);
}
process.on('SIGINT', stop); process.on('SIGTERM', stop);
setTimeout(stop, 20 * 60_000);
while (!host && !stopping) {
  const result = await request('/api/pair/poll', { id: pair.id }, proof);
  if (result.status === 'paired') host = result.host;
  else await Bun.sleep(2000);
}
if (!host) throw Error('Pairing incomplete');
await Bun.write(join(dir, 'cleanup.json'), JSON.stringify({ origin, credential, pair: pair.id, host }));
chmodSync(join(dir, 'cleanup.json'), 0o600);
socket = new WebSocket(`${origin.replace('https:', 'wss:')}/hosts/${host}/connect`, { headers: proof });
socket.onopen = () => console.log(`Synthetic host online: ${origin}/mcp/hosts/${host}`);
socket.onmessage = async event => {
  try {
    const packet = JSON.parse(String(event.data));
    const reply = await fetch(`http://127.0.0.1:${probe.server.port}/mcp`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(packet.request),
    });
    socket?.send(JSON.stringify({ id: packet.id, response: await reply.json() }));
    const method = packet.request.method;
    console.log(['initialize', 'tools/list', 'tools/call', 'ping'].includes(method) ? `Synthetic ${method}` : 'Synthetic unsupported method');
  } catch { console.log('Synthetic fixture request failed.'); }
};
socket.onerror = () => console.log('Synthetic host connection failed.');
socket.onclose = () => console.log('Synthetic host offline.');
