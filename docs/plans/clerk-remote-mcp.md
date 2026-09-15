# Clerk remote MCP

## Acceptance criteria
An opt-in Advanced settings path creates/signs into a Clerk account, pairs this Mac, starts/stops hosting, copies a remote MCP URL, and disconnects. The local app owns the host process. App exit, host failure, sleep and network failure make the MCP unavailable. No cloud message queue or body storage. Remote access reads and stages text drafts only; sending remains local human approval.

## Account and authorization
A standalone Bun service provides HTTPS MCP, OAuth discovery and a ClerkJS account/pairing page. Clerk supplies browser account identity only; the relay verifies session tokens and the allowed browser origin. The Clerk secret stays server-side.

Ghostie provides authorization code with required PKCE S256 and explicit per-Mac consent. Clients are statically configured with exact redirects. No dynamic registration, wildcards, implicit flow or refresh tokens. Opaque tokens are stored hashed, expire after one hour, and bind verified user, configured client, immutable `/mcp/hosts/{id}` resource and fixed read/draft policy version. Each request rechecks the client allowlist and owner/resource/connection binding. `/oauth/revoke` revokes one token; disconnecting a Mac revokes its credential and all tokens. Client callback provisioning and live Clerk acceptance are deployment gates.

Pairing lasts five minutes. The Mac generates a 256-bit secret and sends only its digest when starting. The browser receives a pairing identifier, never the secret. The user signs into Clerk and types the independent code shown on the Mac. Approval is one-time; polling can repeat with the same secret to recover the same existing host reference after a lost response. No new credential or permission is minted on repeated polling. The Mac stores credentials in Keychain and requires a separate Start hosting action. Cancellation attempts remote deletion and explicitly reports when only local cancellation could be confirmed. An unconfirmed browser pairing expires within five minutes.

## Local authority and availability
The app passes credentials to the bundled `ghostie-remote-host` backend role through a private stdin pipe. The host connects outward over WSS. TLS bearer credentials are high-entropy secrets stored hashed at the relay; duplicate connections are rejected, and disconnection disables routing. The app closes the pipe and terminates the host on shutdown. The host also exits on parent PID change, stdin EOF or SIGTERM. Reconnect uses backoff and never replays a pending request.

The host enforces a hard tool allowlist and strict schemas: list/read/search threads, text-only stage, draft list/read. No send, schedule, approve, discard, priority mutation, attachment path, arbitrary RPC, resources or prompts. Existing local approval remains unchanged. Draft source is `ghostie-remote`, visibly labelled in local review.

Limits: one in-flight call per host, six stages/minute on the Mac, 60 MCP requests/minute per host at the relay, 64 KiB requests, 1 MiB responses, 20-second timeout, at most 100 read results. Duplicate host request IDs are ignored. Lost draft responses are ambiguous; the client is instructed to inspect the local queue before retrying.

## Encryption and content protection
HTTPS and WSS encrypt both network legs. TLS terminates at the relay, which can see message bodies in memory. This is not relay-blind end-to-end encryption. No application payload logs, queue or message database. Deployment must disable body/header logging, tracing and core dumps at the provider/edge too. SQLite contains only host ownership and hashed credential/token metadata. Existing local message/draft storage retains its existing protection; no new at-rest message encryption is claimed.

The Mac filters suspected authentication material across previews, bodies, replies, draft context and nested MCP text JSON before network serialization. It removes media/local paths and body hashes. Errors are generic. The filter is heuristic and can miss unfamiliar languages, split messages and encoded secrets; consent and settings state the limitation. The connected AI client receives permitted message content.

## Verification and rollout
Synthetic-data tests cover account/resource/client isolation, PKCE downgrade and replay, expiry/revocation, pairing proof and cancellation, duplicate/offline connections, timeout/no retry, strict tool fields and advertisement, filtering, local rate limits and standard SDK HTTP framing. Swift tests cover configuration, start/stop, process failure, quit preference, revocation and cancellation. Run full Swift build/tests, Bun typechecks/tests, experience contracts and compiled shared-backend verification.

Independent review artifacts are under runs/reviews/. Claude Opus was unavailable because its OAuth session expired. The installed Codex CLI could not use gpt-6-astra; independent gpt-5.5 review was the available substitute. Resolve valid findings before merge. Public Clerk provisioning, TLS relay deployment, real-client/browser QA and James's signed app release remain separate gates; this change stays opt-in and unconfigured by default.
