# Plan review
Claude Opus: one attempt failed, OAuth session expired and could not refresh.
Codex default: one attempt failed, installed CLI cannot use gpt-6-astra.
Codex gpt-5.5 independent substitute completed. Raw findings: runs/reviews/clerk-remote-plan-codex.txt.

Findings 1-4 and 6-10 accepted: authoritative review amendment defines token/resource/consent, exact redirects, pairing, log policy, structural bounds, provenance and negative tests. Finding 5 partly accepted: duplicate/revocation behavior specified; nonce proof rejected with rationale in plan. One-hour token TTL chosen over 15 minutes for client usability, bounded without refresh and per-host revocation.
Verdict: implementation may proceed under these explicit contracts. Live Clerk/client provisioning and TLS relay deployment remain unverified until deployment testing.

## Code review resolution
Independent gpt-5.5 review found one critical and four warnings (runs/reviews/clerk-remote-code-codex.txt).

- Packaging critical accepted: exclude standalone remote-relay from Mac sidecar coverage. Also repair version bump/release staging after extracting facade.ts. Compiled shared backend successfully; experience tests exercise release contracts.
- Configured-client revocation accepted: every request rechecks configured client IDs. Regression test removes a client after token issuance.
- Cancellation warning accepted: native UI reports cancellation failures honestly; stale pairing results cannot restore a cancelled operation. Regression covers cancellation while start is in flight. Offline cancellation cannot promise a server mutation, with TTL as the fallback.
- Repeated polling warning rejected as an exploit: approval changes state only once. Repeated polling returns the same existing host reference to the same secret holder, never a new credential or permission. This is deliberate recovery from a lost polling response. Browser approval replay is refused.
- Swift lifecycle coverage accepted: tests now exercise start, stop, quit preference, process failure, disconnect success/failure, and cancellation while pairing start is in flight. Real Clerk/browser and signed-app acceptance remains required before public enablement.

Follow-up independent verification accepted all four warning resolutions and caught a second packaging defect: optional relay configuration had been inserted inside the plist heredoc. Fixed by moving it after the XML heredoc terminator. The release contract now executes the actual plist-generation fragment and parses the output with plistlib for empty/configured/trailing-slash origins, plus rejects HTTP. This test passes. Final independent verification follows in runs/reviews/clerk-remote-final-codex.txt.

Final independent verification: MERGE-OK. Subsequent bounded hardening omits detected authentication messages entirely from array/search results, preventing a matching redacted placeholder from revealing whether a guessed code exists. Regression tests verify omitted hits and normal text preservation; full Ghostie suite now has 56 passing tests. Compiled host also exits on app-pipe EOF.
