import { randomUUID } from "node:crypto";
import type { ServerWebSocket } from "bun";
import { z } from "zod";
import { Authorization, type OAuthClient } from "./authorization.ts";
import { Store, secret } from "./store.ts";
import { accountPage } from "./page.ts";
import { addMessageLinkTool, MESSAGE_LINK_TOOL_NAME, MessageLinkError, type MessageLinkCreator } from "./message-opener.ts";
import { OAUTH_SCOPE, OFFLINE_ACCESS, SUPPORTED_SCOPES, describeScope, filterToolList, requiredScope, scopeAllows } from "./scopes.ts";

type ConnectionData = { host: string; sequence: number };
type Pending = { host: string; user: string; socket: ServerWebSocket<ConnectionData>; resolve: (response: Response) => void; timer: ReturnType<typeof setTimeout>; addLinkTool: boolean; scope: string };
type Waiter = { grant: (result: "ok" | "timeout") => void; timer: ReturnType<typeof setTimeout> };
export interface RelayOptions {
  origin: string; store: Store; clients: OAuthClient[]; publishableKey: string; clerkScriptURL: string;
  messageLinks: MessageLinkCreator;
  sessionUser: (request: Request) => Promise<string | null>;
  port?: number; timeoutMs?: number; queueWaitMs?: number; now?: () => number;
}
/** Concurrent non-tool requests one host may have in flight, and tool calls that may wait their turn. */
const HOST_IN_FLIGHT = 8;
const HOST_QUEUE = 8;
/** Requests one account may hold across its Macs, and the process-wide ceiling. */
const USER_IN_FLIGHT = 16;
const GLOBAL_IN_FLIGHT = 1000;
/** A Mac connection not heard from (pong, heartbeat, or response) for this long may be replaced by a new one. */
const STALE_AFTER_MS = 20_000;
const bearer = (request: Request) => /^Bearer ([A-Za-z0-9._~-]{20,8192})$/.exec(request.headers.get("authorization") ?? "")?.[1] ?? "";
const json = (body: unknown, status = 200, headers: Record<string, string> = {}) => Response.json(body, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...headers } });
const unavailable = () => json({ error: "host_unavailable", message: "Open Ghostie and start hosting on your Mac. If a draft request was interrupted, inspect the Mac queue before retrying." }, 503);
const challenge = (origin: string, hostID: string, error?: "invalid_token" | "insufficient_scope", scope: string = OAUTH_SCOPE) =>
  `Bearer ${error ? `error="${error}", ` : ""}scope="${scope}", resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp/hosts/${hostID}"`;

export function startRelay(options: RelayOptions) {
  const auth = new Authorization(options.store, options.origin, options.clients, options.now);
  const connections = new Map<string, ServerWebSocket<ConnectionData>>();
  const pending = new Map<string, Pending>();
  const limits = new Map<string, { count: number; reset: number }>();
  const linkRuns = new Map<string, number[]>();
  const linkInFlight = new Set<string>();
  // One tool call reaches a Mac at a time; the rest wait in order instead of failing.
  const locks = new Map<string, { waiters: Waiter[] }>();
  const lastHeard = new WeakMap<ServerWebSocket<ConnectionData>, number>();
  let sequence = 0;
  const now = options.now ?? Date.now;
  function limited(key: string, maximum: number) {
    const current = now();
    if (limits.size > 5000) for (const [id, entry] of limits) if (entry.reset < current) limits.delete(id);
    if (limits.size >= 10000) return true;
    let entry = limits.get(key);
    if (!entry || entry.reset < current) { entry = { count: 0, reset: current + 60_000 }; limits.set(key, entry); }
    return ++entry.count > maximum;
  }
  function linkLimited(key: string, maximum: number) {
    const current = now();
    if (linkRuns.size > 5000) for (const [id, runs] of linkRuns) {
      const active = runs.filter(time => time > current - 60_000);
      if (active.length) linkRuns.set(id, active); else linkRuns.delete(id);
    }
    if (linkRuns.size >= 10000 && !linkRuns.has(key)) return true;
    const active = (linkRuns.get(key) ?? []).filter(time => time > current - 60_000);
    if (active.length >= maximum) { linkRuns.set(key, active); return true; }
    active.push(current); linkRuns.set(key, active); return false;
  }
  function acquire(hostID: string): Promise<"ok" | "full" | "timeout"> {
    const lock = locks.get(hostID);
    if (!lock) { locks.set(hostID, { waiters: [] }); return Promise.resolve("ok"); }
    if (lock.waiters.length >= HOST_QUEUE) return Promise.resolve("full");
    return new Promise(resolve => {
      const waiter: Waiter = {
        grant: result => { clearTimeout(waiter.timer); resolve(result); },
        timer: setTimeout(() => { const index = lock.waiters.indexOf(waiter); if (index >= 0) lock.waiters.splice(index, 1); resolve("timeout"); }, options.queueWaitMs ?? 15_000),
      };
      lock.waiters.push(waiter);
    });
  }
  function release(hostID: string) {
    const lock = locks.get(hostID);
    if (!lock) return;
    const next = lock.waiters.shift();
    if (next) next.grant("ok"); else locks.delete(hostID);
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
          response_types_supported: ["code"], grant_types_supported: ["authorization_code", "refresh_token"], code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none"],
          scopes_supported: [...SUPPORTED_SCOPES, OFFLINE_ACCESS],
        });
        const metadata = /^\/\.well-known\/oauth-protected-resource\/mcp\/hosts\/([A-Za-z0-9_-]{43})$/.exec(path);
        if (request.method === "GET" && metadata) return json({ resource: auth.resource(metadata[1]!), authorization_servers: [options.origin], scopes_supported: [...SUPPORTED_SCOPES], bearer_methods_supported: ["header"] });
        if (request.method === "GET" && ["/account", "/pair", "/oauth/authorize"].includes(path)) {
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
            const { client, host, request: consent, scope } = auth.validateConsent(body, user);
            return json({ client: client.name, redirect_origin: new URL(consent.redirect_uri).origin, host: host.id, scope, permissions: describeScope(scope) });
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
            // A connection the relay has heard from recently is live and keeps its slot. A silent one is
            // usually dead (sleep, NAT reset) and would otherwise refuse the real Mac until the idle timeout;
            // the actual takeover happens in open(), ordered by this sequence number, so a failed upgrade
            // or a handshake race can never leave the Mac with no connection or evict the newer one.
            const existing = connections.get(host.id);
            if (existing && now() - (lastHeard.get(existing) ?? 0) < STALE_AFTER_MS) return json({ error: "host_already_connected" }, 409);
            if (server.upgrade(request, { data: { host: host.id, sequence: ++sequence } })) return;
          }
          return json({ error: "method_not_allowed" }, 405);
        }
        const route = /^\/mcp\/hosts\/([A-Za-z0-9_-]{43})$/.exec(path);
        if (route) {
          const hostID = route[1]!;
          const resource = auth.resource(hostID);
          const presented = request.headers.get("authorization") !== null;
          const token = options.store.authorize(bearer(request), hostID, resource);
          if (!token || !options.clients.some(client => client.id === token.client)) return json({ error: "unauthorized" }, 401, { "WWW-Authenticate": challenge(options.origin, hostID, presented ? "invalid_token" : undefined) });
          if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405, { Allow: "POST" });
          if (limited(`host:${hostID}`, 60)) return json({ error: "rate_limited" }, 429);
          const rpc = await request.json() as Record<string, unknown>;
          if (!rpc || typeof rpc !== "object" || Array.isArray(rpc) || rpc.jsonrpc !== "2.0") return json({ error: "invalid_request" }, 400);
          if (rpc.method === "notifications/initialized" && rpc.id === undefined) return new Response(null, { status: 202, headers: { "Cache-Control": "no-store" } });
          const validID = typeof rpc.id === "string" || typeof rpc.id === "number";
          const rpcResult = (result: unknown) => json({ jsonrpc: "2.0", id: validID ? rpc.id : null, result });
          const rpcError = (code: number, message: string) => json({ jsonrpc: "2.0", id: validID ? rpc.id : null, error: { code, message } });
          const params = rpc.params && typeof rpc.params === "object" && !Array.isArray(rpc.params)
            ? rpc.params as Record<string, unknown> : undefined;
          const toolCall = rpc.method === "tools/call";
          if (toolCall) {
            const needed = typeof params?.name === "string" ? requiredScope(params.name) : undefined;
            if (needed === undefined) return rpcError(-32602, "Tool or arguments not permitted remotely");
            if (!scopeAllows(token.scope, needed)) return json({ error: "insufficient_scope" }, 403, { "WWW-Authenticate": challenge(options.origin, hostID, "insufficient_scope", needed) });
          }
          if (toolCall && params?.name === MESSAGE_LINK_TOOL_NAME) {
            if (!validID) return rpcError(-32600, "Invalid request");
            const toolFailure = (message: string) => rpcResult({ isError: true, content: [{ type: "text", text: message }] });
            if (linkInFlight.has(hostID)) return toolFailure("A Messages link is already being created for this Mac. Wait for that result before trying again.");
            if (linkInFlight.size >= 10) return toolFailure("Messages link creation is temporarily busy. Try again later.");
            if (linkLimited(hostID, 6)) return toolFailure("Messages link rate limit reached. Try again after a minute.");
            linkInFlight.add(hostID);
            try {
              const link = await options.messageLinks.create(params.arguments ?? {});
              return rpcResult({
                content: [{ type: "text", text: `Messages compose link: ${link.url}\nExpires: ${link.expires_at}` }],
                structuredContent: link,
              });
            } catch (error) {
              const message = error instanceof MessageLinkError
                ? error.message
                : "The Messages link request may have completed, but no result was received. Do not retry automatically. Ask the user before creating another link.";
              return rpcResult({ isError: true, content: [{ type: "text", text: message }] });
            } finally {
              linkInFlight.delete(hostID);
            }
          }
          const owner = options.store.host(hostID)?.user;
          let hostPending = 0, userPending = 0;
          for (const work of pending.values()) { if (work.host === hostID) hostPending++; if (work.user === owner) userPending++; }
          if (pending.size >= GLOBAL_IN_FLIGHT || hostPending >= HOST_IN_FLIGHT || userPending >= USER_IN_FLIGHT) return json({ error: "host_busy" }, 429);
          if (toolCall) {
            const slot = await acquire(hostID);
            if (slot === "full") return json({ error: "host_busy" }, 429);
            if (slot === "timeout") return rpcError(-32000, "Mac is busy. Inspect the draft queue before retrying a draft.");
          }
          try {
            const socket = connections.get(hostID);
            if (!socket) return unavailable();
            const id = randomUUID();
            return await new Promise<Response>(resolve => {
              const timeout = options.timeoutMs ?? 20_000;
              const timer = setTimeout(() => finish(id, unavailable()), timeout);
              pending.set(id, { host: hostID, user: token.user, socket, resolve, timer, addLinkTool: rpc.method === "tools/list" && scopeAllows(token.scope, "messages:link"), scope: token.scope });
              if (socket.send(JSON.stringify({ id, deadline: Date.now() + timeout, request: rpc })) === 0) finish(id, unavailable());
            });
          } finally {
            if (toolCall) release(hostID);
          }
        }
        return json({ error: "not_found" }, 404);
      } catch (error) {
        const reason = error instanceof Error ? error.message : "";
        if (path === "/oauth/token" && reason === "temporarily_unavailable") return json({ error: "temporarily_unavailable" }, 503);
        return json({ error: path === "/oauth/token" ? "invalid_grant" : "request_unavailable" }, 400);
      }
    },
    websocket: {
      maxPayloadLength: 1_048_576, idleTimeout: 30, sendPings: true,
      open(socket) {
        if (!options.store.host(socket.data.host)) { socket.close(1008, "Connection refused"); return; }
        const current = connections.get(socket.data.host);
        if (current && current.data.sequence > socket.data.sequence) { socket.close(1008, "Connection refused"); return; }
        if (current) { connections.delete(socket.data.host); current.close(1012, "Replaced by a newer connection"); }
        lastHeard.set(socket, now());
        connections.set(socket.data.host, socket);
      },
      pong(socket) { lastHeard.set(socket, now()); },
      message(socket, message) {
        lastHeard.set(socket, now());
        try {
          const packet = JSON.parse(String(message));
          // Application heartbeat: the Mac learns within seconds that a silent path is dead.
          if (packet && typeof packet === "object" && typeof packet.heartbeat === "number" && Object.keys(packet).length === 1) {
            if (connections.get(socket.data.host) === socket) socket.send(JSON.stringify({ heartbeat: packet.heartbeat }));
            return;
          }
          const work = pending.get(packet.id);
          if (!work || work.socket !== socket || work.host !== socket.data.host) return;
          if (!options.store.host(work.host) || packet.unavailable || !packet.response || typeof packet.response !== "object") finish(packet.id, unavailable());
          else finish(packet.id, json(work.addLinkTool ? addMessageLinkTool(filterToolList(packet.response, work.scope)) : filterToolList(packet.response, work.scope)));
        } catch { socket.close(1008, "Invalid response"); }
      },
      close(socket) {
        if (connections.get(socket.data.host) === socket) connections.delete(socket.data.host);
        for (const [id, work] of pending) if (work.socket === socket) finish(id, unavailable());
      },
    },
    error() { return json({ error: "service_unavailable" }, 503); },
  });
  return { server, auth, connections, stop() { for (const id of pending.keys()) finish(id, unavailable()); for (const lock of locks.values()) for (const waiter of lock.waiters) waiter.grant("timeout"); locks.clear(); server.stop(true); } };
}
