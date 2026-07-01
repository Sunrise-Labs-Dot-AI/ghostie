---
name: birthday-text-voice
description: Draft birthday wishes in James's actual birthday voice, learned from his past outbound birthday texts and segmented by relationship tier (family / friend / partner / colleague). Use whenever James asks to "draft a birthday text to [name]", "what should I text [name] for their birthday", "wish [name] happy birthday", or when the birthday-reminder skill stages a birthday draft. Also use to "refresh my birthday voice" / "relearn how I write birthday wishes" — which re-pulls his past wishes (1:1 AND group threads), recomputes the aggregate fingerprint, and rewrites VOICE.md. Aggregate style only — never stores message bodies. An overlay on anthropic-skills:james-text-voice (apply the base voice first, then the tier-specific patterns here).
---

# birthday-text-voice

How James actually writes birthday wishes — not his default texting voice, his
*birthday* voice — learned from his past outbound wishes and segmented by
relationship tier. An **overlay** on `anthropic-skills:james-text-voice`: apply the
base voice rules first, then the birthday/tier patterns here.

The learned voice lives in two regenerable files next to this one:
- `fingerprint.json` — the aggregate stats (no message bodies, ever).
- `VOICE.md` — the human/LLM-readable patterns + per-tier drafting rules.

If neither exists yet, run the **Refresh flow** first. If they exist, use the
**Apply flow** to draft.

## When to use

- "Draft a birthday text to Mom / Allison / Mark."
- "What should I text [name] for their birthday?"
- "Wish [name] a happy birthday."
- (Invoked by `birthday-reminder` when it stages a birthday draft.)
- "Refresh my birthday voice" / "relearn how I write birthday wishes" → Refresh flow.

Do NOT use for non-birthday messages — that's `james-text-voice` or a per-contact
`<name>-text-voice` skill.

## Apply flow (drafting a birthday wish)

1. **Load the base voice.** Apply `anthropic-skills:james-text-voice` first.
2. **Read `VOICE.md`** (or `fingerprint.json`) next to this skill. If it's missing,
   run the Refresh flow first (or, if James has no birthday-wish history yet, fall
   back to james-text-voice + the relationship tone and say so).
3. **Pick the tier.** Resolve the recipient's relationship from
   `~/.messages-mcp/birthdays.json` (`relationship` field). Use that tier's section
   in VOICE.md. If the tier isn't shown (it was below the sample threshold), use the
   **Overall** section; if Overall is also thin, defer to james-text-voice.
4. **Draft** applying the tier's rules (length, emoji, punctuation, birthday-emoji
   habit, burst shape) on top of the base voice. Use the contact's `notes` from
   birthdays.json for specificity. Don't be robotic — the patterns are statistical.
5. **Stage, never send.** Hand the draft to `stage_draft` (imessage-drafts MCP) for
   hold-to-fire approval, exactly as `birthday-reminder` does. Never auto-send.

## Refresh flow (learning / relearning the voice)

Four phases. This is where the privacy gate matters most — birthday wishes are
personal. Hold bodies in working memory only long enough to aggregate; never write
them to disk.

### Phase 1 — Pull past birthday wishes (1:1 AND group)

Using the `imessage-drafts` MCP, collect James's **outbound** messages that are
birthday wishes, over the last ~8 years:

- Search broadly for the wish phrasing: "happy birthday", "happy bday", "hbd",
  "happy b-day" (case-insensitive). Use `search_messages` and/or `get_thread`,
  filtering to `from_me = true`. Skip tapbacks/reactions.
- Include **group threads** — James wishes people happy birthday in groups too, and
  that's part of the voice. (The base voice analyzer is 1:1-only; this one is not.)

### Phase 2 — Attribute each wish to a relationship tier

For each wish, set `tier` (family / friend / partner / colleague) when you can:

- **1:1 thread** → the recipient is the thread's contact. Look up their
  `relationship` in `~/.messages-mcp/birthdays.json` (match by handle, then name).
- **Group thread** → the recipient is whoever's birthday it was. Try to match a
  known contact whose **first name appears in the wish text** AND who has a
  **birthday within a few days** of the message date (in birthdays.json). If matched,
  use that contact's `relationship`. If not, leave `tier` null — the wish still feeds
  the **overall** voice, just not a tier.
- `gender` is **optional**: only set it if birthdays.json carries an explicit gender
  field for the contact. **Never infer gender from a name.** Leave it null otherwise.

### Phase 3 — Aggregate (no bodies to disk)

Write the tagged wishes to a temp file in a private, auto-cleaned location and run
the analyzer. Use `mktemp` (mode 0600, your-user-only) — NOT a predictable
world-readable `/tmp/wishes.json` — because this file holds raw message bodies:

```bash
WISHES="$(mktemp -t bday-wishes)"; FP="$(mktemp -t bday-fp)"   # 0600, per-user
# ...write the tagged wishes JSON to "$WISHES"...
python3 scripts/analyze_birthday_voice.py --input "$WISHES" > "$FP"
```

Input shape (one object per wish):
```json
[{ "ts": "2025-03-14T09:02:11", "text": "happy birthday!! 🎂",
   "thread_id": 42, "is_group": false, "tier": "family", "gender": null }]
```

The analyzer emits an aggregate fingerprint (overall + per-tier where the sample
clears the threshold). It exits **3** if the overall sample is under 12 wishes (tell
James he doesn't have enough birthday-wish history yet), **5** if the privacy guard
trips (a body leaked — stop and report; do not write anything).

### Phase 4 — Render VOICE.md + fingerprint.json

```bash
# First time:
python3 scripts/render_birthday_voice.py --fingerprint "$FP"
# Refresh in place (prints a drift summary vs the last snapshot):
python3 scripts/render_birthday_voice.py --fingerprint "$FP" --force
```

This writes `VOICE.md` + `fingerprint.json` into this skill dir. Without `--force`
it refuses to overwrite (exit 4). With `--force` it overwrites and prints which
overall stats drifted since last time.

### Phase 5 — Delete the raw-bodies temp files (REQUIRED)

The fingerprint and VOICE.md are aggregate-only, but `$WISHES` still holds raw
message bodies. Delete both temp files now — this is not optional:

```bash
rm -f "$WISHES" "$FP"
```

Then tell James: the sample size, which tiers were learned vs fell below threshold,
and any drift. Suggest he skim `VOICE.md`.

## Notes for the LLM running this

1. **Never persist message bodies.** The committed output is aggregate stats only.
   The analyzer has a body-leak guard (exit 5), but the first line of defense is
   you: the only file that holds raw text is the `mktemp` wishes file, and Phase 5
   deletes it. If the flow stops early for any reason, still `rm -f "$WISHES"`.
2. **Tier from birthdays.json, never guessed.** If a recipient's relationship isn't
   in birthdays.json, leave the wish untiered rather than guessing.
3. **No gender inference from names.** Gender segments only exist if birthdays.json
   carries an explicit field.
4. **Group wishes count** for the overall voice even when unattributable to a tier.
5. **Overlay, not replacement.** Always apply james-text-voice's base rules first.
6. **Sample honesty.** Under 40 overall wishes, surface the small-sample caveat the
   analyzer emits. Thin tiers fall back to Overall — say so rather than over-claiming.

## Layout

- `SKILL.md` — this file (stable logic).
- `scripts/analyze_birthday_voice.py` — Phase 3 analyzer. Reads tagged-wishes JSON,
  emits the segmented fingerprint. Pure stdlib. Privacy-guarded.
- `scripts/render_birthday_voice.py` — Phase 4 renderer. Writes VOICE.md +
  fingerprint.json. Supports `--force` refresh + drift summary.
- `examples/sample-fingerprint.json` — what a fingerprint looks like.
- `fingerprint.json` / `VOICE.md` — generated (absent until the first refresh).
