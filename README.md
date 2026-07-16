# Ghostie

**AI proposes, you approve.** A safer messaging MCP for users who don't
want Claude sending messages on their behalf without a human in the loop.

Ghostie (formerly "Messages for AI") is a single drag-to-/Applications
install at `/Applications/Ghostie.app`. The
.app bundles the menu bar UI, Ghostie (the generalized `ghostie-mcp`
facade), the transport-specific iMessage and WhatsApp MCPs, and their
background daemons. All inner binaries are signed under one bundle
identity and launched through the menu bar app where needed, so Claude
does not need Full Disk Access. On first launch, an onboarding wizard
asks which transports you want enabled.

**v0.3.0 ships two transports: iMessage and WhatsApp.** Signal and
Slack remain on the roadmap.

## How this differs from the official Anthropic iMessage plugin

[Anthropic ships an official iMessage plugin](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/imessage)
that lets Claude send iMessages directly. It's great if you want
frictionless automation. This project exists for the *other* lane — users
who want AI assistance with a safety gate. Pick the one that matches your
risk tolerance:

Claims below describe Anthropic's plugin as published at the linked commit on 2026-05-18; verify against [their repo](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/imessage) if checking later.

| | Anthropic `imessage` plugin | Ghostie (this project) |
|---|---|---|
| **Send model** | Direct: Claude sends immediately on tool call | Staged (default): `send_draft` is gated by a `require_approval` toggle that ships ON; sends route through the menu bar's hold-to-fire Send button. Users can disable the toggle for direct text-only MCP sends. Media always requires review and hold-to-fire in Ghostie. |
| **Approval surface** | macOS Automation TCC prompt on first send only | Menu bar review: hold-to-fire Send / Discard per draft (no in-place edit yet — discard and re-stage instead) |
| **Audit log** | Not present at the linked revision | Every **successful** MCP send appended to `~/.messages-mcp/send-audit.log` with timestamp, recipient handle, and SHA-256 of body. Discards and blocked sends are not currently logged. |
| **UI** | CLI-only | Menu bar surface with thread-context bubbles |
| **Contact resolution** | Raw handles only | Resolves to Contacts names via local sidecar |
| **Transports** | iMessage only | iMessage + WhatsApp (v0.3.0); Signal / Slack on the roadmap (per-transport MCPs sharing one menu bar) |
| **Daily send cap** | Not present at the linked revision | Circuit-breaker default 50/UTC-day, env-configurable via `IMESSAGE_DAILY_SEND_CAP` |
| **Best for** | "Just send the message" automation | "Let me see what Claude wants to say before it goes out" — when the default approval gate is on |

If you want fire-and-forget, use Anthropic's plugin. If you want every
outgoing message to pass through your eye first, use this one.

## What this gives you

- **Generalized Messages MCP**: one stable tool surface for common
  message workflows across iMessage and WhatsApp: list/search/read
  threads, stage/list/get/discard drafts, and manage thread priorities.
  It intentionally does not expose a generalized send tool.
- **iMessage transport**: read threads, messages, search; stage drafts
  under `~/.messages-mcp/drafts/`; approval-gated send via AppleScript
  automation of Messages.app.
- **WhatsApp transport** (opt-in): read recent threads from a local
  cache; stage drafts under `~/.whatsapp-mcp/drafts/`; approval-gated
  send via a background Baileys daemon paired to your phone over QR
  scan. The daemon is bundled inside the .app — there's no separate
  install. See [SECURITY.md](SECURITY.md) for the WhatsApp ToS caveat
  and per-transport threat model before enabling.
- **Menu bar surface** that shows pending drafts from every enabled
  transport in one popover, with hold-to-fire Send / Discard buttons
  and per-transport platform badges (green for WhatsApp, system accent
  for iMessage). Turns "draft" into a real human-review surface rather
  than a JSON file on disk.
- **First-run onboarding wizard** that asks which transports you want
  enabled and chains directly into WhatsApp QR pairing when you opt in.
- **Settings sheet** for per-transport configuration and pair/unpair.
- Contact-name resolution via the menu bar app's Contacts permission —
  agents see and surface real names ("Avery Example"), not raw phone
  numbers.
- Designed for **local MCP clients** (Claude Desktop, Claude Code, Codex
  CLI). The WhatsApp daemon opens a WebSocket to WhatsApp Web; no other
  network surfaces.

## Security

This server gives a local binary three macOS-level privileges (Full Disk
Access, Automation control of Messages.app, optional Open-at-Login). The
trust profile is non-trivial. Read **[SECURITY.md](SECURITY.md)** before
installing — it covers the full threat model, the mitigations in place
(prompt-injection wrapping, minimum staged-age, daily send cap, audit
log, SQL parameterization, etc.), the configuration knobs, and the
recommended user-side practices.

For vulnerability reports: open a GitHub Security Advisory on the repo.

## Why this exists

The agents calling this server run on the same Mac as the Messages data.
A local stdio MCP server is the right shape — no tunnel, no cloud, no
shared secret. The blast radius is "what a process running as you can
already do."

## Tools

The recommended default MCP is Ghostie, the generalized facade
(`ghostie-mcp`). It exposes transport-neutral refs like
`imessage:123` and `whatsapp:<jid>`:

| Tool | Purpose |
|---|---|
| `get_message_current_time` | UTC + system-local timestamps, for building `since` filters. |
| `ghostie_health_check` | Diagnose the facade plus iMessage and WhatsApp daemon dependencies. |
| `list_message_threads` | Recent threads across one or all transports. Requires `since` or `contact_filter`. |
| `get_message_thread` | Messages for a generalized `thread_ref`, paginated via `before`. |
| `search_message_history` | Search across one or all transports. Requires `query` plus `since` or `contact_filter`. |
| `stage_message_draft` | Stage an iMessage or WhatsApp draft for human approval. Does NOT send. |
| `list_message_drafts` | List staged drafts across one or all transports. |
| `get_message_draft` | Read one staged draft by generalized `draft_ref`. |
| `discard_message_draft` | Delete one staged draft by generalized `draft_ref`. |
| `set_message_thread_priority` | Set a cross-transport priority on a `thread_ref`. |
| `clear_message_thread_priority` | Clear a cross-transport priority. |
| `list_message_thread_priorities` | List cross-transport priorities. |

The transport-specific MCPs stay available for compatibility and for
operations that are intentionally not generalized:

- `imessage-drafts-mcp` exposes the original iMessage tools, including
  `send_draft`, voice/style helpers, and automation proposal tools.
- `whatsapp-drafts-mcp` exposes the WhatsApp-specific tools, including
  `send_whatsapp_draft`, full-message hydration, pairing/daemon health,
  and WhatsApp-specific priority tools.

The generalized facade intentionally has no `send_*` tool. Sends remain
explicitly transport-specific or, preferably, happen from the menu bar's
human approval surface.

Hard guardrails:

- `since` older than 2 years → rejected (no deep-history dumps).
- `query` shorter than 2 chars → rejected.
- All message bodies truncated at ~8 KB with a marker.

---

# Product analytics and diagnostics

Product analytics are shown during first-run onboarding with the toggle on by
default; users can turn them off before continuing and can change the setting
any time in Settings. The menu bar app uses PostHog manual capture through an
allowlisted Swift wrapper. It captures only coarse product events such as
app/version seen, settings opened, feature viewed, draft staged/sent,
scheduled-message created, Lab scan start/complete/fail, and diagnostics export
created.
Existing installs keep their stored analytics setting and do not see first-run
onboarding again unless setup is reset.

Analytics never include message bodies, draft text, prompts, model responses,
contact names, phone numbers, emails, Apple IDs, WhatsApp IDs, raw chat IDs,
recipient identifiers, message IDs, API keys, access tokens, or file paths.
Session replay, screen capture, element autocapture, and automatic screen/lifecycle
capture are disabled.

Release/dev builds can provide `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` when
assembling the app bundle. Without a project token, analytics is inert even if the
toggle is enabled. `MESSAGES_FOR_AI_ANALYTICS_DISABLED=1` or
`~/.messages-mcp/analytics.disabled` disables capture at runtime.

Diagnostics exports are separate local zip files created only after the user
clicks Export Diagnostics. Settings choose whether to include local app events,
daemon logs, and relevant crash reports. Daemon logs are off by default because
local bridge logs can include transport identifiers; enable them only when
support asks for the extra context.

---

# Skills

Optional Claude skills that build on the MCP, bundled in this repo under [`skills/`](skills/):

- [`texting-analytics`](skills/texting-analytics/) — a personal "Texting Wrapped" report (reply latency, ball-in-court rate, group contribution) rendered as four charts. Read-only; runs against your iMessage history via the MCP. Needs Python with `matplotlib`.

More skills (voice-cloned drafting, birthday texts) are in progress.

---

# Install

Two paths. Pick A unless you're contributing code.

## Option A — Pre-built release (recommended)

The release zip contains a signed, Apple-notarized .app. No Xcode, no
Apple Developer account, no rebuild required, and no separate WhatsApp
install. Drag and drop, then three manual permission steps.

```sh
# 1. Download the latest release zip.
curl -L \
  https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/releases/latest/download/messages-for-ai.zip \
  -o /tmp/messages-for-ai.zip

# 2. Unzip and run the installer.
cd /tmp && unzip -q messages-for-ai.zip
cd messages-for-ai-v* && bash install.sh
```

The installer copies `Ghostie.app` to `/Applications/`,
refreshes LaunchServices, smoke-tests the bundled MCP binaries via
`initialize` round-trips, creates symlinks at
`~/bin/ghostie-mcp` and `~/bin/imessage-drafts-mcp`
(legacy v0.1.x path), and prints the manual next steps.

After running it, you need to:

1. **Grant Full Disk Access** to `Ghostie.app` — see
   [Permissions](#permissions) below. The menu bar app launches the
   daemons that perform protected local reads, so Claude does not need
   FDA.
2. **Wire up the MCP client** — see [MCP client config](#mcp-client-config) below.
3. **Launch the menu bar app**:
   ```sh
   open "/Applications/Ghostie.app"
   ```
   First popover open will trigger the onboarding wizard. Pick which
   transports you want enabled (iMessage on by default; WhatsApp opt-
   in). If you check WhatsApp, the menubar spawns the daemon and
   chains directly into the QR pairing sheet — scan with WhatsApp on
   your phone via Settings → Linked Devices → Link a Device. First
   popover open will also trigger the macOS Contacts consent dialog.

## Option B — Build from source

For contributors. Requires Bun, Xcode 15+, and an **Apple Developer ID
Application certificate** for full contact-name resolution. Without the
cert, contact lookup gracefully falls back to "raw phone numbers" mode
— the rest of the server works fine.

```sh
git clone https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai.git
cd messages-for-ai

# Step 1: Build and install the menu bar app to /Applications/.
# This MUST run first — it creates the Ghostie.app bundle
# that the MCP binaries install INTO.
cd menubar && bash scripts/dev-install.sh && cd ..

# Step 2: Build and install ALL MCP binaries (generalized MCP,
# iMessage MCP, WhatsApp MCP, and daemons) into the .app's
# Contents/MacOS/, signed with the bundle identifier. Creates symlinks
# at ~/bin/ghostie-mcp and ~/bin/imessage-drafts-mcp.
bash scripts/dev-install.sh
```

Both install scripts auto-detect a Developer ID Application certificate
in your Keychain and use it for signing. If none is found, they fall
back to adhoc signing with a clear warning. To force a hard fail on
missing cert (for CI / release builds), set `CONTACTS_REQUIRE_DEVID=1`.

After rebuilding the MCP binaries, **restart any MCP client that has
already spawned the old one** (Claude Desktop, Claude Code, Codex CLI) —
they hold a long-lived stdio subprocess and won't pick up the new binary
until they re-spawn.

### Why Developer ID matters

Modern macOS (Sequoia+) silently blocks `CNContactStore.requestAccess`
for adhoc-signed apps. Without a Developer ID cert, the menu bar app
can't read your Contacts via the framework path. (FDA grants for adhoc
binaries also get invalidated on every rebuild, since TCC keys off the
binary hash.) See `menubar/scripts/messages-for-ai.entitlements` for
the Hardened Runtime entitlements required (`personal-information.
addressbook` + `automation.apple-events`).

---

# Permissions

Three TCC grants involved, each gated differently:

## 1. Full Disk Access (on `Ghostie.app`)

Required to read `~/Library/Messages/chat.db`. There's no programmatic
prompt for FDA — you have to do it manually:

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Click **+**.
3. Press **⌘⇧G**, paste `/Applications`, press Enter.
4. Select **`Ghostie`** (the .app bundle, NOT an inner binary
   or `~/bin/*-mcp` symlink) and click Open.
5. Confirm the toggle is **on**.

⚠️ **Drag the .app bundle, not the inner Mach-O or the symlink.** macOS
keys FDA grants by the bundle's `CFBundleIdentifier`
(`com.sunriselabs.messages-for-ai`). The bundled helpers share that
identifier for peer-auth and bundle coherence. Dragging an inner binary
or symlink can create confusing stale entries, so targeting the .app is the
unambiguous Apple convention and what the installer printout instructs.

**Troubleshooting: tools return `authorization denied` / `permission_denied`.**
Run `health_check` from a Claude Desktop chat — it'll report which
subsystem is failing and the remediation. Common causes:

- **Forgot to restart Claude Desktop after granting FDA** — the MCP
  child is a long-lived subprocess that re-checks its TCC identity at
  spawn time. `Cmd+Q` Claude Desktop (NOT just close the window) and
  reopen so it forks a fresh child.
- **You dragged the inner binary into FDA in a previous attempt** —
  the resulting row in the FDA list may be stale. Remove it (`–`
  button) and re-add by dragging the `.app` from `/Applications`.
- **You upgraded from v0.1.x** — your old grant against
  `~/bin/imessage-mcp` (identifier `com.sunriselabs.imessage-mcp`)
  is no longer valid. v0.2.0 uses a different identifier
  (`com.sunriselabs.messages-for-ai`). You must grant FDA fresh to
  the new `.app` bundle.

With Developer ID signing in place (default for both the pre-built
release and source builds with a cert), the grant survives rebuilds —
TCC keys off the `(identifier, team-id)` tuple, which is stable.

## 2. Contacts (on the menu bar app)

Required to resolve recipient handles to names. Prompted natively on
first popover open: *"Ghostie Would Like to Access Your Contacts."*
Click OK. The app then exports a `~/.messages-mcp/contacts-cache.json`
sidecar that the MCP reads on each `stage_draft` call.

The sidecar uses the same data source Messages.app uses, including
iCloud-synced contacts that may be CloudKit-only and absent from the
on-disk AddressBook SQLite. The sidecar refreshes automatically via
`CNContactStoreDidChangeNotification` whenever you edit a contact.

## 3. Automation (on the MCP client / menu bar app, targeting Messages.app)

Required to actually send a staged draft. Prompted on the first call to
`send_draft`: *"<parent app> wants to control Messages.app."*
Click **OK**; the grant persists.

To revoke later: System Settings → Privacy & Security → Automation →
your parent app → Messages → toggle off.

---

# MCP client config

> ⚠️ MCP client `command` fields vary in whether they expand `~`. Claude
> Desktop and Codex CLI do; some terminals' MCP plugins don't. If a
> client fails to launch the server, replace `~/bin/ghostie-mcp` with
> the absolute path (`echo $HOME/bin/ghostie-mcp`).

**Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ghostie": {
      "command": "~/bin/ghostie-mcp"
    }
  }
}
```

Restart Claude Desktop (Cmd+Q on the Claude menu, then reopen — the MCP
child only spawns on app launch).

**Claude Code** — add to `.mcp.json` in your project, or
`~/.claude/mcp.json` for global:

```json
{
  "mcpServers": {
    "ghostie": { "command": "~/bin/ghostie-mcp" }
  }
}
```

**Codex CLI** — `~/.codex/config.toml`:

```toml
[mcp_servers.ghostie]
command = "~/bin/ghostie-mcp"
```

(Verify against current Codex docs — config shape may have shifted.)

# Quick smoke test (no client needed)

```sh
cat <<'EOF' | ~/bin/ghostie-mcp 2>/tmp/ghostie-mcp.stderr | tail -1
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ghostie_health_check","arguments":{}}}
EOF
```

The health check reports the facade and daemon dependency state. If you
prefer to wire the legacy iMessage MCP directly, use
`~/bin/imessage-drafts-mcp` and call `health_check`.

---

# Sending drafts — the trust model

The generalized MCP can stage and discard drafts, but it does not expose
a send tool. The transport-specific send tools, such as iMessage
`send_draft({ draft_id })`, consume drafts staged through the MCP and
send through the local app/daemon path. The design has four trust
layers:

1. **MCP destructive annotation.** The tool advertises `destructiveHint: true`
   and `idempotentHint: false`, so MCP clients should surface a confirmation
   prompt before each call.
2. **Send-only-from-draft.** There's no ad-hoc send. Every send requires a
   `draft_id`, so the draft text is observable in the conversation transcript
   before the destructive tool fires — even if the agent calls
   `stage_draft` and `send_draft` in the same turn.
3. **Sent-state lock.** Once a draft has `sent_at` set, re-calling the
   transport-specific send tool returns an explicit "refusing duplicate send"
   error. An agent looping on retry cannot double-send.
4. **macOS TCC Automation.** AppleScript control of Messages.app is gated
   by a separate TCC service from FDA: "Automation". See
   [Permissions](#permissions) above.

If you ever expose this server over a network transport (HTTP / WebSocket /
tunnel), **remove the send tool from the public surface**. The trust
boundary collapses the moment a non-local caller can invoke it — and the
read tools are useful on their own.

---

# Menu bar app

The MCP server stages drafts as JSON files. The companion app at
`/Applications/Ghostie.app` is a SwiftUI `MenuBarExtra` that
surfaces pending drafts with hold-to-fire Send / Discard buttons — so
you actually review what an agent wants to send before it goes out,
rather than rubber-stamping a tool call that shows only a draft UUID.

### How it works

- Watches `~/.messages-mcp/drafts` via `DispatchSourceFileSystemObject`,
  so drafts staged by the MCP server appear in the popover within ~100ms.
- Sends through the same AppleScript path the MCP server uses
  (`osascript` + `tell application "Messages"`). The duplication is
  intentional — it avoids inventing IPC to the stdio MCP server.
- On send, atomically updates the same draft JSON with `sent_at` +
  `send_service`. Recently-sent drafts (within the last 24 hours) appear
  in a faded "Recently sent" section as a confirmation breadcrumb.
- **Contacts export**: on launch, the app calls `CNContactStore.
  enumerateContacts` and writes `~/.messages-mcp/contacts-cache.json`
  with canonicalized handle → display name pairs. The MCP reads this
  sidecar on every `stage_draft` call to populate
  `to_handle_name`. The sidecar refreshes on `CNContactStoreDidChange`.
- **Open at Login is on by default.** The app self-registers via
  `SMAppService` the first time it runs. Toggle off via the popover
  footer, or via System Settings → General → Login Items.
- **Race trade-off**: both the MCP `send_draft` tool and the
  menu bar app's Send button check `sent_at` before sending, but a true
  simultaneous click on both isn't atomic — you could double-send. For
  a single-user single-recipient flow this is acceptable; if you ever
  scale this up, add an `flock` on the draft file in both code paths.

---

# Tests

```sh
bun test
```

104 tests, ~100ms — pure-function + in-memory SQL + sidecar reader.
Coverage highlights:

- `decode.test.ts` — attributedBody typedstream decoder (short/long lengths, UTF-8, malformed input).
- `open.test.ts` — Apple-epoch ↔ ISO-8601 round-trips for both nanosecond (High Sierra+) and seconds (legacy) forms.
- `schema.test.ts` — Zod input validation: 2-year deep-history reject, 2-char minimums, handle format, body length cap.
- `storage/drafts.test.ts` — staging, list ordering, mark-sent persistence, symlink-clobber defense, atomic-rename + dir mtime, backward-compat normalization for older drafts.
- `storage/contacts-cache.test.ts` — sidecar JSON read path, malformed-input tolerance, schema-version mismatch detection.
- `chatdb/queries.test.ts` — end-to-end SQL against an in-memory chat.db fixture, covering pagination (strict `before`), contact-name widening, and `attributedBody` decode in search. Uses test seams `_setChatDbForTesting` + `_setContactsForTesting` to inject fixtures.
- `tools/health.test.ts` — `canonHandlePublic` canonicalization + probe block resolution logic.

---

# What this does NOT do

- **iOS.** Apple does not allow third-party access to Messages on iOS.
  There is no workaround short of jailbreaking.
- **Network.** Stdio only. If you ever want a cloud agent to call this,
  wrap the same query + draft code behind a tunnel + bearer secret —
  the data layer stays unchanged.

## Media and reactions

Mixed media now has read + send parity
  with Messages: agent read tools (`get_thread`, `search_messages`, the Ghostie
  facade) surface per-message attachment metadata — filename, local path,
  MIME, a coarse `kind` (image/video/audio/document), byte size, sticker flag
  (iMessage) and caption (WhatsApp) — so the agent can see what media a thread
  contains, not just that it has some. Outbound, `stage_draft` /
  `stage_whatsapp_draft` / `stage_message_draft` accept an `attachments` array
  of local file paths (≤10 files, ≤100 MB each, ≤250 MB total). At staging,
  Ghostie copies each regular, non-symlink source into private draft-owned
  storage and records its SHA-256 digest. The original can be moved or deleted
  without changing the draft. The managed snapshot is sent before the body
  (so the text reads as a caption) once the human approves the exact recipient,
  text, quote target, schedule, and ordered media manifest in the menu bar.
  The approval card previews the managed media; changed or legacy-unhashed
  attachments fail closed and must be restaged. iMessage media can be staged
  through the MCP, but it is always sent from Ghostie's reviewed app surface.
  After approval, the app copies the exact verified bytes into a short-lived
  handoff under the TCC-protected `~/Library/Messages/GhostieSendSpool`, keeps
  a no-follow descriptor open, makes that copy user-immutable, and gives
  Messages.app its stable macOS file-ID path. Direct MCP media send is blocked,
  even when direct text sending is enabled. WhatsApp media goes through Baileys using the exact bytes read
  and hashed through one no-follow file descriptor (image/video/audio/document
  by MIME). Multipart progress is journaled before
  and after every wire operation, so an ambiguous failure is held for review
  instead of blindly replaying an already-delivered part. The bytes are never
  inlined into model context; only metadata and the proposed source path cross
  the MCP boundary. The menu-bar transcript also displays
  iMessage Tapbacks/custom reaction emoji and WhatsApp reactions. WhatsApp reactions can be sent only from the visible
  Messages tab; MCP/agent tools do not expose a reaction-send method.
  Experimental iMessage Tapback sending lives behind the
  `imessage-ax-tapbacks` feature flag: it always navigates Messages.app to the
  target conversation, verifies the displayed conversation matches the target
  contact (window title vs. contact name/handle), and only then invokes
  Messages.app's own Accessibility action on a visible, unambiguous bubble
  inside that conversation's window — if the conversation can't be positively
  verified, it refuses rather than guessing. In the transcript, right-click
  the target message bubble to choose the reaction.

---

# Project layout

```
src/
  index.ts                 # stdio MCP bootstrap
  schema.ts                # Zod shapes + shared validators
  tools/
    threads.ts             # list_threads, get_thread
    search.ts              # search_messages
    drafts.ts              # stage/list/get/discard/send drafts
    time.ts                # get_current_time
    health.ts              # health_check
    _result.ts             # shared text-result envelopes
  chatdb/
    open.ts                # bun:sqlite read-only handle, Apple-epoch helpers
    decode.ts              # attributedBody → string + truncation
    contacts.ts            # handle → contact name (sidecar primary, SQLite fallback)
    queries.ts             # all SQL — parameterized
  imessage/
    send.ts                # osascript wrapper for Messages.app send
  storage/
    drafts.ts              # ~/.messages-mcp/drafts CRUD
    contacts-cache.ts      # ~/.messages-mcp/contacts-cache.json reader
menubar/
  Package.swift
  Sources/MessagesForAIMenu/
    App.swift              # @main, MenuBarExtra scene, AppDelegate
    DraftStore.swift       # ObservableObject + FS watcher
    DraftSender.swift      # osascript wrapper
    LoginItemController.swift  # SMAppService open-at-login toggle
    ContactsExporter.swift # CNContactStore → sidecar JSON
    Models/Draft.swift     # Codable; mirrors src/storage/drafts.ts
    Views/
      DraftListView.swift  # Pending + Recently-sent sections
      DraftRowView.swift   # Per-draft Send / Discard
      ContactsPermissionBanner.swift  # Shown when NSContacts not granted
  scripts/
    dev-install.sh         # build menubar .app → codesign (Developer ID or adhoc)
    messages-for-ai.entitlements  # Hardened Runtime entitlements
scripts/
  dev-install.sh           # rebuild MCP backend + launchers → install into .app → re-seal
  install-release.sh       # end-user installer bundled INTO the release zip
  build-release.sh         # maintainer: build + notarize + package release zip
  diagnose-contacts.ts     # standalone diagnostic for "contacts not resolving"
  README.md                # audience matrix + .app-wrap architecture explainer
```

---

# Cutting a release (maintainer)

The pre-built release is produced by `scripts/build-release.sh`, which
builds + signs + notarizes the app, backend, and launchers with Apple's notary service and
packages them into a self-contained zip.

### One-time setup

1. Install a **Developer ID Application** certificate (Xcode → Settings
   → Accounts → Manage Certificates → + → Developer ID Application).
2. Generate an app-specific password at https://appleid.apple.com →
   Sign-In and Security → App-Specific Passwords. Label it
   `imessage-drafts-mcp-notarytool`.
3. Store it in your Keychain:
   ```sh
   xcrun notarytool store-credentials imessage-drafts-mcp-notary \
     --apple-id <your-developer-account-email> \
     --team-id <your-team-id> \
     --password <app-specific-password>
   ```

### Cutting a release

```sh
# 1. Tag the commit you want to ship and push.
git tag v0.1.0
git push origin v0.1.0

# 2. Build the release zip. Takes ~5-10 min (notarization round-trip).
bash scripts/build-release.sh v0.2.0
# → produces dist/messages-for-ai-v0.2.0.zip

# 3. Publish via gh CLI.
gh release create v0.2.0 dist/messages-for-ai-v0.2.0.zip \
  --title 'Ghostie v0.2.0' \
  --notes 'See CHANGELOG / commit history.'
```

The build script fails loudly if no Developer ID cert is found OR if
notarytool credentials aren't set up — no slow rebuild waste. After
zip is produced, it auto-extracts to a temp dir and runs
`spctl --assess` against the unzipped `.app` to make sure Gatekeeper
will accept it on end-user machines. If that check fails, the script
exits 1 instead of shipping a broken release.

Override the notarytool profile name (e.g. for CI) via
`NOTARY_PROFILE=...`. Override the signing identity via `CODESIGN_IDENTITY=...`.
