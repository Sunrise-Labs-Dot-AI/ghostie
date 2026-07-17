# Adversarial review: WhatsApp draft diagnostic decoding

- **Public repository:** `https://github.com/Sunrise-Labs-Dot-AI/ghostie`
- **Branch:** `codex/fix-whatsapp-draft-decoding`
- **Base:** `c51fc396ec57a46c35c361cafec7603c15f75fc5`
- **Initial checkpoint:** `849e71b` (`fix(drafts): decode WhatsApp context diagnostics`)
- **Reviewed checkpoint:** `c20f9f0` (`fix(drafts): preserve diagnostic wire shape`)
- **Reviewer lanes:** production failure injection and maintainability/compatibility
- **Model note:** Claude/Opus was unavailable in this environment, so the independent plan and code-review lanes used separate Codex agents with review-only prompts.

## Scope and invariants

The review covered the Swift model that reads staged drafts from both transport MCPs and the regression fixture for a WhatsApp draft containing two ordered image attachments.

Load-bearing invariants:

1. Existing structured iMessage diagnostics remain strict and object-shaped.
2. Compact WhatsApp diagnostics decode without hiding the entire draft from the approval surface.
3. App-side draft rewrites preserve the diagnostic wire format expected by the originating transport.
4. Media metadata and attachment order survive decoding and round trips.
5. The fix does not alter approval, verification, or send behavior.

## Findings and dispositions

| Round | Finding | Decision | Resolution and evidence |
|---|---|---|---|
| Plan | Custom decoding could remove the synthesized initializer and weaken strict iMessage object decoding. | ACCEPT | Added an explicit structured initializer, retained required keyed fields, and added structured-object and malformed-object regression tests. |
| Review 1 | Encoding inferred wire shape from field values. An empty structured iMessage `error` could become a compact string, while a future compact WhatsApp status could become an object after an app-side rewrite. | ACCEPT | Added a private decoded wire-shape marker and encode using that marker. Tests cover a zero-valued structured `error`, all current compact statuses, and an unknown future compact status. |
| Review 1 | The model comment described only the iMessage object and incorrectly tied diagnostics to null context messages. | ACCEPT | Updated the comment to document both transport formats and the shape-preservation invariant. |

## Reviewer verdicts

- **Production failure injection:** MERGE-OK after the compact representation was preserved for current and future status strings.
- **Maintainability/compatibility:** MERGE-OK after wire shape became explicit, documentation was corrected, and the structured-empty edge case received coverage.

## Verification

- Focused `DraftDecodingTests`: 11 tests passed, 0 failures.
- Swift app: clean build completed; 716 tests passed, 2 skipped, 0 failures.
- Exact WhatsApp fixture: two PNG attachments decode in order and survive a full draft round trip.
- Structured diagnostic regression: required object fields stay strict and an empty `error` remains object-shaped.
- Compact diagnostic regression: all current statuses and an unknown future status remain strings after a round trip.
- `git diff --check origin/main`: clean.
- Added-line em dash scan: clean.
- Architecture artifact: not applicable; this is a localized compatibility correction with no architecture-shape change.

## Overall verdict

MERGE-OK from both reviewer lanes.
