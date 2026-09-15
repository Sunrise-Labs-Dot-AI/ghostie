/** Production-image test using only disposable identities and synthetic content. */
import { randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { strict as assert } from 'node:assert';
const name = `ghostie-relay-test-${randomBytes(4).toString('hex')}`;
const dir = mkdtempSync(join(tmpdir(), 'ghostie-relay-test-'));
const canary = `synthetic-content-${randomBytes(16).toString('hex')}`;
const credential = randomBytes(32).toString('base64url');
const token = randomBytes(32).toString('base64url');
const host = randomBytes(32).toString('base64url');
const origin = 'https://relay.example.test';
const command = async (args: string[], input?: string) => {
  const p = Bun.spawn(args, { stdin: input ? new Blob([input]) : 'ignore', stdout: 'pipe', stderr: 'pipe' });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  if (code !== 0) throw new Error(`Command failed: ${args[0]} ${args[1]} (details suppressed)`);
  return out + err;
};
let socket: WebSocket | undefined;
try {
  await command(['docker', 'run', '-d', '--name', name, '-p', '127.0.0.1::8080',
    '-e', `GHOSTIE_RELAY_ORIGIN=${origin}`, '-e', 'CLERK_PUBLISHABLE_KEY=pk_test_Zml4dHVyZS5jbGVyay5hY2NvdW50cy5kZXYk',
    '-e', 'CLERK_SECRET_KEY=sk_test_fixture', '-e', 'CLERK_FRONTEND_ORIGIN=https://fixture.clerk.accounts.dev',
    '-e', 'GHOSTIE_OAUTH_CLIENTS=[{"id":"fixture","name":"Fixture","redirects":["https://client.example.test/callback"]}]',
    '-v', `${dir}:/data`, 'ghostie-relay:local']);
  const mapping = (await command(['docker', 'port', name, '8080'])).trim();
  assert.match(mapping, /^127\.0\.0\.1:\d+$/);
  const base = `http://${mapping}`;
  let ready = false;
  for (let i = 0; i < 60; i++) {
    try { ready = (await fetch(`${base}/health`)).ok; } catch {}
    if (ready) break;
    await Bun.sleep(250);
  }
  assert(ready, 'container readiness');
  const seed = `import {Store,hash} from '/app/src/store.ts'; const s=new Store('/data/relay.sqlite');
    s.addHost({id:${JSON.stringify(host)},user:'fixture',credential:hash(${JSON.stringify(credential)}),created:Date.now()});
    s.db.query('INSERT INTO tokens VALUES (?, ?, ?, ?, ?, ?, 1)').run(hash(${JSON.stringify(token)}),${JSON.stringify(host)},'fixture','fixture',${JSON.stringify(`${origin}/mcp/hosts/${host}`)},Date.now()+60000); s.db.close();`;
  await command(['docker', 'exec', '-i', name, 'bun', 'run', '-'], seed);
  const endpoint = `${base}/mcp/hosts/${host}`;
  assert.equal((await fetch(endpoint, { method: 'POST' })).status, 401);
  socket = new WebSocket(`${base.replace('http:', 'ws:')}/hosts/${host}/connect`, { headers: { Authorization: `Bearer ${credential}` } });
  await new Promise<void>((resolve, reject) => { socket!.onopen = () => resolve(); socket!.onerror = () => reject(new Error('host socket failed')); });
  socket.onmessage = event => {
    const work = JSON.parse(String(event.data));
    socket!.send(JSON.stringify({ id: work.id, response: { jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: canary }] } } }));
  };
  const response = await fetch(endpoint, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'synthetic', arguments: { body: canary } } }) });
  assert.equal(response.status, 200);
  assert((await response.text()).includes(canary));
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const limits = await command(['docker', 'exec', name, 'cat', '/proc/1/limits']);
  assert.match(limits, /Max core file size\s+0\s+0/);
  const contents = await command(['docker', 'exec', name, 'bun', '-e', "import{Database}from'bun:sqlite';let d=new Database('/data/relay.sqlite');console.log(JSON.stringify([d.query('SELECT * FROM hosts').all(),d.query('SELECT * FROM tokens').all()]));"]);
  for (const value of [canary, credential, token]) assert(!contents.includes(value), 'no content or bearer secrets in metadata');
  socket.close(); socket = undefined;
  await Bun.sleep(100);
  const offline = await fetch(endpoint, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: '{"jsonrpc":"2.0","id":2,"method":"ping"}' });
  assert.equal(offline.status, 503);
  await command(['docker', 'exec', name, 'killall', 'caddy']);
  const exit = (await command(['docker', 'wait', name])).trim();
  assert.equal(exit, '1', 'proxy failure must stop relay container');
  const logs = await command(['docker', 'logs', name]);
  for (const value of [canary, credential, token, host, 'sk_test_fixture']) assert(!logs.includes(value), 'no content, identifiers or credentials in logs');
  assert(logs.includes('Relay service stopped unexpectedly.'), 'generic operational signal remains');
  console.log('PASS: production image forwarding, auth gate, no-store, offline, core limits, metadata/log canaries, proxy failure shutdown.');
} finally {
  socket?.close();
  await command(['docker', 'rm', '-f', name]).catch(() => {});
  rmSync(dir, { recursive: true, force: true });
}
