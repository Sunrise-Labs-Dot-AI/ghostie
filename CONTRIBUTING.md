# Contributing to Ghostie

Thanks for your interest. A couple of conventions keep this repo safe to develop in the open.

## No real contact data, ever

Ghostie reads iMessage and WhatsApp, so its tests and fixtures deal in phone numbers, names, and emails. Never commit real ones. Use fictional data only:

- Phone numbers: the reserved `555` ranges (area code `555`, e.g. `+15551234567`, or exchange `555`, e.g. `+1 (415) 555-0142`) or toll-free (`800`/`833`/`844`/...).
- Emails: `example.com` (or `example.org` / `example.net`).
- Names: obviously fictional; avoid real people's names.

A CI guard (`scripts/check-no-real-pii.py`, run by the `pii-guard` workflow on every push and pull request, with no path exceptions) blocks anything that looks like a real US phone number or a personal-domain email. Run it locally before you push:

```bash
python3 scripts/check-no-real-pii.py
```

## Privacy posture

Message content stays on the user's own devices. Ghostie reads and stores bodies locally where the product needs them (drafts, thread context, the WhatsApp message store), but no message body, recipient, contact identifier, prompt, draft, or API key may reach product analytics, telemetry, logs, or any Sunrise Labs-operated service. Features that read bodies locally (analytics, birthday, voice) emit counts, dates, and aggregates only. Keep it that way. See `SECURITY.md` for the full threat model.

## Building and testing

See `CLAUDE.md` and the per-folder `AGENTS.md` files for the Swift menu-bar app and Bun / TypeScript MCP build and test commands.
