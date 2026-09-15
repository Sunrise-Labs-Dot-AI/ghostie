# Ghostie remote MCP

Opt-in remote reading and text-draft staging from a running Ghostie Mac. Clerk manages account creation and browser sign-in. Ghostie issues per-Mac OAuth capabilities after explicit consent. The Mac connects outward over WSS; no inbound Mac ports or router configuration are needed.

## Status

Implemented and tested with synthetic data. This repository does not provision Clerk, a public hostname, TLS, or a production relay. A configured, signed app and a live Clerk/browser/client acceptance run are required before making this feature available to users. Settings accepts a service URL for advanced deployments. A distribution can set `GhostieRemoteRelayURL` in its app Info.plist; development can use `GHOSTIE_RELAY_ORIGIN` in the app launch environment. Neither has an invented production default.

## User flow

1. Open Settings, Advanced, Host a remote MCP.
2. Use the configured service URL, choose Create account or sign in, and create/sign into a Clerk account in the browser.
3. Enter the eight-character code displayed on the Mac. The browser displays the signed-in identity. Confirm that this is your Mac.
4. Return to Ghostie and choose Start hosting. Copy MCP URL into an OAuth-capable remote MCP client.
5. Approve the client's read and draft access in the browser. The token is bound to this exact Mac URL and expires after one hour. Reconnect/approve again to renew; there are no refresh tokens.
6. Review drafts locally. Remote drafts carry a visible source label. Stop hosting immediately disables this process; Disconnect account revokes its host credential and tokens at the relay. If revocation cannot reach the service, Ghostie stops locally and retains the credential so you can retry revocation.

The Mac must be awake, online, and running Ghostie with hosting enabled. Network failures reconnect with backoff. Requests are never queued or automatically retried. A lost draft response is ambiguous: inspect the local queue before retrying. Enabling hosting persists across app launches; it does not make the relay a background messaging host after the app exits.

## Encryption and data handling

- MCP client to relay uses HTTPS; relay to Mac uses WSS. TLS terminates at the relay, so the relay can see message content in memory. This is **not end-to-end encryption against the relay**.
- No cloud message database, payload logs, disk queue, or response cache. SQLite stores host ownership and hashed credentials/tokens only. Restrict its directory to the service account and exclude request bodies/headers from proxy, tracing, crash-report and platform logs. Disable process core dumps.
- Mac host credentials are 256-bit random secrets in macOS Keychain, never argv, URLs, UserDefaults, or ordinary configuration files. The app passes them over a private stdin pipe.
- Existing local iMessage/WhatsApp databases and local draft storage retain their existing protection. This change does **not** encrypt those stores at rest. Use the Mac's existing disk protection; do not describe this feature as encrypted local message storage.
- The Mac filters suspected OTP/2FA/security codes and authentication links before response serialization, including previews, quoted replies and draft context. It omits attachment metadata, local paths and body hashes. Filtering is heuristic, with false positives and possible misses for unfamiliar languages, formats, split messages or encoded secrets. It is not a guarantee that an AI client can never see an authentication secret.
- Both user consent and settings explain that messages reach the configured AI client and are visible to the relay in memory.

## Local permission boundary

Only these methods are callable remotely: list/read/search threads, stage text drafts, list/read drafts. The host enforces strict argument schemas and a hard allowlist even if the relay submits a different request. There is no remote send, approval, schedule, discard, priority mutation, attachment path, generic daemon call, resource or prompt endpoint. Drafts use the existing local review queue; neither an MCP tool hint nor client-provided metadata grants send authority.

One in-flight tool call per host; six stages/minute on the Mac; 60 MCP requests/minute per host at the relay; 64 KiB request and 1 MiB response limits; 20-second response timeout. Body reads retain existing scoped-history rules and are capped at 100 results per call. Relay or host overload fails closed.

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

Configure Clerk sign-up/sign-in for this origin. The browser uses ClerkJS from its Frontend API host; the relay accepts only Clerk **session** tokens from that origin, not arbitrary ID tokens, OAuth tokens or cookies. Clerk manages identity, not Ghostie's MCP scopes. No Clerk secret goes into the Mac app.

Register each supported MCP client with its exact callback URI from that client's settings/documentation. Example with fictional values:

```json
[{"id":"example-client","name":"Example MCP client","redirects":["https://client.example.test/oauth/callback"]}]
```

Clients must support static public client IDs, authorization code with PKCE S256, the `resource` parameter at authorization and token exchange, and Streamable HTTP. No dynamic client registration, client secrets, wildcard redirects, or implicit grant. An exact HTTP loopback callback is permitted only when explicitly registered. Dynamic loopback ports are not supported. Validate the intended client with its real callback before launch; this implementation has SDK transport tests, not a certified production-client compatibility list.

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

## Protocol and verification

The host supports the 2025-03-26, 2025-06-18 and 2025-11-25 Streamable HTTP protocol versions with JSON responses; no SSE stream or server-side MCP session is required. OAuth metadata is served at `/.well-known/oauth-authorization-server` and `/.well-known/oauth-protected-resource/mcp/hosts/{id}`. GET/DELETE on the MCP endpoint returns 405.

Tests cover Clerk-session gate injection, cross-user consent refusal, exact redirects, PKCE downgrade, one-use code exchange, wrong client/resource/proof, expiry, token revocation, cancellation, offline host, disconnection, timeout/no retry, and synthetic message persistence checks. Host SDK tests cover real HTTP client framing, tool visibility, strict fields, local rate enforcement, and response filtering. No personal message data is used.

Before public launch, exercise actual Clerk sign-up and returning sign-in, browser CSP/CAPTCHA, Keychain save/restart, two accounts and two Macs, the chosen MCP client's OAuth flow, TLS verification on both legs, suspend/wake, app force-quit, disconnection/revocation, and local review/send of a synthetic draft. Deployment and signed app release are separate from implementation and require the normal production authorization.

References: [Clerk request authentication](https://clerk.com/docs/reference/backend/authenticate-request), [Clerk OAuth behavior](https://clerk.com/docs/guides/configure/auth-strategies/oauth/how-clerk-implements-oauth), [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization).
