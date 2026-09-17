/** Production-image test using only disposable identities and synthetic content. */
import { randomBytes } from 'node:crypto';
import { strict as assert } from 'node:assert';
const name = `ghostie-relay-test-${randomBytes(4).toString('hex')}`;
const openerName = `${name}-opener`;
const network = `${name}-network`;
const volume = `${name}-data`;
const canary = `synthetic-content-${randomBytes(16).toString('hex')}`;
const credential = randomBytes(32).toString('base64url');
const token = randomBytes(32).toString('base64url');
const openerToken = `opener-${randomBytes(32).toString('base64url')}`;
const host = randomBytes(32).toString('base64url');
const phoneCanary = '+12155550123';
const returnedLinkCanary = 'https://ghostie.app/t/AbCdEf0123_-GhIj';
const origin = 'https://relay.example.test';
const command = async (args: string[], input?: string) => {
  const p = Bun.spawn(args, { stdin: input ? new Blob([input]) : 'ignore', stdout: 'pipe', stderr: 'pipe' });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  if (code !== 0) throw new Error(`Command failed: ${args[0]} ${args[1]} (details suppressed)`);
  return out + err;
};
let socket: WebSocket | undefined;
try {
  await command(['docker', 'network', 'create', network]);
  const opener = `const expectedToken=${JSON.stringify(openerToken)},expectedPhone=${JSON.stringify(phoneCanary)},expectedBody=${JSON.stringify(canary)},link=${JSON.stringify(returnedLinkCanary)};
    Bun.serve({hostname:'0.0.0.0',port:8788,async fetch(request){const url=new URL(request.url);if(url.pathname==='/health')return new Response('ok');
    if(request.method!=='POST'||url.pathname!=='/v1/links'||request.headers.get('authorization')!=='Bearer '+expectedToken)return new Response('{}',{status:401});
    let body;try{body=await request.json()}catch{return new Response('{}',{status:400})}if(body.phone!==expectedPhone||body.body!==expectedBody)return new Response('{}',{status:400});
    return Response.json({url:link,expires_at:new Date(Date.now()+7*24*60*60*1000).toISOString()},{status:201});}});`;
  await command(['docker', 'run', '-d', '--name', openerName, '--network', network, '--network-alias', 'opener.test', 'oven/bun:1.3.14-alpine', 'bun', '-e', opener]);
  await command(['docker', 'run', '-d', '--name', name, '-p', '127.0.0.1::8080',
    '--network', network,
    '-e', `GHOSTIE_RELAY_ORIGIN=${origin}`, '-e', 'CLERK_PUBLISHABLE_KEY=pk_test_Zml4dHVyZS5jbGVyay5hY2NvdW50cy5kZXYk',
    '-e', 'CLERK_SECRET_KEY=sk_test_fixture', '-e', 'CLERK_FRONTEND_ORIGIN=https://fixture.clerk.accounts.dev',
    '-e', `MESSAGE_OPENER_API_TOKEN=${openerToken}`,
    '-e', 'GHOSTIE_CONTAINER_SMOKE=1', '-e', 'MESSAGE_OPENER_API_URL=http://opener.test:8788/v1/links',
    '-e', 'GHOSTIE_OAUTH_CLIENTS=[{"id":"fixture","name":"Fixture","redirects":["https://client.example.test/callback"]},{"id":"ghostie-cursor","name":"Grok Bot / Cursor","redirects":["http://localhost:8787/callback","https://www.cursor.com/agents/mcp/oauth/callback"]}]',
    '-v', `${volume}:/data`, 'ghostie-relay:local']);
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
    s.db.query('INSERT INTO tokens VALUES (?, ?, ?, ?, ?, ?, 2)').run(hash(${JSON.stringify(token)}),${JSON.stringify(host)},'fixture','fixture',${JSON.stringify(`${origin}/mcp/hosts/${host}`)},Date.now()+60000); s.db.close();`;
  await command(['docker', 'exec', '-i', name, 'bun', 'run', '-'], seed);
  const endpoint = `${base}/mcp/hosts/${host}`;
  assert.equal((await fetch(endpoint, { method: 'POST' })).status, 401);
  socket = new WebSocket(`${base.replace('http:', 'ws:')}/hosts/${host}/connect`, { headers: { Authorization: `Bearer ${credential}` } });
  await new Promise<void>((resolve, reject) => { socket!.onopen = () => resolve(); socket!.onerror = () => reject(new Error('host socket failed')); });
  socket.onmessage = event => {
    const work = JSON.parse(String(event.data));
    socket!.send(JSON.stringify({ id: work.id, response: { jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: `${canary} ${returnedLinkCanary}` }] } } }));
  };
  const response = await fetch(endpoint, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'synthetic', arguments: { phone: phoneCanary, body: canary } } }) });
  assert.equal(response.status, 200);
  assert((await response.text()).includes(canary));
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const limits = await command(['docker', 'exec', name, 'cat', '/proc/1/limits']);
  assert.match(limits, /Max core file size\s+0\s+0/);
  const contents = await command(['docker', 'exec', name, 'bun', '-e', "import{Database}from'bun:sqlite';let d=new Database('/data/relay.sqlite');console.log(JSON.stringify([d.query('SELECT * FROM hosts').all(),d.query('SELECT * FROM tokens').all()]));"]);
  for (const value of [canary, phoneCanary, returnedLinkCanary, credential, token, openerToken]) assert(!contents.includes(value), 'no content or bearer secrets in metadata');
  socket.close(); socket = undefined;
  await Bun.sleep(100);
  const linkResponse = await fetch(endpoint, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'ghostie_create_messages_link', arguments: { phone: phoneCanary, body: canary } } }) });
  assert.equal(linkResponse.status, 200);
  const linkPayload = await linkResponse.json() as { result?: { structuredContent?: { url?: string } } };
  assert.equal(linkPayload.result?.structuredContent?.url, returnedLinkCanary);
  const offline = await fetch(endpoint, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: '{"jsonrpc":"2.0","id":2,"method":"ping"}' });
  assert.equal(offline.status, 503);
  await command(['docker', 'exec', name, 'killall', 'caddy']);
  const exit = (await command(['docker', 'wait', name])).trim();
  assert.equal(exit, '1', 'proxy failure must stop relay container');
  const logs = await command(['docker', 'logs', name]);
  for (const value of [canary, phoneCanary, returnedLinkCanary, credential, token, openerToken, host, 'sk_test_fixture']) assert(!logs.includes(value), 'no content, identifiers or credentials in logs');
  assert(logs.includes('Relay service stopped unexpectedly.'), 'generic operational signal remains');
  console.log('PASS: production image forwarding, authenticated offline link creation, auth gate, no-store, offline, core limits, metadata/log canaries, proxy failure shutdown.');
} finally {
  socket?.close();
  await command(['docker', 'rm', '-f', name]).catch(() => {});
  await command(['docker', 'rm', '-f', openerName]).catch(() => {});
  await command(['docker', 'network', 'rm', network]).catch(() => {});
  await command(['docker', 'volume', 'rm', '-f', volume]).catch(() => {});
}
