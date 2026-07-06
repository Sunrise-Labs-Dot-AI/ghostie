#!/usr/bin/env bash
#
# release.sh <version> — one command to ship a Ghostie release.
#
# Ships BOTH channels from a single version (lockstep, option A):
#   • the notarized .app  → GitHub Release (.zip + stable-named .dmg)
#   • the Claude Code plugin (skills) → published by the git tag itself;
#     users pull it via `/plugin marketplace update`
#
# What it does, in order:
#   1. Preflight  — clean tree, on main, tag is new, gh authed, signing
#                   identity present. Fails fast with plain-English errors.
#   2. Bump       — scripts/bump-version.sh sets plugin + MCP versions.
#   3. Commit     — "chore: release vX.Y.Z" (so the tag points at the bump).
#   4. Build .app — scripts/build-release.sh (compile, sign, notarize, staple).
#   5. Build .dmg — scripts/build-dmg.sh (drag-to-install, notarized).
#   6. Push       — push the commit + the new tag to origin.
#   7. Publish    — gh release create (metadata), then a BEST-EFFORT asset
#                   upload (.zip + Ghostie.dmg). GitHub assets are NOT on the
#                   user-facing path — public downloads + Sparkle updates come
#                   from the Vercel Blob mirror (7a/7b) on a different host — so
#                   a flaky uploads.github.com never blocks the release.
#   7a. Mirror    — upload .zip + .dmg to Vercel Blob, write download.json.
#   7b. Appcast   — sign the zip, append the Sparkle <item>, redeploy the feed.
#
# Usage:
#   bash scripts/release.sh v0.3.4              # full release
#   bash scripts/release.sh v0.3.4 --dry-run    # preflight + plan, no changes
#   bash scripts/release.sh v0.3.4 --resume     # re-run ONLY publish (7/7a/7b)
#
# --resume recovers a release that built, tagged, and pushed but died during
# publish (e.g. a transient uploads.github.com TLS error). It skips the bump,
# build, notarize, tag, and push and re-runs the publish steps idempotently —
# requires tag vX.Y.Z to already exist and HEAD == origin/<branch>.
#
# Env overrides:
#   NOTARY_PROFILE   keychain profile name (default: ghostie)
#   RELEASE_BRANCH   branch releases must run from (default: main)
#   POSTHOG_PROJECT_TOKEN  required for shippable product analytics
#   POSTHOG_HOST     PostHog capture host (default: https://us.i.posthog.com)
#
# Solo-operator notes: see RELEASE.md for the one-time setup (certs, notary
# profile) and the full runbook.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Args ────────────────────────────────────────────────────────────────
RAW=""
DRY_RUN=0
RESUME=0
# Parse explicitly: a typo'd flag like --dryrun must FAIL, not silently fall
# through to a live release. The version is the sole positional argument.
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --resume)  RESUME=1 ;;
    --*)       echo "release.sh: unknown option: $a" >&2; exit 1 ;;
    *)
      [ -z "$RAW" ] || { echo "release.sh: unexpected extra argument '$a' (already have version '$RAW')" >&2; exit 1; }
      RAW="$a"
      ;;
  esac
done
if [ -z "$RAW" ]; then
  echo "usage: release.sh <version> [--dry-run] [--resume]   (e.g. v0.3.4)" >&2
  exit 1
fi

VNUM="${RAW#v}"          # 0.3.4
VTAG="v${VNUM}"          # v0.3.4 — build scripts + git tag use this form
RELEASE_BRANCH="${RELEASE_BRANCH:-main}"
RELEASE_ZIP="dist/messages-for-ai-${VTAG}.zip"
RELEASE_DMG="dist/Ghostie.dmg"

if ! [[ "$VNUM" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "✗ '$RAW' is not a valid version. Expected like v0.3.4 or v0.3.3.1." >&2
  exit 1
fi

step()  { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
ok()    { printf '  ✓ %s\n' "$1"; }
die()   { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

stat_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

# Echo the CFBundleShortVersionString of the .app inside a DMG (empty on any
# failure). Mounts read-only/-nobrowse/-noautoopen and ALWAYS detaches. Used to
# catch a stale stable-named dist/Ghostie.dmg on --resume — the zip is
# version-named so its filename already binds it, but the DMG name is fixed.
dmg_short_version() {
  local dmg="$1" mnt plist ver=""
  mnt="$(mktemp -d "/tmp/ghostie-dmg-verify.XXXXXX")" || return 0
  if ! hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -mountpoint "$mnt" >/dev/null 2>&1; then
    rmdir "$mnt" 2>/dev/null || true
    return 0
  fi
  plist="$(/usr/bin/find "$mnt" -maxdepth 3 -path '*.app/Contents/Info.plist' 2>/dev/null | head -1)"
  [ -n "$plist" ] && ver="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true)"
  hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
  rmdir "$mnt" 2>/dev/null || true
  printf '%s' "$ver"
}

require_public_artifact() {
  local url="$1"
  local expected_size="$2"
  local expected_sha256="$3"
  local label="$4"
  local headers status length tmp actual_size actual_sha256

  headers="$(curl -sSIL --max-time 30 "$url" 2>/dev/null)" \
    || die "$label is not reachable at $url"
  status="$(printf '%s\n' "$headers" | awk '/^HTTP\// { code=$2 } END { print code }')"
  [ "$status" = "200" ] || [ "$status" = "206" ] \
    || die "$label returned HTTP $status at $url"
  length="$(printf '%s\n' "$headers" | awk 'BEGIN{IGNORECASE=1} /^content-length:/ { gsub("\r", "", $2); value=$2 } END { print value }')"
  [ "$length" = "$expected_size" ] \
    || die "$label content-length $length did not match expected $expected_size"

  tmp="$(mktemp "/tmp/messages-for-ai-${label//[^A-Za-z0-9]/-}.XXXXXX")"
  curl -fsSL --retry 3 --max-time 300 "$url" -o "$tmp" \
    || die "$label could not be downloaded for sha256 verification"
  actual_size="$(stat_size "$tmp")"
  actual_sha256="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  rm -f "$tmp"

  [ "$actual_size" = "$expected_size" ] \
    || die "$label downloaded size $actual_size did not match expected $expected_size"
  [ "$actual_sha256" = "$expected_sha256" ] \
    || die "$label sha256 $actual_sha256 did not match expected $expected_sha256"
  ok "$label reachable publicly and sha256 verified"
}

require_public_download_flow() {
  # site/.vercel can silently end up linked to a sibling project (it did once:
  # texting-wrapped-landing-page took a v0.6.0 prod deploy meant for
  # messagesfor.ai). Refuse to deploy through the wrong link.
  local expected_project="messages-for-ai-marketing-site"
  local linked_project
  linked_project="$(python3 -c 'import json; print(json.load(open("site/.vercel/project.json")).get("projectName", ""))' 2>/dev/null || true)"
  [ "$linked_project" = "$expected_project" ] \
    || die "site/ is vercel-linked to '${linked_project:-<unlinked>}', expected '$expected_project'. Fix with: (cd site && vercel link --yes --project $expected_project)"

  (cd site && npm run test:downloads >/dev/null) \
    || die "site download contract check failed"

  if (cd site && vercel deploy --prod >/dev/null 2>&1); then
    ok "site redeployed (vercel)"
  else
    die "vercel deploy failed — messagesfor.ai/appcast.xml and /api/download were not updated."
  fi

  (cd site && npm run test:downloads:live >/dev/null) \
    || die "live download smoke test failed after deploy"
  ok "live download smoke test passed"
}

# ── 1. Preflight ─────────────────────────────────────────────────────────
step "Preflight checks for $VTAG"

# Release secrets: env wins; otherwise fall back to the login keychain, like
# the notary profile. Store/update once with:
#   security add-generic-password -a "$USER" -s POSTHOG_PROJECT_TOKEN -w '<token>' -U
#   security add-generic-password -a "$USER" -s BLOB_READ_WRITE_TOKEN  -w '<token>' -U
keychain_secret() { security find-generic-password -s "$1" -w 2>/dev/null || true; }
POSTHOG_PROJECT_TOKEN="${POSTHOG_PROJECT_TOKEN:-$(keychain_secret POSTHOG_PROJECT_TOKEN)}"
BLOB_READ_WRITE_TOKEN="${BLOB_READ_WRITE_TOKEN:-$(keychain_secret BLOB_READ_WRITE_TOKEN)}"
export POSTHOG_PROJECT_TOKEN BLOB_READ_WRITE_TOKEN

POSTHOG_HOST="${POSTHOG_HOST:-https://us.i.posthog.com}"
# PostHog is consumed only by the .app build (build-release.sh). --resume skips
# the build, so don't require it then.
if [ "$RESUME" = "0" ]; then
  [[ "$POSTHOG_PROJECT_TOKEN" =~ [^[:space:]] ]] || \
    die "POSTHOG_PROJECT_TOKEN is required for release builds. Store it once: security add-generic-password -a \"\$USER\" -s POSTHOG_PROJECT_TOKEN -w '<token>' -U"
  [[ "$POSTHOG_HOST" == https://* ]] || \
    die "POSTHOG_HOST must start with https:// (got '$POSTHOG_HOST')."
  ok "PostHog token configured"
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$RELEASE_BRANCH" ] || \
  die "You're on '$CURRENT_BRANCH'. Releases run from '$RELEASE_BRANCH'. Merge your PRs, switch to $RELEASE_BRANCH, then re-run. (Override: RELEASE_BRANCH=$CURRENT_BRANCH)"
ok "on $RELEASE_BRANCH"

# Gate on TRACKED changes only — the release commit is built from tracked
# state, so staged/modified tracked files are the real hazard. Untracked
# files (leftover artifacts, a stray dir from another branch) are surfaced
# as a warning below but don't block.
if [ "$RESUME" = "1" ]; then
  # --resume re-runs only the publish steps, which rewrite + commit
  # site/download.json and site/appcast.xml themselves. Those two may be
  # legitimately dirty from a prior partial publish; any OTHER tracked change
  # is still a hazard.
  # Anchor on the 2-char porcelain status + space so this exempts ONLY the
  # repo-root site/download.json + site/appcast.xml, not e.g. foo/site/download.json.
  UNEXPECTED_DIRTY="$(git status --porcelain=v1 --untracked-files=no | grep -v -E '^.. (site/download\.json|site/appcast\.xml)$' || true)"
  [ -z "$UNEXPECTED_DIRTY" ] || \
    die "You have uncommitted changes to tracked files beyond the publish-managed site/download.json + site/appcast.xml. Commit or stash them first."
  ok "no unexpected uncommitted tracked changes (resume)"
else
  [ -z "$(git status --porcelain --untracked-files=no)" ] || \
    die "You have uncommitted changes to tracked files. Commit or stash them first — the release commit must be clean."
  ok "no uncommitted tracked changes"
fi

UNTRACKED="$(git status --porcelain --untracked-files=all | grep '^??' || true)"
if [ -n "$UNTRACKED" ]; then
  printf '  \033[33m⚠ untracked files present (not blocking, but worth a look):\033[0m\n'
  echo "$UNTRACKED" | sed 's/^?? /      /'
fi

if [ "$RESUME" = "1" ]; then
  # --resume decides what to publish off origin's state, so a stale
  # remote-tracking ref is dangerous (HEAD could falsely look up-to-date). The
  # non-resume path stays tolerant — it only warns, then a real divergence is
  # caught by the push.
  git fetch origin "refs/heads/$RELEASE_BRANCH:refs/remotes/origin/$RELEASE_BRANCH" --tags --quiet \
    || die "Couldn't fetch origin/$RELEASE_BRANCH — refusing --resume against stale remote state. Fix your network/remote, then re-run."
else
  git fetch origin --quiet || true
fi
if [ "$RESUME" = "1" ]; then
  # The original run already committed + pushed the release commit, so HEAD must
  # match origin exactly. If it doesn't, the build artifacts and the published
  # tag could disagree — bail rather than mirror the wrong bytes.
  LOCAL_HEAD="$(git rev-parse HEAD)"
  # --verify --quiet yields empty (not the literal ref) when origin/<branch>
  # can't be resolved, so the "couldn't resolve" guard below actually fires.
  REMOTE_HEAD="$(git rev-parse --verify --quiet "origin/$RELEASE_BRANCH" 2>/dev/null || true)"
  [ -n "$REMOTE_HEAD" ] || die "Couldn't resolve origin/$RELEASE_BRANCH (is the branch pushed? fetch failed?). --resume needs to compare HEAD against it."
  [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] || \
    die "--resume requires HEAD to equal origin/$RELEASE_BRANCH (the release commit must already be pushed). HEAD=$LOCAL_HEAD origin=$REMOTE_HEAD. If the original run never got past the push step, re-run without --resume."
  ok "HEAD == origin/$RELEASE_BRANCH"
else
  if [ -n "$(git rev-list "HEAD..origin/$RELEASE_BRANCH" 2>/dev/null)" ]; then
    die "origin/$RELEASE_BRANCH has commits you don't. Run 'git pull' first so the release is built on top of everything."
  fi
  ok "up to date with origin/$RELEASE_BRANCH"
fi

if [ "$RESUME" = "1" ]; then
  # Tag must exist locally AND on origin AND point at this exact commit —
  # otherwise --resume from a later tip with a stale local tag would publish
  # artifacts under a tag that isn't the current release commit.
  TAG_HEAD="$(git rev-parse --verify --quiet "${VTAG}^{commit}" 2>/dev/null || true)"
  [ -n "$TAG_HEAD" ] || \
    die "--resume needs tag $VTAG to already exist locally (the original run builds, tags, and pushes before publishing). It doesn't — re-run without --resume to ship from scratch."
  [ "$TAG_HEAD" = "$LOCAL_HEAD" ] || \
    die "--resume must run from the tagged release commit: $VTAG points at $TAG_HEAD but HEAD is $LOCAL_HEAD. Check out the release commit, or re-run without --resume."
  # END{...} grabs the peeled commit: for an annotated tag ls-remote appends a
  # refs/tags/$VTAG^{} line (the commit) after the tag-object line; for a
  # lightweight tag there's a single line that already is the commit.
  REMOTE_TAG_HEAD="$(git ls-remote --tags origin "refs/tags/$VTAG" | awk 'END{print $1}')"
  [ -n "$REMOTE_TAG_HEAD" ] || \
    die "--resume needs tag $VTAG to exist on origin (the original run pushes it before publishing). It doesn't — re-run without --resume."
  [ "$REMOTE_TAG_HEAD" = "$TAG_HEAD" ] || \
    die "origin tag $VTAG ($REMOTE_TAG_HEAD) doesn't match your local tag $VTAG ($TAG_HEAD). Reconcile them before resuming."
  ok "tag $VTAG present locally + on origin, points at HEAD (resuming publish)"
else
  if git rev-parse "$VTAG" >/dev/null 2>&1 || git ls-remote --tags origin "$VTAG" | grep -q "$VTAG"; then
    die "Tag $VTAG already exists (locally or on origin). Pick the next version, or delete the tag if this was a mistake."
  fi
  ok "tag $VTAG is new"
fi

command -v gh >/dev/null || die "GitHub CLI 'gh' not found. Install it: brew install gh"
gh auth status >/dev/null 2>&1 || die "Not logged in to GitHub CLI. Run: gh auth login"
ok "gh authenticated"

command -v curl >/dev/null || die "curl not found; release checks need curl."
command -v npm >/dev/null || die "npm not found; release checks need npm."
command -v vercel >/dev/null || die "Vercel CLI not found. Install it: npm i -g vercel"
[ -n "${BLOB_READ_WRITE_TOKEN:-}" ] \
  || die "BLOB_READ_WRITE_TOKEN is required so private GitHub release assets can be mirrored to public Vercel Blob downloads. Store it once: security add-generic-password -a \"\$USER\" -s BLOB_READ_WRITE_TOKEN -w '<token>' -U"
ok "public download tooling present"

if [ "$RESUME" = "1" ]; then
  # --resume skips the build, so the signing cert isn't needed — but the
  # already-built artifacts from the original run must still be on disk to
  # mirror + sign for the appcast.
  [ -f "$RELEASE_ZIP" ] || die "--resume needs the built Sparkle zip at $RELEASE_ZIP (from the original run's build step). It's missing — re-run without --resume to rebuild."
  [ -f "$RELEASE_DMG" ] || die "--resume needs the built DMG at $RELEASE_DMG (from the original run's build step). It's missing — re-run without --resume to rebuild."
  # The zip is version-named so a stale one can't pass; the DMG name is stable,
  # so verify its embedded version before mirroring it — a stale DMG would ship
  # the wrong bytes to fresh installers and into download.json.
  DMG_VER="$(dmg_short_version "$RELEASE_DMG")"
  [ -n "$DMG_VER" ] || die "--resume couldn't read the version from $RELEASE_DMG (mount or Info.plist read failed). Re-run without --resume to rebuild a known-good DMG."
  [ "$DMG_VER" = "$VNUM" ] || die "--resume found a stale DMG: $RELEASE_DMG is version $DMG_VER but you're resuming $VNUM. Delete dist/Ghostie.dmg and re-run without --resume to rebuild."
  ok "build artifacts present; DMG version $DMG_VER matches $VNUM"
else
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    die "No 'Developer ID Application' signing certificate in your keychain. Releases can't be signed without it."
  fi
  ok "Developer ID signing certificate present"
fi

echo
echo "  Plan:"
if [ "$RESUME" = "1" ]; then
  echo "    • RESUME — skip bump/build/notarize/tag/push (tag $VTAG already pushed)"
  echo "    • gh release create $VTAG metadata (skipped if it exists); assets best-effort"
  echo "    • mirror .zip + .dmg to Vercel Blob, refresh download.json (idempotent)"
  echo "    • re-append Sparkle appcast entry + redeploy feed (skips if present)"
else
  echo "    • bump plugin.json + MCP package.json files → $VNUM"
  echo "    • commit 'chore: release $VTAG'"
  echo "    • build + notarize .app  → $RELEASE_ZIP"
  echo "    • build + notarize .dmg  → $RELEASE_DMG"
  echo "    • push commit + tag $VTAG to origin/$RELEASE_BRANCH"
  echo "    • gh release create $VTAG metadata, then best-effort asset upload (.zip + .dmg)"
  echo "    • mirror to Vercel Blob + Sparkle appcast (the user-facing download path)"
  echo "    • plugin ships automatically with the tag (users: /plugin marketplace update)"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo
  ok "DRY RUN — preflight passed, no changes made. Re-run without --dry-run to ship."
  exit 0
fi

# Steps 2-6 (bump, commit, build, notarize, tag, push) build and ship the
# release commit. --resume re-runs ONLY the publish steps (7/7a/7b) against an
# already-built-and-pushed tag, so skip this whole block.
if [ "$RESUME" = "1" ]; then
  step "Resume — skipping bump, build, notarize, tag, push for $VTAG"
  ok "reusing pushed tag $VTAG + already-built artifacts in dist/"
else

# ── 2-3. Bump + commit ─────────────────────────────────────────────────────
step "Bumping versions"
bash scripts/bump-version.sh "$VNUM"
# Stage every file bump-version.sh touches. Glob mcps/*/package.json (not a
# hardcoded list) so a newly-added MCP is committed automatically — the old
# explicit list silently dropped mcps/birthday-generator/package.json, leaving
# the tree dirty and failing the NEXT release's preflight.
git add .claude-plugin/plugin.json mcps/*/package.json
git add mcps/*/src/index.ts
if git diff --cached --quiet; then
  ok "versions already at $VNUM — nothing to commit"
else
  git commit -m "chore: release $VTAG" >/dev/null
  ok "committed 'chore: release $VTAG'"
fi

# ── 4. Build the .app (compile, sign, notarize, staple) ───────────────────
step "Building + notarizing the .app (this is the slow part — a few minutes)"
bash scripts/build-release.sh "$VTAG"
[ -f "$RELEASE_ZIP" ] || die "Expected $RELEASE_ZIP but it's missing. build-release.sh did not produce the zip."
ok "built $RELEASE_ZIP"

# ── 5. Build the .dmg ──────────────────────────────────────────────────────
step "Building + notarizing the .dmg"
bash scripts/build-dmg.sh "$VTAG"
[ -f "$RELEASE_DMG" ] || die "Expected $RELEASE_DMG but it's missing. build-dmg.sh did not produce the dmg."
ok "built $RELEASE_DMG"

# ── 6. Push commit + tag ───────────────────────────────────────────────────
step "Pushing commit + tag $VTAG"
git tag "$VTAG"
git push origin "$RELEASE_BRANCH"
git push origin "$VTAG"
ok "pushed $RELEASE_BRANCH and tag $VTAG"

fi  # end of build-and-push block (skipped under --resume)

# ── 7. Publish the GitHub release (metadata first, assets best-effort) ─────
# The GitHub release ASSETS are NOT on the user-facing download path — public
# downloads + Sparkle updates come from the Vercel Blob mirror (7a/7b) on a
# different host (uploads.github.com vs *.public.blob.vercel-storage.com). So a
# flaky uploads.github.com (we hit repeated 'tls: bad record MAC' on the DMG/zip
# during v0.10.0) must NOT abort the release: create the release metadata first,
# then attempt the asset upload but tolerate failure with a "back-fill later"
# warning so the Blob mirror + appcast + deploy still run.
step "Publishing GitHub Release $VTAG"
if gh release view "$VTAG" >/dev/null 2>&1; then
  ok "GitHub release $VTAG already exists — reusing it"
else
  gh release create "$VTAG" \
    --title "Ghostie $VTAG" \
    --generate-notes
  ok "GitHub release $VTAG created (metadata)"
fi

# --clobber makes this idempotent: overwrites same-named assets, uploads if absent.
if gh release upload "$VTAG" "$RELEASE_ZIP" "$RELEASE_DMG" --clobber; then
  ok "release assets uploaded to GitHub"
else
  echo "  ⚠ couldn't upload assets to GitHub Releases (uploads.github.com may be flaky)."
  echo "    NOT blocking — public downloads + Sparkle come from the Vercel Blob mirror"
  echo "    (next steps), not from GitHub. Back-fill the GitHub assets later with:"
  echo "      gh release upload $VTAG \"$RELEASE_ZIP\" \"$RELEASE_DMG\" --clobber"
fi

# ── 7a. Publish public download artifacts ─────────────────────────────────
step "Publishing public download artifacts (Vercel Blob)"

blob_put() {
  local file="$1"
  local pathname="$2"
  local content_type="$3"
  local output

  output="$(vercel blob put "$file" \
    --non-interactive \
    --access public \
    --pathname "$pathname" \
    --content-type "$content_type" \
    --cache-control-max-age 31536000 \
    --allow-overwrite true 2>&1)" \
    || die "Vercel Blob upload failed for $file: $output"

  OUTPUT="$output" python3 - <<'PY'
import os
import re
from urllib.parse import urlparse

for candidate in re.findall(r"https://[^\s]+", os.environ["OUTPUT"]):
    parsed = urlparse(candidate.rstrip(".,;"))
    if parsed.hostname and parsed.hostname.endswith(".public.blob.vercel-storage.com"):
        print(candidate.rstrip(".,;"))
        raise SystemExit(0)
raise SystemExit("Could not parse Vercel Blob URL from upload output")
PY
}

DMG_PUBLIC_URL="$(blob_put "$RELEASE_DMG" "releases/${VTAG}/Ghostie.dmg" "application/x-apple-diskimage")"
ZIP_PUBLIC_URL="$(blob_put "$RELEASE_ZIP" "releases/${VTAG}/messages-for-ai-${VTAG}.zip" "application/zip")"
ok "public artifacts uploaded"

DOWNLOAD_JSON="site/download.json"
DMG_SHA256="$(shasum -a 256 "$RELEASE_DMG" | awk '{print $1}')"
ZIP_SHA256="$(shasum -a 256 "$RELEASE_ZIP" | awk '{print $1}')"
DMG_SIZE="$(stat_size "$RELEASE_DMG")"
ZIP_SIZE="$(stat_size "$RELEASE_ZIP")"
PUBLISHED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

require_public_artifact "$DMG_PUBLIC_URL" "$DMG_SIZE" "$DMG_SHA256" "public DMG"
require_public_artifact "$ZIP_PUBLIC_URL" "$ZIP_SIZE" "$ZIP_SHA256" "public Sparkle zip"

VTAG="$VTAG" PUBLISHED_AT="$PUBLISHED_AT" DMG_PUBLIC_URL="$DMG_PUBLIC_URL" ZIP_PUBLIC_URL="$ZIP_PUBLIC_URL" \
DMG_SIZE="$DMG_SIZE" ZIP_SIZE="$ZIP_SIZE" DMG_SHA256="$DMG_SHA256" ZIP_SHA256="$ZIP_SHA256" \
python3 - <<'PY'
import json
import os

download = {
    "version": os.environ["VTAG"],
    "publishedAt": os.environ["PUBLISHED_AT"],
    "minimumSystemVersion": "14.0",
    "dmg": {
        "url": os.environ["DMG_PUBLIC_URL"],
        "name": "Ghostie.dmg",
        "size": int(os.environ["DMG_SIZE"]),
        "sha256": os.environ["DMG_SHA256"],
        "contentType": "application/x-apple-diskimage",
    },
    "sparkleZip": {
        "url": os.environ["ZIP_PUBLIC_URL"],
        "name": f"messages-for-ai-{os.environ['VTAG']}.zip",
        "size": int(os.environ["ZIP_SIZE"]),
        "sha256": os.environ["ZIP_SHA256"],
        "contentType": "application/zip",
    },
}

with open("site/download.json", "w") as f:
    json.dump(download, f, indent=2)
    f.write("\n")
PY
ok "download metadata updated"

# ── 7b. Sparkle appcast: sign the zip, append the <item>, redeploy the feed ──
# Sparkle signs the downloaded zip bytes, not the host. If the URL changes to a
# byte-identical mirror, the signature remains valid; if the zip bytes change,
# rerun sign_update and update both sparkle:edSignature and length.
step "Updating Sparkle appcast (messagesfor.ai/appcast.xml)"
APPCAST="site/appcast.xml"
[ -f "$APPCAST" ] || die "Missing $APPCAST — the Sparkle feed seed should be committed."

# The canonical EdDSA sign_update — NOT the deprecated DSA script under
# bin/old_dsa_scripts/ (which has a different CLI + output and would silently
# produce a bad/empty signature). Exclude it explicitly.
SIGN_UPDATE="$(find menubar/.build -type f -name sign_update -path '*sparkle*' ! -path '*old_dsa*' 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || die "sign_update not found under menubar/.build. Run 'cd menubar && swift package resolve', then re-run."

# sign_update prints: sparkle:edSignature="…" length="…"  (needs the EdDSA private
# key in the login keychain — created once by generate_keys; see RELEASE.md).
SIG_AND_LEN="$("$SIGN_UPDATE" "$RELEASE_ZIP" 2>/dev/null || true)"
[ -n "$SIG_AND_LEN" ] || die "sign_update produced no signature. Is the Sparkle EdDSA private key in your keychain? Run generate_keys once (see RELEASE.md)."
# Shape-check before splicing into XML: guards against a future sign_update that
# prints a banner / different format (which would otherwise corrupt the feed).
SIG_RE='edSignature="[^"]+"[[:space:]]+length="[0-9]+"'
[[ "$SIG_AND_LEN" =~ $SIG_RE ]] || die "sign_update output didn't match the expected 'edSignature=\"…\" length=\"…\"' shape: [$SIG_AND_LEN]"

# Reuse the EXACT build number build-release.sh stamped into CFBundleVersion (so the
# appcast's sparkle:version can't drift from the shipped build). Fall back to the
# git count only if the file is somehow absent.
if [ -f dist/cfbundle-version.txt ]; then
  CFBUILD="$(cat dist/cfbundle-version.txt)"
else
  CFBUILD="$(git rev-list --count HEAD)"
fi
ZIP_URL="$ZIP_PUBLIC_URL"
PUBDATE="$(date '+%a, %d %b %Y %H:%M:%S %z')"
ITEM="    <item>
      <title>${VTAG}</title>
      <sparkle:version>${CFBUILD}</sparkle:version>
      <sparkle:shortVersionString>${VNUM}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>${PUBDATE}</pubDate>
      <enclosure url=\"${ZIP_URL}\" ${SIG_AND_LEN} type=\"application/octet-stream\" />
    </item>"

# Insert newest-first after the marker; skip if this version is already present.
APPCAST="$APPCAST" VTAG="$VTAG" ITEM="$ITEM" python3 - <<'PY'
import os
path, vtag, item = os.environ["APPCAST"], os.environ["VTAG"], os.environ["ITEM"]
s = open(path).read()
if f"<title>{vtag}</title>" in s:
    print(f"  appcast already has {vtag} — leaving it"); raise SystemExit(0)
marker = "<!-- release.sh inserts <item> entries here, newest first. -->"
if marker in s:
    s = s.replace(marker, marker + "\n" + item, 1)
else:
    s = s.replace("</channel>", item + "\n  </channel>", 1)
open(path, "w").write(s)
PY

# Validate the feed still parses before committing/deploying a broken appcast.
python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$APPCAST" \
  || die "appcast.xml failed to parse after inserting the $VTAG item — not committing a broken feed."

# Deploy and live-smoke the local feed/download metadata before committing it.
require_public_download_flow

git add "$APPCAST" "$DOWNLOAD_JSON"
if git diff --cached --quiet; then
  ok "appcast already current for $VTAG"
else
  git commit -m "chore: appcast entry for $VTAG" >/dev/null
  # Tolerant push: the release is already public and the feed was already
  # deployed + smoked above. Surface a clear manual-remediation message instead.
  if git push origin "$RELEASE_BRANCH"; then
    ok "appcast entry committed + pushed"
  else
    echo "  ⚠ couldn't push the appcast commit to $RELEASE_BRANCH (it's committed locally)."
    echo "    Push it manually so the repo and the deployed feed agree:"
    echo "      git push origin $RELEASE_BRANCH"
  fi
fi

# ── Done ───────────────────────────────────────────────────────────────────
printf '\n\033[1m✓ Shipped %s\033[0m\n\n' "$VTAG"
echo "  App:    https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/releases/tag/$VTAG"
echo "          DMG download: $DMG_PUBLIC_URL"
echo "  Plugin: live with the tag. Users update with:  /plugin marketplace update ghostie"
echo
echo "  Next: edit the release notes on GitHub if you want a human summary,"
echo "        then install the DMG yourself to confirm the update lands cleanly."
