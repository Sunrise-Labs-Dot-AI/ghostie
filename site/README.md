# ghostie.app — marketing site

Static landing page deployed to Vercel at https://ghostie.app.

## Deploy

One-time setup:

```sh
cd site
npx vercel link        # link to a new or existing Vercel project
npx vercel --prod      # deploy to production
```

Vercel auto-detects static HTML and serves `index.html`. No build step.

## Custom domain

In the Vercel project's Settings → Domains, add `ghostie.app` (and
`www.ghostie.app` if desired). Vercel surfaces the DNS records you
need to point at your registrar — typically:

- `A` record on `@` → `76.76.21.21`
- `CNAME` on `www` → `cname.vercel-dns.com`

(Vercel will give exact values — use those rather than the placeholders
above.)

## TODO

- Replace the screenshot-placeholder div with a real PNG (`screenshot.png`)
  showing the menu bar drafts list with a few drafts staged.
- Add `icon.png` at site root (or `/public/icon.png` if a build step is
  added later) — referenced by `<link rel="icon">` and the header logo.
- If the site grows beyond a landing page, migrate to a framework
  (Next.js / Astro / SvelteKit) and re-deploy. Vercel handles all three
  with zero config.

## Public downloads

The GitHub repo and GitHub Releases stay private. Public app downloads are
mirrored to the Vercel Blob store connected to this project.

- `download.json` stores the current public DMG and Sparkle zip metadata.
- `/api/download` redirects users to the current DMG URL.
- The canonical button path, `/releases/latest/download/Ghostie.dmg`, is routed
  to `/api/download` in `vercel.json`. The legacy path
  `/releases/latest/download/Messages-for-AI.dmg` is kept and also routed there
  so older download links keep working.
- `appcast.xml` uses the public Blob zip URL so Sparkle updates work without
  GitHub authentication.

Release automation uploads the DMG and zip to Blob. Before running
`scripts/release.sh`, make sure the shell has `BLOB_READ_WRITE_TOKEN` for the
`messages-for-ai-releases` Vercel Blob store.

Sparkle EdDSA signatures are signatures over the downloaded zip bytes. If a
Sparkle enclosure URL changes only because the exact same bytes were mirrored to
a new host, the existing signature and length remain valid. If the zip is
recreated, recompressed, or otherwise changes bytes, rerun Sparkle `sign_update`
and update the enclosure signature and length together.

## Mobile Messages opener

`ghostie.app` exposes a compose-only HTTPS bridge for mobile chat clients that
will open web links but reject raw `sms:` links. Opening a generated link never
requires authentication.

Create a seven-day link with a server-side request:

```sh
curl https://ghostie.app/v1/links \
  -H 'Authorization: Bearer <MESSAGE_OPENER_API_TOKEN>' \
  -H 'Content-Type: application/json' \
  --data '{"phone":"+12155550123","body":"Want to grab lunch?"}'
```

The response is:

```json
{
  "url": "https://ghostie.app/t/AbCdEf0123_-GhIj",
  "expires_at": "2026-09-23T12:00:00.000Z"
}
```

Inputs are `phone` (`+` and 7 to 15 digits) and non-empty `body` (at most 2,000
Unicode characters). Creation uses `MESSAGE_OPENER_API_TOKEN`; the returned
`/t/<id>` URL is a bearer link, so anyone who has it can open the draft until it
expires. Draft payloads are encrypted with `MESSAGE_OPENER_ENCRYPTION_KEY`
before the ciphertext is placed in the existing Blob store. The cleanup cron
uses Vercel's `CRON_SECRET`. The landing page composes only and never sends.
