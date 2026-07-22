# SUN-613 phase 1 (read-only): the redaction projection

Loop: **full**. Defines how message content is projected into a cross-device artifact. Privacy core.

Branch `claude/sun-613-phase-1-read-credential`, worktree `.claude/worktrees/sun-613-p1ro`, off
`origin/main` at 20cdc19.

**Rewritten after a second-lane plan review returned BLOCK on the first version** (7 CRITICAL).
Artifact: `runs/reviews/2026-07-22-sun-613-phase-1-plan.md`. The review changed the phase boundary,
not just the field list.

## What the review changed

The first version wired a snapshot publisher into `DraftStore` and wrote per-draft JSON files to
disk. Three findings together (7, 8, 9) showed that is the wrong unit of work:

- **The data plane is undecided.** The M4 cannot read the M1's local directory. Phase 2 is either
  authenticated push (spoke to hub) or authenticated pull (hub reaches each spoke), and those need
  different storage, retry, and deletion contracts. Building persistent storage before that decision
  is premature (finding 7).
- **The queue schema can't be right yet.** An authoritative cross-device queue needs a per-origin
  manifest with a monotonic generation, publish time, complete membership, and tombstones, so a
  device that deletes a draft then goes offline does not leave a phantom. None of that can be settled
  without the transport (finding 8).
- **Writing files nothing reads is the same dead code the plan claimed to avoid**, except it also
  persists message bodies to disk for no runtime consumer (finding 9).

So the publisher, its storage, the manifest, the credential, the flag, and the wiring all move to
phase 2, built as one vertical slice with their consumer. Per the reviewer's explicit carve-out,
what CAN land first, with no wiring and no bodies on disk, is the pure redaction projection and its
adversarial tests, which every phase-2 design needs identically.

## What gets built now (pure, no runtime footprint)

A set of value types and one pure function that projects a `Draft` into the read-only shape a remote
reviewer may see, plus the test suite that proves the projection cannot leak.

**A. Projection types**, each a dedicated allowlist, never a copy of the source model:

  - `RelaySnapshot`: `schema_version`, `snapshot_id`, `origin_device_id` (injected, see below),
    `platform`, `recipient` (a `RelayRecipient`, never a raw handle/guid), `body`, `context`
    (`[RelayContextMessage]`), `staged_at`, `lifecycle`, `has_attachments` (bool), `snapshot_digest`.
  - `RelayRecipient`: group-aware. For a named 1:1, the contact name. For an unknown 1:1, the handle,
    which is the user's own contact and is intentional, tested PII. For a group, a people-count label
    (`RelayGroupLabel`) derived from `participant_names`, and **never** the `chat_guid` or
    `participant_handles`.
  - `RelayContextMessage`: `from_me`, `sender_display` (name if known, else a stable pseudonym like
    `"them"`, never the raw handle of a third party), `body`, `sent_at`. **Dropped:** `guid`,
    `message_id`, `sender_handle`, `reaction`/`reactions` (author identities), receipts, attachments.
  - `RelayQuotedPreview` if a draft quotes a message: `from_me`, `body` only.

**B. `RelaySnapshot.project(from: Draft, originDeviceID: String)`**, pure. The device id is
**injected**, not read inside, so the function does no I/O and `DeviceIdentity.localDeviceID()` (which
can create a file) is never called from a "pure" path (finding 8).

**C. An untrusted-text contract.** Every textual field (`body`, `sender_display`, recipient label,
quoted body) is documented and typed as untrusted plain text destined for `textContent` rendering
under a strict CSP in phase 3, so phase 3 cannot accidentally `innerHTML` a draft body (finding 12).
Enforced now by a marker on the type and a test asserting the fields are declared untrusted.

**D. `snapshot_digest`.** A content hash of the projected (already-redacted) fields, for change
detection only. Explicitly not `deliveryPayloadDigest`, which carries send-authority meaning this
artifact must never have.

## Explicitly NOT in this phase

No `DraftStore` wiring. No file writes. No bodies persisted to disk. No feature flag (a flag gating
nothing is decorative, which was a finding against the previous phase 1). No credential, pairing,
listener, manifest, or transport. Those are phase 2, designed together.

## The security property, and how it is tested

Redaction is an **allowlist asserted by exact encoded key set**, not by checking that a few canary
fields are absent (finding 1). For each projection type the test encodes it to JSON and asserts the
key set equals an expected literal set. Adding a field to the source `Draft` or `ContextMessage`
later cannot leak, because the projection names its keys and the test pins them.

Adversarial fixtures (finding 12): a draft whose body, context body, contact name, and sender name
each contain script tags, event-handler attributes, bidi controls, and JSON-delimiter forgery. The
test asserts these survive as inert text in the value, and documents that rendering is `textContent`.

## Acceptance criteria

1. Each projection type's encoded JSON key set equals its declared allowlist exactly. A test fails if
   any key is added or removed.
2. A projected snapshot of a draft carrying attachments, a reply thread id, a group `chat_guid`,
   participant handles, context messages with third-party handles and reaction authors, and a
   schedule-approval tag contains **none** of: any file path, any `chat_guid`, any
   `participant_handles`, any third-party raw handle, any `message_id`/`guid`, any reaction author,
   `delivery_progress`, `in_reply_to_thread_id`, `schedule_approval_tag`, `relay_executor`.
3. An unnamed group projects to a people-count label, never a guid or handle list.
4. `has_attachments` is correct and the attachment paths are absent.
5. `project(from:originDeviceID:)` is pure: no file is created (asserted by pointing
   `MESSAGES_FOR_AI_HOME` at an empty dir and confirming nothing is written).
6. Script-shaped and bidi-shaped text survives inert in every textual field; the untrusted-text
   marker is present.
7. Full existing suite stays green: 742 Swift, 392 iMessage, 262 WhatsApp, 21 ghostie.

## Rollback

Pure additive library, referenced only by its tests. Revert removes it. Zero runtime footprint, zero
files on disk, so there is nothing to clean up. This is the safest possible thing to land first.

## Phase 2 carries these forward (recorded so they are not lost)

Data-plane decision (push vs pull) before storage; per-origin manifest with monotonic generation,
publish time, complete membership, and tombstones (findings 6, 7, 8); serialized publisher actor with
generation-ordered writes and burst coalescing (finding 5); flag-off purge wired to the flag
transition and to startup, plus every read gated independently of file deletion (finding 4);
availability flag AND explicit local opt-in, not a remote flag alone, before any body is copied
(finding 3); publish only pending/scheduled/held, not sent history, or a short relay TTL (finding 11);
draft-id validation and platform namespacing before use as a filename, `O_NOFOLLOW`, temp cleanup on
startup (finding 10).

## Production validation

None in this phase: it has no runtime behavior. Validation is the test suite. Production validation
returns in phase 2 when the publisher and transport exist.
