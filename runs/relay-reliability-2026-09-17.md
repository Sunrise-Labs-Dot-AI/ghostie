# Remote relay reliability hardening, 2026-09-17 (Pacific)

## Why

James reported the remote MCP as flaky on both the M4 and an always-on M1. Read-only investigation on 2026-09-16 and 2026-09-17 (Railway HTTP logs for deployments b18fb8d0 and 57f2ddca pulled through the Railway API with host ids and query strings stripped, relay and Mac host source, a local consent-schema reproduction, a synthetic half-open WebSocket test, local unified log, pmset, Docker and Tailscale state, and official MCP, Claude, Cursor, Railway, Cloudflare, Tailscale, ngrok, Fly, Bun and Apple documentation) found application-level causes, not hosting problems. No platform 5xx, no container restarts.

| Window (UTC) | Host | MCP POSTs | 200 | 401 | 429 host_busy | 503 host offline | WSS sessions | reconnect 409s | consent 400s | token exchanges |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Sep 16 04:34 to Sep 17 00:23 (b18fb8d0) | M4 | 1030 | 531 | 161 | 77 | 18 | 26 | 82 | 0 | 3 |
| Sep 17 00:23 to 03:33 (57f2ddca) | M4 then M1 | 279 | 129 | 78 | 17 | 0 | 12 | 30 | 79 | 1 |
| Sep 17 03:33 to 14:53 (57f2ddca) | M1 | 347 | 132 | 149 | 2 | 0 | 14 | 51 | 0 | 0 |

Ranked causes:

1. One-hour access tokens with no refresh token. Grok Bot keeps sending the expired token and gets 401 until a human re-consents; four manual re-authorizations in 36 hours and dead stretches of 7 and 10 hours. The always-on M1 was connected for nine hours overnight while every call failed with 401.
2. PR #41 made the consent schema require the exact three-scope string; Cursor's configured two-scope string produced 79 consent 400s until the client configuration changed.
3. One in-flight request per host with HTTP 429 `host_busy` for the second. Grok Bot personas initialize in parallel and the TypeScript MCP client neither serializes nor retries on 429: 96 rejections.
4. After a WebSocket drop the relay kept the dead socket until its 30 s idle timeout and answered reconnects with 409, turning each drop into a 20 to 40 s outage: 163 409s across six churn windows on both Macs. The drop cause is undetermined (no sleep, Wi-Fi, app relaunch, Docker or Tailscale exit-node events line up); a content-free path monitor runs from the M4 to separate house network from Railway edge.
5. No Mac-side heartbeat: a synthetic test with relay-identical settings showed the relay dropping the host at 32 s while the Mac still reported Online 100 s later.

The 18 503s on Sep 16 05:20 to 06:06 UTC coincide with the app being quit and are expected.

## What changed (relay only, no app release)

- Consent accepts any subset of `messages:read messages:draft messages:link` plus the conventional `offline_access`; the granted scope is recorded on the token and enforced per tool at the relay (403 with `WWW-Authenticate: Bearer error="insufficient_scope"`), and tool discovery omits tools the token cannot call.
- The token endpoint issues a rotating refresh token (30 days, replaced on every use, single use; replaying a rotated token revokes the whole grant family, including its access tokens). `grant_types_supported` now lists `refresh_token`; `offline_access` is advertised so Claude requests it. Revoking a refresh token revokes the grant; Disconnect account deletes everything for the Mac.
- Grant scope and family live in a `token_grants` side table and refresh tokens in `refresh_tokens`; the original `tokens` table is unchanged so the previous relay build still runs against the database if rolled back (without refresh support). Token policy stays at 2, so tokens issued since PR #41 keep working.
- Tool calls are serialized per host through a bounded queue (eight waiters, 15 s) instead of being rejected; discovery and pings run concurrently (eight in flight per host). A waiter that runs out of time gets a JSON-RPC busy error rather than an HTTP error.
- A newer authenticated Mac connection replaces a stale one (close code 1012) instead of being refused with 409.
- The relay echoes `{"heartbeat": n}` frames so the next app release can add a Mac-side heartbeat.
- 401 challenges now carry `error="invalid_token"` (when a bearer was presented) and the supported `scope`.

James approved the plan and the 30-day rotating refresh token lifetime on 2026-09-17 morning.

## Verification

- Relay: typecheck and 63 tests / 344 assertions pass (scope subsets and enforcement, refresh rotation, replay revocation, narrowing, binding, revocation, host deletion, legacy tokens, concurrent discovery with serialized calls, bounded queue and timeout, per-host cap, stale replacement, outstanding-work failure on replacement, heartbeat echo, HTTP token endpoint end to end, metadata).
- Production image: local build and container smoke including the refresh grant, replay revocation, and refresh-token canaries in metadata and logs: see rollout notes below.
- Adversarial review: see below.

## Rollout

(filled in after deployment)

## Remaining

- Mac-side heartbeat in `mcps/ghostie/src/remote-host.ts` for the next app release (relay support is live).
- Live confirmation that Grok Bot survives an hour boundary without a Connect card; Cursor's refresh behavior is undocumented, so if it never refreshes, the failure mode is unchanged from before.
- Cause of the periodic WebSocket drops; compare the M4 path monitor with the next churn window in the relay logs.
