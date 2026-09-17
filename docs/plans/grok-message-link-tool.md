# Grok Bot Messages link tool

## Goal

Give every Grok Bot persona connected to Ghostie's hosted MCP one server-side
tool that turns a validated phone number and message body into a short public
`https://ghostie.app/t/<id>` compose link. CoS, Networker, and Sunny should all
receive the capability through their existing Ghostie MCP connection. The
opener API bearer token must remain inside the hosted relay and must never be
returned to the client, written to logs, or placed in a bot prompt.

## Scope and trust boundary

- Add one relay-owned MCP tool named `ghostie_create_messages_link`.
- Make it available to every registered remote MCP client that explicitly
  authorizes the fixed scope `messages:read messages:draft messages:link`, not
  only the `ghostie-cursor` client. Bump the token policy so grants issued before
  link-specific consent are rejected and require a new browser approval.
  Creating a compose-only link never sends.
- Call `POST https://ghostie.app/v1/links` from the Railway relay with
  `MESSAGE_OPENER_API_TOKEN` supplied as a server-only environment variable.
- Do not forward this tool call to the user's Mac. Existing read and staged
  draft tools continue to use the current relay-to-Mac WebSocket path.
- The opener service stores the phone and body as authenticated ciphertext for
  seven days. The returned short URL is a bearer capability: anyone holding it
  can open the prefilled compose screen until expiry.
- No change adds send, approve, schedule, discard, or attachment authority.

## Implementation

1. Add a small message-opener client module under `mcps/remote-relay/src/`.
   Validate inputs with strict Zod schemas before network I/O. `phone` must
   match `^\\+[1-9]\\d{6,14}$` with no normalization. `body` must remain
   unchanged, contain at least one non-whitespace character, contain no lone
   UTF-16 surrogate, and contain at most 2,000 Unicode scalars as counted by
   `Array.from(body).length`. Add boundary tests for whitespace, punctuation,
   non-ASCII digits, lone surrogates, astral characters, and 2,000/2,001
   scalars.
2. Send JSON in exactly one upstream attempt with a five-second timeout and the
   server-only bearer token. Set redirect handling to `error`, require JSON,
   and stream no more than 8 KiB of decompressed response bytes before parsing.
   Accept only a 201 response whose URL is exactly an HTTPS
   `ghostie.app/t/<16-character-id>` link and whose `expires_at` is valid ISO
   UTC and between 6 days 23 hours and 7 days 1 hour from receipt. Return
   actionable MCP errors without upstream bodies, tokens, phone numbers,
   message text, or the returned bearer link. Keep the timeout active through
   the complete body read. A timeout or network failure after dispatch, or any
   malformed response after a 201, is `outcome_unknown`: tell the agent not to
   retry automatically because the opener may already have committed a link.
3. Extend relay configuration with required `MESSAGE_OPENER_API_TOKEN`. Inject
   the opener client into `startRelay` so tests use a fake implementation and
   never need a production credential.
4. Add the dedicated `messages:link` OAuth scope to metadata, token exchange,
   browser consent, and Mac settings. Increment the stored token policy from 1
   to 2 so old tokens fail authorization and clients must re-consent.
5. Keep MCP initialization and discovery Mac-backed so a fresh client never
   receives a partial tool catalog. When the Mac is online, forward
   `tools/list` and merge in the canonical relay tool schema, replacing any
   same-name host entry. After discovery, intercept that tool locally so it can
   still run during a temporary Mac disconnect. The description must tell
   agents to use it for a tappable mobile Messages compose link instead of a
   raw `sms:` URL.
6. Intercept `tools/call` for `ghostie_create_messages_link` after OAuth and
   existing per-host request limiting but before checking Mac connectivity.
   Apply a true rolling limit of six creations per host per minute, one
   in-flight creation per host, and ten in-flight creations globally. Exhausted
   limits fail before any opener request and return an HTTP 200 MCP tool error
   that standard SDK clients can parse. Return both concise text content and
   structured content containing only `url` and `expires_at`. Mark the tool
   non-read-only, non-destructive, non-idempotent, and open-world.
7. Preserve all other JSON-RPC behavior. Existing calls remain single-flight,
   are forwarded to the connected Mac, and keep the current timeout and
   failure semantics.
8. Update the relay README and production container fixture. State the new
   required secret, seven-day encrypted persistence, bearer-link risk, exact
   tool behavior, and the fact that the link composes but never sends.
9. Add landing-page security regressions for bodies containing markup/script
   closers, quotes, ampersands, CRLF, bidi controls, emoji, reserved URL
   characters, and U+2028/U+2029. Require URL encoding, context-aware escaping,
   and the existing restrictive CSP without rejecting legitimate message text.
10. Update the architecture/data-flow documentation if this adds a documented
   component or flow not already represented.

## Tests and acceptance evidence

- Unit-test valid creation, local input rejection, redirect refusal, wrong
  content type, decompressed oversized responses, timeout/network/upstream
  failures, excessive or short expiry, malformed success responses, exactly
  one upstream attempt, exact authorization header use, and absence of
  credential or input data from returned errors.
- Relay-test online authenticated initialization and discovery followed by
  invocation after disconnect; dedicated-scope consent rejection and old-token
  invalidation; wrong-resource, revoked, expired, and unknown-client tokens;
  per-host and global abuse limits; no forwarding of the relay-owned call;
  canonical replacement of a same-name host tool; protocol-valid sanitized
  failures retaining the JSON-RPC ID; and unchanged forwarding of existing
  tools.
- Capture console/logger output for success, validation, timeout, network,
  non-2xx, and malformed-response paths. Extend the production container smoke
  with token, phone, body, and returned-URL canaries and assert that none appear
  in container logs or relay metadata.
- Configuration-test refusal to start without the opener token without
  printing parsed environment data.
- Run `bun run typecheck` and `bun test` in `mcps/remote-relay`.
- Build the exact production Docker image and run the container smoke test with
  a synthetic opener token and local fake opener. Invoke the new tool through
  the container while its Mac socket is disconnected.
- Run an adversarial code review and resolve accepted findings before merge.
- Open a PR, wait for all CI checks, and merge through the normal gate.
- After merge, read the token from login-keychain service
  `ghostie-message-opener-api-token` directly into Railway service variable
  `MESSAGE_OPENER_API_TOKEN` without printing it. Use the canonical production
  identifiers in `runs/trusted-relay-v1.md`: project
  `29d738a2-efd5-4300-9df1-62fb91b27aa5`, environment
  `f2926fbf-e990-4175-8791-79e5b60b8373`, and service
  `2470b3b8-029d-4046-a7d0-bf7ba9687c9b`. Deploy the merged relay source and
  verify deployment success, `/health`, OAuth discovery, and no 5xx responses.
- Final live confidence boundary: reauthorize CoS, Networker, and Sunny for the
  new `messages:link` scope and verify each discovers
  `ghostie_create_messages_link`. Call it from one persona with a synthetic
  recipient/body, then open the returned HTTPS link on iPhone. Do not send the
  composed message.

## Rollback

For a functional regression, redeploy the previous successful Railway
deployment and remove the relay's opener variable. This stops new creation but
does not revoke links already minted. For suspected token exposure, rotate the
token at the opener service, update the login keychain and Railway through the
non-printing secret path, verify the old token receives 401, and purge affected
`message-openers/` records by exact id when known or the whole prefix when the
incident window cannot be bounded. Existing Ghostie read and draft behavior
remains untouched by the opener API itself.
