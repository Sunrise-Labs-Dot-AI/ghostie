# Trusted relay v1 acceptance, 2026-09-15

## Scope and release status

James approved the trusted-relay privacy model and instructed build and ship. He separately approved transfer of the existing Ghostie production Clerk secret to this dedicated Railway service. Clerk app rename to Ghostie is verified. No app release has been published in this rollout. Public launch still requires live identity/client acceptance and signed local-app QA; James runs the final notarized release from his Terminal.

## Production resources

- URL: https://connect.messagesfor.ai
- Railway project: ghostie-remote-relay, `29d738a2-efd5-4300-9df1-62fb91b27aa5`
- Production environment: `f2926fbf-e990-4175-8791-79e5b60b8373`
- Relay service: `2470b3b8-029d-4046-a7d0-bf7ba9687c9b`
- Metadata volume: `13daa279-1e0c-4a29-8f59-02757cc887d1`, `/data`
- First deployment: `1679cf1c-7fac-4d5c-ad78-7b8e30775da5`, successful, verified HTTPS health and OAuth discovery. Follow-up `73a94965-e67a-404b-82b3-df99ef01b3a2` deploys the sign-in form fix; successful, public health and corrected page verified
- One replica, US West California, Dockerfile builder, port 8080, `/health`, three failure retries. Serverless and CDN caching off.
- Clerk production Frontend API: https://clerk.messagesfor.ai, existing primary domain messagesfor.ai. Email verification codes enabled. See the email/passkey follow-up below for the requested login-method changes.
- Static Claude client: `ghostie-claude`, exact callback https://claude.ai/api/mcp/auth_callback, public client (no secret).
- DNS adds only `connect` CNAME and Railway verification TXT. Marketing and Clerk records unchanged.

Upload from `mcps/remote-relay`:

```sh
npx --yes @railway/cli@5.57.2 up . --path-as-root \
  --project 29d738a2-efd5-4300-9df1-62fb91b27aa5 \
  --environment f2926fbf-e990-4175-8791-79e5b60b8373 \
  --service 2470b3b8-029d-4046-a7d0-bf7ba9687c9b --detach --json
```

Never print raw Railway environment config or variables: production secrets are configured. Request only selected non-secret fields. Source upload contains only the relay directory; Docker context excludes tests and local state.

## Verification completed

- Relay: 19 tests, 64 assertions, typecheck pass.
- Mac remote facade: 56 tests, 168 assertions, typecheck pass.
- Swift: build complete; 796 tests, two skipped, zero failures.
- Remote release packaging contract: pass.
- Exact production image: local build and container smoke pass. Verified unauthenticated refusal, WSS upgrade forwarding, synthetic request/response, no-store, no raw credentials or bodies in SQLite/logs, disabled core dumps, offline 503, container failure when proxy dies.
- Independent deployment code review: no blockers for live acceptance, public release still gated. Claude Opus review attempt failed due expired OAuth; independent Codex gpt-5.5 substitute used. Review artifacts in `runs/reviews/trusted-relay-*`.
- Release preflight on feature branch correctly refused non-main. Repeat after merge, without bypassing branch check.

## Still required

Live Clerk and real hosted/desktop OAuth, live deployment log inspection, signed local app account/Keychain/offline/draft review, final CI/merge and James-run release. Keep the default public service unset until live acceptance supports enabling it.

## Live findings and pending user step

- Public TLS verification, `/health` and OAuth discovery pass. Railway application logs contain only volume/container startup messages after the browser pairing attempts. No authenticated payload forwarding has occurred yet, so live payload-canary proof remains pending.
- Production Google sign-in fails at Google with `Missing required parameter: client_id`. Do not silently disable login methods or use development credentials to bypass this.
- Production Clerk has no existing James account. Opened the email signup flow in Chrome. It requires a new password, so browser policy requires James to enter/submit it himself. Async handoff asks him to complete email signup or choose Google configuration first. No password was read or entered by the agent.
- Fixed a live sign-in issue: Clerk listener notifications remounted the login form and reset its state. A regression test and independent follow-up review pass. Follow-up review: `runs/reviews/trusted-relay-page-code.txt`.
- Added exact desktop callback `http://127.0.0.1:18764/callback`, client `ghostie-desktop`, to the configured client list. The second deployment includes that configuration. The synthetic desktop test uses PKCE, official SDK calls and token revocation; it still needs a real account login.
- A signed temporary app with empty `MESSAGES_FOR_AI_HOME` was assembled under `/tmp/ghostie-trusted-local-qa`. Its startup blocks in existing TextingVoice Keychain access before the window opens (confirmed by process sample). Stopped the temporary process. This is not a passed local UI/Keychain test, and the installed app was not replaced.
- CI initially failed because the unpinned Node type dependency resolved to an unavailable npm tarball. Pinned `@types/node` 26.5.1 in the five affected packages; portable CI passed. Changed the synthetic container test to a named Docker volume so Linux cleanup works after the container restricts metadata ownership; container CI passed.
- PR: https://github.com/Sunrise-Labs-Dot-AI/ghostie/pull/39 (draft). Keep release gated on real account and client acceptance. No default app relay URL is enabled yet.

## Email signup and optional passkeys follow-up

James requested email signup with optional passkeys, without social OAuth setup. Clerk production email verification and sign-in codes remain enabled. Passwords are optional at signup; passkeys and the passkey sign-in button are enabled. Passkeys do not bypass configured MFA. The unconfigured Google and Apple connections are disabled (reversible), verified in the dashboard. This supersedes the password-entry handoff above. MCP OAuth-PKCE authorization and per-Mac consent remain separate and unchanged.

Added `/account` and a connected-account link in Advanced settings. Account management opens Clerk's prebuilt profile on the relay origin, keeping passkey enrollment and login on the same site. The account page does not call pairing or consent APIs, even with OAuth query parameters. Users complete their own passkey enrollment.

Validation: relay typecheck and 21 tests/79 assertions pass; Swift build and full suite pass. Independent gpt-5.5 plan and adversarial diff reviews found no blockers (`runs/reviews/trusted-relay-account-{plan,code}.txt`). Prior Claude lane unavailable due expired OAuth, as recorded above. Live account creation, profile/passkey use, and both real client acceptance checks remain pending.

## Real-account acceptance, September 15 evening (Pacific)

James chose his real account rather than a separate test identity and supplied his email for Ghostie signup. Completed the production email OTP flow and verified the signed-in account page. Clerk's prebuilt profile opens on the relay origin and Security shows Add a passkey. No password or passkey was created by the agent; passkey device enrollment remains optional and user-operated.

- Current relay deployment `ffa4b215-b95c-4f32-b3b7-c2fd0db57ebf` is successful. `/account` renders with CSP and no-store. Current application logs contain only volume/container startup lines, including after the synthetic authenticated tool calls.
- Paired the fixed synthetic host with James's real Clerk account. It imports no messaging backend and exposes only `ghostie_connection_check`.
- Desktop acceptance PASS: live Clerk session, per-host consent, S256 exchange, official MCP SDK initialize/list/call, then revocation and 401 rejection. Chrome briefly displayed ERR_BLOCKED_BY_CLIENT on the local callback, but the fixture subsequently received the callback and completed every assertion. No browser block was bypassed by the agent.
- Hosted Claude acceptance PASS: static `ghostie-claude` client, live consent, authenticated tool discovery and one approved tool call returned exactly `Ghostie synthetic connection works. No messages are available.` Evidence chat: https://claude.ai/chat/b43d1367-8666-48d4-b8ab-fce1f0190cce . This verifies the hosted transport; a separate mobile device was not tested.
- Stopped the synthetic fixture. It confirmed host/capability revocation and cleanup. Disconnected the temporary Claude connector and verified the disconnected UI. James's real Clerk account remains signed in.
- Refreshed `/tmp/ghostie-trusted-local-qa/Ghostie.app` with the current UI, compiled shared backend, and all stable role launchers. Restored the canonical bundle identifier; each Mach-O has the canonical signing identifier and Developer ID signature, and strict bundle verification passes. The temporary bundle uses an isolated data folder via LSEnvironment, has updates disabled, and carries the live relay URL. It does not replace the installed app.
- Requested that James open the temporary app from his own Terminal to finish GUI/Keychain/pair/start/stop checks after the earlier automated-launch Keychain stall. No app release has been published. Keep the default release service address unset until this final local acceptance passes.

All 14 CI checks at implementation head `fc0b65b` passed, with two intentional site skips. Only acceptance documentation changed after that head.

### Returning-account redirect fix

The returning-user check found that Clerk's default sign-out destination was `/`, which the relay does not serve. The sign-out button now explicitly returns to `/account`. Sign-in and signup (including switching between them) explicitly preserve the current supported route and query, excluding Clerk hash-router fragments. Regression assertions exercise the options passed to Clerk. Relay typecheck and 21 tests/84 assertions pass; independent gpt-5.5 adversarial review found no blockers (`runs/reviews/trusted-relay-redirect-code.txt`). Passwordless returning sign-in correctly advances from email (empty password field) to the email-code challenge. Deployment `18629d79-4c24-4fc8-bcd6-e4fbfb6a9137` succeeded. Live returning email-code sign-in and sign-out to `/account` passed. All 14 CI checks passed at `c1a50f3`, with two intentional skips.

### Temporary QA bundle launch repair

James's September 15 crash report showed a pre-main DYLD abort loading Sparkle. Inspection confirmed the temporary bundle's main executable was Developer ID signed, but its embedded Sparkle framework still carried an ad-hoc signature without a Team ID. The earlier claim that every Mach-O was Developer ID signed was incorrect: the manual refresh had covered Contents/MacOS only. Strict signature verification alone did not detect the runtime library-validation incompatibility.

Reproduced the exact failure with a small Developer ID signed, hardened-runtime `dlopen` probe: mapping process and mapped file have different Team IDs. Re-signed Sparkle's two XPC services, Autoupdate, Updater.app, and framework inside out using the existing release-script procedure, retaining Sparkle identifiers and omitting app/JIT entitlements. Re-sealed the QA app. No library-validation exception was added. The same loading probe then passed, as did strict recursive bundle verification.

Launched the corrected QA bundle and verified its live accessible UI shows Welcome to Ghostie, with the terms checkbox off and Get Started disabled. The process remained alive. The earlier Keychain startup stall did not recur on this launch. User acceptance of the first-run terms is the next step; local pairing, host start/stop, offline behavior, and draft review remain unverified. Installed Ghostie remains running separately and was not modified. This repair changed temporary packaging only, not release code or the deployed relay.

### Cursor / Grok Bot static OAuth compatibility

James supplied Grok Bot's connection failure and its two callbacks. Cursor's official MCP docs confirm static public client auth and those exact URLs. Added `ghostie-cursor` (display name Grok Bot / Cursor), scopes `messages:read messages:draft`, no secret. Existing Claude/desktop registrations are preserved.

The first config rollout (`01815677-090e-450a-8fa8-44c2053e1664`) exposed a startup-validator mismatch: authorization accepted an exactly registered localhost callback, but the environment validator accepted only numeric HTTP loopback. This caused a brief relay outage. Removed only the localhost callback; web-only registration deployment `6d78d115-9ef1-4249-8715-88b7c562031b` succeeded and live health recovered. The initial in-memory authorization test was insufficient because it bypassed startup validation.

Fix: share the callback schema, allowing exact `localhost` alongside numeric loopback while retaining HTTPS elsewhere, no fragments/userinfo, and exact full callback matching during consent and token exchange. Tests cover both Cursor callbacks, PKCE, owner checks, lookalike domains, URI spelling/port/path mutations, and unsafe protocols. The production container fixture now includes both Cursor callback URLs, exercising actual startup validation.

Validation: typecheck, 23 tests/110 assertions, and full production-image smoke passed, including startup, synthetic forwarding, auth refusal, offline response, no content/token logging/storage, and proxy-failure shutdown. Independent gpt-5.5 plan/code review artifacts: `runs/reviews/trusted-relay-cursor-{plan,code}.txt`. Prior Claude lane unavailable due expired OAuth as recorded above. Code verdict MERGE-OK; constructor trust and fixed callback ports are existing intentional constraints, so no new change required. Rollout: deploy fixed code with web-only registration first, then add localhost after health succeeds. Revert only the localhost callback if final startup fails. End-to-end Grok Bot consent remains a client-side acceptance step.
