import { z } from "zod";
import { createRemoteExecutor } from "./remote-executor.ts";

// A private pipe from the app carries credentials. Neither argv nor disk does.
const configSchema = z.object({ origin: z.string().url(), host: z.string().regex(/^[A-Za-z0-9_-]{43}$/), credential: z.string().regex(/^[A-Za-z0-9_-]{43}$/) }).strict();
let buffer = "";
let started = false;
let socket: WebSocket | undefined;
let stopping = false;
const parent = process.ppid;
const stop = () => { stopping = true; socket?.close(); process.exit(0); };
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
process.stdin.on("end", stop);
setInterval(() => { if (process.ppid !== parent || process.ppid === 1) stop(); }, 1000).unref();

process.stdin.on("data", async chunk => {
  if (started) return;
  buffer += chunk.toString();
  if (buffer.length > 8192) stop();
  if (!buffer.includes("\n")) return;
  started = true;
  try {
    const config = configSchema.parse(JSON.parse(buffer.slice(0, buffer.indexOf("\n"))));
    buffer = "";
    const origin = new URL(config.origin);
    if (origin.protocol !== "https:" || origin.username || origin.password || origin.pathname !== "/" || origin.search || origin.hash) throw new Error("Invalid origin");
    const executor = await createRemoteExecutor();
    const url = new URL(`/hosts/${config.host}/connect`, origin);
    url.protocol = "wss:";
    let delay = 1000;
    const seen = new Map<string, number>();
    const connect = () => {
      if (stopping) return;
      socket = new WebSocket(url.href, { headers: { Authorization: `Bearer ${config.credential}` } });
      const current = socket;
      current.onopen = () => { delay = 1000; process.stdout.write('{"status":"online"}\n'); };
      current.onmessage = async event => {
        if (typeof event.data !== "string" || Buffer.byteLength(event.data) > 65_536) { current.close(); return; }
        try {
          const packet = z.object({ id: z.string().uuid(), deadline: z.number(), request: z.unknown() }).strict().parse(JSON.parse(event.data));
          for (const [id, expires] of seen) if (expires < Date.now()) seen.delete(id);
          if (packet.deadline <= Date.now() || packet.deadline > Date.now() + 30_000 || seen.has(packet.id)) return;
          if (seen.size >= 10000) { current.close(); return; }
          seen.set(packet.id, Date.now() + 3_600_000);
          const response = await executor.execute(packet.request);
          const encoded = JSON.stringify({ id: packet.id, response });
          if (Buffer.byteLength(encoded) > 1_048_576) { current.send(JSON.stringify({ id: packet.id, unavailable: true })); return; }
          if (current.readyState === WebSocket.OPEN && packet.deadline > Date.now()) current.send(encoded);
        } catch { current.close(); }
      };
      current.onerror = () => {}; // no payloads or bearer headers in diagnostics
      current.onclose = () => {
        process.stdout.write('{"status":"offline"}\n');
        setTimeout(connect, delay);
        delay = Math.min(delay * 2, 30_000);
      };
    };
    connect();
  } catch { process.stdout.write('{"status":"error"}\n'); process.exit(1); }
});
