# Control manifest: kill switch + forced upgrade (#76)

The control manifest is the cloud-side lever a solo operator uses to stop or force-upgrade the whole fleet in an incident, without shipping a build, notarizing, or waiting for users to click Install.

## What it is

A small signed JSON file served at a stable URL:

- Manifest: `https://messagesfor.ai/control.json`
- Detached signature: `https://messagesfor.ai/control.json.sig`

The app fetches both on launch and every 15 minutes (and on a manual check). It verifies the signature, applies the directives, and caches the last-good manifest so a kill stays applied even if the network later drops.

This is deliberately the lowest-ops design. There is no server, no database, no admin dashboard to secure. The control surface is the `scripts/set-min-version.sh` CLI on the maintainer's machine, gated by possession of the Sparkle EdDSA private key in the keychain. Only someone who can already sign app updates can change the manifest. That is the correct blast radius.

## Schema

```json
{
  "schema": 1,
  "min_supported_version": "0.0.0",
  "kill": { "scope": "none", "reason": "" },
  "banner": null,
  "issued_at": "2026-06-07T18:01:29Z"
}
```

- `min_supported_version` (semver): the app blocks all sending on any version older than this and shows an "Update required" screen that drives the Sparkle update check. This is the hard, locally-enforced forced-upgrade floor.
- `kill.scope`: `none` | `all` | `send` | `whatsapp` | `imessage`.
  - `all`: block sending and stop both daemons; refuse to relaunch them while active.
  - `send`: block all sending only.
  - `whatsapp` / `imessage`: stop that daemon and block its sends.
- `kill.reason`: shown to the user with the kill.
- `banner`: `null`, or `{ "level": "info|warning|critical", "text": "...", "url": "...|null" }` shown in the popover. Also the operator's only direct channel to talk to users mid-incident.
- `issued_at` (ISO-8601 UTC): the app persists the last-accepted value and rejects any manifest with an older `issued_at` (rollback protection against an attacker replaying an old permissive manifest).

## Trust model and signing

The manifest is signed with the **same Sparkle EdDSA key** that signs app updates (`SUPublicEDKey`, public half in `menubar/scripts/sparkle_public_ed_key.txt`, private half in the maintainer keychain). The app verifies the detached Ed25519 signature with CryptoKit against the exact bytes of `control.json`. Verified compatible: `sign_update` emits a raw Ed25519 signature over the file bytes, which `Curve25519.Signing.PublicKey.isValidSignature(_:for:)` accepts.

`control.json.sig` contains just the base64 of the 64-byte signature (trim whitespace before decoding).

A site or CDN compromise therefore cannot push a malicious kill/min-version: a tampered manifest fails signature verification and is ignored. The residual risk is the same as the update channel itself (theft of the EdDSA private key), tracked under business continuity (#93).

### Caveat: best-effort against a motivated user

A determined user can null-route `messagesfor.ai` in `/etc/hosts` to dodge the fetch. The kill switch is therefore best-effort against honest failure and against a worm spreading through cooperative installs. It is not DRM. The `min_supported_version` floor is the harder control because, once the app has fetched any manifest, the floor is enforced locally and the cached manifest is sticky.

### Fail behavior

- On launch the app applies the cached manifest immediately.
- A kill directive, once seen, stays applied even if later fetches fail.
- The app only fails open (normal operation) when there is no cached manifest AND the fetch fails (a genuinely clean, offline, first-run client).

## Operator runbook

All commands run from the repo root. The CLI updates and signs the manifest; pass `--deploy` to also push the site (or deploy `site/` manually).

Set or raise the forced-upgrade floor:
```
scripts/set-min-version.sh --min-version 0.6.0 --deploy
```

Incident: stop ALL sending and both daemons fleet-wide:
```
scripts/set-min-version.sh \
  --kill all \
  --reason "Security incident: sends paused while we ship a fix" \
  --banner "Sending is paused. Please update to the latest version." \
  --banner-level critical \
  --deploy
```

Stop only WhatsApp (e.g. a Baileys break or ban wave):
```
scripts/set-min-version.sh --kill whatsapp --reason "WhatsApp temporarily disabled" --deploy
```

Recover (lift the kill once the fix is out and the floor is raised):
```
scripts/set-min-version.sh --kill none --min-version 0.6.0 --deploy
```

Preview without writing or signing:
```
scripts/set-min-version.sh --min-version 0.6.0 --dry-run
```

Verify after deploy:
```
curl -s https://messagesfor.ai/control.json && echo && curl -s https://messagesfor.ai/control.json.sig
```

Propagation: edge cache on the manifest is 30-60s (`site/vercel.json`), and the app polls every 15 minutes, so worst case a directive reaches a running client within ~15 minutes (immediately on its next launch). For a faster guarantee in a severe incident, also ship a `min_supported_version` bump so newly-launched clients block on the floor.

## Distribution hardening (#86) — status

Done here:
- `site/vercel.json` sets a short edge cache on `control.json`/`control.json.sig` (fast kill propagation) and a 5-minute cache on `appcast.xml` (absorbs a million polling clients at the edge).

Still to do (needs maintainer accounts; tracked in #86):
- Update zips are ~147 MB each; 1M users overnight is ~147 TB, recurring per update. Move the DMG and Sparkle update zips off GitHub Releases onto cost-capped object storage with a CDN (Cloudflare R2 has zero egress; or S3 + CloudFront with a budget alarm), and add a fallback mirror for the appcast and enclosures.
- Reduce payload with Sparkle delta updates and/or a slimmer app bundle.
