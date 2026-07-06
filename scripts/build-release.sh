#!/usr/bin/env bash
#
# Build, sign, and notarize a release of Ghostie, the menubar app
# plus all bundled MCP transports — ready for upload to GitHub Releases.
#
# Output: dist/messages-for-ai-<version>.zip — a self-contained archive
# containing:
#   - Ghostie.app/           (signed + notarized + stapled .app bundle.
#                             Contains the menubar UI binary, one shared Bun
#                             backend, and tiny role launchers at the stable
#                             MCP/daemon command names inside Contents/MacOS/,
#                             all sharing one bundle identifier so a single
#                             FDA grant on the .app covers every inner Mach-O.)
#   - install.sh             (end-user install script that copies the .app
#                             to /Applications/ and creates a backward-
#                             compat symlink at ~/bin/imessage-drafts-mcp)
#   - README.md              (short user-facing readme; full one is in repo)
#
# End users download the zip, extract, and run `bash install.sh`. No
# Xcode, no Developer Account, no rebuild required — Apple's
# notarization handles trust verification at first launch.
#
# ── Why the .app-wrap architecture (vs a bare CLI binary at zip root) ──
# macOS Sequoia tightened TCC: bare CLI binaries can't reliably hold a
# Full Disk Access grant across rebuilds (cdhash changes invalidate
# path-based grants, and tccutil reset can't address them by bundle ID
# because they have none). The fix is to install the backends INSIDE
# the menubar .app bundle, signing every inner Mach-O with the bundle's
# CFBundleIdentifier (`com.sunriselabs.messages-for-ai`). One FDA grant
# on the .app covers every backend. The inner binaries MUST share the
# bundle's identifier — TCC compares the running process's codesign
# Identifier= string to the granted identifier; if they differ, the
# grant doesn't match. Discovered the hard way during v0.2.0 dev.
#
# Usage:
#   bash scripts/build-release.sh <version>   # e.g. v0.2.0
#
# Required environment:
#   - Developer ID Application cert in keychain (auto-detected)
#   - POSTHOG_PROJECT_TOKEN, supplied from your shell/keychain. This is embedded
#     into Info.plist so opt-in product analytics can reach PostHog.
#   - POSTHOG_HOST, optional (default: https://us.i.posthog.com).
#   - Notarytool credentials stored in keychain as profile "ghostie" (the
#     current default; older machines may still carry the legacy
#     "imessage-mcp-notary" profile from the imessage-mcp era).
#     Override via NOTARY_PROFILE env var if your keychain uses a
#     different name. One-time setup:
#       xcrun notarytool store-credentials ghostie \
#         --apple-id <your-apple-id-email> \
#         --team-id <your-team-id> \
#         --password <app-specific-password-from-appleid.apple.com>
#
# Resuming after an Apple notary backlog timeout:
#   The .app's submission UUID is written to $DIST/notarize-app.uuid
#   BEFORE we poll Apple. If `xcrun notarytool wait` times out, you can
#   re-poll without re-uploading (which would burn another ~5-15 min) via:
#     xcrun notarytool wait $(cat dist/notarize-app.uuid) \
#       --keychain-profile ghostie
#   The trap on INT/TERM/EXIT wipes dist/ on abort, so you must save
#   the UUID elsewhere FIRST if you Ctrl-C during the wait. A future
#   refactor (deferred WARNING #14) will add a proper --resume flag.

set -euo pipefail

VERSION="${1:?usage: build-release.sh <version>, e.g. v0.1.1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ghostie}"

# The only Apple Developer Team ID this build accepts. Auto-detected
# certs from a different Team ID will be REJECTED rather than silently
# used — defends against an attacker who plants a Developer ID cert in
# the maintainer's keychain (via malicious npm postinstall, p12 import,
# stolen cert, etc.) and tries to ship attacker-signed releases.
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

# Absolute paths to macOS-system binaries. Defends against PATH-shimmed
# `security` / `codesign` from a compromised dev environment.
SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
AWK=/usr/bin/awk

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
DIST="$REPO_ROOT/dist"
STAGE="$DIST/stage"
RELEASE_NAME="messages-for-ai-$VERSION"

# Env wins; otherwise read the login keychain (stored once via
#   security add-generic-password -a "$USER" -s POSTHOG_PROJECT_TOKEN -w '<token>' -U
# ) so release builds don't depend on a paste.
POSTHOG_PROJECT_TOKEN="${POSTHOG_PROJECT_TOKEN:-$(security find-generic-password -s POSTHOG_PROJECT_TOKEN -w 2>/dev/null || true)}"
POSTHOG_HOST="${POSTHOG_HOST:-https://us.i.posthog.com}"
if [[ ! "$POSTHOG_PROJECT_TOKEN" =~ [^[:space:]] ]]; then
  echo "✗ POSTHOG_PROJECT_TOKEN is required for release builds." >&2
  echo "  Store it once in the keychain (command above) or export it; do not commit it." >&2
  exit 1
fi
if [[ "$POSTHOG_HOST" != https://* ]]; then
  echo "✗ POSTHOG_HOST must start with https:// (got '$POSTHOG_HOST')." >&2
  exit 1
fi
echo "› PostHog token configured"

# Find the Developer ID cert. Filters by EXPECTED_TEAM_ID to refuse
# attacker-planted certs in the same keychain. Fails loudly if no
# matching cert exists — notarized releases REQUIRE Developer ID
# signing; adhoc isn't valid.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
    | "$AWK" -F\" -v team="$EXPECTED_TEAM_ID" \
        '/Developer ID Application/ && $2 ~ "\\("team"\\)$" {print $2; exit}')
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "✗ no 'Developer ID Application' cert from team $EXPECTED_TEAM_ID found." >&2
  echo "  Install one via Xcode → Settings → Accounts → Manage Certificates," >&2
  echo "  or set CODESIGN_IDENTITY=<identity-name> in the environment (bypasses" >&2
  echo "  the team-id filter — caller's responsibility to ensure it's the right cert)." >&2
  exit 1
fi
# Belt-and-suspenders: re-parse the chosen identity's Team ID and
# verify. This catches the CODESIGN_IDENTITY override case.
DETECTED_TEAM=$(echo "$SIGN_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')
if [[ "$DETECTED_TEAM" != "$EXPECTED_TEAM_ID" ]]; then
  echo "✗ signing identity Team ID '$DETECTED_TEAM' ≠ expected '$EXPECTED_TEAM_ID'" >&2
  exit 1
fi
# Print fingerprint so a maintainer auditing build logs can confirm
# which cert in the keychain was selected.
SIGN_HASH=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
  | "$AWK" -v ident="$SIGN_IDENTITY" '$0 ~ ident {print $2; exit}')
echo "› signing identity: $SIGN_IDENTITY"
echo "› identity SHA-1:   $SIGN_HASH"

# Sanity-check that the notarytool credential profile exists before
# spending several minutes on a build that can't be notarized.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ notarytool credentials not found under profile '$NOTARY_PROFILE'." >&2
  echo "  Set up with:" >&2
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
  echo "      --apple-id <your-apple-id> \\" >&2
  echo "      --team-id <your-team-id> \\" >&2
  echo "      --password <app-specific-password>" >&2
  exit 1
fi
echo "› notarytool profile: $NOTARY_PROFILE"

# ── Sparkle update-signing public key (embedded as SUPublicEDKey) ──
# A shippable Sparkle build REQUIRES a real EdDSA public key — without it the app
# can't verify auto-updates. Validate in preflight so we fail before a multi-minute
# build, not after. The private half lives in the maintainer's keychain (used by
# sign_update in release.sh); only the public half is committed.
SU_KEY_FILE="$REPO_ROOT/menubar/scripts/sparkle_public_ed_key.txt"
# A Sparkle EdDSA public key is a 32-byte value → exactly 44 base64 chars ending
# in one '=' (43 + '='). Extract that token from the file with grep so it's
# tolerant of HOW it was pasted: the bare key, a <string>…</string> line, the full
# SUPublicEDKey block, surrounding quotes/whitespace, or comment lines all work.
# The placeholder has '_' (not a base64 char) so it matches nothing → fails closed.
SU_PUBLIC_ED_KEY="$(grep -oE '[A-Za-z0-9+/]{43}=' "$SU_KEY_FILE" 2>/dev/null | head -1)"
if [[ ! "$SU_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "✗ no valid Sparkle public key in $SU_KEY_FILE." >&2
  echo "  Run generate_keys once and paste the printed public key into that file." >&2
  echo "  See the instructions at the top of that file, or RELEASE.md → Auto-update." >&2
  exit 1
fi
echo "› sparkle public key: ${SU_PUBLIC_ED_KEY:0:12}… (SUPublicEDKey)"

rm -rf "$DIST"
mkdir -p "$STAGE/$RELEASE_NAME"

# Abort guard: if anything between here and the final success echo
# exits non-zero (or the user Ctrl-Cs), wipe dist/ so we never leave
# a signed-but-not-notarized binary that looks like a valid release.
# The trap is cleared right before the final success echoes.
# Ignore further SIGINTs inside the cleanup handler so a double-Ctrl-C
# can't half-delete dist/ and leave a signed-but-not-notarized .app
# behind. PR 11 review finding #4.
trap 'rc=$?; trap "" INT TERM; echo; echo "✗ build aborted (exit $rc); wiping $DIST/" >&2; rm -rf "$DIST"' INT TERM EXIT

# ============================================================================
# Build the inner binaries (Bun for each MCP transport, Swift for menubar)
# ============================================================================
#
# No inner binary is signed/notarized separately. We assemble them into
# the .app FIRST, sign each in place with the bundle's identifier, then
# seal+notarize the bundle as one unit. A single notary submission
# covers every inner binary via the bundle's seal.

mkdir -p "$REPO_ROOT/bin"

echo
echo "=== Building shared Bun backend + launchers ==="
BACKEND_BIN_NAME="messages-for-ai-backend"
BACKEND_LAUNCHERS=(
  "ghostie-mcp"
  "imessage-drafts-mcp"
  "imessage-drafts-daemon"
  "whatsapp-drafts-mcp"
  "whatsapp-drafts-daemon"
  "wrapped-generator"
  "texting-analytics-generator"
  "birthday-generator"
)
(
  cd "$REPO_ROOT/mcps/ghostie"
  echo "› bun install"
  bun install
)
(
  cd "$REPO_ROOT/mcps/imessage-drafts"
  echo "› bun install"
  bun install
)
(
  cd "$REPO_ROOT/mcps/whatsapp-drafts"
  echo "› bun install --frozen-lockfile"
  bun install --frozen-lockfile
)
(
  cd "$REPO_ROOT/mcps/wrapped-generator"
  echo "› bun install"
  bun install
)
(
  cd "$REPO_ROOT/mcps/birthday-generator"
  echo "› bun install"
  bun install
)
echo "› bun build --compile (single role-dispatched backend)"
bun build "$REPO_ROOT/mcps/backend-dispatcher/src/index.ts" --compile \
  --outfile "$REPO_ROOT/bin/$BACKEND_BIN_NAME" \
  --external jimp --external sharp \
  --external link-preview-js --external audio-decode
echo "› cc (tiny role launchers)"
/usr/bin/cc -O2 -Wall -Wextra "$REPO_ROOT/scripts/messages-for-ai-launcher.c" \
  -o "$REPO_ROOT/bin/messages-for-ai-launcher"
for launcher in "${BACKEND_LAUNCHERS[@]}"; do
  cp "$REPO_ROOT/bin/messages-for-ai-launcher" "$REPO_ROOT/bin/$launcher"
done
xattr -cr "$REPO_ROOT/bin/$BACKEND_BIN_NAME" "$REPO_ROOT/bin/messages-for-ai-launcher"
for launcher in "${BACKEND_LAUNCHERS[@]}"; do
  xattr -cr "$REPO_ROOT/bin/$launcher"
done

echo
echo "=== Building MessagesForAIMenu (Swift) ==="
cd "$REPO_ROOT/menubar"
echo "› swift build -c release"
# ── macOS build.db disk-I/O artifact tolerance ──
# In long-running shells (e.g. a multi-hour agent session) `swift build` can
# print `accessing build database ".../.build/build.db": disk I/O error` and
# exit NON-ZERO *after* the binary links cleanly ("Build complete!"). It's a
# SwiftPM/SQLite coalition artifact, NOT a compile failure — same family as the
# notarytool 1.1.0 SIGBUS handled later in this script. We rm the prior binary
# first so a stale one can't masquerade as this run's output, tolerate the exit
# code, then REQUIRE that the build produced a fresh binary — a genuine compile
# failure leaves no binary and still aborts.
SWIFT_RELEASE_BIN=".build/release/MessagesForAIMenu"
rm -f "$SWIFT_RELEASE_BIN"
set +e
swift build -c release
SWIFT_BUILD_RC=$?
set -e
if [[ ! -x "$SWIFT_RELEASE_BIN" ]]; then
  echo "✗ swift build did not produce $SWIFT_RELEASE_BIN (exit $SWIFT_BUILD_RC)." >&2
  echo "  This is a real build failure, not the build.db disk-I/O artifact." >&2
  exit 1
fi
if [[ $SWIFT_BUILD_RC -ne 0 ]]; then
  echo "  ⚠ swift build exited $SWIFT_BUILD_RC but linked a fresh binary —"
  echo "  ⚠ proceeding (known macOS build.db disk-I/O artifact, not a compile error)."
fi
cd "$REPO_ROOT"

# Common .app layout variables
APP_NAME="Ghostie"
APP_DISPLAY_NAME="Ghostie"
BUNDLE_ID="com.sunriselabs.messages-for-ai"
EXE_NAME="MessagesForAIMenu"
# Every inner Mach-O the bundle ships. The menubar binary is also the
# CFBundleExecutable; the shared Bun backend is role-dispatched by tiny
# launcher Mach-Os at the stable historical sidecar names.
INNER_BINARIES=(
  "$EXE_NAME"
  "$BACKEND_BIN_NAME"
  "ghostie-mcp"
  "imessage-drafts-mcp"
  "imessage-drafts-daemon"
  "whatsapp-drafts-mcp"
  "whatsapp-drafts-daemon"
  "wrapped-generator"
  "texting-analytics-generator"
  "birthday-generator"
)
APP_PATH="$STAGE/$RELEASE_NAME/$APP_NAME.app"
ENTITLEMENTS="$REPO_ROOT/menubar/scripts/messages-for-ai.entitlements"

MENUBAR_BIN="$REPO_ROOT/menubar/.build/release/$EXE_NAME"
BACKEND_BIN="$REPO_ROOT/bin/$BACKEND_BIN_NAME"
for f in "$MENUBAR_BIN" "$BACKEND_BIN" "$ENTITLEMENTS"; do
  if [[ ! -e "$f" ]]; then
    echo "✗ build artifact missing: $f" >&2
    exit 1
  fi
done
for launcher in "${BACKEND_LAUNCHERS[@]}"; do
  if [[ ! -e "$REPO_ROOT/bin/$launcher" ]]; then
    echo "✗ build artifact missing: $REPO_ROOT/bin/$launcher" >&2
    exit 1
  fi
done

# ============================================================================
# Assemble Ghostie.app
# ============================================================================
#
# All inner Mach-Os live in Contents/MacOS/. CFBundleExecutable is the
# menubar binary (it's what `open Ghostie.app` launches and what
# LaunchServices indexes). The MCP binaries are sidecars — Claude
# Desktop's stdio MCP framework launches them directly by path, never via
# LaunchServices. The WhatsApp daemon is launched by the menubar process
# itself (see WhatsAppDaemonController.swift).
echo
echo "=== Assembling $APP_NAME.app ==="

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$MENUBAR_BIN" "$APP_PATH/Contents/MacOS/$EXE_NAME"
cp "$BACKEND_BIN" "$APP_PATH/Contents/MacOS/$BACKEND_BIN_NAME"
for launcher in "${BACKEND_LAUNCHERS[@]}"; do
  cp "$REPO_ROOT/bin/$launcher" "$APP_PATH/Contents/MacOS/$launcher"
done

# ── Inner-binary coverage guard (added after the v0.3.3 miss) ───────────────
# v0.3.3 shipped without imessage-drafts-daemon: it was absent from the build
# step, the cp step, AND INNER_BINARIES — all three agreed, so checking the
# bundle against INNER_BINARIES alone would NOT have caught it. The independent
# source of truth is the repo layout: every MCP (mcps/*/src/index.ts →
# <dir>-mcp) and every reader daemon (mcps/*/src/daemon/index.ts → <dir>-daemon)
# MUST be bundled + signed. Derive the expected set from that, fail loudly if
# any is unlisted or unbundled, and reject stowaways that would ship unsigned.
echo
echo "=== Verifying inner-binary coverage (repo layout ↔ bundle) ==="
EXPECTED_SIDECARS=()
for mcp_dir in "$REPO_ROOT"/mcps/*/; do
  base=$(basename "$mcp_dir")
  # backend-dispatcher is the shared Bun backend compiled once to
  # messages-for-ai-backend. The historical MCP/daemon/tool names below are
  # tiny native launchers that exec this backend with a role.
  if [[ "$base" == "backend-dispatcher" ]]; then
    EXPECTED_SIDECARS+=("$BACKEND_BIN_NAME")
    continue
  fi
  # Naming isn't uniform across mcps/. The *-drafts backends are MCP servers
  # (src/index.ts → <dir>-mcp) optionally paired with a reader daemon
  # (src/daemon/index.ts → <dir>-daemon). wrapped-generator is NOT a server:
  # it's a one-shot tool whose src/index.ts compiles to a flat <dir> binary
  # (no -mcp suffix), spawned by the menu-bar app. Special-case it so the
  # guard demands `wrapped-generator`, not a nonexistent `wrapped-generator-mcp`.
  if [[ "$base" == "wrapped-generator" ]]; then
    EXPECTED_SIDECARS+=("wrapped-generator")
    [[ -f "$mcp_dir/src/texting-analytics-generator.ts" ]] && EXPECTED_SIDECARS+=("texting-analytics-generator")
    continue
  fi
  # birthday-generator is the same shape as wrapped-generator: a one-shot tool
  # whose src/index.ts compiles to a flat <dir> binary (no -mcp suffix), spawned
  # by the menu-bar app (BirthdayGeneratorController).
  if [[ "$base" == "birthday-generator" ]]; then
    EXPECTED_SIDECARS+=("birthday-generator")
    continue
  fi
  [[ -f "$mcp_dir/src/index.ts" ]]        && EXPECTED_SIDECARS+=("${base}-mcp")
  [[ -f "$mcp_dir/src/daemon/index.ts" ]] && EXPECTED_SIDECARS+=("${base}-daemon")
done
for want in "${EXPECTED_SIDECARS[@]}"; do
  if [[ " ${INNER_BINARIES[*]} " != *" $want "* ]]; then
    echo "✗ '$want' exists in mcps/ but is not in INNER_BINARIES — it would ship" >&2
    echo "  unbuilt/unsigned. Add it to the build step, the cp step, and" >&2
    echo "  INNER_BINARIES (this is the v0.3.3 regression)." >&2
    exit 1
  fi
  if [[ ! -f "$APP_PATH/Contents/MacOS/$want" ]]; then
    echo "✗ '$want' is in INNER_BINARIES but was never copied into the bundle." >&2
    exit 1
  fi
done
for f in "$APP_PATH/Contents/MacOS/"*; do
  name=$(basename "$f")
  if [[ " ${INNER_BINARIES[*]} " != *" $name "* ]]; then
    echo "✗ '$name' is in Contents/MacOS but not in INNER_BINARIES — it would ship" >&2
    echo "  unsigned (the per-file signing loop only covers INNER_BINARIES)." >&2
    exit 1
  fi
done
echo "  ✓ ${#EXPECTED_SIDECARS[@]} repo sidecars bundled; Contents/MacOS matches INNER_BINARIES"

# App icon — generated from the selected Ghostie brand mascot. The .icns must be
# present here or notarization will succeed but the Finder/Dock icon will
# silently fall back to the generic AppKit one (Apple doesn't fail builds
# over missing CFBundleIconFile).
ICON_SRC="$REPO_ROOT/menubar/Assets/MessagesForAI.icns"
if [[ ! -f "$ICON_SRC" ]]; then
  echo "✗ release build requires $ICON_SRC — run \`swift menubar/scripts/generate-app-icon.swift\` first" >&2
  exit 1
fi
cp "$ICON_SRC" "$APP_PATH/Contents/Resources/MessagesForAI.icns"

GHOSTIE_ASSETS_SRC="$REPO_ROOT/menubar/Assets/Ghostie"
if [[ -d "$GHOSTIE_ASSETS_SRC" ]]; then
  rm -rf "$APP_PATH/Contents/Resources/Ghostie"
  mkdir -p "$APP_PATH/Contents/Resources/Ghostie"
  cp "$GHOSTIE_ASSETS_SRC"/*.png "$APP_PATH/Contents/Resources/Ghostie/"
else
  echo "✗ release build requires $GHOSTIE_ASSETS_SRC for the contextual sidebar mark" >&2
  exit 1
fi

# ── Embed Sparkle.framework (auto-update) ──
# SPM delivers Sparkle as a binary XCFramework artifact; a hand-assembled .app
# (not built by Xcode) doesn't auto-embed it, so copy it into Contents/Frameworks.
# The menubar binary links it via @executable_path/../Frameworks (rpath set in
# Package.swift). Located robustly under .build so a Sparkle version bump doesn't
# break the path. Signed (inside-out) in the signing section below.
SPARKLE_FW="$(find "$REPO_ROOT/menubar/.build" -type d -name Sparkle.framework -path '*xcframework*macos*' 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_FW" || ! -d "$SPARKLE_FW" ]]; then
  echo "✗ Sparkle.framework not found under menubar/.build — did 'swift build' resolve Sparkle?" >&2
  echo "  Try: (cd menubar && swift package resolve)" >&2
  exit 1
fi
echo "› embedding Sparkle.framework from ${SPARKLE_FW#$REPO_ROOT/}"
mkdir -p "$APP_PATH/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP_PATH/Contents/Frameworks/Sparkle.framework"

xattr -cr "$APP_PATH"

# CFBundleVersion must be a monotonically increasing integer for Sparkle to
# order updates (CFBundleShortVersionString is the human-facing "0.4.0"; this
# is the build number Sparkle's appcast compares). The git commit count is
# monotonic across the repo's history — every release is cut from a later
# commit than the last — so it's a stable, automatic build number with no
# manual bookkeeping. (Was hardcoded `1`, which would make every release look
# identical to Sparkle.) Falls back to `1` only if git is somehow unavailable.
CFBUNDLE_VERSION=$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo "1")
[[ -n "$CFBUNDLE_VERSION" ]] || CFBUNDLE_VERSION="1"
echo "› CFBundleShortVersionString=${VERSION#v}  CFBundleVersion=$CFBUNDLE_VERSION (git commit count)"
# Persist the EXACT build number so release.sh's appcast <sparkle:version> reuses
# it verbatim instead of recomputing from git (which could drift if HEAD moves
# between this build and the appcast step). This is the Sparkle ordering contract.
echo "$CFBUNDLE_VERSION" > "$DIST/cfbundle-version.txt"

cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>MessagesForAI</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION#v}</string>
  <key>CFBundleVersion</key>
  <string>$CFBUNDLE_VERSION</string>
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
  <string>$SU_PUBLIC_ED_KEY</string>
  <key>MFAPostHogProjectToken</key>
  <string>$POSTHOG_PROJECT_TOKEN</string>
  <key>MFAPostHogHost</key>
  <string>$POSTHOG_HOST</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
</dict>
</plist>
EOF

# ============================================================================
# Sign each inner binary with the BUNDLE's identifier, then seal the
# bundle. DO NOT use --deep on the bundle seal.
# ============================================================================
#
# Why per-file signing instead of `codesign --deep` on the bundle:
# --deep walks every inner Mach-O and re-derives its codesign
# Identifier= from its path basename, OVERWRITING any explicit
# --identifier we'd pass at the bundle level. A launcher could end up
# with Identifier=imessage-drafts-mcp (path-derived, no reverse-DNS
# prefix), breaking peer-auth and confusing TCC-attributed local reads.
#
# Sign each binary individually first; THEN seal the bundle (without
# --deep) so the explicit identifiers stick.

codesign_with_timestamp_retry() {
  local max_attempts=3
  local attempt output rc
  for attempt in $(seq 1 "$max_attempts"); do
    set +e
    output=$("$CODESIGN" "$@" 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      [[ -n "$output" ]] && printf '%s\n' "$output"
      return 0
    fi
    if [[ "$output" == *"timestamp service is not available"* && $attempt -lt $max_attempts ]]; then
      echo "  ⚠ codesign timestamp service unavailable; retrying ($attempt/$max_attempts)..."
      sleep 5
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$rc"
  done
}

echo
echo "=== Signing embedded Sparkle.framework (inside-out, Developer ID + runtime) ==="
# Sign Sparkle's nested code FIRST (XPC services → Autoupdate → Updater.app), then
# the framework itself, then (below) our inner binaries, then the no-deep app seal.
# NOTE: NO --identifier here — Sparkle's components keep their own identifiers
# (org.sparkle-project.*), unlike our inner Mach-Os. NO app entitlements either —
# Sparkle's code isn't Bun and must not inherit the JIT entitlements. --options=runtime
# is required for notarization. (This is the delicate, notarization-only-verifiable part.)
SP_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
for nested in \
  "Versions/B/XPCServices/Downloader.xpc" \
  "Versions/B/XPCServices/Installer.xpc" \
  "Versions/B/Autoupdate" \
  "Versions/B/Updater.app"; do
  if [[ -e "$SP_FW/$nested" ]]; then
    echo "› Sparkle/$nested"
    codesign_with_timestamp_retry --force --timestamp --options=runtime --sign "$SIGN_IDENTITY" "$SP_FW/$nested"
  fi
done
echo "› Sparkle.framework"
codesign_with_timestamp_retry --force --timestamp --options=runtime --sign "$SIGN_IDENTITY" "$SP_FW"

echo
echo "=== Signing inner binaries (all with --identifier $BUNDLE_ID) ==="

for inner in "${INNER_BINARIES[@]}"; do
  echo "› $inner"
  codesign_with_timestamp_retry --force --timestamp --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options=runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP_PATH/Contents/MacOS/$inner"
done

echo
echo "=== Sealing .app bundle (NO --deep — preserves inner identifiers) ==="
codesign_with_timestamp_retry --force --timestamp --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options=runtime \
  --entitlements "$ENTITLEMENTS" \
  "$APP_PATH"

# Defensive check: confirm both inner binaries still report the bundle
# identifier. If a future edit reintroduces --deep, this trips and we
# fail loudly BEFORE shipping a release that would silently break FDA
# on users' machines. We define this as a function and call it at three
# checkpoints: (1) right after the bundle seal, (2) right before
# stapling, and (3) after extracting the final zip — to catch any
# pipeline step (notarization, stapler, ditto, zip) that could
# inadvertently re-derive identifiers.
verify_inner_identifiers() {
  local where="$1"
  local app_path="$2"
  local inner
  for inner in "${INNER_BINARIES[@]}"; do
    local f="$app_path/Contents/MacOS/$inner"
    local got
    got=$("$CODESIGN" -dv --verbose=2 "$f" 2>&1 | sed -nE 's/^Identifier=(.*)$/\1/p' | head -1)
    if [[ "$got" != "$BUNDLE_ID" ]]; then
      echo "✗ [$where] $f reports Identifier='$got', expected '$BUNDLE_ID'." >&2
      echo "  Did someone reintroduce --deep on the bundle seal, or did" >&2
      echo "  notarization/stapling silently re-derive identifiers?" >&2
      echo "  TCC grants on the .app won't cover this binary's process." >&2
      return 1
    fi
  done
  echo "  ✓ [$where] all ${#INNER_BINARIES[@]} inner binaries report Identifier=$BUNDLE_ID"
}

verify_inner_identifiers "post-seal" "$APP_PATH" || exit 1

"$CODESIGN" --verify --strict --verbose=2 "$APP_PATH"

# ============================================================================
# Notarize the .app — ONE submission covers both inner binaries
# ============================================================================
echo
echo "=== Notarizing $APP_NAME.app ==="

NOTARIZE_APP_ZIP="$DIST/notarize-app.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_APP_ZIP"

# Two-step submit-then-wait so we can stash the submission UUID BEFORE
# `wait` blocks. If Apple's notary backlog times us out, a maintainer
# can resume polling against the saved UUID instead of paying another
# upload round-trip — see script header.
#
# Redirect submit output to a file rather than capture via $(...).
# Long-running command substitutions can be killed by some sandboxed
# parent shells (Claude Code's Bash tool reproducibly SIGBUS'd this
# at the 70 MB upload size — see commit message). File-redirect is
# functionally identical for our use but is robust against parent-
# shell quirks.
#
# ── notarytool 1.1.0 SIGBUS in CoreFoundation string formatter ──
# Apple's notarytool 1.1.0 crashes with EXC_BAD_ACCESS / SIGBUS inside
# __CFStringCreateImmutableFunnel3 AFTER the upload completes and
# Apple acknowledges the submission. The crash is in the response-
# printing path, not the upload — Apple's history shows the submission
# even when the local notarytool exits with signal 10. To survive this:
#   1. Wrap `submit` in `set +e` so the script doesn't bail.
#   2. Recover the UUID from the JSON file (happy path) or from
#      `notarytool history` (SIGBUS-after-upload path).
#   3. Poll for status via `info --output-format json` (shorter response
#      strings than `wait`, less likely to trip the formatter bug).
APP_SUBMIT_JSON_FILE="$DIST/notarize-submit.json"
set +e
xcrun notarytool submit "$NOTARIZE_APP_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json \
  --no-wait > "$APP_SUBMIT_JSON_FILE" 2>&1
SUBMIT_RC=$?
set -e

APP_UUID=""
if [[ -s "$APP_SUBMIT_JSON_FILE" ]]; then
  APP_UUID=$(/usr/bin/python3 - "$APP_SUBMIT_JSON_FILE" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("id", ""))
except Exception:
    pass
PY
)
fi

if [[ -z "$APP_UUID" ]]; then
  echo "  ⚠ notarytool submit didn't return a parseable UUID (rc=$SUBMIT_RC)." >&2
  echo "  ⚠ Querying notarytool history for the most recent submission — Apple typically" >&2
  echo "  ⚠ records the upload server-side even when the local notarytool crashes (SIGBUS" >&2
  echo "  ⚠ in CFStringCreateImmutableFunnel3, known notarytool 1.1.0 bug)." >&2
  APP_UUID=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null \
    | /usr/bin/python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    history = data.get("history", [])
    if history:
        print(history[0].get("id", ""))
except Exception:
    pass
')
fi

if [[ -z "$APP_UUID" ]]; then
  echo "✗ could not obtain notarytool submission UUID. submit rc=$SUBMIT_RC." >&2
  echo "  submit output:" >&2
  cat "$APP_SUBMIT_JSON_FILE" >&2
  exit 1
fi
echo "$APP_UUID" > "$DIST/notarize-app.uuid"
if [[ $SUBMIT_RC -ne 0 ]]; then
  echo "  ⚠ notarytool submit rc=$SUBMIT_RC but Apple accepted submission $APP_UUID."
  echo "  ⚠ (Known notarytool 1.1.0 SIGBUS in response-printing path; upload completed.)"
fi
echo "› submission uuid: $APP_UUID"
echo "› (resumable via: xcrun notarytool info $APP_UUID --keychain-profile $NOTARY_PROFILE)"

# Poll for completion via `info --output-format json`. We don't use
# `notarytool wait` because it hits the same response-formatting SIGBUS
# on long responses; `info` returns a short JSON object that the
# formatter handles reliably.
echo "› polling for notarization completion (timeout: 60 min; Apple's queue can backlog)..."
NOTARIZE_STATUS=""
for i in $(seq 1 180); do
  set +e
  INFO_JSON=$(xcrun notarytool info "$APP_UUID" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null)
  INFO_RC=$?
  set -e
  NOTARIZE_STATUS=$(echo "$INFO_JSON" | /usr/bin/python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("status", "Unknown"))
except Exception:
    print("ParseError")
' 2>/dev/null)
  case "$NOTARIZE_STATUS" in
    Accepted)
      echo "  ✓ Accepted (poll $i, ~$((i*20))s)"
      break
      ;;
    "In Progress")
      printf "  · in progress (poll %d, ~%ds)\n" "$i" "$((i*20))"
      sleep 20
      ;;
    Rejected|Invalid)
      echo "✗ notarization $NOTARIZE_STATUS for $APP_UUID" >&2
      xcrun notarytool log "$APP_UUID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
      exit 1
      ;;
    *)
      echo "  ? unrecognized status='$NOTARIZE_STATUS' (info rc=$INFO_RC, poll $i)" >&2
      sleep 20
      ;;
  esac
done

if [[ "$NOTARIZE_STATUS" != "Accepted" ]]; then
  echo "✗ notarization didn't complete within poll timeout. Last status: $NOTARIZE_STATUS" >&2
  echo "  Resume manually: xcrun notarytool info $APP_UUID --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi

echo "› stapling notarization ticket to app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# Re-run the inner-identifier check post-staple. xcrun stapler writes
# the notarization ticket into Contents/CodeResources; in current
# tooling it doesn't touch inner Mach-O signatures, but if a future
# Xcode release changes that behavior we want to catch it here, not in
# user bug reports after the release is in the wild.
verify_inner_identifiers "post-staple" "$APP_PATH" || exit 1

# ============================================================================
# 3. Bundle the release artifact
# ============================================================================
echo
echo "=== Packaging release ==="

# Copy the end-user install script and a short README into the stage dir.
cp "$REPO_ROOT/scripts/install-release.sh" "$STAGE/$RELEASE_NAME/install.sh"
chmod +x "$STAGE/$RELEASE_NAME/install.sh"

cat > "$STAGE/$RELEASE_NAME/README.md" <<'EOF'
# Ghostie release bundle

This archive contains a pre-built, signed, and Apple-notarized macOS app.
No Xcode, no Apple Developer Account, no rebuilding required.

The MCP binaries live inside the .app. The install script creates a
current symlink at `~/bin/ghostie-mcp` for the generalized
facade and a backward-compat symlink at `~/bin/imessage-drafts-mcp` so
existing MCP client configs keep working.

## Install

```sh
bash install.sh
```

The installer will:
- Copy `Ghostie.app` to `/Applications/Ghostie.app`
- Create symlinks at `~/bin/ghostie-mcp` and
  `~/bin/imessage-drafts-mcp` → into the .app
- Remove legacy installs from `~/Applications/` and the old
  `~/bin/imessage-mcp` binary (v0.1.x)
- Refresh LaunchServices so macOS finds the new bundle
- Print next steps for granting Full Disk Access + wiring up Claude Desktop

## What you'll need to do manually after install

1. **Grant Full Disk Access** to **Ghostie.app** so the
   menu-bar-launched daemon can read `chat.db` (your iMessage history):
   - System Settings → Privacy & Security → Full Disk Access
   - Click `+`, navigate to `/Applications`, select
     **`Ghostie`** (the .app, not the inner binary), Open
   - Confirm the toggle is ON

   ⚠️ Drag the **.app bundle itself**, not the inner binary. macOS keys
   FDA grants by the bundle's CFBundleIdentifier
   (`com.sunriselabs.messages-for-ai`); the bundled helpers share that
   identifier for peer-auth and bundle coherence.

2. **Configure Claude Desktop** to use the MCP server. Add to
   `~/Library/Application Support/Claude/claude_desktop_config.json`:
   ```json
   {
     "mcpServers": {
       "ghostie": {
         "command": "/Users/YOUR-USERNAME/bin/ghostie-mcp"
       }
     }
   }
   ```
   The path can be either the symlink (`~/bin/ghostie-mcp`) or
   the direct .app-internal binary
   (`/Applications/Ghostie.app/Contents/MacOS/ghostie-mcp`)
   — they resolve to the same Mach-O.

   Then quit Claude Desktop (Cmd+Q on the menu — NOT just closing the
   window) and reopen.

3. **Launch the menu bar app**: `open "/Applications/Ghostie.app"`
   On first popover open, macOS will prompt for Contacts access — approve it.

After these three steps, in a Claude Desktop chat ask:
> "Call the ghostie_health_check tool from the Ghostie MCP."

You should see the generalized facade plus daemon dependency status.
If you see `permission_denied`, double-check that the .app (not the
inner binary) is in the FDA list. See the full README in the GitHub repo
for the diagnostic walkthrough.
EOF

# Strip any extended attributes / quarantine flags from the stage tree
# before zipping. `ditto -c -k` (which we previously used here) faithfully
# encodes macOS xattrs as AppleDouble `._*` companion files inside the
# zip, which:
#   - bloats the archive
#   - breaks the .app bundle's codesign seal after unzip
#     ("a sealed resource is missing or invalid")
# Modern codesigns are stored in-place — inside the Mach-O for binaries,
# in Contents/_CodeSignature/CodeResources + Contents/CodeResources
# (stapled ticket) for bundles — so clearing xattrs is signature-safe.
xattr -cr "$STAGE/$RELEASE_NAME"

# Zip the stage dir into the release artifact. Using plain `zip` instead
# of `ditto -c -k` because zip doesn't generate AppleDouble files and
# is the universal portable archive format end users expect.
#
# `-y` (store symlinks AS symlinks) is REQUIRED now that Sparkle.framework is
# embedded: a framework's `Versions/Current` (and the top-level Sparkle/
# Resources/Headers) are symlinks. Without `-y`, zip DEREFERENCES them — the
# extracted framework becomes a malformed directory tree, which (a) makes
# `spctl --assess` reject the unzipped app with "bundle format is ambiguous
# (could be app or framework)" and, worse, (b) means Sparkle's own downloaded
# update would install a broken framework. (The notarize zip at the top uses
# `ditto`, which preserves symlinks — that's why notarization passed while this
# release zip's post-extract check failed.)
RELEASE_ZIP="$DIST/$RELEASE_NAME.zip"
echo "› writing $RELEASE_ZIP"
cd "$STAGE"
zip -r -y -q "$RELEASE_ZIP" "$RELEASE_NAME"

# Post-zip verify: ensure the staple still validates on the bundle
# inside the archive. We extract to a temp dir and spctl-assess. If
# this fails, the release zip would Gatekeeper-reject on end-user
# machines — bail out so we don't ship a broken bundle.
echo "› verifying packaged bundle (extract to temp + spctl-assess)"
VERIFY_DIR=$(mktemp -d)
unzip -q "$RELEASE_ZIP" -d "$VERIFY_DIR"
# Third inner-identifier checkpoint — against the EXTRACTED bundle.
# Catches any pipeline step between the in-stage bundle (`$APP_PATH`)
# and the user-facing zip that could have re-derived identifiers
# (ditto, zip, unzip — none currently does, but defense in depth).
EXTRACTED_APP="$VERIFY_DIR/$RELEASE_NAME/$APP_NAME.app"
verify_inner_identifiers "post-zip-extract" "$EXTRACTED_APP" || exit 1

if ! spctl --assess --type execute --verbose=2 "$EXTRACTED_APP" >/dev/null 2>&1; then
  echo "✗ spctl --assess FAILED on the unzipped .app — refusing to ship." >&2
  spctl --assess --type execute --verbose=2 "$EXTRACTED_APP" >&2 || true
  rm -rf "$VERIFY_DIR"
  exit 1
fi
echo "  ✓ Gatekeeper-accepts the bundle"
rm -rf "$VERIFY_DIR"

# Cleanup intermediates. Leaves the release zip and the .uuid file
# (for post-hoc resume / audit) in $DIST.
rm -rf "$STAGE" "$DIST/notarize-app.zip"

# Build succeeded — clear the abort guard so dist/ survives the exit.
trap - INT TERM EXIT

echo
echo "✓ release built: $RELEASE_ZIP"
echo
echo "Next steps:"
echo "  1. Sanity test the bundle locally:"
echo "       cd /tmp && unzip $RELEASE_ZIP && cd $RELEASE_NAME && bash install.sh"
echo "  2. Publish via gh CLI:"
echo "       gh release create $VERSION $RELEASE_ZIP \\"
echo "         --title 'Ghostie $VERSION' \\"
echo "         --notes 'See CHANGELOG / commit history.'"
