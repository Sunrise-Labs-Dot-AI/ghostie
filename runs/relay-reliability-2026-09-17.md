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

- Relay: typecheck and 67 tests pass (scope subsets and enforcement from an explicit allowlist pinned to the Mac's, refresh rotation in one transaction, reuse grace and replay revocation, narrowing, binding, cap behaviour, revocation, host deletion, legacy-token backfill, concurrent discovery with serialized calls, bounded queue and timeout, per-host and per-account caps, liveness-gated replacement, concurrent connects, outstanding-work failure on replacement, heartbeat echo, HTTP token endpoint end to end, metadata).
- Production image: local build and container smoke on the reviewed code, including the refresh grant, replay revocation, and refresh-token canaries in metadata and logs.
- Adversarial review (`/code-review`, three clean-context personas, Security Auditor escalated): 15 findings, 14 accepted and fixed in the same PR, 1 deferred (per-token queue fairness for one account with several clients). The material ones: refresh rotation was not atomic, so a cap hit could burn a client's token and a retry would revoke its grant (fixed with a single transaction and per-family caps); two concurrent refreshes from one honest client revoked its own grant (fixed with a 30 second reuse grace); unconditional connection replacement let any credential holder evict a live Mac and had a handshake race (fixed with a 20 second liveness gate and takeover ordered by sequence in the socket open handler); the tool-to-scope map was default-allow (fixed with an explicit allowlist that a test keeps equal to the Mac's). Two clean-context verifiers then re-read the code and tests: all accepted fixes verified (one verifier confirmed empirically that Bun delivers the server `pong` event for automatic pings, so the liveness gate has data even before the Mac heartbeat ships); two tests that were weaker than their names were tightened and a non-upgrade connect now answers 426 instead of 405. Sidecar: `/tmp/code-review-pr44-20260917T0903.md`.

## Rollout

PR [#44](https://github.com/Sunrise-Labs-Dot-AI/ghostie/pull/44) passed all 14 CI checks (two intentional site skips) at `b44c5ba` and merged as `0b92aea`. The merged relay directory was uploaded with Railway CLI `up . --path-as-root` to the canonical project, environment, and service; deployment `4065d330-5fc0-45b8-8226-2d2b2e7cc94a` reported SUCCESS at 16:19 UTC (09:19 PDT). Application logs contain only the two container-start lines. Live checks: `/health` ok; the authorization-server metadata now lists `refresh_token` and `offline_access`; a 401 challenge carries `error="invalid_token"` and the supported scope. Existing hosts, tokens, and the volume were kept; token policy stays at 2, so tokens issued since PR #41 keep working and the M1's pairing did not change.

Rollback: redeploy the relay directory from `eb9db3c` (PR #42 era). The old build runs against the migrated database but cannot refresh or revoke refresh tokens; after any rollback with a revocation in it, delete every row from `refresh_tokens` before redeploying this build (see README).

User step after rollout: reconnect Grok Bot once (configure the three scopes or none, so Cursor discovers them). Nothing else changes for claude.ai; it will start refreshing silently on its next connection.

## Remaining

- Mac-side heartbeat: PR [#45](https://github.com/Sunrise-Labs-Dot-AI/ghostie/pull/45) (`remote-heartbeat.ts`, 15 second send, 10 second echo timeout, terminate and reconnect) rides the next app release; relay support is live.
- Live confirmation that Grok Bot survives an hour boundary without a Connect card; Cursor's refresh behavior is undocumented, so if it never refreshes, the failure mode is unchanged from before.
- Cause of the periodic WebSocket drops; compare the M4 path monitor with the next churn window in the relay logs.

## Follow-up, 2026-09-19 (Pacific): post-rollout check and per-host limit

James reported the remote MCP as "still flaky" two days after the rollout. Read-only evidence: Railway HTTP logs for deployment `4065d330` (Sep 17 16:19 to Sep 19 20:25 UTC, 11,842 rows, host ids stripped), the M1 over SSH (process table, sockets, content-free activity timestamps, daemon logs), and the M4 path monitor.

| Window (UTC) | What happened |
| --- | --- |
| Sep 17 16:19 to 20:00 | 30 × 401 and nothing else: the pre-rollout token had expired and there was no refresh token until James re-consented at 20:00 (iPhone). Expected. |
| Sep 17 20:00 to Sep 18 07:34 | 850 × 200, 369 × 202. One 401 per hour boundary, each followed within a second by a silent refresh (25 exchanges over the deployment, no Connect card). Zero 409. 12 × 429 in two bursts. No call slower than 100 ms at the edge. |
| Sep 18 08:56 to 09:01 | House WAN outage seen by both Macs (the M4 monitor's TLS leg and the M1's WhatsApp daemon). The relay logged the M1's socket closing at 08:56:07 after 16.6 h. |
| Sep 18 13:28 to Sep 19 20:24 | 189 × 503 `host_unavailable`, all immediate. Zero reconnect attempts reached the relay. |

Findings:
1. The M1 (Ghostie 0.14.0, host process from Sep 17 03:24 UTC) still held one ESTABLISHED socket to the Railway edge (the A record of `connect.messagesfor.ai`), half open: the relay's close was lost in the outage, the 0.14.0 host has no heartbeat, Bun's WebSocket client sets no TCP keepalive (`net.inet.tcp.always_keepalive=0`), and the reconnect loop only runs on close. The app kept showing Online. The host's last executed request was 07:31:53 UTC Sep 18 (M1 activity log, pid-matched). Cause #5 above, observed live. The app's `terminationHandler` turns hosting off rather than respawning, so killing the process would not have helped; James chose Stop hosting then Start hosting at 20:38 UTC Sep 19 and every call from 20:40 was 200 again.
2. The twelve 429s were the fixed-window per-host limiter (60 authenticated POSTs per minute), not `host_busy`: in the first burst the relay accepted exactly 60 POSTs from 21:33:37 and refused the 61st, then served again after the window reset. Cursor's Grok Bot initializes personas in parallel (about four requests each, peaks of 75 to 103 requests per minute) and does not retry a 429, so refused personas never initialized. The in-flight cap of eight was never reached (peak 20 requests in one second, all fast).
3. The path monitor's echo.websocket.org leg closes every 605 s on its own (service limit) and was never a network signal; the TLS leg to the relay stayed up 17.4 h and 5.3 h and captured the outage. Monitor stopped; log kept in the session scratchpad.

Change: PR [#46](https://github.com/Sunrise-Labs-Dot-AI/ghostie/pull/46) (`c879e6f`) raises the per-host limit to `HOST_REQUESTS_PER_MINUTE = 240` with a test (240 admitted, the 241st refused as `rate_limited`, reset after a minute) and a README update. Typecheck clean, 68 tests, 14 CI checks green including the container smoke. James ran the admin merge and the Railway upload (the auto-mode classifier refused both to the agent). Deployment `50e7c572-6a87-46cb-9b84-69398f614e52` SUCCESS at 20:49:00 UTC. The old container closed the M1's socket at 20:48:55; the M1's first reconnect waited 15 s at the edge for the single replica (502), and the next attempt was connected by 20:49:22 with no Stop/Start. Live checks: `/health` ok, metadata lists both grant types, an unauthenticated call answers 401.

Remaining:
- Done 2026-09-19 20:57 UTC: James released v0.15.0 (heartbeat #45, link tool #41, mobile opener #40) and updated both Macs. Verified: GitHub release with both assets, appcast item, `download.json` at v0.15.0; both Macs report 0.15.0 and the installed backend carries the heartbeat; the M1's new host (started 21:01:08 UTC) kept the same socket across a 40 s sample, and the relay logged only the previous host's close (21:01:10) with two 503s inside that restart. Success watch: the next WAN blip should produce a reconnect within about 25 s (15 s send, 10 s echo timeout) with no Stop/Start.
- Success watch for the limiter: no 429 during Grok Bot persona bursts.
- Deferred: per-token queue fairness.
