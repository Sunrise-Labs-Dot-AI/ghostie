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

PR [#41](https://github.com/Sunrise-Labs-Dot-AI/ghostie/pull/41) passed every
CI check and merged as `f9718a27eaea5098bc9f83d75adcb9adabafe07d`.
Deployment `57f2ddca-796b-4ae3-a8ec-2bb2e8305e87` uploaded exactly that merged
relay directory to the canonical Railway project, environment, and service
recorded in `runs/trusted-relay-v1.md`. Railway reports SUCCESS.

The opener token was read directly from login-keychain service
`ghostie-message-opener-api-token` into the Railway variable
`MESSAGE_OPENER_API_TOKEN` via stdin without displaying it or putting it in a
process argument.

Post-deploy checks:

- `https://connect.messagesfor.ai/health` returns `{"status":"ok"}`.
- OAuth metadata advertises `messages:read`, `messages:draft`, and
  `messages:link`.
- The live account/consent page contains the encrypted seven-day storage and
  public compose-link disclosures.
- Application logs contain only volume/container startup lines.
- Railway HTTP logs report zero 5xx requests in the deployment window.

## Remaining user-controlled acceptance

After deployment, reauthorize CoS, Networker, and Sunny, verify that each sees
`ghostie_create_messages_link`, and create one synthetic link through a persona.
The final physical acceptance is opening that HTTPS URL on iPhone without
sending the composed message.
