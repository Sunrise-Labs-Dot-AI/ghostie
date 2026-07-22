# Adversarial review, SUN-613 phase 0 (executor gate)

PR: https://github.com/Sunrise-Labs-Dot-AI/ghostie/pull/12
Branch: `claude/sun-613-phase-0-executor-gate`
Author lane: Claude (Opus 4.8). Second lane: Codex (`codex exec`, read-only sandbox), independent of the author per the Sunrise landing gate.
Date: 2026-07-22

**Initial verdict: BLOCK**, 6 CRITICAL, 3 WARNING.
**After fixes: 5 fixed, 4 accepted-partial with named phase-2 requirements. No open CRITICAL.**

A first review run was cancelled at the 10-minute foreground cap before producing output; it is noted here for completeness and produced no findings. The recorded run used the same prompt with the diff pre-extracted.

## Why this review mattered

Two findings directly refuted the author's stated reasoning rather than finding incidental bugs:

- **Finding 4** killed the argument that excluding `relay_executor` from `deliveryPayloadDigest` is safe "because a rewriter cannot forge an approval." It does not need to forge one. For a scheduled draft a valid approval tag **already exists**, and neither it nor the WhatsApp daemon's approved-digest bound the executor. Flipping the stamp preserved both.
- **Finding 2** found a real ungated wire path the author missed: the WhatsApp daemon's `handleSendDraft` reloads the draft and calls Baileys, and any permitted RPC peer can reach `approveDraft` + `sendDraft` without going through the guarded MCP tool at all.

## Traceability

| # | Sev | Finding | Disposition | Fix | Verified |
|---|---|---|---|---|---|
| 1 | CRITICAL | Unstamped drafts remain executable by every Mac; mixed-version rollout unsafe | ACCEPT-PARTIAL → phase 2 | spec requirement + acceptance criterion | ✅ |
| 2 | CRITICAL | WhatsApp daemon `handleSendDraft` ungated | ACCEPT | `server.ts` gate at the wire boundary | ✅ |
| 3 | CRITICAL | Cross-host TOCTOU; per-host lock is not a cross-host claim | ACCEPT-PARTIAL → phase 2 | claim reworded; assignment revision + CAS required | ✅ |
| 4 | CRITICAL | Existing approval replayable after executor change | ACCEPT | executor bound into the approval **scope** | ✅ |
| 5 | CRITICAL | Whole-file rewrites can erase a concurrently written stamp | ACCEPT-PARTIAL → phase 2 | relay writers must take the per-draft lock | ✅ |
| 6 | CRITICAL | Malformed stamps fail OPEN in TS; Swift and TS disagree | ACCEPT | both languages fail closed; normalize preserves | ✅ |
| 7 | WARNING | `device.json` follows symlinks, trusts any readable file | ACCEPT | O_NOFOLLOW + fstat + uid/mode + schema check | ✅ |
| 8 | WARNING | `O_EXCL` publishes before contents exist; partial write wedges | ACCEPT | write-temp → fsync → `link()` publish | ✅ |
| 9 | WARNING | Direct-send helpers ungated; "every send path" overstated | ACCEPT (wording) + DEFER | invariant narrowed to staged-draft execution | ✅ |

## Fixes applied

**Finding 2, daemon wire-boundary gate.** `mcps/whatsapp-drafts/src/daemon/server.ts` now calls `executorRefusal` immediately after `handleSendDraft` reloads the draft, before the approval and digest gates. This is the last point before Baileys, and it is reached by every caller including a direct `approveDraft` + `sendDraft` RPC pair.

**Finding 4, bind the executor into approval provenance.** `Draft.scheduleApprovalScopeForDraft` appends `|executor=<id>` to the HMAC scope for stamped drafts, leaving the bare legacy scope for unstamped ones. Any executor change now invalidates an existing tag, which is the fail-closed direction. Unstamped drafts keep verifying with tags minted before the relay existed, which is the back-compat the whole "not in the digest" decision exists to protect. Pinned by `testExecutorIsBoundIntoTheScheduleApprovalScope` and `testUnstampedDraftsKeepTheLegacyApprovalScope`.

**Finding 6, fail closed on malformed routing data.** The rule is now identical in both languages: absent or JSON `null` means unrouted; a present value that is the wrong type, empty, whitespace, or outside the device-id alphabet is REFUSED. Previously TypeScript coerced every non-string to `""` and allowed it, so `"relay_executor": 42` sent on both MCP paths while Swift refused the same file. Both `normalizeDraft` implementations now preserve a malformed value verbatim instead of collapsing it to `null`, because collapsing it made the draft look unrouted and therefore sendable by anyone.

**Findings 7 and 8, identity file hardening, both languages.** Reads go through `O_NOFOLLOW` plus `fstat` on the descriptor actually opened, requiring a regular file owned by the current uid with no group/other bits and a matching `schema_version`; the parent is checked for symlinks, mirroring the existing `ensureDir` guard in the iMessage drafts storage. Creation is now write-temp → verified byte-count loop → `fsync` → `link()` publish, so a crash mid-write cannot leave a permanently empty `device.json` that every future create refuses to replace.

Note: the first run of the new hardening failed one of my own tests, because the test fixture wrote `device.json` at mode 0644. The check was right and the fixture was wrong. Fixtures now write 0600, and there are explicit tests for the permissive-mode, symlink, and wrong-schema cases.

## Accepted-partial, with requirements now written into the spec

These are real and the reviewer is right, but none can be closed before a relay exists to stamp drafts. Each is now a P0 requirement on phase 2 in `docs/plans/cross-device-draft-sync-spec.md` rather than a vague intention.

**Finding 1, mixed-version rollout.** "Unstamped means allowed" is correct and must stay, or upgrading strands every existing draft. The genuine hazard is that an older menubar or MCP ignores `relay_executor` entirely and will send a stamped draft, and an older `normalizeDraft` will *erase* the stamp on its next write. Phase 2 must therefore not stamp until every paired device advertises gate support, with a minimum-version cutover.

**Finding 3, cross-host TOCTOU.** Correct: a per-host advisory lock cannot serialize against another host or against the relay writer, so phase 0 alone does not deliver at-most-once under concurrent reassignment. The PR and commit language claiming this "closes the hole" was too strong and has been corrected to "makes it achievable." Phase 2 must add an assignment revision that is atomically claimed and re-verified at the wire boundary.

**Finding 5, read-modify-replace races.** Correct, and the criticism of the tests is fair: they prove sequential preservation only. Latent today because nothing writes stamps concurrently. Phase 2 must make relay writes participate in the same per-draft lock, and add stamp-vs-schedule, stamp-vs-approval, and stamp-vs-progress race tests.

**Finding 9, direct-send helpers.** The invariant is now stated as *staged-draft execution*, not "every send path." `DraftSender.sendDirect` / `sendDirectAttachment` are the inline composer: a human typing on that Mac, with no draft and no stamp, and deliberately out of scope. The reviewer's sharper sub-point, that the WhatsApp daemon's `sendDirectMessage` authorizes on a caller-supplied `source` string, is real but predates this PR and is not a cross-device issue. Filed as follow-up rather than scope-creeping this diff.

## Rejected

None. Every finding was either fixed or accepted with a named requirement.

## Verification

- `cd menubar && rm -f .build/build.db && swift build && swift test` → 732 passed, 0 failed, 2 skipped
- `mcps/imessage-drafts`: typecheck clean, `bun test` → 392 passed, 0 failed
- `mcps/whatsapp-drafts`: typecheck clean, `bun test` → 258 passed, 0 failed
- `mcps/ghostie`: typecheck clean, `bun test` → 21 passed, 0 failed
