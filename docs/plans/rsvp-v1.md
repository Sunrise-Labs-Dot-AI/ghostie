# RSVP V1: messaging-native invites, status, and unified view

Tracks GitHub epic [#47](https://github.com/Sunrise-Labs-Dot-AI/ghostie/issues/47)
and children #48 to #54. Supersedes the archived draft ghostie-archive#140 as the
implementation plan. Written 2026-09-19.

## Goal

Ship a first-party sidebar tool called **RSVP** that (1) finds the events
friends invited you to across iMessage and WhatsApp threads and shows your
inferred reply status, and (2) lets you host an event, invite people through
the existing staged-draft approval path, and track who said yes, no, or maybe.
No public RSVP page, no auto-send, no message bodies on disk.

## Shape of the solution (decided)

RSVP is built as a **Swift lab in the menu bar app**, the same shape as Don't
Ghost, not as a Bun generator. Reason: every piece it needs already lives in
Swift: BYOK key access (`LabModelPreferences.clientSelection`), the budget gate
(`AIBudgetPrecheck`), usage metering (`AIUsageLedger`), the WhatsApp decrypt path
(`WhatsAppRPCClient`), the contacts sidecar, and draft creation (`DraftStore`).
A generator would have to re-implement the first four.

Sequencing is **Invited first, Hosting second**:

- V1a Invited (#52, #48 inbound half, #49 Invited mode): read-only. No new send
  authority. Exercises the store, the scanner, the extractor, and the flag/analytics
  plumbing that Hosting then reuses. The first-run "it found my invites" moment is
  the PLG hook, the same way Don't Ghost's first scan is.
- V1b Hosting (#50, #51, #48 outbound half): event creation, invites via drafts,
  guest reply classification (the same extractor with a different prompt).
- V1c enhancements (#53 email summary, #54 add to calendar).

Both transports are in scope from V1a. Don't Ghost already scans both with one
code path, and the WhatsApp leg degrades to iMessage-only when the daemon is
down (`RPCError.isDaemonUnavailable`).

## Scope and trust boundary

- New tool behind `MFAFeatureFlag.rsvp` (PostHog key `rsvp`, builtin default
  off, dev override in Settings). Hidden from the sidebar and onboarding until the
  flag resolves true.
- All chat.db reads are read-only SQLite opened from the menu bar process (FDA is
  launcher-attributed, see `CLAUDE.md`). WhatsApp bodies come through the daemon
  socket only.
- The LLM never causes a send. Extraction and classification write records to
  the RSVP store; every outbound message is a normal `Draft` that passes the
  existing approval gates (hold-to-fire, or scheduled with a per-draft HMAC tag
  from `ApprovalAuthenticator`). Nothing in RSVP calls `DraftSender.send` without a
  user gesture on that draft or batch.
- Store: `~/.messages-mcp/rsvp.json`, `schema_version` 1, 0600, atomic write,
  corrupt-file quarantine (copy of the `KeepTabsStore` block). Holds structured
  fields only: titles (max 80 chars), place names, times, statuses, confidence,
  evidence message ids and timestamps, contact keys and display names. **No
  message bodies and no free-text rationale.** Evidence is re-hydrated from
  chat.db or the WhatsApp daemon at render time, the way `DontGhostCacheStore`
  does.
- Telemetry: closed enums and buckets only, enforced by the existing
  `AnalyticsClient.sanitize` allowlist. New events carry `lab`, `mode`
  (invited or hosting), `result_count_bucket`, `duration_bucket`, and a status
  enum. Never names, handles, bodies, addresses, or free text.
- Message content that reaches a prompt is untrusted: sanitized (zero-width
  strip, angle-bracket escape, per-message byte cap) and wrapped in
  `<untrusted_content>` blocks, a Swift port of `mcps/shared/src/untrusted.ts`.
  The system prompt states that content inside those blocks is data, never
  instructions.
- Non-goals for V1 (from #47): public RSVP page, unchecked auto-send, Google
  Calendar sync as a dependency, MCP-facing RSVP tools, location autocomplete
  (place is free text in V1).

## Data model

```
RSVPDatabase { schema_version: 1, events: [RSVPEvent], guests: [RSVPGuest],
               dismissals: [RSVPDismissal], scan_state: RSVPScanState }

RSVPEvent   { id, kind: invited|hosting, title, start?, end?, place_name?,
              address?, description?, rsvp_deadline?, status: active|cancelled|
              dismissed|archived, source: { platform, thread_id,
              host_contact_key? }, evidence_message_id?, evidence_at?,
              confidence?, user_status: yes|no|maybe|unknown|needsReview,
              user_status_overridden: Bool, created_at, updated_at }

RSVPGuest   { id, event_id, contact_key, display_name, routes: [ { platform,
              handle } ], selected_route?, invite_draft_ids: [String],
              invite_sent_at?, rsvp_status: yes|no|maybe|unknown|needsReview,
              confidence?, party_size?, evidence_message_id?, evidence_at?,
              needs_review: Bool, overridden: Bool, updated_at }

RSVPDismissal { key: "<platform>:<thread_id>:<evidence_message_id>", at }
RSVPScanState { last_scan_at?, lookback_days, thread_tail: { "<platform>:
              <thread_id>": last_message_key } }
```

Contact keys use `ContactAvatarStore.canonicalKey` so iMessage and WhatsApp
handles for one person collapse to one guest. Transport-specific ids (chat guid,
JID) live only inside `routes` and `source`, never in the event model proper.

## Prototype findings (2026-09-19, deterministic pass over one real 90-day history)

A read-only Python prototype (no model) over 219 threads and 8,908 texts,
three tuning passes, graded by hand on snippets:

- Naive cues (invitation phrase or event noun plus a date signal) gave 127
  candidates at about 40 percent precision. Work and household logistics were
  the main false positives ("are you free Tuesday 3pm", "what do you want for
  lunch", "cal invite").
- Three deterministic fixes took it to 95 candidates at roughly two thirds
  precision, four fifths in the high tier: gate "want to" and "wanna" on an
  activity verb; subtract a logistics lexicon (zoom, call, meeting, recruiter,
  nanny, pick up, reservation); skip threads whose people the Severance store
  labels business, work, spam, or neither; boost group-invite patterns ("who's
  in", "anyone want", "any dads"); parse Partiful, Evite, and Paperless Post
  texts exactly (they carry the title).
- Dates: two thirds of candidates resolve to a day from a weekday, "tonight",
  "tomorrow", or an explicit date; the rest need the model or a Needs review
  state.
- Reply status: the easy replies classify ("unfortunately can't tonight",
  "yup I'm around"); sympathy "sorry", "would love to but", and double
  negatives are misread. About 60 percent on decided replies.
- Titles: deterministic output is "Bowling (group name)" or "Golf with X";
  only platform texts yield a real title.

Consequence for the plan: build the Invited scanner the way Don't Ghost is
built. Deterministic core that works with no key (candidates, dates, group
invites, platform invites, easy replies), with an optional AI pass that
sharpens titles, places, and reply status and demotes logistics chatter. A
Haiku-class model is enough for that pass; no Sonnet-class reasoning is
required. The tool therefore does not require an API key.

## AI in the loop (decided after the prototype)

The model is on by default, not a boost. The deterministic pass owns discovery
(it is complete and free); the model owns verification and extraction over the
roughly 100 candidate clusters a 90-day window produces: social invite versus
logistics, title, place, the missing third of dates, and reply nuance ("would
love to but", sympathy "sorry", double negatives). That is about 150k input
tokens per full scan on a Haiku-class model, cents thereafter. No-key mode still
runs the deterministic pass and shows a Needs review heavy list; it is a
fallback, not the headline.

## Reciprocity and response analytics (new child issue, after V1a)

The RSVP store makes these countable without bodies. Definitions, 1:1 and
group reported separately:

- Response rate: replied or tapbacked within 72 hours, over inbound invites.
- No-RSVP rate: no reply and no tapback within 72 hours, over inbound invites.
- Turn-down rate: no, over decided (yes, no, maybe).
- Hosting hit rate: yes over decided, and yes over all invited.
- Reciprocity balance per person: invites from them minus invites from me in
  the window. Group invites attribute to the sender of the anchor message;
  platform texts attribute to the host named in the text, not the sender.
- Reply latency: median hours from invite to first reply.

Surfaces: a summary strip at the top of the RSVP tool (this quarter's counts),
RSVP cards in Texting Analytics, and Wrapped story cards (top inviter, the
friend you owe an invite, flake rate, no-RSVP rate, hosting hit rate). Don't
Ghost consumes unanswered inbound invites older than 48 hours as its strongest
owed-reply signal, replacing the `invitationCues` heuristic. Requires two model
additions: `host_contact_key` on inbound events and a household exclusion
(partner and family threads dominate raw counts).

The prototype computed every one of these from its deterministic list in a
few lines of code, so the metrics cost nothing beyond the store. Personal
results stay out of this document.

## Sweep model: backfill once, then incremental (decided 2026-09-20)

The model never re-reads text it has already judged. Three pieces:

**Watermarks.** `scan_state` holds `imessage_watermark_rowid` (the `message.ROWID`
high-water mark; ROWID rather than date because iCloud sync inserts older-dated
rows with new ROWIDs), a `whatsapp_watermark` for the daemon's `messages.db`,
`last_sweep_at`, and `backfill_completed_at` with `backfill_days`. Watermarks are
per transport so a WhatsApp daemon outage skips that leg without losing it. A
watermark advances only after the deterministic pass for that sweep has been
persisted.

**Open events.** Each event carries `open_until`: end of the event day when a
date is known, otherwise anchor plus 14 days. Past `open_until` an event is
closed: frozen for analytics, never sent to the model again. Each event also
stores `last_reply_rowid_seen` per relevant thread.

**Result cache.** `ai_cache` maps a content key to the structured result (no
bodies): cluster key `platform:thread:anchor_rowid:tail_rowid` for verify and
extract, reply key `event_id:last_relevant_rowid` for reply classification.
Re-sweeps, tool re-opens, and app restarts hit the cache.

**Each sweep** (on tool open, every 15 minutes while the app runs, about 100 ms
of SQL):

1. Read rows above the watermark, plus tapback rows whose
   `associated_message_guid` points at an open event's anchor.
2. Score new texts deterministically. For each candidate load its thread's
   24-hour window (max 40 messages) to cluster. New clusters go to queue A
   (verify and extract). Clusters that fail deterministic scoring never reach
   the model.
3. For each open event, if a new row landed on the relevant side (Invited: my
   outbound texts or my tapback on the anchor; Hosting: inbound from that
   guest's thread), queue B (classify reply) keyed by the latest relevant rowid.
   Group chatter from third parties does not trigger a call.
4. Close events past `open_until`. Advance the watermarks.
5. Drain queue A in batches of five clusters per call and queue B as one call
   for all touched events, each with its post-invite window (max 20 messages).
   `AIBudgetPrecheck` before every call. A failed call leaves the rows marked
   `needs_ai` (shown as Needs review) and the next sweep retries only those.

**Backfill.** First open runs the deterministic pass over the lookback window
(30 days default, 90 optional) in about a second; rows appear immediately as
"checking", then upgrade as the model verifies in batches (about 20 calls for
90 days). Past events are verified too because the analytics need them.

**Measured on one real 90-day history** (deterministic prototype, on the order
of a hundred texts a day): about one new candidate cluster a day (no candidate
on four days in ten), about 10 open events at any time, and about 1.5 open
events touched by new thread messages a day before the relevant-side filter. Model load is a median of 2.8k
tokens a day, worst day 10k, so roughly $0.10 a month on a Haiku-class model
after a backfill of about 140k tokens for 90 days. The cost floor was already
low; what the incremental design buys is a sweep that feels instant and a model
that only ever sees new text.

**Hosted invites are tracked exactly, not discovered.** An invite sent through
Ghostie leaves a `Draft` with `source: "rsvp"`, the recipient handle, the
thread, and `sent_at`, and the guest record keeps its `invite_draft_ids`. The
sweep therefore knows the exact threads to watch and only reads inbound rows
in them after `sent_at`. After send it also locates the sent row in chat.db
(handle plus a one-minute window around `sent_at` plus body match) and reads
what iMessage already records on it: `date_delivered`, `date_read` when the
guest has read receipts on, and tapbacks whose `associated_message_guid` is
that row. That gives a deterministic per-guest ladder, not delivered, delivered,
seen, replied, before the model classifies a single word; a tapback like or
love on the invite is a yes signal with no model call. The same exact link
drives follow-ups: seen with no reply after 48 hours, or not seen after 72
hours, surfaces as a nudge draft. Invites typed directly in Messages still go
through discovery like any outbound candidate. WhatsApp gets the same ladder
where the daemon exposes delivery and read state.

**Edge cases.** An anchor row that disappears (unsend) flips its event to Needs
review. Edited bodies are ignored unless the anchor itself changed, which
re-keys the cluster. Rows older than the lookback window that arrive through
sync are ignored even though their ROWID is new.

## Addressing: direct, named, or open (decided 2026-09-20)

Not every invite carries the same obligation. Each inbound event gets an
`addressing` value that drives ranking, analytics, the Don't Ghost handoff,
and the register of the suggested reply:

- `direct`: a 1:1 thread.
- `named`: a group message that names me (an iMessage mention when the
  `attributedBody` carries one, else my first name or nicknames from the
  Contacts me card, configurable), says "you two" or "you both", or lands in a
  small group (three others or fewer) with "you guys" or "you".
- `open`: a group call with no one named ("who's in", "anyone want", "any
  dads", "who's around"), or any larger group with no addressing cue.

Deterministic rules assign it first; the model confirms it as one field of the
extraction JSON, since "Sam you should come" versus "anyone?" is exactly the
kind of read a small model gets right. `audience_size` (others in the thread)
and `thread_velocity` (messages a day over 30 days, bucketed quiet, normal,
noisy) are stored alongside so "open call in a noisy chat" is distinguishable
from "open call in a four-person chat".

`response_weight` (direct 1.0, named 0.8, open 0.3) multiplies with recency
and relationship strength (Keep Tabs watchlist, thread priorities, message
frequency) to order the Invited list. Effects:

- Direct and named invites unanswered after 24 hours go red; open calls close
  quietly when the event passes and never count against you.
- The headline no-RSVP and flake rates use direct and named only; open calls
  are reported as their own line.
- Don't Ghost receives direct and named unanswered invites as its heaviest
  owed-reply signal and never receives open calls.
- The suggested reply register follows the tier: a thoughtful draft in the
  texting voice for direct and named, a one-line "in" or "out" for open.

In the prototype window the three tiers were roughly equal in count among
inbound invites, and the unanswered share differed sharply by tier, with the
named tier (small groups of three to five people) the one most often left
hanging. That is also the tier where silence is most visible, which is the
argument for surfacing it.

## Extraction pipeline (#48)

1. **Candidate threads.** iMessage 1:1 and group chats (`chat.style IN (43, 45)`)
   plus WhatsApp 1:1 and group threads, active within the lookback window (default
   30 days, user-selectable 30 or 90). Cap 300 threads. Per thread load the last
   40 messages (bounded by count, as Don't Ghost does) truncated to 600 chars each.
2. **Deterministic pre-filter** (no LLM, fully unit-tested on synthetic
   fixtures). A thread is a candidate only if a message in the window matches
   both an invitation cue (Don't Ghost's `invitationCues` plus `invite`, `party`,
   `birthday`, `wedding`, `housewarming`, `bbq`, `join us`, `save the date`,
   `you in`) and a date or time signal from `NSDataDetector` (`.date`) or a
   weekday word. This is what keeps LLM spend bounded.
3. **LLM extraction.** Batches of up to 5 candidate threads per call through a
   new shared `LabLLMClient` (extracted from `DontGhostLLMClient`, provider
   dispatch for Anthropic and OpenAI unchanged, usage reported to
   `AIUsageLedger`, `AIBudgetPrecheck.allow(lab: .rsvp)` before every call). The
   prompt carries the reference date and timezone so "Saturday" resolves, and
   asks for strict JSON:
   `{ "threads": [ { "thread_ref", "events": [ { "title", "start_iso"?,
   "end_iso"?, "place"?, "direction": "inbound"|"outbound", "host_message_id",
   "user_status": "yes"|"no"|"maybe"|"unknown"|"needsReview",
   "status_evidence_message_id"?, "party_size"?, "confidence": 0..1 } ] } ] }`.
4. **Strict parse.** Tolerant envelope (`jsonCandidates`, code fences stripped),
   strict rows: dates must parse as ISO-8601, statuses must be in the enum,
   message ids must be ones we sent in the prompt, confidence clamped to [0, 1],
   title trimmed to 80 chars. Bad rows drop; a batch with zero valid rows is a
   parse failure, not silent success.
5. **Merge.** Key events by `platform:thread_id:host_message_id`. Dismissals and
   user overrides are sticky. Rescans skip threads whose tail message key has not
   moved. Events with confidence below 0.6 land in the Needs review section.
6. **Guest reply classification (#51)** reuses steps 3 to 5 with a second prompt
   over the guest thread window that starts at the invite draft's `sent_at`
   (max 20 messages). Latest evidence wins; a manual override stays in force and
   newer inbound evidence sets `needs_review` instead of overwriting it.

Only Invited-side extraction ships in V1a. The direction field is produced from
day one so outbound invites (V1b) need no schema change.

## Implementation (PR sequence)

Each PR is branch to PR to CI to `gh pr merge --admin --squash` by James. Each
carries its own tests and an adversarial review before merge.

1. **PR 1, scaffolding and flag (#52).** `MFAFeatureFlag.rsvp`; `AILab.rsvp` with
   a per-feature token estimate; `AnalyticsLab.rsvp`, `AnalyticsFeature.rsvp`,
   the new event names and their allowlist rows; `ToolCatalog.rsvp` in all four
   sets; the `ConsoleTool` entry (`featureFlag: .rsvp`, `requiresAPIKey` per the
   open decision below) with intro copy, a placeholder view, and a
   `labSidebarOrder` slot; `RSVPStore` with the schema above and the
   load/quarantine/persist block. Ships dark.
2. **PR 2, extraction engine (#48 inbound).** `RSVPScanner` (chat.db and WhatsApp
   candidates, pre-filter), `UntrustedPromptContent` (sanitize and wrap),
   `LabLLMClient` (shared), `RSVPExtractionParser`, `RSVPController.scan()`
   wiring the budget gate, ledger, analytics, and merge. A "Scan now" button on
   the placeholder view.
3. **PR 3, Invited UI (#49 Invited).** List with title, when, status, host,
   source; Needs review section; confirm, dismiss, edit (title, date, place,
   status), open source thread (`pendingConversationHandles`, the Birthdays
   deep-link); lookback picker; last-scan time; empty states. V1a complete.
   Turn the flag on through James's dev override and dogfood on the M4 and M1
   before any wider rollout.
4. **PR 4, Hosting create and invite (#50, drafts path).** Event form with
   validation (name, date, start required; end after start; deadline before
   start; timezone-safe formatting); guest picker over
   `ContactsExporter.searchContacts` and recent threads; per-guest route choice
   when a contact has both an iMessage and a WhatsApp handle; invite copy as a
   blast template with a `{name}` placeholder or per-guest LLM personalization
   from event details and the display name only (no thread bodies in that
   prompt); "Send to Drafts" stages one `Draft` per guest with
   `source: "rsvp"`, no context messages, each approved individually through the
   existing Drafts pane. Hosting tab lists events and guests.
5. **PR 5, guest tracking (#51, #48 outbound).** Reply classifier over guest
   threads; per-guest status, party size, headcount, needs-review queue; manual
   override; message all, filtered, or one guest via drafts; follow up unanswered;
   cancel silently or with a staged notice.
6. **PR 6, batch approval (#50, gated on decision 1 below).** "Schedule all" stages
   N scheduled drafts, shows a review list with every recipient and body, and on
   one confirm calls `DraftStore.updateScheduling(scheduleApproved: .some(true))`
   per draft so each gets its own HMAC tag and flows through
   `ScheduledSendController` (quiet hours, fails closed on any tampered draft).
   Batch cap 25 per gesture, enforced in Swift because the daemon daily caps do
   not cover the Swift send path.
7. **PR 7, email summary (#53).** `mailto:` with a plain-text summary of selected
   or all upcoming events; self only.
8. **PR 8, add to calendar (#54).** ICS export first (no new entitlement), then
   EventKit add behind a Calendars usage string. No silent calendar writes.

Follow-up issue, not in this plan: migrate the other five inline LLM clients
(Don't Ghost, EQ, Deep Read, Texting Voice, Severance) onto `LabLLMClient`.

## Tests and acceptance evidence

Swift (`menubar/Tests/MessagesForAIMenuTests/`):

- `RSVPStoreTests`: 0600, atomic write, corrupt quarantine, schema stamp, and a
  guard test that encodes a fixture and asserts the key set contains no
  body-like field.
- `RSVPPrefilterTests`: synthetic threads; detects invites with dates, ignores
  plain "dinner was great" chatter and transactional threads.
- `RSVPExtractionParserTests`: code fences, bad dates, unknown statuses, foreign
  message ids, confidence out of range, all-bad batch.
- `RSVPClassifierEvalTests`: synthetic replies for yes, no, maybe, plus-one,
  changed answer, cancellation, no reply, and the override-sticky rule.
- `UntrustedPromptContentTests`: zero-width strip, angle-bracket escape, byte
  cap, and a fixture with an instruction-shaped message that must survive as
  inert data.
- `RSVPBatchApprovalTests` (PR 6): each draft gets a verifiable tag; the 26th
  draft is refused; a body edited after approval fails
  `isScheduleAuthenticallyApproved`.
- `FeatureFlagTests.testBuiltinDefaultsMatchShipPolicy` keeps `rsvp` off;
  `AnalyticsClientTests` cover the new allowlist rows and reject a `title` key.

Fixtures stay synthetic (`tests/fixtures/`). No real thread content in tests.

## Traceability to the epic

| Issue | PR | Acceptance |
|---|---|---|
| #52 flag + analytics | 1 | flag off by default, dev override, six events allowlisted |
| #48 extraction | 2, 5 | clear invites found, non-events ignored, status with confidence and evidence id |
| #49 unified UI | 3, 4 | one list, confirm/dismiss/edit, clear empty and low-confidence states |
| #50 hosting | 4, 6 | create/edit/cancel, per-guest route, batch approval keeps the approval story |
| #51 guest tracking | 5 | five statuses, override, message by filter, follow up |
| #53 email summary | 7 | self only |
| #54 calendar | 8 | one tap, no silent writes |

## Risks

- **Prompt injection through message content.** Sanitized and wrapped content,
  strict output schema, and the structural fact that model output only writes
  store rows. A send always needs a human gesture on a concrete draft.
- **LLM spend.** Pre-filter, 300-thread cap, 40-message window, batch of 5, the
  budget gate, and tail-key rescans. Rough full-scan cost on a small model is
  cents; see the brief.
- **Group-chat noise.** Confidence threshold plus Needs review plus sticky
  dismissals; the pre-filter requires a date signal.
- **Relative dates and DST.** Reference date and timezone in the prompt;
  parser tests around DST boundaries; "date unsure" state when `start` is
  missing.
- **Batch approval widens the blast radius.** Cap, full preview, per-draft tags,
  scheduled path fails closed. Gated on decision 1.
- **Six-way copy of the LLM client grows to seven.** Avoided by introducing the
  shared client in PR 2 and filing the migration follow-up.

## Rollback

Flag off remotely (PostHog remote beats builtin) hides the tool without a
release. Each PR is a clean revert. The store file is additive and ignored by
every other tool; deleting `~/.messages-mcp/rsvp.json` resets the feature.

## Verification and rollout

1. After PR 3: dev override on for James; scan the last 30 days on the M4;
   expect the real invites of that window found with at most one false positive
   per ten rows, and PostHog `rsvp` events with zero sanitizer rejections in
   `DiagnosticsStore`.
2. After PR 5: host one real event with five or more guests through the drafts
   path; expect replies classified within one scan of arrival.
3. Flag on remotely for everyone only after both dogfood checks pass and a
   release (James runs `release.sh`) carries the code.
