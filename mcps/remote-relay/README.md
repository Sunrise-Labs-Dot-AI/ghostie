# Ghostie remote MCP

Opt-in remote reading, text-draft staging, and mobile Messages compose-link creation. Clerk manages account creation and browser sign-in. Ghostie issues per-Mac OAuth capabilities after explicit consent. The Mac connects outward over WSS; no inbound Mac ports or router configuration are needed.

## Status

The trusted-relay implementation and production container are tested with synthetic data. The managed service uses Railway at `https://connect.messagesfor.ai` with the existing Ghostie production Clerk application. Live acceptance status is tracked in `runs/trusted-relay-v1.md`. A configured, signed app and a live Clerk/browser/client acceptance run are required before making this feature available to users. Settings accepts a service URL for advanced deployments. A distribution can set `GhostieRemoteRelayURL` in its app Info.plist; development can use `GHOSTIE_RELAY_ORIGIN` in the app launch environment. Neither has an invented production default.

## User flow

1. Open Settings, Advanced, Host a remote MCP.
2. Use the configured service URL, choose Create account or sign in, and create/sign into a Clerk account in the browser.
3. Enter the eight-character code displayed on the Mac. The browser displays the signed-in identity. Confirm that this is your Mac.
4. Return to Ghostie and choose Start hosting. Copy MCP URL into an OAuth-capable remote MCP client.
5. Approve the client's read, draft, and compose-link access in the browser. The token is bound to this exact Mac URL and expires after one hour. Reconnect/approve again to renew; there are no refresh tokens. Tokens issued before compose-link consent was added are rejected and must be replaced through this flow.
6. Review drafts locally. Remote drafts carry a visible source label. Stop hosting immediately disables this process; Disconnect account revokes its host credential and tokens at the relay. If revocation cannot reach the service, Ghostie stops locally and retains the credential so you can retry revocation.

The Mac must be awake, online, and running Ghostie with hosting enabled for MCP initialization, tool discovery, message access, and draft staging. After a client has discovered the compose-link tool, that tool can execute during a temporary Mac disconnect because it is owned by the relay. Network failures reconnect with backoff. Requests are never queued or automatically retried. A lost draft response is ambiguous: inspect the local queue before retrying. Enabling hosting persists across app launches; it does not make the relay a background messaging host after the app exits.

## Encryption and data handling

- MCP client to relay uses HTTPS; relay to Mac uses WSS. TLS terminates at the relay, so the relay can see message content in memory. This is **not end-to-end encryption against the relay**.
- The relay has no cloud message database, payload logs, disk queue, or response cache. SQLite stores host ownership and hashed credentials/tokens only. Restrict its directory to the service account and exclude request bodies/headers from proxy, tracing, crash-report and platform logs. Disable process core dumps.
- `ghostie_create_messages_link` is the explicit exception to memory-only relay handling: it sends the requested recipient and body to `ghostie.app`, where authenticated ciphertext is stored for seven days. The returned short URL is a bearer capability. Anyone holding it can open the prefilled compose screen until expiry. The page never sends the message.
- Mac host credentials are 256-bit random secrets in macOS Keychain, never argv, URLs, UserDefaults, or ordinary configuration files. The app passes them over a private stdin pipe.
- Existing local iMessage/WhatsApp databases and local draft storage retain their existing protection. This change does **not** encrypt those stores at rest. Use the Mac's existing disk protection; do not describe this feature as encrypted local message storage.
- The Mac filters suspected OTP/2FA/security codes and authentication links before response serialization, including previews, quoted replies and draft context. It omits attachment metadata, local paths and body hashes. Filtering is heuristic, with false positives and possible misses for unfamiliar languages, formats, split messages or encoded secrets. It is not a guarantee that an AI client can never see an authentication secret.
- Browser consent and Mac settings explain the separate read/draft and compose-link data paths, including seven-day encrypted persistence and bearer-link access.

## Local permission boundary

Only these capabilities are callable remotely: list/read/search threads, stage text drafts, list/read drafts, and create short HTTPS links that open a prefilled iOS Messages compose screen. The relay owns `ghostie_create_messages_link`; after online discovery it can execute during a Mac disconnect and is never forwarded to the host. Fresh MCP initialization and discovery still require the Mac, which prevents a partial offline catalog from hiding Mac-backed tools. The host enforces strict argument schemas and a hard allowlist for every Mac-backed call even if the relay submits a different request. There is no remote send, approval, schedule, discard, priority mutation, attachment path, generic daemon call, resource or prompt endpoint. Drafts use the existing local review queue; neither an MCP tool hint nor client-provided metadata grants send authority.

One in-flight Mac-backed tool call per host; six stages/minute on the Mac; six compose-link creations/minute and one in-flight creation per host at the relay; ten link creations in flight globally; 60 MCP requests/minute per host at the relay; 64 KiB request and 1 MiB response limits; 20-second host-response timeout. Link creation makes one five-second upstream attempt and never automatically retries an ambiguous result. Body reads retain existing scoped-history rules and are capped at 100 results per call. Relay or host overload fails closed.

## Service configuration

Run a **single relay process** with a persistent metadata volume. Host routing is process-local, so multiple replicas require a future coordinated routing design. A restart drops connections and outstanding requests; Macs reconnect. Existing hashed tokens and host records survive; pending pairing and authorization codes expire with the process.

Required environment variables:

| Variable | Value |
| --- | --- |
| `GHOSTIE_RELAY_ORIGIN` | Public HTTPS origin, with no trailing slash |
| `CLERK_PUBLISHABLE_KEY` | Clerk publishable key for this deployment |
| `CLERK_SECRET_KEY` | Backend secret from the same instance, server only |
| `CLERK_FRONTEND_ORIGIN` | That instance's HTTPS Frontend API origin |
| `GHOSTIE_RELAY_DB` | Absolute path to a private persistent SQLite file |
| `GHOSTIE_OAUTH_CLIENTS` | JSON list of registered public MCP clients, below |
| `MESSAGE_OPENER_API_TOKEN` | Server-only bearer token for `POST https://ghostie.app/v1/links` |

Configure Clerk sign-up/sign-in for this origin. The browser uses ClerkJS from its Frontend API host; the relay accepts only Clerk **session** tokens from that origin, not arbitrary ID tokens, OAuth tokens or cookies. Clerk manages identity, not Ghostie's MCP scopes. No Clerk secret goes into the Mac app.

Register each supported MCP client with its exact callback URI from that client's settings/documentation. Example with fictional values:

```json
[{"id":"example-client","name":"Example MCP client","redirects":["https://client.example.test/oauth/callback"]}]
```

Clients must support static public client IDs, authorization code with PKCE S256, the `resource` parameter at authorization and token exchange, and Streamable HTTP. No dynamic client registration, client secrets, wildcard redirects, or implicit grant. An exact HTTP loopback callback is permitted only when explicitly registered. Dynamic loopback ports are not supported. Validate the intended client with its real callback before launch; this implementation has SDK transport tests, not a certified production-client compatibility list.

Cursor / Grok Bot uses the public client `ghostie-cursor`, scopes `messages:read messages:draft messages:link`, and no client secret. Register both `http://localhost:8787/callback` and `https://www.cursor.com/agents/mcp/oauth/callback`, as documented in [Cursor's static OAuth setup](https://cursor.com/docs/mcp#static-oauth-for-remote-servers). The explicit `localhost` HTTP exception supports its fixed desktop callback; consent and token exchange still require the exact registered URI. The MCP URL and OAuth `resource` are the host-specific URL copied from Ghostie's Advanced settings, not the relay root. Every newly authorized remote client receives `ghostie_create_messages_link`; CoS, Networker, and Sunny do not need separate opener secrets or per-persona configuration, but each existing connection must reconnect once to receive the new scope and token policy.

```sh
cd mcps/remote-relay
bun install
bun run typecheck
bun test
bun start
```

The listener binds **127.0.0.1:8787**. Put a TLS reverse proxy on the same host; preserve the public Host header, support WebSocket upgrades, disable caching/body logging and use an idle timeout above 30 seconds. Never expose the plaintext listener or terminate the two network legs without TLS. Apply per-source rate limits at the public edge too: the app-level loopback peer limiter is an aggregate last resort behind a reverse proxy.

Caddy example, with the hostname supplied by deployment configuration:

```caddyfile
{$GHOSTIE_RELAY_DOMAIN} {
    reverse_proxy 127.0.0.1:8787
    header {
        Strict-Transport-Security "max-age=31536000"
        Cache-Control "no-store"
    }
}
```

Keep access logs and request-body capture disabled. Set `LimitCORE=0` in the service supervisor. Do not deploy this relay as a stateless Vercel function: it owns long-lived WSS connections.

## Production container on Railway

Build from `mcps/remote-relay` with its Dockerfile. Run one replica with a persistent volume at `/data`, port `8080`, health path `/health`, restart on failure (three attempts), and serverless/CDN caching disabled. Keep the start command empty so the image entrypoint runs. The entrypoint disables core dumps, restricts volume permissions and drops to the Bun user. The supervisor owns both processes and stops the container if either exits. Caddy accepts Railway edge traffic and forwards only to the loopback Bun listener. Railway terminates public TLS and documents encryption between its edge and applications. This is a trusted hosting boundary, not relay-blind encryption.

Configure the required variables above, with `GHOSTIE_RELAY_DB=/data/relay.sqlite` and `PORT=8080`. Store the Clerk secret only in Railway service variables. Clerk telemetry, Caddy logging and child stdout/stderr capture are disabled; only generic supervisor failures are emitted. Railway HTTP metadata can still include request paths, timing and source addresses. Do not claim that request metadata is deleted or that process memory is securely erased after a request.

Verify the exact image locally before upload:

```sh
docker build -t ghostie-relay:local mcps/remote-relay
bun run mcps/remote-relay/tests/container-smoke.ts
```

Upload only the relay directory using Railway CLI `up . --path-as-root` from that directory, with the explicit production project/service/environment IDs from the rollout record. New Railway services use dashboard settings or Infrastructure as Code; do not add a legacy railway.json. Keep deployments manual until live acceptance passes. Registered Claude client ID: `ghostie-claude`, callback `https://claude.ai/api/mcp/auth_callback` (no client secret).

For manual browser acceptance, `GHOSTIE_RELAY_ORIGIN=https://connect.messagesfor.ai bun run mcps/remote-relay/tests/live-acceptance.ts` starts a fixed synthetic host and prints a pairing URL/code. It never imports messaging backends. Stop it with Ctrl-C to revoke the test host. If interrupted unexpectedly, its private temporary cleanup file permits retrying revocation; never commit or upload that file.

## Protocol and verification

The host supports the 2025-03-26, 2025-06-18 and 2025-11-25 Streamable HTTP protocol versions with JSON responses; no SSE stream or server-side MCP session is required. OAuth metadata is served at `/.well-known/oauth-authorization-server` and `/.well-known/oauth-protected-resource/mcp/hosts/{id}`. GET/DELETE on the MCP endpoint returns 405.

Tests cover Clerk-session gate injection, cross-user consent refusal, exact redirects, PKCE downgrade, one-use code exchange, old-policy token invalidation, wrong client/resource/proof, expiry, token revocation, cancellation, offline host, disconnection, timeout/no retry, rolling link limits, and synthetic message persistence checks. A standard MCP SDK test verifies tool discovery and protocol-valid rate-limit results. The production container smoke invokes the relay-owned link tool against a synthetic local opener while the Mac socket is disconnected. Host SDK tests cover real HTTP client framing, tool visibility, strict fields, local rate enforcement, and response filtering. No personal message data is used.

Before public launch, exercise actual Clerk sign-up and returning sign-in, browser CSP/CAPTCHA, Keychain save/restart, two accounts and two Macs, the chosen MCP client's OAuth flow, TLS verification on both legs, suspend/wake, app force-quit, disconnection/revocation, and local review/send of a synthetic draft. Deployment and signed app release are separate from implementation and require the normal production authorization.

References: [Clerk request authentication](https://clerk.com/docs/reference/backend/authenticate-request), [Clerk OAuth behavior](https://clerk.com/docs/guides/configure/auth-strategies/oauth/how-clerk-implements-oauth), [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization).
