import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { resultText, tool } from './probe.ts';
const url = new URL(process.argv[2] ?? '');
if (url.protocol !== 'https:' || url.hostname !== 'railway-probe.ghostie.app' || url.pathname !== '/mcp' || url.username || url.password || url.search || url.hash) throw new Error('Only the dedicated synthetic probe URL is allowed');
const client = new Client({ name: 'ghostie-railway-compatibility-check', version: '1' });
const timer = setTimeout(() => { console.error('Probe timed out'); process.exit(1); }, 20_000);
try {
  await client.connect(new StreamableHTTPClientTransport(url));
  const tools = (await client.listTools()).tools;
  if (tools.length !== 1 || tools[0]?.name !== tool.name) throw new Error('Unexpected tool catalog; refusing to call');
  const result = await client.callTool({ name: tool.name, arguments: {} });
  if (JSON.stringify(result.content) !== JSON.stringify([{ type: 'text', text: resultText }])) throw new Error('Unexpected synthetic result');
  console.log('PASS: live verified TLS, MCP initialization, tool listing and synthetic call.');
} finally { clearTimeout(timer); await client.close(); }
