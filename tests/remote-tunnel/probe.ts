/** Disposable synthetic MCP fixture. Never import a messaging backend here. */
const versions = new Set(['2025-03-26', '2025-06-18', '2025-11-25']);
export const tool = {
  name: 'ghostie_connection_check',
  description: 'Returns a fixed synthetic connection-test result. No account or message access.',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
};
export const resultText = 'Ghostie synthetic connection works. No messages are available.';
export function startProbe(options: { hostname?: string; port?: number; cert?: string; key?: string } = {}) {
  if (Boolean(options.cert) !== Boolean(options.key)) throw new Error('Both certificate and key are required');
  const events: string[] = []; // Method names only, bounded. No inputs, headers or bodies.
  const server = Bun.serve({
    hostname: options.hostname ?? '127.0.0.1', port: options.port ?? 0,
    tls: options.cert && options.key ? { cert: options.cert, key: options.key } : undefined,
    maxRequestBodySize: 4096, idleTimeout: 10,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === '/health' && request.method === 'GET') return new Response('synthetic probe only');
      if (path !== '/mcp') return new Response('Not found', { status: 404 });
      if (request.method !== 'POST') return new Response(null, { status: 405, headers: { Allow: 'POST' } });
      if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) return new Response(null, { status: 415 });
      let message: any;
      try { message = await request.json(); } catch { return new Response(null, { status: 400 }); }
      if (!message || Array.isArray(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string') return new Response(null, { status: 400 });
      const id = message.id;
      if (id === undefined) return new Response(null, { status: 202 });
      if (typeof id !== 'string' && typeof id !== 'number') return new Response(null, { status: 400 });
      const reply = (data: object) => Response.json({ jsonrpc: '2.0', id, ...data }, { headers: { 'Cache-Control': 'no-store' } });
      const error = (code: number) => reply({ error: { code, message: 'Invalid synthetic probe request' } });
      const record = (name: string) => { if (events.length < 100) events.push(name); };
      switch (message.method) {
        case 'initialize':
          record('initialize');
          return reply({ result: { protocolVersion: versions.has(message.params?.protocolVersion) ? message.params.protocolVersion : '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'ghostie-synthetic-probe', version: '0.0.1' } } });
        case 'ping': return reply({ result: {} });
        case 'tools/list':
          record('tools/list');
          return reply({ result: { tools: [tool] } });
        case 'tools/call':
          if (message.params?.name !== tool.name || (message.params.arguments !== undefined && (typeof message.params.arguments !== 'object' || message.params.arguments === null || Array.isArray(message.params.arguments) || Object.keys(message.params.arguments).length))) return error(-32602);
          record('tools/call');
          return reply({ result: { content: [{ type: 'text', text: resultText }] } });
        default: return error(-32601);
      }
    },
    error() { return new Response(null, { status: 400 }); },
  });
  return { server, events };
}
if (import.meta.main) {
  const cert = process.env.PROBE_TLS_CERT;
  const key = process.env.PROBE_TLS_KEY;
  if (!cert || !key) throw new Error('Disposable probe TLS configuration required');
  const { server, events } = startProbe({ hostname: process.env.PROBE_BIND_HOST ?? '127.0.0.1', port: Number(process.env.PORT ?? 9443), cert, key });
  const stop = () => { server.stop(true); process.exit(0); };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
  setTimeout(stop, 30 * 60 * 1000);
  let seen = 0;
  setInterval(() => { for (; seen < events.length; seen++) process.stdout.write(`probe ${events[seen]}\n`); }, 1000);
  process.stdout.write('Synthetic probe ready\n');
}
