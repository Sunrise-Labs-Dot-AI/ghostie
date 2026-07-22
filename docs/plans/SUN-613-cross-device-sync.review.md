# SUN-613 adversarial plan review

Plan under review: Linear SUN-613, "Spec: Ghostie cross-device draft sync across M1, M4, and iPhone".
Reviewed against the code in this worktree, 2026-07-22.
Personas run: Saboteur, Security Auditor, Cost/Scope, New Hire (all four triage signals tripped).

**Verdict: BLOCK.** Four CRITICAL findings. Two of them (C1, C2) mean the spec's headline
safety property is not achieved by the protocol as written. One (C3) is a fleet-wide
blast radius that a feature flag cannot contain, which is directly responsive to the
constraint "flag it or don't bake it in."

---

## CRITICAL

### C1 — "At most once" is false: there are four executors, not two

**Where:** "Single-executor safety protocol", and success target "Zero duplicate wire-level
sends in 100,000 race, replay, retry, and crash simulations".

**Issue:** The protocol coordinates the Swift `DraftSender` path. But each Mac has a *second*,
independent send path: the TypeScript MCP `send_draft` / `send_whatsapp_draft` tools
(`mcps/imessage-drafts/src/tools/drafts.ts`, `mcps/whatsapp-drafts/src/tools/drafts.ts`),
which fire when `settings.require_approval` is off and are driven by whatever Claude session
is attached on that machine. Two Macs x two paths = four executors. A Claude on M1 calling
`send_draft` never touches CloudKit, never sees M4's `sending` state, and never consults the
claim. The only thing interlocking the Swift and TS paths today is the filesystem lock in
`~/.messages-mcp/locks/<id>.lock` (`SendLock.swift` and `src/storage/send-lock.ts`, which
mirror each other byte-for-byte) — and that lock is **per-host**.

**Consequence:** the stated success target is unreachable by the specified design. Duplicate
wire-level sends remain possible on the M1-MCP / M4-Swift pair.

**Suggested fix:** land the shared lifecycle state in the artifact both executors already read
under the shared lock — the draft JSON — rather than a parallel CloudKit-only state machine.
Then add an explicit gate: an MCP send path must refuse (`REMOTE_CLAIM_HELD`) when the local
draft JSON carries a foreign claim or `sending`. Otherwise the spec must state plainly that
at-most-once holds only when `require_approval` is on for every paired Mac, and enforce that
as a sync precondition.

### C2 — Reply and group targeting is not portable, and the digest is blind to it

**Where:** "Another Mac may execute a text-only draft only after resolving an equivalent local
transport target and publishing a matching portable digest."

**Issue:** `deliveryPayloadDigest` (`menubar/Sources/MessagesForAIMenu/Models/Draft.swift:228`)
covers id, platform, recipient binding, body, `quoted_message_id`, `scheduled_send_at`, and the
attachment manifest. It does **not** cover `in_reply_to_thread_id` — which is a chat.db ROWID,
local to one Mac — and group sends resolve their target at fire time via
`IMessageGroupResolver().resolveExactGroup(participant_handles)` on the executing machine
(`DraftSender.swift:288`).

So a cross-Mac execution that re-resolves the thread or group to a *different* chat produces an
identical digest. The payload-comparison guard at `DraftSender.swift:152` — the thing standing
between a mutated draft and a wrong send — structurally cannot catch a mis-routed reply. The
spec's "matching portable digest" is not sufficient for the property it is claimed to provide.

**Suggested fix:** in v1, apply the same rule already applied to attachments — any draft with
`in_reply_to_thread_id`, `imessage_group`, or `quoted_message_id` set is origin-Mac-only.
If alternate-Mac replies are wanted later, extend the digest with a portable target identity
(normalized participant handle set) and re-verify it on the executor *after* local resolution.

### C3 — CloudKit puts a launch-time failure dependency into every user's bundle, and a flag can't contain it

**Where:** "Recommended architecture: use the user's private CloudKit database."

**Issue:** CloudKit under Developer ID distribution requires an embedded Developer ID
provisioning profile, and that profile is evaluated at install *and at every app launch* —
if it is invalid, the app does not launch. Today `menubar/scripts/messages-for-ai.entitlements`
embeds no profile, and the bundle is hand-assembled by shell scripts under a fragile signing
invariant (per-Mach-O `--identifier`, deliberately no `--deep`). Adding iCloud + APNs
entitlements plus a profile introduces a new whole-fleet launch dependency, a new interaction
with the Sparkle in-place update path, and new re-sign drift risk — for a feature exactly one
person uses.

Profile *expiry* is not the near-term risk (profiles issued after 2017-02-22 are valid 18
years). Misconfiguration and re-sign drift are.

**This is the direct answer to the "feature-flag it" question:** a runtime flag gates UI and
code paths. It does not gate an entitlement, a provisioning profile, a CloudKit container in
the production team, the privacy-disclosure copy, or the launch-time profile check. The
CloudKit design is *not containable* by flagging.

**Suggested fix:** either accept the fleet-wide entitlement change as a deliberate platform
decision with its own release-verification checklist, or choose a transport that requires no
entitlement change (see Option C below).

### C4 — Approval provenance inverts, and key placement is unspecified

**Where:** "The approving device signs the exact draft revision..." / "Sharing an iCloud
account is necessary, but does not itself grant send authority."

**Issue:** `ApprovalAuthenticator.swift` currently binds "a human approved this" to a
**per-install Keychain secret**, HMAC'd over id + recipient + body + scope. That is what makes
the promise unforgeable by any process that can write files. An iPhone approval cannot mint a
valid local tag. So the executing Mac must verify a remote signature and then *re-mint* the
local tag — at which point the property degrades from "the Keychain proves a human pressed the
button on this Mac" to "the sync layer asserts a human pressed it somewhere."

That is the real posture change in this spec. The policy gate section focuses on encrypted
body storage, which is the lesser issue.

Two unspecified details that decide whether the spec's own claim holds:

1. **Device private keys must be local-Keychain-only** (`kSecAttrSynchronizable = false`).
   If they land in the iCloud Keychain, an Apple ID compromise *does* grant send authority —
   precisely what the spec says it prevents.
2. **Pairing must verify out-of-band** (short-authentication-string / numeric comparison shown
   on both devices). If device trust bootstraps through the CloudKit channel, whoever controls
   the iCloud account can enroll their own signing key. "Physically paired" is not a mechanism.

**Suggested fix:** state both explicitly as P0 requirements, and add an acceptance criterion
that the executing Mac's re-minted local tag is bound to the *remote* device identity so the
audit trail names which device approved.

---

## WARNING

### W5 — The 2-minute expiry contradicts the motivating scenario

Approving from the iPhone matters when you are away from the Macs. A closed-lid laptop will not
reliably service a CloudKit push. The success target reads "selected **awake** Mac acknowledges
within 10 seconds" — "awake" is carrying the whole feature. The honest statement is: this works
only when a designated Mac is always on. Say so in the spec, because it changes the design.

### W6 — The dominant simplification is absent from the alternatives

Designate the always-on M4 as the **sole** executor, permanently. At-most-once then holds by
construction: no compare-and-set, no claim, no losing-Mac refetch, no `sending` takeover rule,
no `ambiguous` state, no 100k-simulation harness. M1 and iPhone become review clients.

WhatsApp already forces this shape: the Baileys session lives in one machine's
`~/.whatsapp-mcp/session.db` and is not portable, so WhatsApp sends have a natural single
executor regardless. Only iMessage is genuinely multi-executor-capable, and only because
Messages.app is signed into the same Apple ID on both machines.

This cut removes delivery phase 3 outright and most of phase 5.

### W7 — Alternatives were scored against the wrong objective function

Tailscale/direct mesh is rejected for "weak sleep behavior and poor product onboarding." At
n=1 the onboarding cost is approximately zero, and per W5 the sleep behavior is equally weak
for CloudKit. The two genuine CloudKit advantages — offline queueing and push wake — are the
two things W5 says do not deliver in the scenario that motivated the feature. The rejection
reasoning imports product constraints into a personal-tool decision.

### W8 — The iPhone client is not a 1-2 week line item in this repo

There is no Xcode project. `menubar/Package.swift` is SwiftPM, macOS-only, hand-assembled into
a .app by shell scripts. An iPhone companion means a second signing, provisioning, and
distribution pipeline with its own recurring cost: TestFlight builds expire at 90 days, ad-hoc
personal-team builds at 7. For a single-user feature that is a permanent maintenance tax on a
solo repo.

A responsive web review surface served by the menubar over the tailnet removes the pipeline
entirely, and keeps every existing Swift-side guard (payload comparison, attachment
verification, SendLock, kill switch, audit) exactly where it is.

### W9 — The canonical spec does not exist

The issue names `docs/plans/iphone-draft-sync-spec.md` as "canonical working spec". It is not
present on any ref in this repository (checked with `git ls-tree` across all branches). Either
the Linear issue is the spec, or the real one was never shared. Anyone picking this up follows
a dead pointer.

---

## NOTE

### N10 — The policy gate is over-framed

The gate is stated as a binary: permit encrypted bodies in iCloud, or abandon the feature.
The premise is `CONTRIBUTING.md:21` — "Ghostie is metadata-only: it never stores or transmits
message bodies." That sentence is already inaccurate as written: draft JSON under
`~/.messages-mcp/drafts/` persists plaintext `body` **and** `context_messages` (which are
message bodies), and bodies flow to Claude through the MCP read tools by design.

The operative, accurate promise is the narrower one on the shipped privacy page
(`site/ghostie/privacy/index.html:149`): "Sunrise Labs does not operate a server that receives
your message history from the core app." A user's own private CloudKit database does not
violate that.

So the decision is not "break the privacy promise or kill the feature." It is: amend the
over-broad CONTRIBUTING sentence to match what the product actually does, and add a pairing
disclosure. The one line that would become false is the Ghostie marketing description "All on
your Mac" (`site/ghostie/index.html:7`), and only if the feature ships enabled to users.

### N11 — Effort estimate is light

"Zero duplicate wire-level sends in 100,000 race, replay, retry, and crash simulations"
requires a deterministic CloudKit fake with `ifServerRecordUnchanged` semantics plus crash
injection. That is roughly a week on its own and does not appear as a line item. 4-6 weeks is
the optimistic path for the spec as written; 8-10 is the inference from the phase list plus
the missing harness plus the iOS pipeline in W8.

### N12 — Retention and quota questions are premature at n=1

Encrypted `context_messages` in the private database bill against the user's own iCloud quota.
Seven-day retention is trivially answerable for one user; it becomes a real question only if
this productizes. Do not spend spike time on it.

---

## Options, head to head

| | A: ship as specced | B: cut to read-only sync + fixed executor | C: tailnet, no entitlement |
|---|---|---|---|
| Transport | CloudKit private DB | CloudKit private DB | Tailscale between M1/M4/iPhone |
| Executor | selectable, CAS claim | M4 always | M4 always |
| iPhone surface | native SwiftUI app | native SwiftUI app | web UI served by menubar |
| Entitlement change to shipped bundle | yes (iCloud + APNs + profile) | yes | none |
| Containable by feature flag | no (C3) | no (C3) | yes |
| Distributed claim protocol | required | not required (W6) | not required |
| Effort | 8-10 wks (N11) | 2-3 wks | 3-5 days |
| Generalizes to other users later | yes | yes | no |
| Offline queue / push wake | yes, but see W5 | yes, but see W5 | no |

**Recommendation (proposal, mine): Option C**, gated behind a dev-only flag, with the M4 as
sole executor and every existing Swift guard left untouched — the web surface only conveys
"a human approved revision X", and the Mac re-runs payload comparison, attachment
verification, `SendLock`, kill switch, and audit exactly as today.

**Strongest counter to C, stated fairly:** it introduces a local HTTP surface on the Mac that
can trigger real sends, so authorization must be a device token bound into the
`ApprovalAuthenticator` canonical message — "reachable on the tailnet" is not an authorization
model. It adds a Tailscale runtime dependency, has no offline queue, and nothing built
generalizes if cross-device becomes a product feature within a year. If the 12-month roadmap
includes selling this, B is the better first step and C is throwaway.

Confidence: medium-high that C is right under the stated n=1 constraint; low if productizing
cross-device is intended inside 12 months.

## If Option A or B proceeds anyway — mandatory before any code

1. Two-hour spike: prove a Developer ID + notarized build with an embedded provisioning
   profile still launches, still holds its FDA grant, and still passes the Sparkle update path
   (C3). Binary go/no-go before anything else in the plan.
2. Resolve C1 by deciding where shared state lives, and gate the MCP send paths.
3. Add the C2 exclusion rule (origin-only for reply/group/quoted drafts) to P0.
4. Write the C4 key-placement and pairing-ceremony requirements into P0 explicitly.
5. Write the actual spec file at `docs/plans/iphone-draft-sync-spec.md` (W9).

## Traceability

| # | Severity | Persona | Finding | Disposition | Verified? |
|---|---|---|---|---|---|
| C1 | CRITICAL | Saboteur | Four executors, not two; MCP send path uncoordinated | Open — spec unchanged | ❌ |
| C2 | CRITICAL | Saboteur | Thread/group target not portable; digest blind to it | Open — spec unchanged | ❌ |
| C3 | CRITICAL | Cost/Scope | Entitlement + profile = fleet launch dependency, not flaggable | Open — spec unchanged | ❌ |
| C4 | CRITICAL | Security Auditor | Approval provenance inverts; key placement + pairing unspecified | Open — spec unchanged | ❌ |
| W5 | WARNING | Saboteur | 2-min expiry contradicts away-from-Mac use case | Open | ❌ |
| W6 | WARNING | Cost/Scope | Sole-executor simplification absent from alternatives | Open | ❌ |
| W7 | WARNING | Cost/Scope | Alternatives scored on product objective, not n=1 | Open | ❌ |
| W8 | WARNING | Cost/Scope | iPhone client understated; no Xcode pipeline exists | Open | ❌ |
| W9 | WARNING | New Hire | Canonical spec file does not exist on any ref | Open | ❌ |
| N10 | NOTE | Security Auditor | Policy gate over-framed vs. actual shipped promise | Open | ❌ |
| N11 | NOTE | Cost/Scope | Estimate omits the race-simulation harness | Open | ❌ |
| N12 | NOTE | Cost/Scope | Retention/quota premature at n=1 | Open | ❌ |

All rows are ❌ because the plan lives in Linear and was not edited by this review. Applying
the accepted findings means editing SUN-613 (or writing the missing spec file), which is a
separate, confirmable action.
