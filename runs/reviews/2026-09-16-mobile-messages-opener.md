# Mobile Messages opener code review

## Review execution

Triage selected Security Auditor, Saboteur, and Accessibility because the diff adds an authenticated public API, bearer links, encrypted persistence, deletion behavior, a dependency, and generated mobile UI.

The alternative-model Claude Code lane was unavailable because its OAuth session was expired and could not be refreshed. The review used three fresh isolated Codex contexts as the strongest available substitute, with an independent verification pass after fixes.

## Traceability

| # | Severity | Persona | File:line | Finding | Disposition | Fix applied? | Verified? |
|---|---|---|---|---|---|---|---|
| 1 | WARNING | Security | `site/scripts/check-message-opener.js:92` | Public fixtures included the real acceptance recipient | ACCEPT | ✅ Replaced every occurrence with fictional 555 fixtures | ✅ Full-tree search and reviewer follow-up |
| 2 | NOTE | Security | `site/api/message-opener.js:393` | Link ids used 72 bits instead of the planned 96 | ACCEPT | ✅ 12 random bytes, 16-character validation and docs | ✅ Reviewer follow-up and entropy assertion |
| 3 | WARNING | Saboteur | `site/api/message-opener.js:393` | Same insufficient-entropy issue | ACCEPT | ✅ Combined with finding 2 | ✅ Reviewer follow-up |
| 4 | CRITICAL | Saboteur | `site/api/message-opener.js:294` | Alternate URL forms had no user-gesture fallback | ACCEPT | ✅ Added semantic controls for forms 2 and 3 | ✅ Reviewer follow-up and HTML assertion |
| 5 | WARNING | Saboteur | `site/api/message-opener.js:423` | Blob deletion failure changed expired links from 410 to 503 | ACCEPT | ✅ Immediate deletion is best effort; cron retries | ✅ Reviewer follow-up and rejecting-delete test |
| 6 | WARNING | Saboteur | `site/api/message-opener.js:355` | One bad Blob aborted all cleanup | ACCEPT | ✅ Per-object read/delete isolation with failure count | ✅ Reviewer follow-up and partial-failure test |
| 7 | WARNING | Accessibility | `site/api/message-opener.js:286` | Fallback note failed normal-text contrast | ACCEPT | ✅ Darkened to 6.06:1 and added focus outlines | ✅ Accessibility verifier and contrast regression test |

## Verification evidence

- 15 focused opener tests pass.
- Existing download, tip jar, referral, AI proxy, and site metadata suites pass.
- `npm audit --omit=dev` reports zero vulnerabilities.
- `vercel build --yes --cwd site` completes successfully with Vercel CLI 54.9.0.
- All three verifier passes report the accepted findings addressed. The security verifier first found one remaining prefix-less real number; it was replaced with a fictional 555 fixture and verified by a full-tree search.

## Verdict

**MERGE-OK.** No CRITICAL or WARNING finding remains open. The exact production link still requires the planned iOS Simulator Safari acceptance run after deploy, followed by a physical Grok Bot tap before that client is described as verified.
