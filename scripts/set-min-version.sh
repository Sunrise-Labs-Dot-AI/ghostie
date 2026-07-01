#!/usr/bin/env bash
# set-min-version.sh — the cloud-side control plane for the kill switch + forced upgrade (issue #76).
#
# This is the "service" for setting the minimum app version and for killing the
# app fleet-wide in an incident. It is deliberately the lowest-ops design: a small
# signed JSON manifest (site/control.json) hosted next to the Sparkle appcast at
# https://messagesfor.ai/control.json, signed with the SAME Sparkle EdDSA key the
# app already trusts (SUPublicEDKey), and deployed with the same `vercel deploy`
# flow as the appcast. The app fetches + verifies it on launch and every 15 min.
#
# There is no server to run, no database, no admin dashboard to secure — the
# control surface is this CLI on the maintainer's machine, gated by possession of
# the EdDSA private key in the keychain. That is the right blast-radius for a
# solo operator: only someone who can already sign updates can change the manifest.
#
# Usage:
#   scripts/set-min-version.sh --min-version 0.6.0
#   scripts/set-min-version.sh --kill all --reason "CVE-2026-XXXX: stop sends" --banner "Update required — sending paused" --banner-level critical
#   scripts/set-min-version.sh --kill none --min-version 0.6.0 --deploy
#
# Flags (all optional; omitted fields keep their current value, issued_at always bumps):
#   --min-version X.Y.Z       Block sending on any app older than this (forced upgrade floor).
#   --kill SCOPE              none | all | send | whatsapp | imessage
#   --reason "text"           Shown with the kill (why).
#   --banner "text"           In-app banner text (omit/empty to clear).
#   --banner-level LEVEL      info | warning | critical (default warning).
#   --banner-url URL          Optional link shown with the banner.
#   --deploy                  Run `vercel deploy --prod` from site/ after signing.
#   --dry-run                 Show the resulting manifest; do not sign or write.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL="$REPO_ROOT/site/control.json"
SIG="$REPO_ROOT/site/control.json.sig"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_dim=$'\e[2m'; c_rst=$'\e[0m'
die()  { echo "${c_red}✗ $*${c_rst}" >&2; exit 1; }
ok()   { echo "${c_grn}✓ $*${c_rst}"; }
note() { echo "${c_dim}  $*${c_rst}"; }

MIN_VERSION=""; KILL=""; REASON=""; BANNER=""; BANNER_LEVEL=""; BANNER_URL=""
DEPLOY=0; DRY=0; SET_BANNER=0; SET_REASON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --min-version) MIN_VERSION="${2:-}"; shift 2;;
    --kill)        KILL="${2:-}"; shift 2;;
    --reason)      REASON="${2:-}"; SET_REASON=1; shift 2;;
    --banner)      BANNER="${2:-}"; SET_BANNER=1; shift 2;;
    --banner-level) BANNER_LEVEL="${2:-}"; shift 2;;
    --banner-url)  BANNER_URL="${2:-}"; shift 2;;
    --deploy)      DEPLOY=1; shift;;
    --dry-run)     DRY=1; shift;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown flag: $1 (try --help)";;
  esac
done

[ -n "$KILL" ] && case "$KILL" in none|all|send|whatsapp|imessage) ;; *) die "--kill must be none|all|send|whatsapp|imessage";; esac
[ -n "$BANNER_LEVEL" ] && case "$BANNER_LEVEL" in info|warning|critical) ;; *) die "--banner-level must be info|warning|critical";; esac
[ -n "$MIN_VERSION" ] && [[ "$MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ -z "$MIN_VERSION" ] || die "--min-version must be semver X.Y.Z"

ISSUED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Read-modify-write the manifest with python3 (no jq dependency). Omitted flags
# keep their current value; issued_at always advances (the app rejects an older
# issued_at than the last it accepted — rollback protection).
NEW_JSON="$(python3 - "$CONTROL" "$ISSUED_AT" "$MIN_VERSION" "$KILL" "$REASON" "$SET_REASON" "$BANNER" "$SET_BANNER" "$BANNER_LEVEL" "$BANNER_URL" <<'PY'
import json, sys, os
path, issued_at, min_v, kill, reason, set_reason, banner, set_banner, blevel, burl = sys.argv[1:11]
cur = {}
if os.path.exists(path):
    cur = json.load(open(path))
m = {
    "schema": 1,
    "min_supported_version": cur.get("min_supported_version", "0.0.0"),
    "kill": cur.get("kill", {"scope": "none", "reason": ""}),
    "banner": cur.get("banner", None),
    "issued_at": issued_at,
}
if min_v:
    m["min_supported_version"] = min_v
if kill:
    m["kill"] = {"scope": kill, "reason": (reason if set_reason == "1" else m["kill"].get("reason", ""))}
elif set_reason == "1":
    m["kill"]["reason"] = reason
if set_banner == "1":
    if banner.strip() == "":
        m["banner"] = None
    else:
        m["banner"] = {"level": (blevel or "warning"), "text": banner, "url": (burl or None)}
# Canonical, stable formatting so the signed bytes are deterministic.
print(json.dumps(m, indent=2, sort_keys=True, ensure_ascii=False))
PY
)"

echo "── manifest ─────────────────────────────────────────"
echo "$NEW_JSON"
echo "─────────────────────────────────────────────────────"

if [ "$DRY" = "1" ]; then note "dry run — nothing written"; exit 0; fi

printf '%s\n' "$NEW_JSON" > "$CONTROL"
ok "wrote site/control.json"

# Sign the EXACT bytes of control.json with the Sparkle EdDSA key (same key as the
# appcast). The app verifies the detached Ed25519 signature against SUPublicEDKey.
SIGN_UPDATE="$(find "$REPO_ROOT/menubar/.build" -type f -name sign_update -path '*sparkle*' ! -path '*old_dsa*' 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || die "sign_update not found under menubar/.build. Run 'cd menubar && swift package resolve' (or a build) first."

# sign_update prints: sparkle:edSignature="BASE64" length="N"
SIG_OUT="$("$SIGN_UPDATE" "$CONTROL")" || die "sign_update failed — is the Sparkle EdDSA private key in your keychain?"
SIG_B64="$(printf '%s' "$SIG_OUT" | grep -oE 'edSignature="[^"]+"' | head -1 | sed -E 's/edSignature="([^"]+)"/\1/')"
[ -n "$SIG_B64" ] || die "could not extract edSignature from sign_update output: [$SIG_OUT]"
printf '%s' "$SIG_B64" > "$SIG"
ok "wrote site/control.json.sig (detached Ed25519, base64)"
note "pubkey (SUPublicEDKey) the app verifies against: $(grep -oE '[A-Za-z0-9+/]{43}=' "$REPO_ROOT/menubar/scripts/sparkle_public_ed_key.txt" | head -1 | cut -c1-12)…"

if [ "$DEPLOY" = "1" ]; then
  if command -v vercel >/dev/null 2>&1; then
    (cd "$REPO_ROOT/site" && vercel deploy --prod >/dev/null 2>&1) \
      && ok "deployed site/ → messagesfor.ai/control.json" \
      || die "vercel deploy failed — deploy site/ manually so messagesfor.ai/control.json updates"
  else
    die "vercel CLI not found — deploy site/ manually (the manifest is signed and ready)"
  fi
else
  note "not deployed. Run with --deploy, or: (cd site && vercel deploy --prod)"
  note "verify after deploy: curl -s https://messagesfor.ai/control.json && echo && curl -s https://messagesfor.ai/control.json.sig"
fi
