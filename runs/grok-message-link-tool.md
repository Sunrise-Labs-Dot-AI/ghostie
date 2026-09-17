# Grok Bot Messages link tool rollout

Date: 2026-09-16 Pacific

## Outcome

The hosted Ghostie relay now owns `ghostie_create_messages_link`. An authorized
MCP client supplies `phone` and `body`; the relay calls the existing
`https://ghostie.app/v1/links` service with its server-only token and returns
only the short public URL and expiry. The call does not depend on the Mac after
the client has discovered the tool. It composes a message and never sends it.

## Authorization and data boundary

- OAuth fixed scope is now `messages:read messages:draft messages:link`.
- Token policy is version 2. Earlier tokens are rejected, so existing bots must
  reconnect and approve the new scope.
- Browser consent and Advanced settings disclose that a link stores recipient
  and body as encrypted ciphertext for seven days and that the returned URL is
  a public bearer capability.
- Fresh MCP initialization and tool discovery still require the Mac. This
  avoids returning a partial offline catalog that hides Mac-backed tools.
- The opener credential remains a Railway-only service secret and never enters
  a bot prompt, mobile client, tool result, relay log, or metadata database.

## Verification before PR

- Relay: typecheck plus 46 tests and 226 assertions pass.
- Site: downloads, tip jar, referral, AI proxy, and 16 opener tests pass.
- Dependency audit: zero findings.
- Swift: build complete; 796 tests pass, 2 skipped, 0 failures.
- Docker: exact production image and authenticated offline link-creation smoke
  pass.
- Independent adversarial review: MERGE-OK. Details in
  `runs/reviews/2026-09-16-grok-message-link-tool.md`.

## Production rollout

Pending the PR/CI gate. Deployment uses the canonical Railway project,
environment, and service recorded in `runs/trusted-relay-v1.md`. The opener
token is read directly from login-keychain service
`ghostie-message-opener-api-token` into the Railway variable
`MESSAGE_OPENER_API_TOKEN` without printing it.

After deployment, reauthorize CoS, Networker, and Sunny, verify that each sees
`ghostie_create_messages_link`, and create one synthetic link through a persona.
The final physical acceptance is opening that HTTPS URL on iPhone without
sending the composed message.
