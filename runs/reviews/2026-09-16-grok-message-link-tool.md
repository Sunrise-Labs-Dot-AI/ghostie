# Adversarial review: Grok Bot Messages link tool

- Branch: `codex/grok-message-links`
- Base: `220eb76`
- Review lanes: security, correctness/failure injection, and MCP API contract
- Model note: the Claude Opus review lane was attempted but its OAuth session
  was expired. Three independent Codex review contexts were used, followed by
  targeted re-verification of every accepted finding.

## Scope and invariants

The review covers the relay-owned `ghostie_create_messages_link` MCP tool, its
OAuth authorization boundary, upstream opener client, protocol behavior,
production container path, consent copy, and the opener landing-page security
regressions.

Load-bearing invariants:

1. A client must receive explicit `messages:link` consent before it can persist
   a recipient and body at the opener service.
2. Tokens issued under the earlier read/draft policy must not inherit the new
   authority.
3. The tool composes only and never sends, approves, schedules, or bypasses the
   local Ghostie review queue.
4. The opener token remains server-only. Inputs, credentials, and returned
   bearer links must not enter relay logs or metadata.
5. One upstream attempt is made. Ambiguous outcomes must not encourage an
   automatic retry that could mint a duplicate bearer link.
6. Existing Mac-backed tools keep their discovery and forwarding behavior.

## Findings and dispositions

| Severity | Finding | Resolution and evidence |
|---|---|---|
| CRITICAL | Existing read/draft tokens silently gained seven-day cloud persistence and public bearer-link authority. | Added exact `messages:link` scope, browser and Mac disclosure, token policy 2, and rejection tests for policy-1 and old-scope grants. Security re-verification returned ADDRESSED. |
| CRITICAL | The five-second deadline ended after response headers, so a stalled body could hold host/global slots indefinitely. | Kept the abort deadline through bounded body reading, cancel the reader on abort, and added stalled-header and stalled-body tests. |
| WARNING | Malformed 201 responses encouraged a retry even though a link might already exist. | Every failure after 201 is `outcome_unknown` with explicit no-auto-retry guidance. |
| WARNING | The documented rolling limit was a fixed window. | Added a per-host timestamp window. The boundary regression sends one call at t=0, five at t=59,999, then requires one success and one rejection at t=60,001, which fails under the former fixed-window design. |
| WARNING | HTTP 429 prevented standard Streamable HTTP clients from decoding the intended MCP error. | Link limits now return HTTP 200 `CallToolResult` errors. An official MCP SDK test verifies the result is parsed. |
| WARNING | Offline initialization exposed only the relay tool with no usable catalog-change notification. | Initialization and discovery remain Mac-backed. A previously discovered link tool can still execute during a temporary Mac disconnect. |
| WARNING | The advertised body schema was looser than runtime validation. | Added `maxLength: 2000` and non-whitespace `pattern`, while runtime validation remains the Unicode-scalar and well-formedness authority. |
| WARNING | Container smoke never invoked the new path. | Added an exact-image fake opener and invoked the authenticated relay-owned tool after disconnecting the Mac socket. The smoke asserts no token, phone, body, host id, or returned URL enters relay logs/metadata. |

## Verification

- Relay TypeScript: typecheck passes; 46 tests and 226 assertions pass.
- Standard MCP SDK: initialization, merged discovery, six successful calls,
  and a parsed seventh-call tool error pass.
- Opener site: 16 tests pass, including hostile text and URL/HTML boundary
  cases; the rest of the site suites pass; `npm audit` reports zero findings.
- Swift app: build completes; 796 tests pass, 2 skipped, 0 failures.
- Exact production image: build passes and container smoke passes with offline
  link creation, auth refusal, no-store, core-limit, metadata/log canaries, and
  proxy-failure shutdown.
- `git diff --check`: clean. Added-line em dash scan: clean. Secret scan found
  only an intentional synthetic bearer canary in a unit assertion.

## Verdict

MERGE-OK. All critical and warning findings were resolved and independently
re-verified. Deployment still requires the normal PR/CI gate, production secret
injection, live health checks, and one-time reauthorization of CoS, Networker,
and Sunny for the new scope.
