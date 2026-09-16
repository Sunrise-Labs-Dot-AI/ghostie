# Mobile Messages opener

## Objective

Ship a public HTTPS link on `ghostie.app` that opens the iOS Messages composer with a validated recipient and prefilled body. The service composes only. It never sends a message.

## Acceptance criteria

1. `POST /v1/links` accepts JSON `phone` and `body`, validates both, and returns a short public `https://ghostie.app/t/<id>` URL.
2. Link creation requires a bearer token. Opening `/t/<id>` never requires login, cookies, Vercel Deployment Protection, or SSO.
3. The landing page immediately attempts, in order, the three requested `sms:` URL forms. It includes a large visible fallback button and a no-JavaScript meta refresh.
4. The page sends no analytics, external assets, or referrer. It sets `Cache-Control: private, no-store` and restrictive browser security headers.
5. Draft payloads are never stored as plaintext. The function encrypts them with AES-256-GCM before writing to the existing Vercel Blob store. The URL id carries at least 96 bits of randomness.
6. Links expire after seven days. The first read of an expired stored link returns HTTP 410 and deletes it; later reads return 404. A daily authenticated cron removes expired objects that are never opened.
7. Phone input is E.164-like (`+` plus 7 to 15 digits), body input is non-empty well-formed Unicode scalar text capped at 2,000 characters, and all HTML/script embedding is escaped.
8. Automated tests cover validation, authorization, encryption round trips and tamper rejection, landing-page escaping, URL order, expiry, routing, and cleanup.
9. The user-provided acceptance payload produces a live short URL, responds publicly without an auth challenge, and renders all three encoded `sms:` targets.

## Implementation

### Runtime

- Add `site/api/message-opener.js` as one small Node.js Vercel Function with dependency-injected Blob operations for deterministic tests.
- Route `POST /v1/links`, `GET /t/:id`, and the daily cleanup request to that function through `site/vercel.json`.
- Keep the production custom domain as the public surface. Preview deployment protection is irrelevant to the final link because `ghostie.app` is already publicly reachable.
- Authenticate before parsing JSON, reject requests above a small whole-body byte limit with HTTP 413, and strictly validate the short id alphabet and length before any Blob operation. Tests must prove rejected authorization and malformed ids never call storage.

### Storage and secrets

- Reuse the project's existing public Blob store only as an object backend. Every opener object lives under the dedicated `message-openers/` prefix. Persist authenticated ciphertext, never recipient or body plaintext.
- Encrypt a versioned JSON payload with AES-256-GCM using `MESSAGE_OPENER_ENCRYPTION_KEY` from the Vercel environment. Store the IV, authentication tag, ciphertext, and expiry.
- Protect link creation with `MESSAGE_OPENER_API_TOKEN`. Compare bearer tokens with a timing-safe comparison.
- Protect cleanup with Vercel's `CRON_SECRET` bearer contract.
- Generate all three secrets locally with cryptographic randomness and add them only to Vercel Production. Never write secret values to files, logs, commits, command output, or chat.
- Cleanup must paginate through the complete `message-openers/` prefix and must never list or delete outside it. Validate the versioned opener record before deletion.
- Privacy boundary: James's request in this coding-session prompt explicitly authorizes this feature to process newly supplied outbound draft text through Vercel and retain only encrypted ciphertext for seven days. This is a narrow exception for user-supplied compose drafts, not permission to upload existing message history or analytics bodies. Anyone holding a short URL can open its draft until expiry. Request bodies, decrypted values, rendered HTML, phone numbers, and message bodies must never be written to application logs, analytics, or error reports.

### Mobile landing behavior

- Build the target forms from the decrypted data with `encodeURIComponent(body)`:
  1. `sms://<phone>/?body=<body>`
  2. `sms:<phone>&body=<body>`
  3. `sms://<phone>;?&body=<body>`
- Call `location.replace()` for the first form immediately. If the page remains visible, attempt the second and third forms on short timers. Cancel timers on `pagehide` or when the document becomes hidden so a successful handoff cannot trigger another attempt when Safari resumes.
- Include a meta refresh and a prominent anchor to the first form. Show the recipient and an expiry note, but do not echo the message body into visible page copy.
- Reject unpaired UTF-16 surrogates before persistence so `encodeURIComponent` cannot throw while rendering a validly parsed JSON string.

### Verification and landing

- Add a Node test script to `site/package.json` and include it in the existing site CI job.
- Run `npm ci`, all site tests, and the broader repository site metadata checks locally.
- Run the repo's adversarial code review, fix accepted findings, and record the review under `runs/reviews/`.
- Commit, push, open a PR, wait for required CI, and merge only when green.
- Deploy the merged `main` site to the already-linked `messages-for-ai-marketing-site` Vercel project.
- Create the acceptance link through the authenticated production API, then check status, public headers, HTML targets, and absence of an auth wall with `curl`.
- Treat mobile handoff as a release gate, not a curl-only check. Open the exact acceptance link in the installed iOS Simulator Safari, verify that Messages receives the exact recipient and complete body, and exercise the visible fallback when automatic navigation is blocked. Record the iOS version and the working URL form. A physical-device Grok Bot tap remains the only named confidence boundary if Grok Bot is not available in the simulator; do not describe that surface as verified until James performs the tap.

## Failure handling and rollback

- Missing Blob or encryption configuration returns HTTP 503 without leaking configuration details.
- Invalid or tampered ids return 404. A stored expired id returns 410 once, then 404 after deletion. Unsupported methods return 405 with `Allow`.
- A failed production smoke test triggers `vercel rollback` to the prior deployment. Blob ciphertext objects are inert without the deployment secret.
- Removing the three rewrites and cron entry fully disables the surface without affecting the rest of `ghostie.app`.
