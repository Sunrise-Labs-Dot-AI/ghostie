# SUN-613 phase 2a: the authenticated read listener

Loop: **full**. First inbound network surface in the app, plus a credential. Not abbreviated.

Branch `claude/sun-613-phase-2-read-listener`, worktree `.claude/worktrees/sun-613-p2`, off
`origin/main` at 75604ab.

**Third revision. Two prior versions were BLOCKed** (6 CRITICAL, then 4 CRITICAL). Artifact:
`runs/reviews/2026-07-22-sun-613-phase-2a-plan.md`.

## Why the approach changed, not just the details

The last round is the one that matters: two of my fixes for previous CRITICALs **did not hold**
(interface provenance, and source completeness), and a flag I added to fix one problem (`truncated`)
introduced a new deletion bug. Round over round, the reviewer kept finding another gap in a network
protocol I was designing myself: response authentication, MAC canonicalization, nonce and clock
semantics, audience binding, replayable signed tuples.

That is the signature of hand-rolling an authenticated transport. The correct engineering response is
not a fourth patch, it is to stop rolling my own and delegate transport security to audited
infrastructure that already exists on this machine.

**Ghostie binds loopback only, and `tailscale serve` exposes it.** Verified present here: Tailscale
1.98.9, CLI at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, and
`tailscale serve --bg <port>` proxies a `127.0.0.1` HTTP server onto the tailnet with TLS terminated
using the node's own certificate.

What that dissolves, by construction rather than by patch:

| Prior CRITICAL | Now |
|---|---|
| Binding proof: `utun*` + `100.64.0.0/10` does not prove Tailscale (another VPN can hold both) | **Gone.** The app never binds a tailnet address. It binds `127.0.0.1`. There is no interface-provenance question to answer. |
| Plain HTTP authenticates the host, not the Ghostie process; an impostor can bind the port | **Gone.** Tailscale terminates TLS with the node's real certificate, so the reader authenticates the server. |
| A captured signed request tuple is itself a replayable bearer authorization; the response is unauthenticated and a forged `complete:true` empty envelope would drive deletions in 2b | **Gone.** TLS authenticates and integrity-protects the response. |
| MAC canonicalization, nonce cache, clock skew, audience binding | **Gone.** No hand-rolled MAC exists. |

And because TLS now authenticates the server, a **bearer token is once again the right credential**,
which also lets the server store only a HASH of it rather than the raw key the HMAC scheme forced.

Phase 3 benefits too: MagicDNS gives a real `https://` origin, so the PWA gets a secure context with
no mixed-content or cross-origin preflight problem.

## Round-4 review: three fixes, then build

The fourth review confirmed two claims genuinely hold (interface provenance, and the hand-rolled
MAC/nonce/clock, are gone; Tailscale does terminate HTTPS in `tailscaled`). Three findings remain and
are fixed below rather than taken to a fifth design round, since the reviewer supplied the exact
shape of each fix.

**R4-1 (CRITICAL): Tailscale authenticates the NODE, not the Ghostie process.** `tailscaled`
terminates TLS then proxies plain HTTP to `127.0.0.1:<port>`, so local malware that squats that port
first receives the bearer token and can serve a forged queue.

  - The read half is a non-escalation: that process can already read `~/.messages-mcp/drafts/`.
  - The forgery half is real: a forged `complete: true` empty queue would be trusted by 2b and the
    phone. Under read-only it cannot cause a send, but it can mislead.
  - **Fix: two secrets at pairing.** A `token` that IS sent (authorizes the read) and a `verify_key`
    that is NEVER sent. Every response carries `HMAC-SHA256(verify_key, body)` in a header, and the
    reader rejects an unverified body. Malware that harvests the token still cannot forge a response,
    because it never sees `verify_key`. This is response integrity only, so it needs no nonce, clock
    window, or canonicalization: the reader is verifying data it already asked for.

**R4-2 (CRITICAL): completeness needs a fail-closed initial state and a stable source set.**
`DraftRefreshSnapshot.empty` currently claims `complete: true` before any refresh has run, and
`whatsappEnabled` is decided at init while the daemon may create that directory later, so the source
set can change mid-life. Fix: the pre-refresh state is `complete: false`; the snapshot records which
directories were scanned; and a source set that changes between scans forces `complete: false` for
that pass.

**R4-3 (CRITICAL): revocation must be linearizable with authentication.** Fix: one `actor` owns the
reader records, the live-connection registry, and revocation. Authenticate, register the connection
under its `keyid`, revoke, and cancel all happen inside that actor, so a request cannot authenticate
against a record that is being revoked concurrently.

**R4-4 / R4-5 (WARNING), accepted as stated:** Tailscale identity headers are NOT process
authentication (a direct loopback caller can forge them), so they are used for nothing; and
`serve status --json` verification must check the exact expected shape (HTTPS frontend, expected
hostname and port, exact `http://127.0.0.1:<port>` target, **Funnel disabled**) rather than merely
"something is served".

## Data plane: pull, not push (unchanged)

Each device serves its own queue; the hub fetches and aggregates (2b). No endpoint anywhere accepts
data: every route is a GET with no body. Serving on demand from live state means nothing is
persisted, so there are no snapshot files, no manifest format, no tombstones, no purge-on-disable.
The only durable state is the reader credential list.

## What gets built

**A. `RelayReaderTokens`.** Issue / verify / revoke.
  - Issue: 32 bytes from `SecRandomCopyBytes`, base32 for typing, shown once in the Mac UI.
  - Store: `~/.messages-mcp/relay/readers.json`, 0600, dir 0700, with the O_NOFOLLOW + fstat + uid
    discipline phase 0 established. Records hold `{id, label, sha256_of_token, created_at}`, so the
    file yields no usable credential.
  - Verify: hash the presented token, constant-time compare against **every** record with no early
    return, then select by match. Cap 16 readers.

**B. `RelayLoopbackServer`.** Binds `127.0.0.1` **only**, never `0.0.0.0`, never a tailnet address.
  - One route: `GET /queue`. Every other path and method rejected. Any request carrying a body
    (`Content-Length` or chunked) rejected, since no route accepts one.
  - Limits: 8 KB request line + headers, 5 s header-completion timeout, 8 concurrent connections.

**C. `RelayQueueSource`.** The read-only boundary, structurally. The server is initialized with an
immutable `Sendable` snapshot provider and **holds no reference to `DraftStore` or any sender**, so
network work cannot reach a mutation path, and cannot block the main actor or delay a scheduled send.

**D. `RelayServerController`.** The named lifecycle owner. Observes the feature flag, the local
setting, **and revocation events**; serializes start / stop / rebind; tracks live connections with
the authenticated `keyid` that fetched them; cancels the listener and matching connections on stop
or revoke. Honest guarantee, stated in code: *after disable or revocation is observed locally, no new
connection is accepted and matching in-flight connections are cancelled; bytes already handed to the
kernel cannot be recalled.*

**E. `DraftStore` completeness (a real fix, not a flag).** Today `loadDir` records directory-
enumeration errors but silently drops per-file read/decode failures, and `drafts` and
`lastRefreshError` are published in separate assignments, so an observer can pair new drafts with a
stale error. Change: count every per-file failure, and publish ONE atomic value carrying
`(drafts, complete, generation, observedAt)`. `complete` is true only when enumeration succeeded and
every eligible file parsed.

**F. Response envelope.** `schema_version`, `origin_device_id`, `server_instance` (random per process
start, so `generation` is only meaningful within an instance), `generation`, `observed_at`,
`complete`, `truncated`, `snapshots`.

  `complete` means **authoritative membership**: source complete AND not truncated. Truncation forces
  `complete = false`. One flag with correct semantics, so 2b's rule is simply "delete by absence only
  from `complete: true`" and the previous footgun (complete-but-truncated authorizing deletion of the
  remainder) cannot occur.

  Publishes only `pending` / `scheduled` / `held`. **Never `sent`**, so a week of retained sent
  drafts is not replicated as a queue.

## Exposure and gating

- Serves only when the `deviceRelay` flag is on AND an explicit local `relay.enabled` setting is
  true. A remote flag alone must never start copying bodies anywhere.
- Tailnet exposure is a deliberate, separate user action: `tailscale serve --bg <port>`. The app
  reads `tailscale serve status --json` and displays whether the queue is exposed, so the state is
  visible rather than assumed. The app does not silently enable exposure.
- With the feature off, no socket is bound at all.

## Threat model, stated plainly

- **Server authentication, confidentiality, integrity in transit:** TLS terminated by Tailscale with
  the node's certificate, over a WireGuard mesh. Not hand-rolled.
- **Worst case of a stolen reader token:** a tailnet peer reads the user's own draft queue. It cannot
  send, edit, or discard: no such route exists.
- **Loopback reachability:** any local process can connect to `127.0.0.1:<port>`. Accepted and
  stated: a same-user process can already read `~/.messages-mcp/drafts/` directly, so this is not an
  escalation. The token still gates it.
- **Not defended:** an attacker who is a tailnet node AND holds a reader token. That is what
  revocation is for.
- **Dependency:** if `tailscale serve` is not configured, the queue is simply not reachable from
  other devices. Fail closed, and surfaced in the UI.

## Acceptance criteria

1. `GET /queue` with a valid token returns pending/scheduled/held; `sent` never appears.
2. Missing, malformed, unknown, and revoked tokens are all 401 with no queue data.
3. Every route and method except `GET /queue` is rejected, and any request carrying a body is
   rejected.
4. The listener binds `127.0.0.1` only. A test asserts it is not reachable on a non-loopback address.
5. Flag off or setting off: no socket bound; an in-flight connection is cancelled on disable.
6. Revoking a reader cancels that reader's in-flight connections and 401s its next request.
7. `complete` is false when the directory errored OR any file failed to parse OR the response was
   truncated; a malformed-file test and a truncation test both assert it.
8. `readers.json` stores only hashes; the plaintext token appears nowhere on disk.
9. The server's initializer cannot take a `DraftStore` or a sender (enforced by its signature).
10. Full existing suite stays green: 760 Swift, 392 iMessage, 262 WhatsApp, 21 ghostie.

## Rollback, honestly

Reverting the code removes the listener and stops serving. It does **not** delete
`~/.messages-mcp/relay/readers.json` from a machine that already ran it, and it does not undo a
`tailscale serve` configuration the user created; both are inert once no code serves, and both are
removable by hand (`tailscale serve reset`). No message content is ever persisted, so there is no
body residue.

## Recorded for later phases

- **2b:** delete by absence only from `complete: true`; mark unreachable origins stale rather than
  deleting them.
- **3:** served over MagicDNS HTTPS, so secure context and same-origin are satisfied.
- Optional hardening: Tailscale identity headers / LocalAPI `WhoIs` to additionally bind a request to
  a source node.

## Test plan

`RelayReaderTokensTests` (issue/verify/revoke, hash-only storage, no early return, file mode),
`RelayLoopbackServerTests` (route allowlist, body rejection, limits, auth failures, `sent` exclusion,
loopback-only binding, gating, in-flight cancel on disable and on revoke),
`DraftStoreCompletenessTests` (malformed file and directory error both yield `complete: false`, and
the atomic publication pairs drafts with their own completeness).

## Production validation

On the M4 with flag and setting on: `tailscale serve --bg <port>`, then from the M1 fetch the
MagicDNS HTTPS URL with and without the token (200 / 401), confirm a sent draft is absent, revoke and
confirm 401, disable the setting and confirm the port is closed, and `tailscale serve reset` after.
