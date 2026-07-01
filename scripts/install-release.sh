#!/usr/bin/env bash
#
# End-user installer for the pre-built imessage-drafts-mcp release. This script
# ships INSIDE the release zip — it doesn't rebuild from source. It just
# copies the already-signed-and-notarized artifacts into the conventional
# locations and prints next steps.
#
# If you're a developer building from source, use scripts/dev-install.sh
# and menubar/scripts/dev-install.sh in the repo root instead.

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────

# The only Apple Developer Team ID this installer accepts. If the bundle
# extracted from the release zip was signed by a different Team ID
# (e.g. a phishing-site forged release signed under an attacker's
# Developer ID), the install ABORTS with a clear error rather than
# silently installing the attacker's binary. Override only if you know
# you're testing against a fork.
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

# Absolute paths to macOS-system binaries. Defends against PATH-shimmed
# `codesign` / `spctl` (e.g. a malicious shell rc planting an attacker
# binary on $PATH).
CODESIGN=/usr/bin/codesign
SPCTL=/usr/sbin/spctl

# Resolve script directory (works whether invoked via `bash install.sh`
# from the unzip target, or `./install.sh`). Also normalize with -P
# (physical, follows symlinks) so we have a canonical path for sanity
# checks below.
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd -P )"
cd "$SCRIPT_DIR"

APP_NAME="Ghostie"
OLD_APP_NAME="Messages for AI"
APP_SRC="$SCRIPT_DIR/$APP_NAME.app"
APP_DEST="/Applications/$APP_NAME.app"
OLD_APP_DEST="/Applications/$OLD_APP_NAME.app"
# Inner MCP launcher paths inside the bundle (post-install). The release
# zip ships only the .app — the MCP launchers live inside it. We create
# symlinks under ~/bin so MCP client configs can point at stable paths.
APP_GHOSTIE_MCP_BIN="$APP_DEST/Contents/MacOS/ghostie-mcp"
GHOSTIE_BIN_SYMLINK="$HOME/bin/ghostie-mcp"
APP_MCP_BIN="$APP_DEST/Contents/MacOS/imessage-drafts-mcp"
BIN_SYMLINK="$HOME/bin/imessage-drafts-mcp"
LEGACY_BIN="$HOME/bin/imessage-mcp"   # v0.1.x bare binary; removed below

# ─── Sanity check the archive ───────────────────────────────────────────────

if [[ ! -d "$APP_SRC" ]]; then
  echo "✗ missing $APP_SRC — is the release archive intact?" >&2
  exit 1
fi
if [[ ! -x "$APP_SRC/Contents/MacOS/imessage-drafts-mcp" ]]; then
  echo "✗ missing iMessage MCP launcher at $APP_SRC/Contents/MacOS/imessage-drafts-mcp" >&2
  echo "  (release archive is malformed — the .app should contain the menubar" >&2
  echo "  UI binary and bundled MCP launchers inside Contents/MacOS/)" >&2
  exit 1
fi
if [[ ! -x "$APP_SRC/Contents/MacOS/ghostie-mcp" ]]; then
  echo "✗ missing generalized MCP launcher at $APP_SRC/Contents/MacOS/ghostie-mcp" >&2
  echo "  (release archive is malformed — the .app should contain the generalized" >&2
  echo "  Ghostie MCP launcher inside Contents/MacOS/)" >&2
  exit 1
fi

# ─── Verify the archive's signing identity matches EXPECTED_TEAM_ID ─────────
#
# This is the headline check that defends against a phishing-site
# release. Even if the user is tricked into downloading a malicious
# zip, the bundle inside will have been signed by the attacker's
# Developer ID — its embedded TeamIdentifier won't match ours, and
# this script will refuse to install it. The check runs BEFORE any
# files are copied to destination paths, so a refused install leaves
# the user's existing setup untouched.

echo "=== Verifying release artifact identity ==="

verify_team_id() {
  local target="$1"
  local kind="$2"
  local detected
  detected=$("$CODESIGN" -dv --verbose=2 "$target" 2>&1 | sed -nE 's/^TeamIdentifier=([A-Z0-9]+)$/\1/p' | head -1)
  if [[ -z "$detected" ]]; then
    echo "✗ $kind has no embedded TeamIdentifier — refusing to install." >&2
    echo "  Expected signature from Team ID $EXPECTED_TEAM_ID." >&2
    return 1
  fi
  if [[ "$detected" != "$EXPECTED_TEAM_ID" ]]; then
    echo "✗ $kind is signed by Team ID '$detected', expected '$EXPECTED_TEAM_ID'." >&2
    echo "  This release zip may be a forgery — REFUSING to install." >&2
    echo "  If you intentionally built from a fork, set EXPECTED_TEAM_ID=$detected." >&2
    return 1
  fi
  # Run the actual seal verification too. `codesign --verify` walks the
  # binary and checks every signed component against the embedded code
  # directory. A passing exit code means the contents match the signature.
  if ! "$CODESIGN" --verify --strict --verbose "$target" >/dev/null 2>&1; then
    echo "✗ $kind failed codesign --verify (seal is corrupted or modified)." >&2
    return 1
  fi
  echo "  ✓ $kind: Team $detected, seal intact"
}

verify_team_id "$APP_SRC" "$APP_NAME.app" || exit 1
verify_team_id "$APP_SRC/Contents/MacOS/ghostie-mcp" "generalized MCP launcher" || exit 1
# Also verify the iMessage MCP launcher is sealed by the same Team. The .app
# verify above would catch a missing/corrupt inner Mach-O via the seal,
# but checking explicitly here gives a clearer error if someone shipped
# a release zip with a stale or unsigned launcher.
verify_team_id "$APP_SRC/Contents/MacOS/imessage-drafts-mcp" "iMessage MCP launcher" || exit 1

# Gatekeeper-assess the .app. This is the system's own "would I allow
# this app to run?" check, which incorporates notarization status.
echo "› Gatekeeper assess on $APP_NAME.app"
if ! "$SPCTL" --assess --type execute "$APP_SRC" 2>&1; then
  echo "✗ Gatekeeper rejected $APP_SRC — refusing to install." >&2
  exit 1
fi

echo "=== Installing $APP_NAME ==="

# ─── Menu bar app (with embedded MCP launchers) → /Applications/ ────────────

echo
echo "› $APP_DEST"
if [[ ! -w "/Applications" ]]; then
  echo "✗ /Applications is not writable by $USER." >&2
  echo "  Either re-run this script with sudo, or install the app to your" >&2
  echo "  per-user folder manually: cp -R \"$APP_SRC\" ~/Applications/" >&2
  exit 1
fi

# Stage the new bundle BEFORE touching the existing install. This way,
# an interrupted install (OOM kill, power loss, codesign --verify
# failure between ditto and verify) doesn't leave the user with no
# Ghostie.app at all. The previous install + its FDA grant
# survive on /Applications/ until the atomic swap below.
APP_DEST_NEW="${APP_DEST}.new.$$"
APP_DEST_OLD="${APP_DEST}.old.$$"

# EXIT/INT/TERM trap: roll back to the prior install if anything below
# fails before we explicitly clear the trap. The trap is idempotent and
# safe to run when there's nothing to clean up (mv/rm with missing paths
# noop silently when 2>/dev/null).
trap 'rc=$?; trap "" INT TERM EXIT;
      rm -rf "$APP_DEST_NEW" 2>/dev/null;
      if [[ -d "$APP_DEST_OLD" ]]; then
        rm -rf "$APP_DEST" 2>/dev/null;
        mv "$APP_DEST_OLD" "$APP_DEST" 2>/dev/null && \
          echo "  ↩ rolled back to prior install at $APP_DEST" >&2;
      fi;
      exit $rc' INT TERM EXIT

# 1. Copy to the staging path. Doesn't touch the live install yet.
ditto "$APP_SRC" "$APP_DEST_NEW"

# 2. Re-verify the seal on the staged copy. ditto preserves attributes
#    but the bytes are different files now, so this is a separate
#    signature check from the one we did on the source.
if ! "$CODESIGN" --verify --strict --verbose "$APP_DEST_NEW" >/dev/null 2>&1; then
  echo "✗ post-copy codesign --verify failed on staged $APP_DEST_NEW" >&2
  exit 1
fi
echo "  ✓ staged copy seal verified"

# Politely quit any running instance BEFORE swapping bundles or removing
# the legacy install. The old-named app ("Messages for AI") is typically
# running as a login item; rm -rf'ing a running app's bundle leaves a
# zombie process executing deleted code (plus the daemons it spawned)
# and confuses TCC/LaunchServices. Both names share the bundle id
# com.sunriselabs.messages-for-ai, so one AppleEvent reaches whichever
# is running. Fall back to pkill on the executable name; tolerate
# failure throughout — a quit hiccup must never abort an install.
echo "› asking any running instance to quit"
osascript -e 'tell application id "com.sunriselabs.messages-for-ai" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  pgrep -x "MessagesForAIMenu" >/dev/null 2>&1 || break
  sleep 1
done
pkill -x "MessagesForAIMenu" 2>/dev/null || true

# Login-item note: the old app registered open-at-login via SMAppService
# from "/Applications/Messages for AI.app". Removing that bundle leaves
# the registration stale (System Settings → Login Items may show a
# "Messages for AI" entry that points nowhere). The new app self-heals on
# launch — LoginItemController re-registers when SMAppService reports
# .notFound — but if macOS keeps a ghost row in Login Items, the user can
# remove it manually; it's cosmetic only.

# 3. Move the live install aside, then rename the staged copy into
#    place. Two rename(2) calls on the same filesystem — neither is
#    individually atomic but the window between them is microseconds.
#    The trap above rolls back if the second rename fails.
if [[ -d "$APP_DEST" ]]; then
  mv "$APP_DEST" "$APP_DEST_OLD"
fi
mv "$APP_DEST_NEW" "$APP_DEST"

# 4. Success — clear the rollback trap, then sweep the .old.
trap - INT TERM EXIT
if [[ -d "$APP_DEST_OLD" ]]; then
  rm -rf "$APP_DEST_OLD"
fi
echo "  ✓ install atomically swapped into $APP_DEST"

# Remove stale app bundles left over from earlier names or install roots.
LEGACY_APPS=(
  "$HOME/Applications/$APP_NAME.app"
  "$HOME/Applications/$OLD_APP_NAME.app"
  "$OLD_APP_DEST"
)
for LEGACY_APP in "${LEGACY_APPS[@]}"; do
  if [[ -d "$LEGACY_APP" && "$LEGACY_APP" != "$APP_DEST" ]]; then
    echo "  › removing legacy install at $LEGACY_APP"
    rm -rf "$LEGACY_APP"
  fi
done

# ─── MCP symlinks under ~/bin ───────────────────────────────────────────────
#
# MCP client configs that point at ~/bin/imessage-drafts-mcp (the v0.2.0
# documentation default, or a config carried over from a pre-.app-wrap
# build) keep working — the symlink resolves to the .app-internal
# binary at exec time. TCC sees the binary's actual path inside the
# .app and applies the bundle's grant.
#
# We also nuke the v0.1.x bare binary at ~/bin/imessage-mcp (if it's
# present) since it's a different binary that doesn't share the new
# bundle's TCC identity — leaving it around just confuses
# Claude Desktop configs that haven't been migrated yet.

echo
echo "› ~/bin/ghostie-mcp → $APP_GHOSTIE_MCP_BIN"
mkdir -p "$HOME/bin"
ln -sfn "$APP_GHOSTIE_MCP_BIN" "$GHOSTIE_BIN_SYMLINK"

echo "› ~/bin/imessage-drafts-mcp → $APP_MCP_BIN  (backward-compat symlink)"
ln -sfn "$APP_MCP_BIN" "$BIN_SYMLINK"

# Remove the legacy v0.1.x entry at ~/bin/imessage-mcp unconditionally
# if anything is there — regular file, symlink, or dangling symlink.
# `rm -f` on a symlink unlinks the symlink itself (it does not follow
# to the target), so this is safe even if a malicious symlink was
# planted there. `-L` catches symlinks before `-e` (which follows
# symlinks and returns false on dangling ones), so we cover all three
# of: regular file, valid symlink, dangling symlink.
if [[ -L "$LEGACY_BIN" || -e "$LEGACY_BIN" ]]; then
  echo "  › removing legacy v0.1.x entry at $LEGACY_BIN"
  rm -f "$LEGACY_BIN"
fi

# ─── Refresh LaunchServices ────────────────────────────────────────────────
# So `open` finds the new bundle (otherwise the cached path can win and
# `open` returns error -600).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
fi

# ─── Smoke test ─────────────────────────────────────────────────────────────

echo
smoke_mcp() {
  local label="$1"
  local bin="$2"
  local output
  output=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-smoke","version":"0"}}}' | "$bin" 2>&1 | head -1)
  if echo "$output" | grep -q '"serverInfo"'; then
    echo "  ✓ $label responds to initialize"
    return 0
  fi
  echo "✗ smoke test failed — $label did not respond" >&2
  echo "  with a valid initialize. Bundle copy succeeded; the bundle" >&2
  echo "  is at $APP_DEST, but it is not functional. NOT printing" >&2
  echo "  the 'Install complete' banner because the install is broken." >&2
  echo "  stdout: $output" >&2
  exit 1
}

echo "› smoke test (initialize calls against MCP binaries)"
smoke_mcp "ghostie-mcp" "$APP_GHOSTIE_MCP_BIN"
smoke_mcp "imessage-drafts-mcp" "$APP_MCP_BIN"

# ─── Next steps printout ────────────────────────────────────────────────────

cat <<EOF

==================================================================
✓ Install complete. Bundle signed by Team $EXPECTED_TEAM_ID, seal verified.

Three things you need to do manually:

1. GRANT FULL DISK ACCESS to **Ghostie.app** so the
   menu-bar-launched daemon can read chat.db (your iMessage history):

     System Settings → Privacy & Security → Full Disk Access
     Click "+" → navigate to /Applications → select "Ghostie"
     (the .app, NOT the inner binary) → Open → confirm toggle is ON

   IMPORTANT: drag the .app itself, not the inner Mach-O. macOS keys
   FDA grants by the bundle's CFBundleIdentifier
   (com.sunriselabs.messages-for-ai); the bundled helpers share that
   identifier so one .app-level grant covers the bundled helpers.

   Upgrading from Messages for AI? Your existing grant carries over
   (same bundle id and signing identity). The Full Disk Access row may
   still be named "Messages for AI"; that row IS Ghostie's grant, so
   just confirm its toggle is ON. No need to add a second row.

2. CONFIGURE CLAUDE DESKTOP to use the MCP. Edit:

     ~/Library/Application Support/Claude/claude_desktop_config.json

   Add (or merge into existing mcpServers):

     {
       "mcpServers": {
         "ghostie": {
           "command": "$GHOSTIE_BIN_SYMLINK"
         },
         "imessage-drafts": {
           "command": "$BIN_SYMLINK"
         }
       }
     }

   The paths can be either the symlinks under ~/bin or the direct
   .app-internal binaries — they resolve to the same Mach-Os.

   Then quit Claude Desktop entirely (Cmd+Q on the Claude menu, NOT
   just closing the window) and reopen it.

3. LAUNCH THE MENU BAR APP:

     open "$APP_DEST"

   On first popover open, macOS will ask:
    "Ghostie Would Like to Access Your Contacts"
   Click OK. The app populates a sidecar (~/.messages-mcp/contacts-cache.json)
   that the MCP reads to resolve recipient names.

After these three steps, in a Claude Desktop chat ask:
   "Call the ghostie_health_check tool from the Ghostie MCP."
You should see the generalized facade plus daemon dependency status.
If you see permission_denied, double-check that **Ghostie.app**
(not the inner binary) is in the FDA list and toggled ON.
==================================================================
EOF
