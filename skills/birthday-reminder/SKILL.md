---
name: birthday-reminder
description: Build the user's birthday list from who they're actually in regular contact with (sourcing birthdays the Mac doesn't have), and surface upcoming birthdays + draft a happy-birthday iMessage. Use when the user asks "build my birthday list", "who should I add for birthdays", "find the birthdays I'm missing", "update my birthday list", "whose birthday is coming up", "any birthdays this week/month", "remind me of birthdays", "did I miss anyone's birthday", "draft a birthday text to [name]", or "what should I text [name] for their birthday". Read-only on message data; outbound is draft-only via the imessage-drafts MCP — never auto-sends. Pairs with texting-analytics (relationship context), james-text-voice (base voice), and birthday-text-voice (learned birthday voice).
---

# birthday-reminder

Two jobs, one skill:

- **Mode A — Build / update the list.** Figure out *who* should be on the user's
  birthday list (the people they're actually in regular contact with), source the
  birthdays the Mac doesn't already have, ask the user about the rest, and write
  the finalized list back into the app.
- **Mode B — Remind + draft.** Once the list exists, surface upcoming birthdays
  and (optionally) draft a happy-birthday iMessage that sounds like the user.

The list lives at `~/.messages-mcp/birthdays.json` and is read by the Messages
for AI menu-bar app (which shows it, reminds, and runs the draft/approve/send
gate). **The skill never auto-sends** — drafts go through the app's hold-to-fire
approval gate.

## Why Mode A exists (the core idea)

The Mac's own data is too sparse to build a good list: most people the user texts
regularly have **no birthday saved in Contacts**. So a list built only from "saved
birthdays" is tiny and full of gaps. The division of labor:

- **The app is great at "who."** It scans the message history (metadata only) and
  produces a *seed*: everyone the user is in regular contact with, marked with a
  saved birthday, an inferred birthday, or neither.
- **You (the LLM) build the list.** You take the seed, source the missing
  birthdays (from the date of past "happy birthday" texts, thread context, and by
  **asking the user**), and write the finalized list back.

The seed is the candidate *pool*, not the final list. The user decides who's
actually on it — you help them get there fast.

---

## Mode A — Build / update my birthday list

Triggers: "build my birthday list", "who should I add", "find birthdays I'm
missing", "update my birthday list", "let's set up birthdays".

### A1. Get the seed (who you're in regular contact with)

If the app already wrote a seed at `~/.messages-mcp/birthday-seed.json` (the
"Build my birthday list" button does this), use it. Otherwise generate it with
the engine:

```bash
# From the repo root. (This skill lives at skills/birthday-reminder/, so from the
# skill dir the engine is ../../mcps/birthday-generator/src/index.ts.)
bun run mcps/birthday-generator/src/index.ts --seed --out ~/.messages-mcp/birthday-seed.json
```

The seed needs to read `~/Library/Messages/chat.db`, which requires Full Disk
Access on whatever launched this session. The output reports `signals_available`:
if it's `false`, the scan couldn't open chat.db — tell the user to run the app
(which holds FDA) or grant FDA to the terminal, and stop. The seed shape:

```json
{ "contacts_available": true, "signals_available": true, "count": 120,
  "contacts": [ { "name": "...", "best_handle": "...", "saved_birthday": "MM-DD|YYYY-MM-DD|null",
                  "inferred_birthday": "MM-DD|null", "out_count": 0, "call_count": 0,
                  "last_texted_days": 0, "last_call_days": null, "reason": "..." } ] }
```

Contacts are **sorted closest-first** (text + call affinity). `inferred_birthday`
is the month-day of a past "happy birthday" text — an approximate guess for
someone with no saved date.

### A2. Bucket the seed into a work-list

Don't eyeball 120 rows. Run the categorizer — it diffs the seed against the
already-built list and tells you what to do with each person:

```bash
python3 skills/birthday-reminder/scripts/plan_list.py --seed ~/.messages-mcp/birthday-seed.json
# or pipe straight from the engine:
# bun run mcps/birthday-generator/src/index.ts --seed | python3 .../plan_list.py --seed -
```

Buckets (each person in exactly one):

- `already_on_list` — already in `birthdays.json`. Skip (or confirm only if asked).
- `ready_saved` — has a saved birthday, not yet on the list. Ready to add.
- `confirm_inferred` — a birthday was inferred from a past wish. **Confirm it.**
- `needs_sourcing` — no date at all. **Source it or ask.**

Pass `--top N` to consider only the closest N (the seed is affinity-sorted), e.g.
`--top 40` for a first pass.

### A3. Resolve birthdays, closest-first

Work the buckets in this order, and **batch your questions** — never interrogate
the user one person at a time:

1. **`ready_saved`**: include them. Saved date, nothing to ask.
2. **`confirm_inferred`**: each has a date inferred from when the user last texted
   "happy birthday." It's approximate (a wish sent near midnight can be a day off).
   To strengthen it before asking, you may read the thread and check whether the
   wish recurs on the same month-day across years (consistent = high confidence) —
   see the imessage-drafts MCP below. Then present them together: "I inferred these
   from your past birthday texts — confirm or fix any." Let the user correct in bulk.
3. **`needs_sourcing`**: no date.
   - *Best effort:* read the thread for an explicit mention ("my birthday's the
     12th", "turning 30 next month"). This is hit-or-miss — don't force it, and
     don't burn many turns per person.
   - *Otherwise ask.* Present the names in one batch and let the user fill in what
     they know and skip the rest. This is the expected path for most of them, and
     it's fine — the user knows their people's birthdays better than the data does.

**Process closest-first and offer a natural cutoff.** After the top tier (say the
first 30–40), check in: "That's your closest circle. Want to keep going further
down, or call the list done here?" The user decides depth; you don't auto-include
all 120.

Reading threads for sourcing: use `mcp__imessage-drafts__list_threads`
(`contact_filter` = the name) to get a `thread_id`, then `search_messages` /
`get_thread`. Reading the user's own messages to find a birthday date is exactly
the intended gated read here. But **store only the date** (plus, at most, a short
note the user confirms) — never copy raw message text into the list.

### A4. Write the finalized list back

Assemble the confirmed people as a JSON array and import them (one atomic write;
preserves existing entries + unknown fields; validates every date):

```bash
# Write the array to a temp file, then:
bun run mcps/birthday-generator/src/index.ts --import --in /tmp/birthday-import.json
```

Each entry:

```json
{ "name": "Sam Sample", "contact_handle": "samsample@example.com",
  "birthday": "07-15", "relationship": "friend", "notes": "optional short cue" }
```

- `birthday` is `MM-DD` or `YYYY-MM-DD`. `contact_handle` should be the seed's
  `best_handle` (so the app can route a draft). `relationship` is one of
  partner / family / friend / colleague when you know it; omit if you don't.
- Imported entries are **pinned** ("on your list") by default. Don't include
  people the user didn't confirm.
- The import reports `{ created, updated, skipped, skipped_detail }`. Relay it:
  "Added N, skipped M (bad/missing dates)." Invalid rows are skipped, not fatal.

If you **can't write files** (e.g. a sandboxed Cowork session), output the same
JSON array as a paste-able block and tell the user to paste it into the app's
Import field. The `--import` path above is the clean route when you have a shell
(Claude Code / Codex).

### A5. Confirm

Tell the user what's on the list now and that the app will show it + remind them.
Offer Mode B: "Want me to draft anyone's birthday text, or show what's coming up?"

---

## Mode B — Remind + draft

Triggers: "whose birthday is coming up", "any birthdays this week/month", "remind
me of birthdays", "did I miss anyone", "draft a birthday text to [name]".

Three phases. Don't skip any.

### Phase 1: Resolve upcoming birthdays

Run `scripts/birthdays.py` rather than computing dates yourself (it handles leap
years, year-wrap, and missing fields):

```bash
python3 skills/birthday-reminder/scripts/birthdays.py --input ~/.messages-mcp/birthdays.json --window 14
```

Output: `{ today, window_days, count, upcoming: [...] }`; each `upcoming` entry has
`name`, `contact_handle`, `next_occurrence`, `days_until`, `weekday`, `age_turning`
(null if no birth year), `relationship`, `notes`, `last_year_skipped`.

Honor an explicit window ("next 30 days" → 30, "this month" → ~31). If the input
file **doesn't exist** the script exits 2 — the user has no list yet, so switch to
**Mode A** ("Let's build your list first"). If `count` is 0, say so plainly:
"No birthdays in the next N days." Don't pad.

### Phase 2: Enrich with context (optional)

For each upcoming birthday, optionally surface recency from the imessage-drafts
MCP: `list_threads` with `contact_filter` = the name, then read the last message's
timestamp to show "last texted N days ago." In Mode B, do **not** pull message
bodies — the timestamp is enough, and bodies leak into drafts. (Mode A is
different: there, reading a thread to source a birthday is the point.)

Skip Phase 2 if the user only asked for a list.

### Phase 3: Briefing or draft

**If briefing**, render markdown:

```
## Birthdays — next 14 days

- **Allison** — Wed Jun 4 (in 7 days) · partner · last texted today
- **Mark** — Sat Jun 7 (in 10 days) · friend · last texted 3 weeks ago
```

End with a one-line nudge if any "last texted" is >2 weeks: "Worth a no-occasion
check-in to Mark before the birthday text lands."

**If draft**, layer two voice skills:
1. `anthropic-skills:james-text-voice` (if available) — base texting voice.
2. `birthday-text-voice` (if available) — his birthday voice, learned from past
   wishes. Read its `VOICE.md`, pick the section for the contact's `relationship`
   tier (fall back to Overall, then base voice), apply those patterns (length,
   emoji, the birthday-emoji habit, punctuation, burst shape).

Pass the voice skills the contact's name, relationship, and `notes`, plus:
"Draft a happy-birthday text for [name], James's [relationship]. Apply
james-text-voice, then the birthday-text-voice patterns for the [relationship]
tier. Don't make it generic — use the `notes` field if present."

If `birthday-text-voice` has no `VOICE.md` yet, fall back to relationship tone
(warm-and-personal for family/partner, casual for friends, brief-and-kind for
colleagues) and mention the user can say "refresh my birthday voice" to learn it.

Then call `stage_draft` with the rendered text and the contact's handle. The
menu-bar app picks it up for hold-to-fire approval.

## Data source

The list is `~/.messages-mcp/birthdays.json` (v1), an array of:

```json
{ "name": "Alex Chen", "contact_handle": "+15551234567",
  "birthday": "MM-DD or YYYY-MM-DD", "relationship": "friend",
  "notes": "free-form context", "pinned": true }
```

`contact_handle` should match the canonical handle the iMessage MCP returns from
`list_threads`. The file is **built by Mode A and the app's curation**, not
hand-edited by the user — if it's missing or thin, run Mode A.

## First-time setup

If `~/.messages-mcp/birthdays.json` doesn't exist, **don't** seed it from the
example file and don't ask the user to hand-write JSON. Run **Mode A**: generate
the seed, source the birthdays, and write the list. That's the whole point — the
list should come from who they actually talk to, not a blank file.

## Notes for the LLM running this

1. **Never auto-send.** Even on "send Mark a birthday text," stage a draft and say
   it's queued in the menu-bar app. The approval gate is the product.
2. **Privacy — store dates, not bodies.** Mode A may read threads to source a
   birthday, but only the date (and a short, user-confirmed note) is written to
   `birthdays.json`. Never write raw message text. Never paste names + birthdays
   into a third-party service; everything stays under `~/.messages-mcp/`.
3. **Don't fake a birthday.** An inferred date is a *guess to confirm*, not a fact.
   If you can't source or confirm a date, leave the person off and say so — better
   a shorter true list than a wrong one.
4. **Batch your questions** in Mode A. A 40-question interrogation is a failure
   mode; group the asks so the user answers in one pass.
5. **Handles must match** for drafting: `stage_draft`'s `to_handle` must come from
   `list_threads`. Resolve via `contact_filter` before staging.
6. **Higher bar for family/partner.** Use the `notes` field; a generic "Happy
   birthday!" to a spouse is worse than no reminder.

## Layout

- `SKILL.md` — this file.
- `scripts/plan_list.py` — buckets the engine `--seed` output into a work-list
  (already_on_list / ready_saved / confirm_inferred / needs_sourcing). Pure stdlib.
- `scripts/birthdays.py` — date resolver for Mode B (leap years, year-wrap). Pure stdlib.
- `examples/birthdays.example.json` — schema example (kept for reference only;
  Mode A builds the real list, don't seed from this).
- `tests/` — `python3 -m unittest` from the skill dir.

## Future extensions

- App "Build my birthday list" button writes the seed + opens this skill, and an
  Import field accepts the paste-able block for sandboxed sessions (in progress).
- `listBirthdays` daemon RPC pulling from `CNContactStore` so saved birthdays
  don't need the Contacts cache export.
- Weekly digest mode: a scheduled "this week's birthdays" summary.
- Group-birthday awareness for coordinating a group thread.
