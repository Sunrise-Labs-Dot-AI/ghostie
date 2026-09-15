import { randomUUID } from "node:crypto";
import type { ServerWebSocket } from "bun";
import { z } from "zod";
import { Authorization, type OAuthClient } from "./authorization.ts";
import { Store, secret } from "./store.ts";
import { accountPage } from "./page.ts";

type ConnectionData = { host: string };
type Pending = { host: string; socket: ServerWebSocket<ConnectionData>; resolve: (response: Response) => void; timer: ReturnType<typeof setTimeout> };
export interface RelayOptions {
  origin: string; store: Store; clients: OAuthClient[]; publishableKey: string; clerkScriptURL: string;
  sessionUser: (request: Request) => Promise<string | null>;
  port?: number; timeoutMs?: number;
}
const bearer = (request: Request) => /^Bearer ([A-Za-z0-9._~-]{20,8192})$/.exec(request.headers.get("authorization") ?? "")?.[1] ?? "";
const json = (body: unknown, status = 200, headers: Record<string, string> = {}) => Response.json(body, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...headers } });
const unavailable = () => json({ error: "host_unavailable", message: "Open Ghostie and start hosting on your Mac. If a draft request was interrupted, inspect the Mac queue before retrying." }, 503);

export function startRelay(options: RelayOptions) {
  const auth = new Authorization(options.store, options.origin, options.clients);
  const connections = new Map<string, ServerWebSocket<ConnectionData>>();
  const pending = new Map<string, Pending>();
  const limits = new Map<string, { count: number; reset: number }>();
  function limited(key: string, maximum: number) {
    const now = Date.now();
    if (limits.size > 5000) for (const [id, entry] of limits) if (entry.reset < now) limits.delete(id);
    if (limits.size >= 10000) return true;
    let entry = limits.get(key);
    if (!entry || entry.reset < now) { entry = { count: 0, reset: now + 60_000 }; limits.set(key, entry); }
    return ++entry.count > maximum;
  }
  function finish(id: string, response: Response) {
    const work = pending.get(id);
    if (!work) return;
    clearTimeout(work.timer); pending.delete(id); work.resolve(response);
  }
  const server = Bun.serve<ConnectionData>({
    hostname: "127.0.0.1", port: options.port ?? 8787, maxRequestBodySize: 65_536,
    async fetch(request, server) {
      const url = new URL(request.url);
      const path = url.pathname;
      if (path === "/health" && request.method === "GET") return json({ status: "ok" });
      const origin = request.headers.get("origin");
      if (origin && origin !== options.origin) return json({ error: "forbidden_origin" }, 403);
      // Public TLS proxy must preserve Host and must be the only route to this listener.
      if (request.headers.get("host") !== new URL(options.origin).host) return json({ error: "invalid_host" }, 403);
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: { "Access-Control-Allow-Origin": options.origin, "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS", "Access-Control-Allow-Headers": "Authorization, Content-Type, MCP-Protocol-Version", "Cache-Control": "no-store" } });
      try {
        if (request.method === "GET" && path === "/.well-known/oauth-authorization-server") return json({
          issuer: options.origin, authorization_endpoint: `${options.origin}/oauth/authorize`, token_endpoint: `${options.origin}/oauth/token`, revocation_endpoint: `${options.origin}/oauth/revoke`,
          response_types_supported: ["code"], grant_types_supported: ["authorization_code"], code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none"], scopes_supported: ["messages:read", "messages:draft"],
        });
        const metadata = /^\/\.well-known\/oauth-protected-resource\/mcp\/hosts\/([A-Za-z0-9_-]{43})$/.exec(path);
        if (request.method === "GET" && metadata) return json({ resource: auth.resource(metadata[1]!), authorization_servers: [options.origin], scopes_supported: ["messages:read", "messages:draft"], bearer_methods_supported: ["header"] });
        if (request.method === "GET" && ["/pair", "/oauth/authorize"].includes(path)) {
          const nonce = secret();
          const clerkOrigin = new URL(options.clerkScriptURL).origin;
          return new Response(accountPage(options.publishableKey, options.clerkScriptURL, nonce), { headers: {
            "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY",
            "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}' ${clerkOrigin} https://challenges.cloudflare.com; style-src 'unsafe-inline'; connect-src 'self' ${clerkOrigin}; img-src 'self' https://img.clerk.com data:; frame-src ${clerkOrigin} https://challenges.cloudflare.com; font-src ${clerkOrigin}; worker-src blob:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`,
          } });
        }
        const ip = server.requestIP(request)?.address ?? "unknown";
        if (limited(`edge:${ip}`, 300)) return json({ error: "rate_limited" }, 429);
        if (path === "/api/pair/start" && request.method === "POST") {
          const { digest } = z.object({ digest: z.string() }).strict().parse(await request.json());
          return json(auth.startPair(digest));
        }
        if (path.startsWith("/api/pair/") && path !== "/api/pair/approve" && request.method === "POST") {
          const { id } = z.object({ id: z.string().max(100) }).strict().parse(await request.json());
          if (path === "/api/pair/poll") return json(auth.pollPair(id, bearer(request)));
          if (path === "/api/pair/cancel") { auth.cancelPair(id, bearer(request)); return json({ ok: true }); }
        }
        if (["/api/pair/approve", "/api/consent/details", "/api/consent/approve"].includes(path) && request.method === "POST") {
          if (origin !== options.origin || !bearer(request)) return json({ error: "unauthorized" }, 401);
          const user = await options.sessionUser(request);
          if (!user) return json({ error: "unauthorized" }, 401);
          const body = await request.json();
          if (path === "/api/pair/approve") {
            const { id, code } = z.object({ id: z.string().max(100), code: z.string().length(8) }).strict().parse(body);
            auth.approvePair(id, code, user); return json({ ok: true });
          }
          if (path === "/api/consent/details") {
            const { client, host, request: consent } = auth.validateConsent(body, user);
            return json({ client: client.name, redirect_origin: new URL(consent.redirect_uri).origin, host: host.id });
          }
          return json({ redirect: auth.approveConsent(body, user) });
        }
        if (request.method === "POST" && ["/oauth/token", "/oauth/revoke"].includes(path)) {
          const body = Object.fromEntries(new URLSearchParams(await request.text()));
          if (path === "/oauth/token") return json(auth.exchange(body));
          if (body.token) options.store.revoke(body.token);
          return json({});
        }
        const hostRoute = /^\/hosts\/([A-Za-z0-9_-]{43})(\/connect)?$/.exec(path);
        if (hostRoute) {
          const host = options.store.hostAuthorized(hostRoute[1]!, bearer(request));
          if (!host) return json({ error: "unauthorized" }, 401);
          if (request.method === "DELETE" && !hostRoute[2]) {
            options.store.deleteHost(host.id); connections.get(host.id)?.close(1000, "Disconnected"); return json({ ok: true });
          }
          if (request.method === "GET" && hostRoute[2]) {
            if (connections.has(host.id)) return json({ error: "host_already_connected" }, 409);
            if (server.upgrade(request, { data: { host: host.id } })) return;
          }
          return json({ error: "method_not_allowed" }, 405);
        }
        const route = /^\/mcp\/hosts\/([A-Za-z0-9_-]{43})$/.exec(path);
        if (route) {
          const hostID = route[1]!;
          const resource = auth.resource(hostID);
          const token = options.store.authorize(bearer(request), hostID, resource);
          if (!token || !options.clients.some(client => client.id === token.client)) return json({ error: "unauthorized" }, 401, { "WWW-Authenticate": `Bearer resource_metadata="${options.origin}/.well-known/oauth-protected-resource/mcp/hosts/${hostID}"` });
          if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405, { Allow: "POST" });
          if (limited(`host:${hostID}`, 60)) return json({ error: "rate_limited" }, 429);
          const socket = connections.get(hostID);
          if (!socket) return unavailable();
          if (pending.size >= 100 || [...pending.values()].some(p => p.host === hostID)) return json({ error: "host_busy" }, 429);
          const rpc = await request.json() as Record<string, unknown>;
          if (!rpc || typeof rpc !== "object" || Array.isArray(rpc) || rpc.jsonrpc !== "2.0") return json({ error: "invalid_request" }, 400);
          if (rpc.method === "notifications/initialized" && rpc.id === undefined) return new Response(null, { status: 202, headers: { "Cache-Control": "no-store" } });
          const id = randomUUID();
          return await new Promise<Response>(resolve => {
            const timeout = options.timeoutMs ?? 20_000;
            const timer = setTimeout(() => finish(id, unavailable()), timeout);
            pending.set(id, { host: hostID, socket, resolve, timer });
            if (socket.send(JSON.stringify({ id, deadline: Date.now() + timeout, request: rpc })) === 0) finish(id, unavailable());
          });
        }
        return json({ error: "not_found" }, 404);
      } catch { return json({ error: path === "/oauth/token" ? "invalid_grant" : "request_unavailable" }, 400); }
    },
    websocket: {
      maxPayloadLength: 1_048_576, idleTimeout: 30, sendPings: true,
      open(socket) {
        if (connections.has(socket.data.host) || !options.store.host(socket.data.host)) { socket.close(1008, "Connection refused"); return; }
        connections.set(socket.data.host, socket);
      },
      message(socket, message) {
        try {
          const packet = JSON.parse(String(message));
          const work = pending.get(packet.id);
          if (!work || work.socket !== socket || work.host !== socket.data.host) return;
          if (!options.store.host(work.host) || packet.unavailable || !packet.response || typeof packet.response !== "object") finish(packet.id, unavailable());
          else finish(packet.id, json(packet.response));
        } catch { socket.close(1008, "Invalid response"); }
      },
      close(socket) {
        if (connections.get(socket.data.host) === socket) connections.delete(socket.data.host);
        for (const [id, work] of pending) if (work.socket === socket) finish(id, unavailable());
      },
    },
    error() { return json({ error: "service_unavailable" }, 503); },
  });
  return { server, auth, connections, stop() { for (const id of pending.keys()) finish(id, unavailable()); server.stop(true); } };
}
