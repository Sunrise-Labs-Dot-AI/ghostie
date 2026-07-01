---
name: texting-voice-skill-creator
description: Build OR refresh a per-relationship texting-voice skill by analyzing the user's outbound iMessage history with a specific contact and producing a SKILL.md that captures how they text that person. Use when the user asks "create a texting-voice skill for [contact]", "build a voice skill for how I text [name]", "make a [name]-text-voice skill", "generate a per-contact voice skill", "I want a voice skill for texts with [contact]", OR to refresh an existing one as their style drifts — "refresh my texting voice for [name]", "update the voice skill for [contact]", "relearn how I text [name]" (re-pulls recent history, recomputes the fingerprint, and reports what drifted). Outputs/updates a directory under skills/ with a populated SKILL.md (aggregate style fingerprint, NOT message bodies). Complements the existing james-text-voice skill (which captures default texting voice) with relationship-specific overlays.
---

# texting-voice-skill-creator

A meta-skill. Given a contact, this skill analyzes the user's outbound texts to that contact and produces a new texting-voice skill — a SKILL.md the user can keep, edit, and ship — that captures the patterns of how they text *that specific person*.

The point: voice is relational. The way the user texts their spouse is not the way they text a colleague is not the way they text their brother. The base `james-text-voice` skill (from `anthropic-skills`) captures the user's default texting voice. This skill produces overlays for specific relationships.

## When to use

Trigger this skill when the user asks any of:

- "Create a texting-voice skill for Allison."
- "Build a voice skill for how I text Mark."
- "Make a brother-text-voice skill from my history with Sam."
- "Generate a per-contact voice skill for my mom."
- "I want a relationship-specific voice skill — start with [contact]."

Do NOT trigger for "draft a text to [contact]" — that's the job of `james-text-voice` (or, once produced, the relationship-specific skill this one generates).

## What it produces

A new directory under `skills/<contact-slug>-text-voice/` containing:

1. `SKILL.md` — frontmatter + body capturing the voice fingerprint and drafting rules.
2. `fingerprint.json` — the raw aggregate stats the analysis produced (so future runs can diff against it and detect drift).
3. (No message bodies. Ever. The output is style-only.)

The generated `SKILL.md` will:

- Have a description tuned to trigger on "text [contact name]", "reply to [contact]", "what should I say to [contact]".
- List concrete observed patterns: median length, punctuation tendencies, emoji use, opener/closer patterns, multi-message burst rate.
- Translate patterns into drafting rules ("Keep replies to 1–2 sentences. End most messages without punctuation. Never use 'Hey' as an opener — observed 0% of 300 outbound messages.").
- Cite the sample size and time window so future drift is detectable.

## How to run it

Four phases. Skip none.

### Phase 1: Resolve the contact

1. Take the contact name from the user. If ambiguous (multiple contacts match), surface candidates from `list_threads` with `contact_filter` and ask which one. Do not guess.
2. Once resolved, capture: the canonical contact name, the handle(s), and a slug (lowercase-hyphenated first name, e.g. `allison`, `mark-s`). The slug becomes the new skill's directory name.

### Phase 2: Pull outbound texts

Using the `imessage-drafts` MCP:

1. `list_threads` with the contact's filter, get the relevant thread_id(s). For 1:1 voice, only use 1:1 threads — group threads have a different voice register.
2. `get_thread` for each. Filter to `from_me=true` messages. Skip tapbacks/reactions (they're not voice samples).
3. Cap at the most recent 500 substantive outbound messages OR the last 12 months, whichever comes first. If the sample is under 30 messages, stop and tell the user: voice analysis needs more signal. Suggest they pick a different contact.

**Privacy gate**: at this point the model has message content in context. The output `SKILL.md` and `fingerprint.json` **must not** contain any actual message bodies. Hold message content only in working memory long enough to compute aggregates, then drop it.

### Phase 3: Compute the voice fingerprint

Write the filtered outbound messages to a temp JSON file (`[{ts, text, thread_id}, ...]`) and run `scripts/analyze_voice.py` rather than computing percentiles in your head:

```bash
python3 scripts/analyze_voice.py --input /tmp/outbound.json \
    --contact "Allison" --slug allison > /tmp/fingerprint.json
```

The script exits with code 3 if the sample is under 30 — at that point stop and tell the user voice analysis needs more signal. With 30-100 messages, the fingerprint includes a `warnings` array and the rendered SKILL.md will surface the small-sample caveat.

The fingerprint schema is:

```
{
  "contact": "Allison",
  "slug": "allison",
  "sample_size": 432,
  "window": "2025-05-28 to 2026-05-28",

  "length": {
    "median_chars": 47,
    "p25_chars": 18,
    "p75_chars": 92,
    "pct_under_20_chars": 0.34
  },

  "capitalization": {
    "pct_lowercase_start": 0.71,
    "pct_all_lowercase": 0.42
  },

  "punctuation": {
    "pct_ending_with_period": 0.12,
    "pct_ending_with_nothing": 0.68,
    "pct_ending_with_exclaim": 0.09,
    "pct_ending_with_question": 0.11
  },

  "emoji": {
    "pct_messages_with_emoji": 0.18,
    "top_5": [
      {"emoji": "❤️", "count": 41},
      {"emoji": "😂", "count": 27}
    ]
  },

  "abbreviations": {
    "lol": 38, "lmao": 12, "omw": 24, "ty": 19
  },

  "bursts": {
    "median_messages_per_burst": 2,
    "p75_messages_per_burst": 4,
    "burst_definition_minutes": 2
  },

  "openers": {
    "top_3": [
      {"phrase": "hey", "count": 24},
      {"phrase": "ok", "count": 21},
      {"phrase": "yeah", "count": 19}
    ]
  },

  "closers": {
    "top_3": [
      {"phrase": "love you", "count": 31},
      {"phrase": "<3", "count": 9}
    ]
  }
}
```

These are aggregates — never individual message text.

### Phase 4: Generate the SKILL.md

Run `scripts/render_skill.py` — it consumes the fingerprint JSON from Phase 3 and writes `<slug>-text-voice/SKILL.md` + `fingerprint.json` to the output directory:

```bash
python3 scripts/render_skill.py --fingerprint /tmp/fingerprint.json --output-dir ./skills
```

The render is deterministic — same fingerprint in, same SKILL.md out. For a NEW skill the script refuses to overwrite an existing `<slug>-text-voice/` directory (exit code 4). To **refresh** an existing one in place, pass `--force` (see "Refreshing an existing skill" below).

The generated SKILL.md follows this structure (the script handles all of it):

```markdown
---
name: <slug>-text-voice
description: Draft iMessages to <Contact Name> in James's voice for that specific relationship. Use whenever James asks "text <name>", "reply to <name>", "what should I say to <name>", "draft a message to <name>" — for the 1:1 iMessage thread with <Contact Name>. Captures voice patterns observed across N=<sample> outbound messages (window: <start> to <end>). Pairs with james-text-voice — apply james-text-voice's base rules first, then the overlays here.
---

# <slug>-text-voice

How James texts <Contact Name>, captured from N=<sample> outbound 1:1 messages over <window>.

## Voice fingerprint (observed)

[Render the JSON as a short bulleted summary.]

## Drafting rules (derived)

[Convert observations into imperatives. Examples:
- Median message is <median> chars — keep drafts at or under that.
- <pct_lowercase_start>% of openers are lowercase — default to lowercase first word.
- <pct_ending_with_nothing>% of messages end with no punctuation — only add a period when the tone is genuinely formal.
- Emoji rate is <pct>% — use sparingly; favor <top emoji>.
- Multi-message bursts (median <n>) — when the response is naturally two thoughts, stage them as two separate drafts, not one long message with a paragraph break.]

## Anti-patterns (observed absent or rare)

[List things explicitly NOT to do:
- "Hey there" appears 0 times — never use it.
- Messages over 200 chars are <P95_pct>% — avoid wall-of-text.]

## Drift detection

The fingerprint.json next to this SKILL.md is the snapshot at generation time. If the user texts very differently in 6 months, re-run texting-voice-skill-creator for <Contact Name> and compare.

## Notes

- This skill assumes james-text-voice is also loaded. It is an *overlay*, not a replacement.
- If a drafting request to <Contact Name> conflicts with these patterns (e.g. user says "draft a formal message to <Contact>"), honor the user's explicit override.
- This skill draws from a sample — patterns are statistical, not absolute. Don't be robotic about them.
```

After writing `SKILL.md` and `fingerprint.json` to the new directory, tell the user:

1. The new skill is at `skills/<slug>-text-voice/`.
2. They should review it (especially the description and the "Anti-patterns" section, which can be over-confident on small samples).
3. To activate it for dev, symlink: `ln -snf ../../skills/<slug>-text-voice .claude/skills/<slug>-text-voice` (or run the planned `scripts/dev-link-skills.sh` if it exists).

## Refreshing an existing skill

When the user asks to "refresh my texting voice for [contact]" (or the skill already
exists and they want it re-learned), run the same four phases — but in Phase 4 pass
`--force`:

```bash
python3 scripts/render_skill.py --fingerprint /tmp/fingerprint.json --output-dir ./skills --force
```

`--force` overwrites the existing `<slug>-text-voice/SKILL.md` + `fingerprint.json`
in place and prints a `drift` block in its JSON output — the headline stats
(`sample_size`, `median_chars`, `pct_lowercase_start`, `pct_ending_with_nothing`,
`pct_messages_with_emoji`) as `was` → `now`. Surface that to the user so they can
see how their voice with this contact has shifted. Note: `--force` regenerates the
SKILL.md, so any hand-edits to the generated file are replaced (the fingerprint is
the source of truth). Without `--force`, an existing directory still hard-stops
(exit 4) so a fresh build can't silently clobber.

## Notes for the LLM running this

1. **Never write message bodies to disk.** The output is aggregate stats only. Triple-check the generated SKILL.md and fingerprint.json before writing — search for any direct quotes from messages and remove them.
2. **Sample-size honesty.** Under 30 outbound messages: refuse. 30–100: surface the small-sample caveat prominently in the SKILL.md. 100+: confident output.
3. **Group threads are a different register.** Don't mix 1:1 and group samples. If the user wants a group-context voice skill, generate it separately with the group thread as input — and label it `<group-name>-group-voice` to keep it distinct.
4. **Slug collisions.** If `skills/<slug>-text-voice/` already exists, stop and ask: overwrite, version, or pick a different slug? Don't silently clobber a previously-generated skill.
5. **Respect anthropic-skills:james-text-voice as the base.** The generated skill is an overlay. Reference it explicitly in the description so the model knows to load both.

## Layout

- `SKILL.md` — this file.
- `scripts/analyze_voice.py` — Phase 3 analyzer. Reads outbound-messages JSON, emits fingerprint JSON. Pure stdlib. Enforces the <30-sample refusal.
- `scripts/render_skill.py` — Phase 4 generator. Reads fingerprint JSON, writes `<slug>-text-voice/SKILL.md` + `fingerprint.json`. Refuses to overwrite.
- `examples/sample-fingerprint.json` — what a fingerprint looks like (Allison-shaped example, 36 messages, includes the small-sample warning).

## Future extensions

- ~~Diff mode: surface the deltas (drift report) instead of overwriting.~~ **Shipped** — `render_skill.py --force` overwrites in place and prints a drift summary (see "Refreshing an existing skill").
- Multi-platform: when the contact has WhatsApp history too, pull from `whatsapp-drafts` MCP as well and produce a unified voice profile.
- Group voice: a sibling skill `group-voice-skill-creator` that does the same analysis for a group thread, capturing the user's voice in that group context.
