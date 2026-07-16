# Adversarial review: staged media drafts

- **Public repository:** `https://github.com/Sunrise-Labs-Dot-AI/ghostie`
- **Branch:** `codex/mcp-image-drafts`
- **Base:** `80ccf329743c3bd0ad16856185c022f0dea044c9`
- **Checkpoint:** `959e155` (`feat(drafts): attach reviewed images safely`)
- **Reviewer lanes:** security boundary, failure injection, and accessibility/approval UX
- **Model note:** Claude/Opus was unavailable in this environment, so the independent reviewer personas used separate Codex agents with review-only prompts.

## Scope and invariants

The review covered the Ghostie facade, both transport MCPs, the WhatsApp daemon, the Swift review/send surface, snapshot retention, approval binding, and public security documentation.

Load-bearing invariants:

1. Agents can stage media but cannot bypass the human review surface for iMessage media.
2. The bytes sent must match the bytes represented by the reviewed manifest.
3. A crash or ambiguous multipart result must not cause an ordinary retry to duplicate a confirmed or possibly delivered part.
4. Cleanup must not follow attacker-controlled symlinks or use the FDA-enabled app as a deletion deputy.
5. Invalid legacy media fails closed while legacy text-only drafts remain usable.

## Findings and dispositions

| Round | Finding | Decision | Resolution and evidence |
|---|---|---|---|
| 1 | iMessage attachment verification had a pathname race before AppleScript consumed the file. | ACCEPT | The final design blocks direct MCP media send. Ghostie copies verified bytes into `~/Library/Messages/GhostieSendSpool`, keeps no-follow descriptors open, marks the protected copy immutable, and sends by stable file-ID path. |
| 1 | WhatsApp could be used as a confused deputy for an arbitrary raw path. | ACCEPT | Every draft attachment must belong to the draft-owned snapshot manifest. The daemon reads and hashes through a pinned descriptor and sends the exact verified Buffer. |
| 1 | A stale Swift `DraftStore` object could overwrite a newer multipart progress marker. | ACCEPT | Every mutation re-reads current JSON under the shared cross-process send lock. A deterministic race test preserves the ambiguity marker. |
| 1 | Scheduled WhatsApp approval was not bound to the actual scheduled time. | ACCEPT | The cross-language canonical payload digest includes the schedule and is verified at approval and delivery. |
| 1 | Transport-level media behavior lacked direct regression coverage. | ACCEPT | Added iMessage staging/boundary tests and WhatsApp exact-Buffer, multipart, failure, and schedule tests. |
| 1 | Invalid media drafts hid recovery actions and exposed inaccurate attachment-only text. | ACCEPT | Invalid cards clearly explain restaging, keep Delete available, avoid a false Send action, and expose accurate accessibility labels and hints. |
| 1 | Synchronous staging and hashing could block the WhatsApp event loop; abandoned snapshots could leak. | ACCEPT | Staging failures distinguish pre-request cleanup from post-write ambiguity. The daemon performs startup and daily orphan/sent retention sweeps. |
| 2 | Scheduled override/discard could erase progress while a send was active. | ACCEPT | Both mutations now acquire the same `SendLock` used by delivery. |
| 2 | Attachment count and byte caps were only staging-time assumptions. | ACCEPT | Shared, Swift, and daemon send-time validation re-enforces 10 files, 100 MB per file, and 250 MB total. |
| 2 | Snapshot and spool cleanup could traverse symlinked roots or leave immutable crash residue. | ACCEPT | Swift cleanup is descriptor-anchored with `O_NOFOLLOW`, strict UUID/file-name validation, stable inode enumeration, explicit immutable-flag clearing, and exact `unlinkat` removal. Startup and pre-send cleanup cover crash residue. |
| 2 | User-immutable source files alone did not protect against a hostile same-UID staging process. | ACCEPT | The source is no longer the wire object. The reviewed app creates the final copy inside the macOS Messages TCC boundary. The iMessage MCP has no media send function and returns an app-review instruction even when direct text send is enabled. The documented residual trust boundary includes any other process explicitly granted Full Disk Access. |
| 3 | Shared TypeScript snapshot cleanup used an `lstat` followed by recursive pathname deletion, allowing an FDA-enabled daemon cleanup race. | ACCEPT | Cleanup now accepts only canonical UUID draft IDs, pins every directory with `O_NOFOLLOW`, enumerates by stable file-ID path, deletes only canonical managed regular files, and removes the parent only if its current device/inode still matches the pinned directory. Symlink-root and unrecognized-file tests pass. |
| 3 | A protected spool younger than one hour at app startup could survive indefinitely if no later media send occurred. | ACCEPT | Ghostie now sweeps at startup and every 30 minutes, and clears the timer at termination. Immutable stale files are cleared and removed by descriptor. |

## Reviewer verdicts

- **Accessibility / approval UX:** MERGE-OK. Invalid media no longer advertises Send and gives an accurate Delete/restage recovery hint.
- **Failure injection / state machine:** MERGE-OK. Locking, pre-request cleanup, post-write retention, daemon sweep, and multipart journal behavior passed targeted tests.
- **Security boundary:** MERGE-OK after the TCC-protected handoff, descriptor-anchored cleanup, strict UUID/file-name validation, and periodic crash-spool sweep were re-reviewed.

## Verification

- Ghostie MCP: typecheck passed; 21 tests passed.
- iMessage MCP: typecheck passed; 368 tests passed.
- WhatsApp MCP/daemon: typecheck passed; 258 tests passed.
- Swift app: clean build completed; 712 tests passed, 2 skipped, 0 failures.
- Cross-language approval digest vector: `9c4c23978c28f9cbcf0310ff3711aec1ef6fb3925eca797f556d06121922207f`.
- `git diff --check origin/main`: clean.
- Added-line em dash scan: clean.

## Overall verdict

MERGE-OK from all three reviewer lanes.
