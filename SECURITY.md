# Security Considerations

This document is the honest threat model for **Ghostie** (formerly
"Messages for AI") — the .app that ships the menubar UI plus the
iMessage and WhatsApp MCP
transports. Read it before installing — the trust profile is non-trivial,
and the WhatsApp transport in v0.3.0 adds a third-party-messaging risk
surface that didn't exist in v0.2.x.

## Summary

You are giving a single .app the following macOS-level privileges:

1. **Full Disk Access (FDA)** — required to read `chat.db`. macOS does
   not expose a "chat.db-only" scope; the FDA grant lets every binary
   inside the .app read **any file** in your home directory. (The
   .app's CFBundleIdentifier is the TCC grant key — one grant covers
   the menubar, the iMessage MCP, the WhatsApp stdio MCP, and the
   WhatsApp background daemon. See "Bundle identity" below.)
2. **Automation control of Messages.app** — granted on first iMessage
   send. Lets the binary spawn `osascript` to send iMessages/SMS to
   any recipient you have, without further prompting.
3. **Open-at-login** (menu bar app) — defaults on; the menu bar app
   auto-launches when you sign in. Toggleable in Settings.
4. **WhatsApp account linkage** (opt-in, off by default). Pairing
   adds your WhatsApp account to the Baileys session on this Mac;
   the daemon can read and send WhatsApp messages on your behalf
   until you unlink. WhatsApp's ToS does not officially sanction
   third-party clients — see the WhatsApp section below.

If a future commit, dependency, or local binary replacement is
malicious, those privileges become its privileges. The trust boundary
is "I trust this .app the way I trust software I write myself" — not
"I trust this .app because of some sandbox."

## Threat model

### In scope

- **Prompt injection** via incoming iMessages, where attacker text in
  a peer's message hijacks an agent reading the thread.
- **Confused-deputy** attacks where the agent uses the read tools to
  see attacker text and then a *different* tool (web fetch, shell,
  email) to exfiltrate or act on it.
- **Runaway send loops** where an agent gets into a bad state and
  re-sends or blast-sends repeatedly.
- **Binary substitution** where an attacker with write access to
  `/Applications/Ghostie.app/Contents/MacOS/` swaps an inner
  binary for a malicious one and inherits the FDA + Automation
  grants. (The .app's signature would be invalidated on next launch
  by Gatekeeper, but only on FIRST run; subsequent launches don't
  re-verify.)
- **Local peer impersonation of the menubar.** The WhatsApp daemon
  listens on a Unix socket at `~/.whatsapp-mcp/daemon.sock` which is
  reachable by ANY local process running as the user. Without
  peer-auth, an npm postinstall script or browser extension could
  `socat` into the socket and bypass the daemon's hold-to-fire
  guardrails. See "WhatsApp peer-auth" below.
- **Supply chain** — a malicious update to the source repo, or a
  compromised dependency.

### Out of scope

- Apple Notarization is out of scope (no Developer Program enrollment).
  Gatekeeper will not mark the binary as notarized; users may need to
  approve it via System Settings on first launch.
- Sandbox containment via `sandbox-exec` is out of scope. macOS's
  sandbox profile API is undocumented and unstable across releases.
- Defending against root-level attackers. If something is running as
  root on your Mac, you have larger problems.
- Defending against macOS itself / Apple. If the OS leaks chat.db
  to third parties or breaks TCC, this server can't help.

## What we do about it

| Defense | What it stops | Caveats |
|---|---|---|
| **`<untrusted_content>` body wrapping** | Naive prompt injection: "ignore prior instructions and …" | Doesn't stop a determined attacker who knows the model; doesn't stop confused-deputy via other tools |
| **Required `since` (≤2y) or `contact_filter` on read/search** | Unbounded history dumps into agent context | Doesn't stop reads inside the bounded window |
| **8 KB body truncation** | Mega-payload prompt injections | A 4 KB injection works the same as an 8 KB one |
| **Send-only-from-draft** | Ad-hoc send tool calls | Agent can stage + send in one turn (see next) |
| **`require_approval` setting** (default ON) | All MCP send paths — agents can only stage; the menu bar app is the sole send surface | User-controllable toggle in the menu bar footer. Off if the user explicitly disables. |
| **Minimum staged-age (default 5s)** | Single-turn stage-and-send bypassing human review when `require_approval` is off | Configurable, can be disabled |
| **Daily send cap (default 50/UTC day)** | Runaway loops, blast attacks | Cap is per-day, not per-recipient; configurable |
| **Send audit log** at `~/.messages-mcp/send-audit.log` | Forensic gap (post-hoc only) | Doesn't prevent; helps investigate. Body content is SHA-256-hashed, not stored. |
| **`destructiveHint: true` + `idempotentHint: false` annotations on send** | MCP clients can surface confirmation prompts | Depends on the client implementing the hint |
| **Sent-state lock** (`sent_at` set on draft → refused) | Double-send via retry loops | Doesn't stop staging a fresh draft |
| **SQL parameterized everywhere** | SQL injection | — |
| **`osascript` argv passing** (not string interpolation) | AppleScript injection via `to_handle` / `body` | — |
| **UUID validation on `draft_id`** | Path traversal via draft id | — |
| **Drafts dir mode 0600** | Other users on the same Mac reading drafts | Other processes running as you can still read |
| **Stable codesign identifier** | Adhoc rebuilds invalidating FDA on every install | Doesn't stop binary replacement |
| **No iMessage-side network listener, no iMessage outbound calls** | Network-based attack surface on the iMessage transport | The WhatsApp daemon DOES open an outbound WebSocket to WhatsApp Web; see the WhatsApp section. |
| **`PRAGMA query_only = ON` + `readonly: true` on `chat.db`** | Accidental writes corrupting Messages state | — |
| **WhatsApp peer-auth: runtime self-identity match** | Local processes other than the .app's own binaries from connecting to the WhatsApp daemon's Unix socket | Bypassed when daemon runs with `WHATSAPP_MCP_DEV=1`; the daemon refuses dev mode if its own binary is signed for production. |
| **WhatsApp session.db AES-GCM at rest** | Plaintext exfiltration of the Baileys session credential (the keys that authorize WhatsApp message read/send on your behalf) | Encryption key lives in the macOS Keychain; the daemon process and any other binary running as you can both reach it. |
| **Product analytics allowlist** | Accidental telemetry of message bodies, prompts, contacts, raw chat/message IDs, paths, or API keys | Product analytics are presented during onboarding with a visible opt-out and use PostHog manual capture only. Autocapture and session replay are disabled. |

## Bundle identity

All inner binaries (`MessagesForAIMenu`, `imessage-drafts-mcp`,
`whatsapp-drafts-mcp`, `whatsapp-drafts-daemon`) ship in
`/Applications/Ghostie.app/Contents/MacOS/` and are
codesigned with `--identifier com.sunriselabs.messages-for-ai` — the
same string as the .app's `CFBundleIdentifier`. TCC keys grants by the
running process's codesign `Identifier=`, so one FDA grant on the .app
covers every inner Mach-O. This is also the foundation of the WhatsApp
peer-auth check: the daemon authorizes only peers whose Identifier and
TeamIdentifier match its own.

## WhatsApp transport (opt-in)

The WhatsApp transport uses [@whiskeysockets/baileys][baileys], an
unofficial WhatsApp Web protocol client. WhatsApp's Terms of Service do
not officially sanction third-party clients. Practical implications:

- Your account COULD be flagged or banned. This is unlikely in practice
  for normal-volume personal use, but it's not zero risk — read the
  Baileys repo's own warnings before pairing.
- The transport is OFF by default. The onboarding wizard makes you opt
  in explicitly. You can unlink any time from Settings.
- The daemon stores your Baileys session credentials at
  `~/.whatsapp-mcp/session.db`, AES-GCM wrapped with a key derived from
  a per-Mac Keychain item. Anything running as you can still reach the
  Keychain item — defense-in-depth, not full isolation.
- Daemon stdout/stderr are piped to
  `~/.messages-mcp/logs/whatsapp-daemon.log` (10 MB rotation). Logs are
  message-content-free, but they DO record JIDs and connection events
  — review before sharing.

[baileys]: https://github.com/WhiskeySockets/Baileys

## Media previews (opt-in)

The transcript previews attachments and video links. The local and remote
cases have deliberately different network postures:

- **Photos and local videos are fully offline.** Image thumbnails (ImageIO)
  and video poster frames + inline playback (AVFoundation) read the on-disk
  attachment files Messages.app already wrote. No network, no opt-in.
- **Web-video links (YouTube/Vimeo) are gated behind one off-by-default
  setting** (`embeddedMediaPreviews`, Settings → "Rich previews for video
  links"). With it OFF — the default — Ghostie makes **no outbound request**
  for a link card: the card is a local placeholder and tapping it opens your
  system browser. Only when you turn it ON does Ghostie (a) fetch the video's
  static thumbnail over an ephemeral, cookie-free `URLSession`, and (b) play
  the video inline in a non-persistent `WKWebView` pointed at
  `youtube-nocookie.com` / Vimeo's player host. The single switch governs
  both, so "off" means zero third-party requests on your behalf.

## Configuration knobs

User-controllable in the menu bar UI:

- **iMessage / WhatsApp enabled toggles** (Settings sheet). Toggling
  WhatsApp off SIGTERMs the bundled daemon; toggling on respawns it.
- **Require approval to send** (per-transport, default ON). When on,
  MCP `send_draft` is disabled entirely — every send must come from a
  human pressing Hold-to-Fire in the menu bar app. Persists to
  `~/.messages-mcp/settings.json` (schema v2) under
  `transports.imessage.require_approval` and (for WhatsApp's own MCP)
  `~/.whatsapp-mcp/settings.json`; both MCP servers read on every send
  call so toggling takes effect immediately.
- **Product analytics**. First-run onboarding shows a visible product
  analytics toggle on by default; users can turn it off before
  continuing and can change it any time in Settings. Existing installs
  keep their stored analytics setting and do not see first-run
  onboarding again unless setup is reset. When enabled, the app captures
  only allowlisted product events through PostHog: app/version seen,
  settings opened, feature viewed, draft staged/sent, scheduled-message
  created, Lab scan start/complete/fail, and diagnostics export created.
  Properties are coarse enums or buckets only. Message bodies, draft
  text, prompts, model responses, contacts, phone numbers, emails,
  Apple IDs, WhatsApp IDs, raw chat IDs, recipient identifiers, raw
  message IDs, API keys, access tokens, and file paths are rejected by
  the analytics boundary. Session replay, screen capture, element
  autocapture, and automatic lifecycle/screen events are not used.
- **Diagnostics export categories**. Export Diagnostics creates a local
  zip only after a user click. Settings control whether the bundle
  includes local app events, daemon logs, and relevant macOS crash
  reports. Daemon logs are off by default because local bridge logs can
  include transport identifiers; the app does not upload the bundle
  automatically.

Env vars (configure for trusted automation contexts):

- `IMESSAGE_MIN_DRAFT_AGE_MS` — minimum age (ms) a draft must be before
  it can be sent via MCP. Default `5000`. Set to `0` to disable. Only
  applies when `require_approval` is off.
- `IMESSAGE_DAILY_SEND_CAP` — maximum sends per UTC day. Default `50`.
  Set to `0` to disable.
- `MESSAGES_MCP_IDENTIFIER` — codesign identifier embedded in every
  inner MCP binary by `scripts/dev-install.sh`. Default
  `com.sunriselabs.messages-for-ai` (same as the parent .app bundle's
  `CFBundleIdentifier`). For the `.app`-wrap architecture, every inner
  binary's identifier MUST match the bundle's so that TCC's grant on
  the .app covers all running processes. Changing this to a value
  that differs from the bundle's identifier will break FDA — TCC
  compares the running process's `Identifier=` against the granted
  identifier as strings; mismatch = no grant match.
- `WHATSAPP_MCP_DEV=1` — bypasses the WhatsApp daemon's peer-auth.
  Use only when running the daemon from source; the daemon refuses to
  start under this flag if its own binary is signed for production.
- `POSTHOG_PROJECT_TOKEN` / `POSTHOG_HOST` — optional build-time or
  environment configuration for product analytics. Without a project
  token, analytics capture is inert even if the UI toggle is on.
- `MESSAGES_FOR_AI_ANALYTICS_DISABLED=1` — runtime kill switch for
  product analytics. Creating `~/.messages-mcp/analytics.disabled` has
  the same effect.

## What you should do as a user

1. **Read the source before installing.** The codebase is ~5000 lines
   of TypeScript (across two MCP transports) + ~1500 lines of Swift.
   A careful review is feasible.
2. **Build from source.** Don't run prebuilt binaries someone else
   shipped you.
3. **Pin to a tag.** Don't track `main` in production-feeling setups.
4. **Don't pair this server with an agent that also has destructive
   non-iMessage tools** unless you have a reason to. The interesting
   attack is a confused-deputy: read tool sees attacker text → agent
   uses some *other* tool to exfiltrate or act.
5. **Use the menu bar app for the human-review pattern.** Configure
   your MCP client to NOT auto-approve `send_draft`. Have
   agents stage-only; you click Send in the menu bar.
6. **Audit your daily send-audit log occasionally.** If something
   weird happened, it's in `~/.messages-mcp/send-audit.log`.
7. **Treat `/Applications/Ghostie.app` like an SSH key.**
   Permissions matter. If a compromised app on your Mac could write
   to `/Applications/`, it could replace an inner binary and inherit
   the FDA + Automation grants. The .app's signature would invalidate
   on next Gatekeeper check, but Gatekeeper only re-verifies on first
   launch — subsequent launches don't.
8. **Audit `~/.messages-mcp/logs/whatsapp-daemon.log` if you've paired
   WhatsApp.** Connection events + JIDs only (no message content), but
   useful when something looks off.

## Reporting a vulnerability

For security issues that should not be discussed in public:

- Open a GitHub Security Advisory on this repo (preferred — gives
  the maintainer a private channel and a way to coordinate disclosure).
- Or email the maintainer; see the GitHub profile on the repo.

For things you're comfortable discussing publicly (style nits,
mitigations you think we should add, etc.), open a regular issue.

I (the maintainer) am one person doing this in spare time. Expect a
response within a few days for routine issues; acute security
disclosures will get a same-day acknowledgment when possible.
