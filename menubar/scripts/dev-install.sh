#!/usr/bin/env bash
#
# DEV build + install of the Ghostie menu bar app.
#
# This is the dev-loop installer. End users should get the release zip
# from GitHub Releases and run its bundled `install.sh` (sourced from
# scripts/install-release.sh in this repo) — that path installs a pre-
# built notarized .app without needing Xcode or a Developer ID cert.
#
# This script (in contrast):
#   - Compiles the menu bar app from source via `swift build -c release`.
#   - Assembles a proper `.app` bundle so macOS shows a real icon / name
#     in TCC prompts.
#   - Installs as a regular app with a menu-bar status item, so it is available
#     from Spotlight, Dock, and the app switcher.
#   - Codesigns with a Developer ID cert matching EXPECTED_TEAM_ID if
#     present, falls back to adhoc with a warning.
#
# After install, launch via:    open "/Applications/Ghostie.app"
# Or set it as a Login Item:    System Settings → General → Login Items.
#
# Install destination: /Applications by default. This is where Finder's
# sidebar "Applications" item points and where Launchpad indexes. Override
# with INSTALL_ROOT=/some/other/path if /Applications isn't writable (e.g.
# on a managed Mac):
#   INSTALL_ROOT="$HOME/Applications" bash scripts/dev-install.sh

set -euo pipefail

cd "$(dirname "$0")/.."

# ─── Configuration ──────────────────────────────────────────────────────────

# The only Apple Developer Team ID accepted for non-adhoc signing.
# Auto-detected `Developer ID Application: ...` certs whose parenthesized
# Team ID doesn't match this value are REJECTED — script falls back to
# adhoc rather than silently signing with an attacker-planted cert.
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

# Absolute paths to macOS-system binaries. Defends against PATH-shimmed
# `security` / `codesign` (e.g. a malicious npm postinstall planting an
# attacker binary on $PATH).
SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
AWK=/usr/bin/awk

APP_NAME="Ghostie"
APP_DISPLAY_NAME="Ghostie"
OLD_APP_NAME="Messages for AI"
# Bundle ID history:
#   `com.local.imessage-drafts` (v0.1.x dev, poisoned by an early build
#     that lacked NSContactsUsageDescription)
#   → `com.sunriselabs.imessage-drafts` (v0.1.x release)
#   → `com.sunriselabs.messages-for-ai` (current; v0.2.0 rename)
# macOS TCC's opaque "this bundle is suspicious" cache survives both
# `tccutil reset` and `killall tccd`. Each fresh bundle ID dodges the
# whole apparatus and is treated as a new app for TCC purposes. The
# `.local.` namespace is reserved for Bonjour multicast DNS anyway —
# `com.sunriselabs.*` matches the GitHub org and is the conventional
# reverse-DNS shape for signed dev/release tools.
BUNDLE_ID="com.sunriselabs.messages-for-ai"
# IDs that existed in v0.1.x installs and may have left orphan TCC
# entries on existing user machines. Surface them in the tccutil cleanup
# hint after install. Do NOT include the current BUNDLE_ID here.
LEGACY_BUNDLE_IDS=("com.local.imessage-drafts" "com.sunriselabs.imessage-drafts")
INSTALL_ROOT="${INSTALL_ROOT:-/Applications}"
APP="${INSTALL_ROOT}/${APP_NAME}.app"
LEGACY_APPS=(
  "${HOME}/Applications/${APP_NAME}.app"
  "${HOME}/Applications/${OLD_APP_NAME}.app"
  "${INSTALL_ROOT}/${OLD_APP_NAME}.app"
)
EXE_NAME="MessagesForAIMenu"

# Pre-flight: make sure we can write to the install root before doing the
# slow swift build. /Applications is writable by the local admin user on
# a default macOS setup (no sudo required), but managed / multi-user Macs
# can have it locked down.
if [[ ! -d "$INSTALL_ROOT" ]]; then
  echo "✗ install root does not exist: $INSTALL_ROOT" >&2
  exit 1
fi
if [[ ! -w "$INSTALL_ROOT" ]]; then
  echo "✗ install root is not writable by $USER: $INSTALL_ROOT" >&2
  echo "  Either re-run with sudo:    sudo bash scripts/dev-install.sh" >&2
  echo "  Or install to your per-user folder:" >&2
  echo "    INSTALL_ROOT=\"\$HOME/Applications\" bash scripts/dev-install.sh" >&2
  exit 1
fi

echo "› swift build -c release"
BIN=".build/release/${EXE_NAME}"
# ── macOS build.db disk-I/O artifact tolerance ──
# In long-running shells `swift build` can print
#   accessing build database ".../.build/build.db": disk I/O error
# and exit NON-ZERO *after* the binary links cleanly ("Build complete!"). It's a
# SwiftPM/SQLite coalition artifact, NOT a compile failure (same family handled
# in scripts/build-release.sh). Under `set -e` a bare `swift build` would abort
# the whole install here — leaving a stale .app + stale build stamp, which looks
# exactly like "my changes didn't install." Mirror build-release.sh: rm the prior
# binary so a stale one can't masquerade as this run's output, tolerate the exit
# code, then REQUIRE a fresh binary (a real compile failure leaves none → abort).
#
# Worse failure mode (observed during the 2026-06-02 v1.1 PR-A dev-install): the
# build.db corruption can leave the link product UNWRITTEN — "Build complete!"
# prints but `.build/release/MessagesForAIMenu` never appears (only the .dSYM +
# intermediates do), so the freshness check below aborts. The only manual fix was
# `rm -rf .build` then re-run. We now self-heal that: if the binary is missing AND
# the build.db disk-I/O error was in the output, wipe .build and retry the release
# build ONCE before declaring a real failure. Bounded to a single retry so a
# genuine, reproducible compile failure can't loop forever.

# String SwiftPM prints when the build.db SQLite handle hits the coalition
# disk-I/O artifact. Matching it is what distinguishes a recoverable corrupted
# link product (wipe .build, retry) from a real compile failure (abort).
BUILD_DB_ERR_RE='build\.db.*disk I/O error'

# Runs `swift build -c release` once, streaming output to the terminal while
# capturing it so we can scan for the build.db artifact afterward. Removes any
# stale binary first (so a leftover can't masquerade as this run's output) and
# sets SWIFT_BUILD_RC + SWIFT_BUILD_LOG.
run_release_build() {
  [[ -n "${SWIFT_BUILD_LOG:-}" ]] && rm -f "$SWIFT_BUILD_LOG"
  SWIFT_BUILD_LOG="$(mktemp -t mfa-swift-build)"
  rm -f "$BIN"
  set +e
  swift build -c release 2>&1 | tee "$SWIFT_BUILD_LOG"
  SWIFT_BUILD_RC=${PIPESTATUS[0]}
  set -e
}

run_release_build

# Self-heal: build.db corrupted the link product (binary missing despite the
# disk-I/O error). Wipe .build and rebuild from scratch — exactly once.
if [[ ! -x "$BIN" ]] && grep -qE "$BUILD_DB_ERR_RE" "$SWIFT_BUILD_LOG"; then
  echo "  ⚠ build.db corrupted the link product — wiping .build and retrying once."
  rm -rf .build
  run_release_build
fi
rm -f "$SWIFT_BUILD_LOG"

if [[ ! -x "$BIN" ]]; then
  echo "✗ swift build did not produce $BIN (exit $SWIFT_BUILD_RC)." >&2
  echo "  This is a real build failure, not the build.db disk-I/O artifact." >&2
  exit 1
fi
if [[ $SWIFT_BUILD_RC -ne 0 ]]; then
  echo "  ⚠ swift build exited $SWIFT_BUILD_RC but linked a fresh binary —"
  echo "  ⚠ proceeding (known macOS build.db disk-I/O artifact, not a compile error)."
fi

echo "› assembling ${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

# Atomic install of the executable so a running instance isn't ripped out
# from under itself.
cp "$BIN" "${APP}/Contents/MacOS/${EXE_NAME}.new"
xattr -c "${APP}/Contents/MacOS/${EXE_NAME}.new"
mv "${APP}/Contents/MacOS/${EXE_NAME}.new" "${APP}/Contents/MacOS/${EXE_NAME}"

# App icon: ship the Ghostie .icns generated from the selected brand mascot. The Info.plist
# below points at it via CFBundleIconFile=MessagesForAI; macOS resolves that to
# Contents/Resources/MessagesForAI.icns. Regenerate from the Swift script if the
# variant changes.
#
# Path note: the earlier `cd "$(dirname "$0")/.."` puts PWD at <repo>/menubar/,
# so the icon path is relative to menubar/ — NOT menubar/menubar/.
ICON_SRC="${PWD}/Assets/MessagesForAI.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "${APP}/Contents/Resources/MessagesForAI.icns"
else
  echo "⚠  no app icon at $ICON_SRC — bundle will use the generic AppKit icon" >&2
fi

GHOSTIE_ASSETS_SRC="${PWD}/Assets/Ghostie"
if [[ -d "$GHOSTIE_ASSETS_SRC" ]]; then
  rm -rf "${APP}/Contents/Resources/Ghostie"
  mkdir -p "${APP}/Contents/Resources/Ghostie"
  cp "$GHOSTIE_ASSETS_SRC"/*.png "${APP}/Contents/Resources/Ghostie/"
else
  echo "⚠  no Ghostie assets at $GHOSTIE_ASSETS_SRC — sidebar mark will use the app icon" >&2
fi

# Build stamp so the Settings footer can identify exactly which dev build
# is installed. Git runs fine from this subdir (it walks up to the repo
# root). "-dirty" flags an install built from an uncommitted working tree.
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git diff --quiet HEAD 2>/dev/null; then
  GIT_SHA="${GIT_SHA}-dirty"
fi
BUILD_TIME="$(date -u '+%Y-%m-%d %H:%M UTC')"
echo "› build stamp: ${GIT_SHA} (${BUILD_TIME})"

# Sparkle public key (best-effort for dev). Unlike build-release.sh, dev DOESN'T
# fail without a real key — dev builds don't auto-update — but the framework is
# still embedded below (or the app won't launch). With a real key + a live
# appcast, the "Check for Updates" smoke test works from a dev install. Keep the
# dev CFBundleVersion numeric so Sparkle never parses a git SHA as a build number
# that can incorrectly outrank real releases.
#
# Local dev installs should also be easy to order by eye. Default to a
# machine-local monotonically increasing build number (max of the currently
# installed bundle and the saved counter, plus one), while still honoring an
# explicit DEV_CFBUNDLE_VERSION override for one-off smoke tests.
read_json_version() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  "$AWK" -F'"' '/"version"[[:space:]]*:/ { print $4; exit }' "$path"
}
if [[ -z "${DEV_BASE_VERSION:-}" ]]; then
  DEV_BASE_VERSION="$(
    read_json_version "${PWD}/../.claude-plugin/plugin.json" ||
    read_json_version "${PWD}/../mcps/imessage-drafts/package.json" ||
    true
  )"
fi
if [[ ! "$DEV_BASE_VERSION" =~ ^[0-9]+([.][0-9]+){2}([-.][0-9A-Za-z]+)*$ ]]; then
  echo "✗ could not derive DEV_BASE_VERSION from plugin/package metadata; got '${DEV_BASE_VERSION:-}'" >&2
  echo "  Override with DEV_BASE_VERSION=X.Y.Z bash scripts/dev-install.sh" >&2
  exit 1
fi
DEV_SHORT_VERSION="${DEV_BASE_VERSION%-dev}-dev"
echo "› CFBundleShortVersionString=${DEV_SHORT_VERSION} (derived)"

DEV_BUILD_COUNTER_FILE="${DEV_BUILD_COUNTER_FILE:-${HOME}/Library/Application Support/Messages for AI/dev-build-number}"
next_dev_bundle_version() {
  local current=0
  local installed_version=""
  local installed_short_version=""
  if [[ -f "${APP}/Contents/Info.plist" ]]; then
    installed_short_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist" 2>/dev/null || true)
    installed_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP}/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$installed_short_version" == *"-dev"* ]] && [[ "$installed_version" =~ ^[0-9]+$ ]] && (( installed_version > current )); then
      current="$installed_version"
    fi
  fi
  if [[ -f "$DEV_BUILD_COUNTER_FILE" ]]; then
    local saved_version
    saved_version="$(<"$DEV_BUILD_COUNTER_FILE")"
    if [[ "$saved_version" =~ ^[0-9]+$ ]] && (( saved_version > current )); then
      current="$saved_version"
    fi
  fi
  echo $((current + 1))
}
if [[ -z "${DEV_CFBUNDLE_VERSION:-}" ]]; then
  DEV_CFBUNDLE_VERSION="$(next_dev_bundle_version)"
  DEV_CFBUNDLE_VERSION_SOURCE="auto-incremented"
else
  DEV_CFBUNDLE_VERSION_SOURCE="override"
fi
if [[ ! "$DEV_CFBUNDLE_VERSION" =~ ^[0-9]+$ ]]; then
  echo "✗ DEV_CFBUNDLE_VERSION must be an integer, got '$DEV_CFBUNDLE_VERSION'" >&2
  exit 1
fi
mkdir -p "$(dirname "$DEV_BUILD_COUNTER_FILE")"
printf '%s\n' "$DEV_CFBUNDLE_VERSION" > "$DEV_BUILD_COUNTER_FILE"
echo "› CFBundleVersion=${DEV_CFBUNDLE_VERSION} (dev, ${DEV_CFBUNDLE_VERSION_SOURCE})"
SU_KEY_FILE="${PWD}/scripts/sparkle_public_ed_key.txt"
# Extract the ed25519 key token (44 base64 chars ending '='), tolerant of how it
# was pasted (bare key / <string>…</string> / quotes / comments) — same as
# build-release.sh. Placeholder has '_' → matches nothing → empty (updates off).
SU_PUBLIC_ED_KEY="$(grep -oE '[A-Za-z0-9+/]{43}=' "$SU_KEY_FILE" 2>/dev/null | head -1)"
if [[ ! "$SU_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "  ⚠ no valid Sparkle public key in $SU_KEY_FILE — embedding empty SUPublicEDKey"
  echo "    (auto-update disabled in this dev build; run generate_keys to enable)."
  SU_PUBLIC_ED_KEY=""
fi
POSTHOG_PROJECT_TOKEN="${POSTHOG_PROJECT_TOKEN:-}"
POSTHOG_HOST="${POSTHOG_HOST:-https://us.i.posthog.com}"
if [[ ! "$POSTHOG_PROJECT_TOKEN" =~ [^[:space:]] ]]; then
  echo "  ⚠ POSTHOG_PROJECT_TOKEN is not set — product analytics will be inert in this dev build."
elif [[ "$POSTHOG_HOST" != https://* ]]; then
  echo "✗ POSTHOG_HOST must start with https:// (got '$POSTHOG_HOST')." >&2
  exit 1
else
  echo "› PostHog token configured"
fi

cat > "${APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${EXE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_DISPLAY_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>MessagesForAI</string>
  <key>CFBundleShortVersionString</key>
  <string>${DEV_SHORT_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${DEV_CFBUNDLE_VERSION}</string>
  <key>MFABuildSHA</key>
  <string>${GIT_SHA}</string>
  <key>MFABuildTime</key>
  <string>${BUILD_TIME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Ghostie sends staged iMessage drafts via Messages.app.</string>
  <key>NSContactsUsageDescription</key>
  <string>Ghostie reads your Contacts to resolve recipient names. The same data Messages.app shows, including iCloud-synced contacts. The exported list is written to ~/.messages-mcp/contacts-cache.json on this Mac and is not uploaded by the app.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.sunriselabs.messages-for-ai.auth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>messagesforai</string>
      </array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 Sunrise Labs. All rights reserved.</string>
  <key>SUFeedURL</key>
  <string>https://messagesfor.ai/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>${SU_PUBLIC_ED_KEY}</string>
  <key>MFAPostHogProjectToken</key>
  <string>${POSTHOG_PROJECT_TOKEN}</string>
  <key>MFAPostHogHost</key>
  <string>${POSTHOG_HOST}</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
</dict>
</plist>
EOF

# ── Embed Sparkle.framework (auto-update) ──
# Must be embedded even in dev or the app won't launch (the menubar binary links
# Sparkle via @executable_path/../Frameworks). Located under .build/artifacts
# (SPM binary artifact). PWD is menubar/ here (cd at the top of the script).
SPARKLE_FW="$(find .build -type d -name Sparkle.framework -path '*xcframework*macos*' 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_FW" || ! -d "$SPARKLE_FW" ]]; then
  echo "✗ Sparkle.framework not found under .build — run 'swift package resolve' first." >&2
  exit 1
fi
echo "› embedding Sparkle.framework"
mkdir -p "${APP}/Contents/Frameworks"
rm -rf "${APP}/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_FW" "${APP}/Contents/Frameworks/Sparkle.framework"

echo "› clearing xattrs"
xattr -cr "$APP"

# Pick a codesigning identity. Order of preference:
#   1. $CODESIGN_IDENTITY (explicit override — bypasses Team ID check;
#      caller's responsibility).
#   2. First `Developer ID Application: ... (<EXPECTED_TEAM_ID>)` cert
#      in the keychain.
#   3. Adhoc (`-`) as a last-resort fallback.
#
# Why this matters: macOS Sequoia silently blocks CNContactStore.
# requestAccess for any adhoc-signed app, regardless of bundle ID,
# Info.plist, or TCC state — verified empirically. A real Developer
# ID cert unblocks it. Adhoc still works for sending iMessages via
# Automation, just not for CNContacts. The CONTACTS_REQUIRE_DEVID env
# var lets a hostile-environment build fail loudly instead of silently
# falling back.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # Match the FULL identity line including the Team ID suffix. This
  # rejects an attacker-planted "Developer ID Application: Victim
  # (FAKEID)" cert because (FAKEID) ≠ (EXPECTED_TEAM_ID).
  SIGN_IDENTITY=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
    | "$AWK" -F\" -v team="$EXPECTED_TEAM_ID" \
        '/Developer ID Application/ && $2 ~ "\\("team"\\)$" {print $2; exit}')
fi

# Script cd's to `menubar/` at line 30 ("$(dirname "$0")/.."), so a
# `$(dirname "$0")/...` path here resolves against the original
# invocation cwd, not the post-cd one — leaving `menubar/scripts/...`
# pointing at a nonexistent `menubar/menubar/scripts/...` path after
# the cd. Pin via PWD (which IS post-cd) instead.
ENTITLEMENTS="$PWD/scripts/messages-for-ai.entitlements"

# Sign the inner Mach-Os explicitly with the bundle's identifier, then
# seal the bundle WITHOUT --deep. See scripts/README.md (Architecture
# section) for the full reasoning — short version: `codesign --deep`
# overrides any --identifier flag on inner Mach-Os and re-derives each
# from its path basename, leaving the menubar binary with Identifier=
# MessagesForAIMenu (path-derived, no reverse-DNS prefix), which TCC
# cannot match against any grant. We need the menubar binary's process
# identity to equal the bundle's CFBundleIdentifier so the FDA grant
# on the .app covers it.
#
# This script signs ONLY the menubar binary + bundle. If the MCP
# binary is already inside the bundle (from a prior repo-root
# dev-install.sh run), the repo-root dev-install.sh re-signs it
# afterwards. We deliberately avoid --deep so that, if the MCP binary
# IS already there, we don't clobber its explicit identifier.

if [[ -n "$SIGN_IDENTITY" ]]; then
  # Defense-in-depth: re-verify Team ID embedded in the chosen identity.
  # The awk filter above already enforces this for auto-detection; a
  # CODESIGN_IDENTITY override skips that filter.
  DETECTED_TEAM=$(echo "$SIGN_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')
  if [[ "$DETECTED_TEAM" != "$EXPECTED_TEAM_ID" ]]; then
    echo "✗ signing identity Team ID '$DETECTED_TEAM' ≠ expected '$EXPECTED_TEAM_ID'" >&2
    echo "  Refusing to sign with an unknown identity." >&2
    exit 1
  fi
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  ADHOC=0
else
  if [[ "${CONTACTS_REQUIRE_DEVID:-}" == "1" ]]; then
    echo "✗ no Developer ID Application cert from team $EXPECTED_TEAM_ID found, but CONTACTS_REQUIRE_DEVID=1" >&2
    echo "  Install one via Xcode → Settings → Accounts → Manage Certificates," >&2
    echo "  then re-run." >&2
    exit 1
  fi
  echo "› no Developer ID cert from team $EXPECTED_TEAM_ID found; falling back to adhoc"
  echo "  ⚠  CNContactStore.requestAccess will fail under adhoc signing —"
  echo "     Contacts resolution will be unavailable until you install a"
  echo "     Developer ID Application cert. Sending iMessages still works."
  SIGN_ARGS=(--force --sign -)
  ADHOC=1
fi

# Sign the menubar binary in place with the bundle's identifier.
echo "› signing menubar binary with --identifier ${BUNDLE_ID}"
"$CODESIGN" "${SIGN_ARGS[@]}" \
  --identifier "${BUNDLE_ID}" --options=runtime \
  "$APP/Contents/MacOS/$EXE_NAME"

# If a sibling MCP binary already lives inside the bundle (from a
# prior repo-root dev-install.sh run), re-sign it too — with the SAME
# bundle identifier — so the bundle seal below validates a consistent
# inner-identifier state. The repo-root dev-install.sh will re-sign
# it again with fresh build output, but signing it here keeps the
# intermediate state valid.
MCP_SIBLING="$APP/Contents/MacOS/imessage-drafts-mcp"
if [[ -x "$MCP_SIBLING" ]]; then
  echo "› re-signing existing MCP sibling with --identifier ${BUNDLE_ID}"
  "$CODESIGN" "${SIGN_ARGS[@]}" \
    --identifier "${BUNDLE_ID}" --options=runtime \
    "$MCP_SIBLING"
fi

# Sign Sparkle.framework inside-out BEFORE the bundle seal. Sparkle's nested code
# keeps its OWN identifiers (no --identifier here), and the seal below is no-deep so
# it won't clobber them. Uses the same SIGN_ARGS (Dev ID or adhoc) + runtime.
SP_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SP_FW" ]]; then
  echo "› signing Sparkle.framework (inside-out)"
  for nested in \
    "Versions/B/XPCServices/Downloader.xpc" \
    "Versions/B/XPCServices/Installer.xpc" \
    "Versions/B/Autoupdate" \
    "Versions/B/Updater.app"; do
    # if/then (not `[[ … ]] && codesign`): under `set -e` the &&-form would SWALLOW
    # a real codesign failure (the && short-circuit isn't an errexit-abort site), so
    # a mis-signed nested component could slip past. if/then lets a failure abort.
    if [[ -e "$SP_FW/$nested" ]]; then
      "$CODESIGN" "${SIGN_ARGS[@]}" --options=runtime "$SP_FW/$nested"
    fi
  done
  "$CODESIGN" "${SIGN_ARGS[@]}" --options=runtime "$SP_FW"
fi

# Seal the bundle. NO --deep — the explicit per-file signing above
# put the right identifiers on each inner Mach-O; --deep would now
# overwrite them.
#
# --entitlements passes the per-feature permissions Hardened Runtime
# requires for Contacts framework access and Apple Events. Without
# the addressbook entitlement, CNContactStore.requestAccess throws
# "Access Denied" synchronously even for Developer-ID-signed apps.
if [[ "$ADHOC" -eq 1 ]]; then
  # Adhoc bundle seal — no entitlements file (adhoc-signed bundles
  # can't claim entitlements that require Apple authorization).
  echo "› sealing .app bundle adhoc"
  "$CODESIGN" "${SIGN_ARGS[@]}" \
    --identifier "${BUNDLE_ID}" --options=runtime "$APP"
else
  echo "› sealing .app bundle with Developer ID + entitlements"
  "$CODESIGN" "${SIGN_ARGS[@]}" \
    --identifier "${BUNDLE_ID}" --options=runtime \
    --entitlements "$ENTITLEMENTS" "$APP"
fi

echo "› verifying signature seal"
if ! "$CODESIGN" --verify --strict --verbose "$APP" 2>&1; then
  echo "✗ codesign --verify failed on $APP" >&2
  exit 1
fi
"$CODESIGN" -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true

# Re-register the bundle with LaunchServices. Without this, `open
# "$APP"` can fail with error -600 (procNotFound) if LaunchServices
# still has the legacy ~/Applications/ path cached — common on machines
# that previously installed there. lsregister with -f forces a refresh
# of the bundle metadata at the new location.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  echo "› refreshing LaunchServices registration"
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

# Add the bundle to Gatekeeper's trusted-apps list. Without this,
# adhoc-signed apps (signature=adhoc, TeamIdentifier=not set) can
# trigger an "Access Denied" rejection from CNContactStore.requestAccess
# even when NSContactsUsageDescription is set and TCC has no recorded
# denial — verified empirically on macOS Sequoia. spctl --add registers
# the path as an approved source, which lets the TCC subsystem trust
# the calling process for sensitive APIs.
echo "› adding to Gatekeeper trusted apps"
spctl --add "$APP" 2>/dev/null || true

# Remove stale app bundles left over from earlier names or install roots. Done
# AFTER the new install succeeds so a failed install never removes the working app.
#
# If a legacy bundle exists, the running instance is probably IT (old-name
# login item) — politely quit before deleting its bundle out from under it,
# with a pkill fallback. Quitting is deliberately scoped to the
# legacy-present case so routine dev re-installs don't kill the app the
# developer is iterating on. Tolerate failure: a quit hiccup must not
# abort an install. (The old SMAppService login-item registration goes
# stale with the old path; LoginItemController re-registers on launch when
# SMAppService reports .notFound.)
LEGACY_PRESENT=0
for LEGACY_APP in "${LEGACY_APPS[@]}"; do
  [[ -d "$LEGACY_APP" && "$LEGACY_APP" != "$APP" ]] && LEGACY_PRESENT=1
done
if [[ "$LEGACY_PRESENT" -eq 1 ]]; then
  echo "› legacy install present — asking any running instance to quit"
  osascript -e 'tell application id "com.sunriselabs.messages-for-ai" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -x "$EXE_NAME" >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -x "$EXE_NAME" 2>/dev/null || true
fi
for LEGACY_APP in "${LEGACY_APPS[@]}"; do
  if [[ -d "$LEGACY_APP" && "$LEGACY_APP" != "$APP" ]]; then
    echo "› removing legacy install at $LEGACY_APP"
    rm -rf "$LEGACY_APP"
  fi
done

echo
echo "installed: $APP"
echo
echo "Next steps:"
echo "  1) Launch:  open \"$APP\""
echo "  2) On the first Send, macOS will prompt to allow ${APP_DISPLAY_NAME} to"
echo "     control Messages.app — click OK."
echo "  3) Open-at-login is on by default — the app auto-registers itself"
echo "     via SMAppService the first time it runs. Toggle off via the"
echo "     popover footer, or via System Settings → General → Login Items."
