#!/usr/bin/env bash
#
# Build, sign, notarize, and staple the polished drag-to-install .dmg
# for a Ghostie release.
#
# Runs AFTER scripts/build-release.sh has produced the notarized .zip
# in dist/. Extracts the .app from that zip, wraps it in a create-dmg
# layout (drag-to-Applications), signs + notarizes + staples the .dmg,
# and outputs dist/Ghostie.dmg.
#
# The output filename is stable (no version suffix) so the marketing
# site's /releases/latest/download/Ghostie.dmg URL works without
# touching site/index.html on every release. The legacy
# Messages-for-AI.dmg download path still redirects (site/vercel.json)
# so older links keep working.
#
# Usage:
#   bash scripts/build-dmg.sh <version>   # e.g. v0.3.2.1
#
# Required environment / state:
#   - scripts/build-release.sh has already run for the same VERSION;
#     dist/messages-for-ai-<version>.zip exists.
#   - create-dmg is installed (brew install create-dmg) — script will
#     auto-install if missing.
#   - Developer ID Application cert in keychain (auto-detected by
#     filter on Team ID).
#   - Notarytool keychain profile (override via NOTARY_PROFILE env var).

set -euo pipefail

VERSION="${1:?usage: build-dmg.sh <version>, e.g. v0.3.2.1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-imessage-mcp-notary}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
AWK=/usr/bin/awk

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
DIST="$REPO_ROOT/dist"
RELEASE_NAME="messages-for-ai-$VERSION"
RELEASE_ZIP="$DIST/$RELEASE_NAME.zip"
STAGE="$DIST/dmg-stage"
DMG="$DIST/Ghostie.dmg"
APP_NAME="Ghostie"

if [[ ! -f "$RELEASE_ZIP" ]]; then
  echo "✗ release zip not found: $RELEASE_ZIP" >&2
  echo "  Run scripts/build-release.sh $VERSION first." >&2
  exit 1
fi

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
    | "$AWK" -F\" -v team="$EXPECTED_TEAM_ID" \
        '/Developer ID Application/ && $2 ~ "\\("team"\\)$" {print $2; exit}')
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "✗ no 'Developer ID Application' cert from team $EXPECTED_TEAM_ID found." >&2
  exit 1
fi
echo "› signing identity: $SIGN_IDENTITY"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ notarytool credentials not found under profile '$NOTARY_PROFILE'." >&2
  exit 1
fi
echo "› notarytool profile: $NOTARY_PROFILE"

if ! command -v create-dmg >/dev/null; then
  echo "› installing create-dmg via brew"
  brew install create-dmg
fi

echo
echo "=== Extracting notarized .app from $RELEASE_ZIP ==="
rm -rf "$STAGE"
mkdir -p "$STAGE"
TMP_UNZIP=$(mktemp -d)
unzip -q "$RELEASE_ZIP" "$RELEASE_NAME/$APP_NAME.app/*" -d "$TMP_UNZIP"
mv "$TMP_UNZIP/$RELEASE_NAME/$APP_NAME.app" "$STAGE/"
rm -rf "$TMP_UNZIP"
xcrun stapler validate "$STAGE/$APP_NAME.app" >/dev/null
echo "  ✓ stapled ticket survived the extract"

echo
echo "=== Building polished .dmg (create-dmg) ==="
rm -f "$DMG"
# Window + icon coordinates picked to look right on a 640x380 default-
# size DMG window. Background image is a v0.3.3+ polish item — needs a
# designed PNG with a drag-arrow visual. Layout is correct without it.
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 640 380 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 160 180 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 480 180 \
  --no-internet-enable \
  "$DMG" \
  "$STAGE"

echo
echo "=== Signing .dmg ==="
"$CODESIGN" --sign "$SIGN_IDENTITY" --options runtime --timestamp "$DMG"

echo
echo "=== Notarizing .dmg (Apple round-trip, ~2-15 min depending on queue) ==="
# Same notarytool 1.1.0 SIGBUS-survival flow as scripts/build-release.sh:
# wrap submit in `set +e`, recover UUID from history if the local crash
# blanks the JSON, poll via `info` instead of relying on `--wait`.
NOTARIZE_DMG_JSON="$DIST/notarize-dmg.json"
set +e
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json \
  --no-wait > "$NOTARIZE_DMG_JSON" 2>&1
SUBMIT_RC=$?
set -e

DMG_UUID=""
if [[ -s "$NOTARIZE_DMG_JSON" ]]; then
  DMG_UUID=$(/usr/bin/python3 - "$NOTARIZE_DMG_JSON" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("id", ""))
except Exception:
    pass
PY
)
fi

if [[ -z "$DMG_UUID" ]]; then
  echo "  ⚠ notarytool submit didn't return a parseable UUID (rc=$SUBMIT_RC)." >&2
  echo "  ⚠ Querying notarytool history (notarytool 1.1.0 SIGBUS workaround)." >&2
  DMG_UUID=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null \
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

if [[ -z "$DMG_UUID" ]]; then
  echo "✗ could not obtain DMG submission UUID. submit rc=$SUBMIT_RC." >&2
  cat "$NOTARIZE_DMG_JSON" >&2
  exit 1
fi
echo "$DMG_UUID" > "$DIST/notarize-dmg.uuid"
echo "› submission uuid: $DMG_UUID"

# Poll for completion via `info --output-format json` (short response,
# sidesteps the SIGBUS that hits `--wait`).
echo "› polling for DMG notarization completion (timeout: 60 min)..."
DMG_STATUS=""
for i in $(seq 1 180); do
  set +e
  INFO_JSON=$(xcrun notarytool info "$DMG_UUID" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null)
  set -e
  DMG_STATUS=$(echo "$INFO_JSON" | /usr/bin/python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("status", "Unknown"))
except Exception:
    print("ParseError")
' 2>/dev/null)
  case "$DMG_STATUS" in
    Accepted)
      echo "  ✓ Accepted (poll $i, ~$((i*20))s)"
      break
      ;;
    "In Progress")
      printf "  · in progress (poll %d, ~%ds)\n" "$i" "$((i*20))"
      sleep 20
      ;;
    Rejected|Invalid)
      echo "✗ DMG notarization $DMG_STATUS for $DMG_UUID" >&2
      xcrun notarytool log "$DMG_UUID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
      exit 1
      ;;
    *)
      echo "  ? unrecognized status='$DMG_STATUS' (poll $i)" >&2
      sleep 20
      ;;
  esac
done

if [[ "$DMG_STATUS" != "Accepted" ]]; then
  echo "✗ DMG notarization didn't complete within poll timeout. Last status: $DMG_STATUS" >&2
  echo "  Resume manually: xcrun notarytool info $DMG_UUID --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi

echo
echo "=== Stapling notarization ticket ==="
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | head -3

# Cleanup the stage dir; leave the .dmg + notarize JSON for audit.
rm -rf "$STAGE"

echo
echo "✓ polished .dmg built: $DMG"
echo
echo "Next steps:"
echo "  1. Upload to the GitHub release:"
echo "       gh release upload $VERSION $DMG"
echo "  2. The marketing site at messagesfor.ai pulls from"
echo "       /releases/latest/download/Ghostie.dmg"
echo "     so as long as this asset is attached to the latest release,"
echo "     the Download button stays current."
