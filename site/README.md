# messagesfor.ai — marketing site

Static landing page deployed to Vercel at https://messagesfor.ai.

## Deploy

One-time setup:

```sh
cd site
npx vercel link        # link to a new or existing Vercel project
npx vercel --prod      # deploy to production
```

Vercel auto-detects static HTML and serves `index.html`. No build step.

## Custom domain

In the Vercel project's Settings → Domains, add `messagesfor.ai` (and
`www.messagesfor.ai` if desired). Vercel surfaces the DNS records you
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
