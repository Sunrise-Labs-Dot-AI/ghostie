# Railway encrypted MCP compatibility probe

## Scope and gate
Use the full engineering loop because this experiment changes network and encryption boundaries. James approved trying Railway first and requires cloud/mobile plus desktop clients, and no app release during this experiment. First prove transport compatibility with a synthetic-only fixture. Do not expose real messages, Clerk secrets, local daemons, or the existing plaintext relay during this probe. Do not present the experiment as the finished encrypted product.

## Stage 0: hosted-client port gate (execute first)
Before any custom tunnel implementation, test the exact HTTPS URL shape in the existing signed-in clients. Claude accepts a nonstandard port syntactically but its connection check needs a real server. ChatGPT developer mode must be inspected before adding a synthetic connector. A format check or SDK-only test is not compatibility evidence.

Build only a minimal synthetic MCP fixture for this stage. Deploy this fixture directly on Railway behind its assigned raw TCP proxy, with a dedicated public certificate. This disposable fixture certificate may be installed on Railway because it protects only synthetic status text and is never used for messaging. This stage makes NO claim of encryption against Railway. Limit the server to one harmless status tool and bounded JSON input; no arbitrary echo, fetch, commands, files or messages. Both hosted clients must list and call the fixture. Stop and record evidence if either rejects the port. Only after both pass should the custom tunnel below be implemented. Cleanup the temporary service, DNS records and disposable certificate/key after the probe.

## Stage 1: encrypted experiment (gated on Stage 0)
Build an isolated Node-compatible TCP reverse tunnel under tests/remote-tunnel, using the existing Bun runtime and dependencies. The synthetic MCP endpoint and its TLS private key run on the Mac. Railway runs a bounded byte-forwarder with a public TCP proxy and a separate host control channel. The Mac establishes the host connection outward. Use WebSocket framing on the host channel, authenticated by a temporary random token, with bounded streams, frame sizes, timeouts, and buffers. The relay only forwards inner TLS bytes. It cannot initiate arbitrary host connections: the Mac forwards exclusively to a configured loopback synthetic TLS server.

Use a single host and one active public stream for this probe, explicitly rejecting excess connections. A persistent control channel introduces a stream identifier; only one matching data stream may claim that identifier. The relay never reads the inner HTTP protocol or holds an origin certificate/private key. Remove all sessions on disconnect; no request queue or automatic replay. Bind local test listeners to loopback. Cloud probe exposes only synthetic tools with no write side effects.

Use a locally generated test CA only in automated tests with explicit per-client trust, never global certificate-validation bypasses or browser warning bypasses. For real cloud-client testing, a dedicated probe subdomain must have a publicly trusted certificate whose private key is generated and remains on the Mac. DNS and ACME provisioning must be isolated from production hostnames. Railway's generated TCP port is preserved in the MCP URL. Its regular HTTPS edge may carry the outer host channel, never decrypted MCP content.

## Acceptance evidence
1. Standard MCP SDK connects through the reverse tunnel on a nonstandard port using verified TLS, initializes, lists a harmless synthetic tool, and calls it.
2. A unique synthetic response canary appears at the client and is absent from captured relay frames. The relay has no private key or plaintext origin HTTP handling. This is evidence about the tested transport, not proof against compromised DNS, CAs, clients, or endpoints.
3. Wrong certificate, wrong host token, duplicate host/stream, oversized traffic, expired pending streams, host loss, slow buffers, and orderly shutdown fail closed. No pending request replays after reconnection.
4. Railway deployment runs only this synthetic fixture, not any production messaging package. Temporary credentials and deployment configuration stay outside the public repo. Shut the probe down after measurement.
5. Real ChatGPT and Claude hosted connectors must successfully list/call the synthetic tool through the Railway-assigned port. Desktop SDK success alone does not pass this gate. If no public certificate/endpoint or signed-in client is available, mark these checks unverified and report the precise missing requirement.

## Product integration boundary
A passing probe permits the next production implementation step. The existing Clerk/OAuth relay cannot simply be wrapped: grants and authorization enforcement must move to the Mac (or another explicitly trusted component), so a relay cannot mint itself message access. Keys, certificate issuance/renewal, per-Mac hostname ownership, account binding, revocation and migration require separate reviewed implementation. Current remote-host mode remains unconfigured and unreleased. Keep the existing honest UI/privacy wording until that implementation is verified.

## Operational limits
No production deployment, app replacement, release, new plan/subscription, or access to messages is part of this probe. Use an isolated Railway service for the temporary synthetic test only, bounded resources, no persistent volume. Record exact deployment, hostname, cleanup and client evidence in runs. If a paid commitment or security-sensitive external change needs approval, prepare the exact configuration and surface only that action after local proof.

## Review dispositions
Independent Claude Opus review attempt 1 had a CLI argument error, corrected in attempt 2; attempt 2 failed with "OAuth session expired and could not be refreshed". Independent Codex gpt-5.5 substituted.
- ACCEPT release ambiguity: probe explicitly excludes release; only the next reviewed product plan follows success.
- ACCEPT sequencing: Stage 0 tests the actual hosted clients before implementing a custom tunnel.
- ACCEPT opacity evidence: Stage 1 requires inspection confirming no origin private key, HTTP parser, payload logging or core dumps at relay, plus opaque inner TLS record capture. Canary absence alone is insufficient.
- ACCEPT token handling: Stage 1 tokens are generated locally outside git, supplied through protected config/header, never argv/query/logs, rotated every run, 30 minute expiry, one active host. Replays of spent stream IDs fail.
- ACCEPT lifecycle: absent host closes public TCP immediately; pending stream buffers at most 64 KiB for 5 seconds; claimed stream is exclusive; loss closes both ends; expiry destroys pending buffer and invalidates the ID; reconnect never restores prior streams. Raw-TCP failures terminate the TLS connection, not fabricated HTTP responses.
- ACCEPT scope reduction: do not build tunnel/ACME lifecycle for the product until Stage 0 clears. Stage 0 uses a disposable certificate only.
