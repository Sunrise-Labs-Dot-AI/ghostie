# Mobile Messages opener plan review

## Review execution

Triage selected Security Auditor, Saboteur, and Cost/Scope because the plan adds public endpoints, secrets, untrusted input, cloud persistence, cron deletion, and a production deploy.

The required alternative-model lane was attempted three times in parallel with Claude Code 2.1.241, using Opus for security and Sonnet for the other two personas. All three attempts failed before inference with: `Failed to authenticate: OAuth session expired and could not be refreshed`. Three fresh isolated Codex reviewer contexts were used as the strongest available substitute.

## Traceability

| # | Severity | Persona | Finding | Disposition | Edit location | Verified? |
|---|---|---|---|---|---|---|
| 1 | WARNING | Security | Bound unauthenticated request parsing and malformed-id work | ACCEPT | Runtime | ✅ |
| 2 | WARNING | Security | Cloud draft handling conflicts with the repository's broad metadata-only wording | ACCEPT | Storage and secrets | ✅ |
| 3 | CRITICAL | Saboteur | Core iOS handoff could ship with curl-only verification | ACCEPT | Verification and landing | ✅ |
| 4 | WARNING | Saboteur | Deleting expired records makes later 410 responses impossible | ACCEPT | Acceptance, verification, failure handling | ✅ |
| 5 | WARNING | Saboteur | Shared-store cleanup needs a strict namespace and pagination | ACCEPT | Storage and secrets | ✅ |
| 6 | WARNING | Saboteur | Lone JSON surrogates can crash `encodeURIComponent` | ACCEPT | Acceptance, mobile behavior | ✅ |
| 7 | WARNING | Cost/Scope | Validate the mobile handoff before treating backend work as complete | ACCEPT | Verification and landing | ✅ |

## Verification

The updated plan now requires authentication before parsing, whole-request byte limits, storage-free malformed-id rejection, a scoped user-authorized privacy exception, a dedicated Blob namespace, paginated cleanup, well-formed Unicode validation, explicit 410-to-404 lifecycle semantics, and an iOS Simulator Safari release gate. Physical Grok Bot verification remains clearly outside the available simulator surface and cannot be claimed until performed on James's iPhone.

## Verdict

**CLEAN.** The CRITICAL mobile-verification gap is addressed with a required iOS Simulator Safari acceptance run on the exact production link. The remaining physical Grok Bot tap is a named external confidence boundary, not silently treated as proven.
