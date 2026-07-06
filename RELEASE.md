# Releasing Ghostie

How to ship a new version. Written so you don't have to remember the steps —
the script does the remembering. Read this once; after that it's one command.

## TL;DR

```bash
# 1. Merge any feature PRs into main first (on GitHub).
git checkout main && git pull

# 2. Ship. One command. (Dry-run first if you want to be sure.)
#    Secrets (PostHog token, Vercel Blob token) come from the login
#    keychain automatically — see One-time setup. An exported env var
#    overrides the keychain if you ever need to.
bash scripts/release.sh v0.3.4 --dry-run   # checks everything, changes nothing
bash scripts/release.sh v0.3.4             # the real thing
```

That's it. The app lands on GitHub Releases (DMG + zip), and the plugin/skills
ship with the same git tag. Existing users update each channel through its own
mechanism (below).

---

## The mental model: one version, two channels

Ghostie ships through **two independent pipes**, both driven by a
single version number:

| Channel | What ships | How users get it |
|---|---|---|
| **The .app** | menubar UI + 4 MCP/daemon binaries, notarized | Download the DMG from GitHub Releases; thereafter it auto-updates in-app via Sparkle (you approve each install) |
| **The plugin** | `plugin.json` + `skills/*` (no build, no notarization) | `/plugin marketplace update ghostie` in Claude Code — pulls straight from the git tag |

**"Releasing the plugin" is not a build.** It's just the version bump commit +
tag landing on `main`. The Claude Code plugin marketplace reads the repo
directly. So when `release.sh` pushes the tag, the plugin is already live.

### Where the version number actually lives

- **The .app version** is stamped by `build-release.sh` from its `vX.Y.Z`
  argument straight into `Info.plist` (`CFBundleShortVersionString`). You never
  hand-edit it.
- **Three "soft" files** don't follow that arg automatically, so
  `bump-version.sh` rewrites them: `.claude-plugin/plugin.json` and both
  `mcps/*/package.json`. `release.sh` runs this for you.

The first `release.sh` run normalizes all three to match, so any current drift
(plugin.json is on a different number than the MCPs right now) self-heals.

---

## One-time setup

You only do this once per machine. If `release.sh --dry-run` passes, you're set.

1. **Developer ID Application certificate** in your login keychain. (You already
   have this — it's how every build so far got signed.)
2. **Notary credentials** stored as a keychain profile named
   `ghostie` (older machines may still carry the legacy `imessage-mcp-notary`
   profile). Override with the `NOTARY_PROFILE` env var if yours differs.
3. **GitHub CLI** authenticated: `gh auth login`.
4. **create-dmg**: `brew install create-dmg` (the dmg script auto-installs it if
   missing).
5. **Release secrets in the login keychain** (stored once; the scripts read
   them automatically, like the notary profile — an exported env var
   overrides the keychain):

   ```sh
   security add-generic-password -a "$USER" -s POSTHOG_PROJECT_TOKEN -w '<phc_…>' -U
   security add-generic-password -a "$USER" -s BLOB_READ_WRITE_TOKEN -w '<vercel_blob_rw_…>' -U
   ```

   `POSTHOG_PROJECT_TOKEN` is embedded in the build for release analytics
   (`POSTHOG_HOST` defaults to `https://us.i.posthog.com`, HTTPS-only).
   `BLOB_READ_WRITE_TOKEN` mirrors release assets to public Vercel Blob
   downloads (Vercel dashboard → Storage → the blob store). Never commit
   either token.

`release.sh` preflight checks #1, #3, #5, and the tag/branch state, and fails
with a plain-English message if something's off — before it changes anything.

---

## What `release.sh` does, step by step

1. **Preflight** — on `main`, clean working tree, up to date with origin, tag is
   new, `gh` authed, signing cert present, and PostHog release analytics config
   present. Any failure stops here with no changes.
2. **Bump** — `bump-version.sh` sets the three soft versions.
3. **Commit** — `chore: release vX.Y.Z`, so the tag points at the bump.
4. **Build .app** — `build-release.sh`: compile (Swift + Bun), sign every inner
   binary, notarize, staple, Gatekeeper-verify. The slow part (a few minutes).
5. **Build .dmg** — `build-dmg.sh`: wrap the notarized .app in the drag-to-install
   layout, notarize, staple. Output name is stable (`Messages-for-AI.dmg`) so the
   marketing site's `/releases/latest/download/Messages-for-AI.dmg` link never
   changes.
6. **Push** — commit + tag to origin. (This is the moment the plugin goes live.)
7. **Publish** — `gh release create` uploads **both** the `.zip` and the `.dmg`,
   auto-generating notes from merged PRs (release titles are "Ghostie
   vX.Y.Z"). Edit the notes on GitHub afterward if you want a human summary.

### Notes for the next release (one-time, v0.7.0)

- **Plugin rename:** the Claude Code plugin is now named `ghostie` (was
  `messages-for-ai`). Existing installs under the old name do NOT
  auto-migrate — users must `/plugin uninstall messages-for-ai` and
  re-install `ghostie` from the marketplace. Put this in the release notes.
- **Deliberately unchanged across the rebrand** (see CLAUDE.md "Rebrand
  invariants"): bundle id / codesign identifier
  `com.sunriselabs.messages-for-ai`, `~/.messages-mcp` paths, the stable
  `Messages-for-AI.dmg` download name, and `SUFeedURL`. (The notary keychain
  profile is a local, overridable name — now defaulting to `ghostie` — not a
  cross-machine invariant.)

---

## If something breaks mid-release

- **Notarization crash (SIGBUS / signal 10) after upload.** Known notarytool 1.1.0
  bug — the crash is in its output formatter, *not* a failed submission. The build
  scripts already handle it (recover the UUID from history, poll with `info`).
  See the project README's notarization note.
- **Preflight rejected you.** Read the message — it tells you exactly what to fix
  (wrong branch, dirty tree, existing tag, not logged in). Fix and re-run.
- **Build failed after the version bump committed.** The `chore: release` commit
  is already made but nothing was pushed. Fix the build issue, then re-run
  `release.sh vX.Y.Z` — the bump step is idempotent (sees versions already set,
  skips the commit) and it picks up from there. Nothing was pushed or tagged, so
  there's no public mess to clean up.
- **GitHub asset upload fails with `tls: bad record MAC` / `broken pipe`.** A flaky
  network path corrupts `gh`'s HTTP/2 large-file upload to `uploads.github.com`
  (the build + Vercel Blob steps are unaffected, so the public download/appcast
  are already live — the product release is NOT blocked). The release object and
  the Vercel Blob mirror are fine; only the GitHub *release-page* binaries are
  missing. Re-attach them with curl over HTTP/1.1 with the Expect/100-continue
  handshake disabled, which survives the corrupting middlebox:
  ```sh
  RID=$(gh release view vX.Y.Z --json databaseId -q .databaseId); TOK=$(gh auth token)
  for f in dist/*.zip dist/*.dmg; do
    curl --http1.1 -H "Expect:" -X POST \
      "https://uploads.github.com/repos/Sunrise-Labs-Dot-AI/ghostie/releases/$RID/assets?name=$(basename "$f")" \
      -H "Authorization: Bearer $TOK" -H "Content-Type: application/octet-stream" \
      --data-binary @"$f"; done   # retry on HTTP 000 — it lands within a few tries
  ```
- **You need to abandon a release entirely.** If nothing was pushed: `git reset
  --hard origin/main`. If the tag was pushed but you want to pull it:
  `git push origin :vX.Y.Z` and delete the GitHub release in the UI.

---

## Auto-update (Sparkle) — runbook

Sparkle is wired up. The app auto-checks `https://messagesfor.ai/appcast.xml` in
the background and, when a newer build exists, shows its "Update available" window;
**the user clicks Install** (nothing auto-installs — `SUAutomaticallyUpdate` is off).
Sparkle verifies every update (EdDSA signature + Developer ID + notarization) before
running it. Config: `SUEnableAutomaticChecks=true` (on by default; a Settings toggle
+ a status-menu "Check for Updates…" let the user check on demand).

### One-time setup (per release machine)

1. **Generate the EdDSA keypair** (stores the PRIVATE key in your login keychain,
   prints the PUBLIC key). `generate_keys` ships in the Sparkle SPM artifact:

   ```sh
   (cd menubar && swift package resolve)   # ensures the artifact is present
   "$(find menubar/.build -type f -name generate_keys -path '*sparkle*' ! -path '*old_dsa*' | head -1)"
   ```

2. **Commit the public key.** Replace the entire contents of
   `menubar/scripts/sparkle_public_ed_key.txt` with the printed public key (one
   base64 line, nothing else). It's safe to commit — it's embedded in every build
   as `SUPublicEDKey`. `build-release.sh` refuses to ship until this is a real key.
   The PRIVATE key stays in your keychain — **never commit it**; it's new secret
   material guarded like the notary credentials.

### What each release does (automatic, via `release.sh`)

`build-release.sh` embeds `Sparkle.framework` into the bundle and signs it
inside-out (XPC services → Autoupdate → Updater.app → framework) with the Developer
ID + Hardened Runtime, before the no-`--deep` app seal (so our inner-Mach-O
identifiers and Sparkle's own identifiers both survive). `release.sh` then, after
`gh release create`, runs `sign_update` on the release zip (using the keychain
private key) and appends a signed `<item>` to `site/appcast.xml` pointing at the
GitHub release zip, commits it, and redeploys the site so the feed goes live.

The Sparkle enclosure is the **versioned `.zip`** (`messages-for-ai-vX.Y.Z.zip`);
the stable `Messages-for-AI.dmg` remains the human marketing-site download.

### Trust boundaries (treat like the signing key)

The EdDSA signature + Developer ID + notarization mean a compromised feed host or
DNS **cannot inject attacker-authored code** — Sparkle rejects anything not signed
by your private key. The residual risk is *update suppression / serve-an-old-signed
build*: whoever controls the Vercel deploy creds or the `messagesfor.ai` domain
could prune the feed to an older, still-validly-signed (but known-vulnerable)
release. So lock down the Vercel project (scoped token, 2FA, minimal collaborators)
and the domain registrar (registrar lock, 2FA), and don't treat auto-update as the
*only* patch channel. The feed URL is also pinned in-app via `FeedURLPin`
(`UpdaterController.swift`) so a local `defaults write … SUFeedURL` can't repoint it.
Future hardening: add `sparkle:minimumAutoupdateVersion` to set a version floor.

### FDA across updates (verify once, then trust)

A Sparkle update is a same-Developer-ID re-sign of the same bundle ID. macOS TCC
keys the Full Disk Access grant to the signing identity (cdhash-tolerant), so a
same-identity update should **not** force users to re-grant FDA — message reads keep
working across an auto-update. This is the scariest failure mode for *this* app, and
it's favorable. **Confirm it with one real end-to-end update test before trusting it
in production** (TCC has surprised this project before — see the #17 saga).

### Testing
- **Smoke (no second release):** after keygen + the public key is committed + the
  seeded `messagesfor.ai/appcast.xml` is live, `dev-install` the app, then status
  menu → "Check for Updates" → Sparkle opens and says "You're up to date" (proves
  the framework loads, the feed fetches, and the key parses).
- **End-to-end:** ship vN, install it, ship vN+1, then on vN click "Check for
  Updates" → it offers vN+1, Install runs, the app relaunches on vN+1, and an
  iMessage read still works (FDA survived).
