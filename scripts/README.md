# scripts/

Three scripts live here. They have **different audiences** and run in
**different contexts**. The naming is deliberate — there is no plain
`install.sh` in the repo so that a contributor can't run the wrong one
by reflex.

## Architecture: the `.app`-wrap layout

The menubar UI binary (`MessagesForAIMenu`), one shared Bun backend
(`messages-for-ai-backend`), and the stable MCP/daemon launcher names
live inside one `.app` bundle:

```
/Applications/Ghostie.app/
└── Contents/
    ├── Info.plist           (CFBundleIdentifier = com.sunriselabs.messages-for-ai)
    └── MacOS/
        ├── MessagesForAIMenu        (Swift menubar UI — Info.plist's CFBundleExecutable)
        ├── messages-for-ai-backend  (compiled Bun backend, role-dispatched)
        ├── ghostie-mcp      (tiny signed launcher — generalized facade)
        ├── imessage-drafts-mcp      (tiny signed launcher — iMessage tools)
        ├── imessage-drafts-daemon   (tiny signed launcher — chat.db daemon)
        ├── whatsapp-drafts-mcp      (tiny signed launcher — WhatsApp tools)
        └── whatsapp-drafts-daemon   (tiny signed launcher — WhatsApp daemon)
```

A current symlink at `~/bin/ghostie-mcp` points at the
generalized facade. A backward-compat symlink at `~/bin/imessage-drafts-mcp` →
`/Applications/Ghostie.app/Contents/MacOS/imessage-drafts-mcp`
lets MCP client configs that hard-coded `~/bin/imessage-drafts-mcp`
keep working.

**Why every inner Mach-O shares `Identifier=com.sunriselabs.messages-for-ai`:**
Full Disk Access is launcher-attributed: the chat.db reads happen in a
daemon launched by the menu bar app, so Claude never needs FDA. The shared
identifier is still load-bearing for peer-auth and bundle coherence: MCP
clients and daemons can verify that their local peer is part of the same
signed product, not an unrelated binary. This also follows Apple's normal
multi-Mach-O bundle convention (Xcode, Photoshop, anything with sidecar
binaries in `Contents/MacOS/`).

⚠️ **Never run `codesign --deep` on the bundle after you've signed
inner binaries with explicit `--identifier`.** `--deep` re-derives
each inner Mach-O's identifier from its path basename and clobbers
the explicit value. The bundle's seal may still verify and the .app may
still launch, but peer-auth or TCC-attributed daemon behavior can fail
in surprising ways.
`dev-install.sh` and
`build-release.sh` both guard against this — `build-release.sh`
has a defensive post-seal check that fails the build if any inner
binary's identifier ≠ `com.sunriselabs.messages-for-ai`.

## Install order (important — read this before running anything)

The dev install is a two-step sequence. The order matters because
`scripts/dev-install.sh` (the repo-root MCP installer) expects the
`.app` bundle to already exist at `/Applications/Ghostie.app`:

```sh
# Step 1: create the .app bundle with the menubar binary inside.
cd menubar && bash scripts/dev-install.sh && cd ..

# Step 2: build the backend plus launchers and install them INTO the existing .app.
bash scripts/dev-install.sh    # (or: bun run install:bin)
```

If you run Step 2 first, the script exits with
`✗ menubar .app not found at: /Applications/Ghostie.app`.

**Do not run the two scripts concurrently** (e.g. one in each terminal
tab). They both modify `/Applications/Ghostie.app/`'s codesign
state; running them in parallel can interleave per-binary signing with
bundle re-sealing and leave the bundle's seal pointing at a different
version of a launcher than the on-disk file actually contains.
Wait for Step 1 to finish before starting Step 2.

## `dev-install.sh` — contributor / local development

Rebuilds the shared backend from source via `bun build --compile`,
codesigns it with the contributor's
`Developer ID Application: ... (LQ93LRM9QU)` cert (auto-detected;
falls back to adhoc with a warning), installs it INTO the existing
`/Applications/Ghostie.app/Contents/MacOS/`, then re-seals
the bundle (without `--deep`).

Run this when:
- You've made a code change to `mcps/*/src/` and want to test it against your
  live Claude Desktop / Claude Code MCP client.
- You're iterating on the MCP server itself.

**Prerequisite:** the menubar `.app` must already exist at
`/Applications/Ghostie.app/`. If it doesn't, install it first:

```sh
cd menubar && bash scripts/dev-install.sh
```

Then from the repo root:

```sh
bun run install:bin    # or: bash scripts/dev-install.sh
```

Identifier embedded in the signed inner binary:
**`com.sunriselabs.messages-for-ai`** (same as the bundle). Same
identifier in both dev and release builds — TCC's grant matches on
`(identifier, team-id)` and is tolerant of cdhash changes, so a dev
rebuild updates the cdhash but doesn't invalidate any existing FDA
grant on the bundle.

## `build-release.sh` — maintainer

Builds + signs + notarizes ONE `.app` bundle containing the menu bar app,
the shared backend, and all stable launcher binaries,
packages it (plus a copy of `install-release.sh` renamed to
`install.sh`, plus a short user-facing README) into
`dist/messages-for-ai-<version>.zip`, ready for upload to GitHub
Releases.

Single notary submission for the bundle (the bundle's seal covers
all inner binaries — no separate binary submission needed).

Run this when cutting a tagged release. One-time setup required:

```sh
xcrun notarytool store-credentials imessage-drafts-mcp-notary \
  --apple-id <your-apple-id> \
  --team-id LQ93LRM9QU \
  --password <app-specific-password-from-appleid.apple.com>
```

Then:

```sh
bash scripts/build-release.sh v0.2.0
gh release create v0.2.0 dist/messages-for-ai-v0.2.0.zip ...
```

Takes ~5–10 minutes (most of which is Apple's notarization queue).

Identifier embedded in every inner binary and the bundle:
**`com.sunriselabs.messages-for-ai`**.

## `install-release.sh` — end user

Does NOT compile anything. Copies the pre-built, already-signed-and-
notarized `.app` from a release zip into `/Applications/`, creates the
`~/bin/ghostie-mcp` current symlink and
`~/bin/imessage-drafts-mcp` backward-compat symlink, removes legacy
v0.1.x install artifacts (`~/bin/imessage-mcp`, `~/Applications/...`).

This script ships *inside* the release zip (where `build-release.sh`
renames it to plain `install.sh` because that's the universal naming
convention end users expect). End users do NOT run it from the repo —
they download the release zip, unzip, and run the bundled `install.sh`.

Lives in the repo so contributors can audit and modify what the
end-user install does.

Before copying anything, this script verifies:
1. The bundle's embedded `TeamIdentifier` matches `LQ93LRM9QU`. Refuses
   to install otherwise — defends against phishing-site forged releases
   signed under an attacker's Developer ID.
2. The bundled MCP launcher's `TeamIdentifier` also matches (catches a
   release zip with a stale or unsigned launcher).
3. `codesign --verify --strict` passes on the .app.
4. `spctl --assess` accepts the .app (i.e. Apple's notarization is
   recognized).

Override `EXPECTED_TEAM_ID=...` if you're intentionally installing a
fork's release.

## Menu bar app entitlements

The signed menu bar app embeds `menubar/scripts/messages-for-ai.entitlements`.
It declares **`com.apple.security.automation.apple-events: true`** (required
for hardened-runtime non-sandboxed apps to send any Apple Event at all —
removing it would block the AppleScript path the app uses to talk to
Messages.app) and **`com.apple.security.scripting-targets`** scoped to
`com.apple.iChat` (the historical bundle ID Messages.app still ships with).

⚠️ The `scripting-targets` entry is **not enforced** by the OS for
non-sandboxed apps — it documents intent but doesn't bound the Apple
Events scope at runtime. Real enforcement requires turning the menubar
into a sandboxed app with `com.apple.security.app-sandbox`, which needs
temporary-exception entries for `~/.messages-mcp/` filesystem access.
That's a deferred refactor (v0.1.2). The full reasoning lives in the
XML comment at the top of the entitlement file. A reviewer auditing
Apple-events exposure should read both this section AND that comment.

## `diagnose-contacts.ts`

Not an installer — a standalone diagnostic that runs the contact-
resolution code paths against the local Contacts.app data and prints
what would happen. Useful when `to_handle_name` resolution is silently
failing and you want to know which DB the loader picked, whether the
sidecar is being honored, etc.

```sh
bun scripts/diagnose-contacts.ts
```
