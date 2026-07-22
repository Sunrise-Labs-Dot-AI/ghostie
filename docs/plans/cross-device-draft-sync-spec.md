# Ghostie cross-device draft sync, working spec

Linear: SUN-613. Supersedes the CloudKit design in the original issue description.
Adversarial review that produced this rewrite: [SUN-613-cross-device-sync.review.md](SUN-613-cross-device-sync.review.md).
Status: ready to implement. Personal-scale feature, off by default, contained behind a flag.

## Problem

Ghostie keeps draft state per installation. James runs it on an M1 and an M4, so a draft
staged or resolved on one Mac is invisible on the other, and there is no way to review or
approve a draft from an iPhone.

## Shape of the solution

One always-on **hub** Mac (the M4) owns execution. Every other device is a **spoke** that can
see the queue and approve, but never sends. Spokes reach the hub directly over Tailscale.
The iPhone surface is a web page the hub serves; there is no iOS app.

This is deliberately a single-writer system. The original design allowed either Mac to execute
and therefore needed a distributed mutual-exclusion protocol (compare-and-set claims, a durable
attempt journal, an `ambiguous` state, no-automatic-failover rules, and a 100,000-iteration race
harness). Fixing the executor to one host deletes all of it: at-most-once follows from the
per-host `SendLock` the code already has.

## Why not CloudKit

CloudKit under Developer ID requires an embedded provisioning profile that macOS evaluates at
install and at **every launch**; an invalid profile means the app does not launch. That is a
fleet-wide dependency, and no runtime feature flag can gate an entitlement, a provisioning
profile, or a production CloudKit container. For a feature with one user, the blast radius is
wrong. The menubar is non-sandboxed hardened-runtime, so a local listener needs no new
entitlement at all, the tailnet design ships zero change to
`menubar/scripts/messages-for-ai.entitlements`.

Accepted cost: nothing here generalizes if cross-device sync is later sold as a product
feature. Revisit CloudKit at that point, not before.

---

## Executor model

Fixed per transport. No selection UI, no failover, no takeover.

| Draft kind | Executor | Rationale |
|---|---|---|
| iMessage, text-only, no reply/group target | Hub (M4) | Messages.app on the same Apple ID resolves the handle identically |
| iMessage with `in_reply_to_thread_id`, `imessage_group`, or `quoted_message_id` | Origin Mac only | targets are chat.db ROWIDs / locally-resolved GUIDs and are not portable (see below) |
| iMessage with attachments | Origin Mac only | trusted files stay on the origin Mac |
| WhatsApp | The Mac holding the linked Baileys session | `~/.whatsapp-mcp/session.db` is not portable |

**Why reply and group targets are excluded.** `DraftSender` routes replies with
`draft.in_reply_to_thread_id`, a chat.db ROWID, and resolves groups at fire time via
`IMessageGroupResolver().resolveExactGroup(participant_handles)`
([DraftSender.swift:288](../../menubar/Sources/MessagesForAIMenu/DraftSender.swift:288)).
`deliveryPayloadDigest`
([Draft.swift:228](../../menubar/Sources/MessagesForAIMenu/Models/Draft.swift:228)) does **not**
cover `in_reply_to_thread_id`, so a draft that re-resolves to a different chat on another Mac
still produces a matching digest and the payload-comparison guard at
[DraftSender.swift:152](../../menubar/Sources/MessagesForAIMenu/DraftSender.swift:152) cannot
see the mis-route. Until the digest carries a portable target identity, these drafts do not
cross machines.

---

## The executor gate (this is the load-bearing change)

Each Mac runs **two** independent send paths: the Swift `DraftSender` and the TypeScript MCP
`send_draft` / `send_whatsapp_draft` tools, which fire when `settings.require_approval` is off
and are driven by whichever Claude session is attached. Across two Macs that is four executor
processes. They interlock today only through the per-host advisory lock at
`~/.messages-mcp/locks/<id>.lock` (`SendLock.swift` and `src/storage/send-lock.ts`, byte-identical
by contract).

The relay therefore does **not** invent a parallel state machine. It writes the canonical draft
into the hub's own `~/.messages-mcp/drafts/<id>.json`, the same file both local executors
already read under the same lock, plus one new field:

```jsonc
"relay_executor": "<device-id of the machine permitted to send this draft>"
```

Enforcement, on every send path:

1. **Swift**, `DraftSender.send` refuses when `relay_executor` is present and does not equal the
   local device id. Fail-closed on an unreadable device id.
2. **TypeScript**, `send_draft` and `send_whatsapp_draft` apply the same check and return a new
   error code `WRONG_EXECUTOR`, alongside the existing `PENDING_APPROVAL` family.
3. **The WhatsApp daemon**, `handleSendDraft` re-checks at the wire boundary, after its own
   reload. The MCP tool's check is not sufficient: the daemon reloads the draft, and any permitted
   RPC peer can reach `approveDraft` + `sendDraft` without going through the guarded tool.
4. **Spokes**, a spoke Mac stamps its local copy with the hub's device id, so the spoke's own
   Swift and TS paths both refuse. A spoke is structurally incapable of sending a relayed draft.

The rule is identical in both languages, and the case table is the contract: absent or JSON `null`
means unrouted; a present value that is the wrong type, empty, whitespace, or outside the device-id
alphabet is REFUSED; an unreadable local device id is REFUSED. A divergence between the Swift and
TypeScript gates is a duplicate send, so both sides carry the same table in a comment.

Result: exactly one host may execute any given draft, and on that host the existing lock already
provides at-most-once. The property is inherited from code that is already tested, not asserted
by new consensus machinery.

**This gate is worth landing on its own, before any networking.** It is a small, safe change that
makes at-most-once *achievable* across the two Macs. It does not by itself deliver it, see the
requirements below, which the phase-0 second-lane review established and which phase 2 must satisfy
before the relay stamps its first draft.

### Phase-2 requirements inherited from the phase-0 review

From the adversarial review of PR #12
(`runs/reviews/2026-07-22-sun-613-phase-0-executor-gate.md`). P0 on phase 2, not aspirations.

1. **Do not stamp until every executor supports the gate.** An older menubar or MCP ignores
   `relay_executor` and will send a stamped draft; worse, an older `normalizeDraft` projects
   field-by-field and will *erase* the stamp on its next write, silently un-routing the draft.
   Gate activation on a capability or minimum-version handshake with every paired device, and
   refuse to enable the relay in a mixed-version fleet.
2. **An assignment revision, atomically claimed.** A per-host advisory lock cannot serialize
   against another host or against the relay writer, so "read the stamp under the lock" is not a
   cross-host claim. Executor assignment must be immutable once a draft is executable, or carry a
   revision claimed compare-and-set and re-verified at the wire boundary immediately before each
   `sendText` / `sendMedia` / AppleScript call.
3. **Relay writes take the per-draft send lock.** Every draft mutation is read-modify-replace, so
   copying `existing.relay_executor` preserves the value seen at the initial read, not one written
   concurrently before the final rename. `DraftStore.updateScheduling` reading an unstamped draft,
   the relay stamping it, then `updateScheduling` replacing the file with its stale `nil` would
   silently un-route it. Relay writers must take the same lock, and tests must cover
   stamp-vs-schedule, stamp-vs-approval, and stamp-vs-progress races, not only sequential rewrites.
4. **Executor changes invalidate approvals.** Done in phase 0 for the scheduled path
   (`Draft.scheduleApprovalScopeForDraft` binds the executor into the HMAC scope). Phase 2 must
   extend the same binding to the WhatsApp daemon's approved-digest, and phase 3's remote approvals
   must sign the executor and the assignment revision explicitly.

### Scope of the invariant

The invariant is **staged-draft execution**, not "every send." `DraftSender.sendDirect` and
`sendDirectAttachment` are the inline composer, a human typing on that Mac, with no draft and no
stamp, and are deliberately out of scope. State it that way in any user-facing copy, because
"a spoke never sends" is false as written.

---

## Device identity, pairing, and approval provenance

Today `ApprovalAuthenticator` binds "a human approved this" to a per-install Keychain secret,
HMAC'd over id + recipient + body + scope. A remote approval cannot mint that tag. The rule
below keeps the guarantee rather than diluting it.

**Keys.** Each device holds an Ed25519 keypair. On Macs the private key lives in the login
Keychain with `kSecAttrSynchronizable = false`, **local-only, never iCloud Keychain**. If these
keys synced, an Apple ID compromise would grant send authority, which is exactly what this design
must prevent. Add an explicit unit test asserting the attribute.

**Pairing.** Out-of-band short-authentication-string ceremony: both devices display a 6-digit code
derived from the two public keys, the human confirms they match, and only then is the peer
enrolled. Device trust is never bootstrapped through the transport, because the transport is the
channel an attacker would control.

**Approval flow.**

1. The approving device signs `"ghostie-approve-v1" || draft_id || deliveryPayloadDigest ||
   device_id || issued_at || nonce`.
2. The hub verifies the signature against the enrolled public key, checks that `issued_at` is
   within the 120-second TTL, and checks the nonce against a persistent replay ledger.
3. The hub re-reads the local draft and confirms `deliveryPayloadDigest` still matches. A changed
   draft returns `stale` and requires a fresh review.
4. Only then does the hub call the **existing** `ApprovalAuthenticator.recordSessionApproval` /
   `tag(for:)` path to mint the local tag, with the approving device id carried in the `scope`
   component so the audit records who approved and a remote approval is distinguishable from a
   local one.
5. Everything downstream is untouched: payload comparison, attachment manifest verification,
   `SendLock`, kill switch, daemon health checks, failure log, audit.

The TTL exists for replay defence, not as the product mechanism. A spoke never queues a command
for a sleeping hub, if the hub is unreachable the spoke says so and the approval does not happen.

---

## Transport and the iPhone surface

**Hub listener.** The menubar binds an HTTPS listener on the Tailscale interface only, never
`0.0.0.0`. This is the app's first inbound network surface; it is off unless the flag and the
setting are both on, and it binds nothing when off. Being on the tailnet is *not* an
authorization model: every request carries a device token, and every state-changing request
carries the Ed25519 signature above.

**Spoke Macs.** `DraftStore` already watches the drafts directories with
`DispatchSourceFileSystemObject`, so the spoke pushes new and changed drafts to the hub on the
existing change signal, and receives terminal states (sent, failed, discarded, expired) back.

**iPhone.** A responsive page served by the hub, added to the Home Screen as a PWA. The keypair is
a non-extractable WebCrypto Ed25519 key in IndexedDB. Hold-to-send mirrors the existing
`draftSafetyStates` two-step arm-then-fire so there is a keyboard and VoiceOver path, not
pointer-only.

Two honest weaknesses: a WebCrypto key in IndexedDB is weaker protection than the iOS Keychain or
Secure Enclave, and Safari evicts site data after seven days of non-use unless the page is
installed to the Home Screen, in which case re-pairing is occasionally required. Both are
acceptable at n=1; neither would be acceptable in a shipped product.

**Notification.** None in v1, open the page. If that proves annoying, the cheapest option is a
Ghostie-to-self iMessage nudge from the hub using the send path that already exists.

---

## Containment

- New `MFAFeatureFlag` case `deviceRelay`, `builtinDefault = false`.
- New additive `"relay"` block in `~/.messages-mcp/settings.json` (schema v2 is already additive;
  absence on read means disabled).
- No entitlement change. No provisioning profile. No CloudKit container. No Xcode project. No App
  Store or TestFlight pipeline. No change to `SUFeedURL`, the bundle id, the codesign identifier,
  or the state directories.
- With the flag off the listener never binds, no keys are generated, and `relay_executor` is never
  written, so the shipped behavior for every other user is byte-identical to today.
- Marketing copy is unaffected because nothing leaves the user's own devices. The
  `CONTRIBUTING.md:21` sentence should still be corrected separately, it claims Ghostie "never
  stores or transmits message bodies" while draft JSON already persists plaintext `body` and
  `context_messages`, but that is a docs accuracy fix, not a gate on this work.

---

## Delivery plan

| Phase | Scope | Effort |
|---|---|---|
| 0 | `relay_executor` field, Swift + TS executor gate, `WRONG_EXECUTOR` error code, tests. Lands standalone. | 0.5 day |
| 1 | Device identity, local-only Keychain keys with the synchronizable test, SAS pairing ceremony, settings block, feature flag. | 1 day |
| 2 | Hub listener on the tailnet, spoke push on the existing `DraftStore` watch, canonical hydration into the hub's drafts dir, exclusion rules, queue UI showing origin / executor / last-sync recency. | 1.5 days |
| 3 | Mobile web review surface, WebCrypto keypair, hold-to-send, signed approval verified into the existing `ApprovalAuthenticator` mint. | 1.5 days |
| 4 | Revocation, replay ledger persistence, audit entries, kill-switch integration, red-team pass. | 0.5 day |

Roughly 5 focused days. Phase 0 is independently valuable and should land first regardless of
whether the rest proceeds.

## Acceptance criteria

- A draft staged on the spoke Mac appears on the hub and the iPhone with the same
  `deliveryPayloadDigest`.
- A spoke Mac cannot send a relayed draft by any path: the Swift `DraftSender` refuses, and both
  MCP send tools return `WRONG_EXECUTOR`, including with `require_approval` off.
- A draft carrying `in_reply_to_thread_id`, `imessage_group`, `quoted_message_id`, or attachments
  is never relayed for execution, and the UI names the required origin Mac.
- An iPhone approval whose signature, TTL, nonce, or digest check fails never reaches
  `DraftSender`.
- A draft edited after approval returns `stale` and requires a fresh review.
- A revoked device's approval is rejected.
- The hub's minted approval tag records the approving device id in its scope.
- Device private keys are not present in the iCloud Keychain (asserted by test).
- With the flag off, no listener binds and no key material is generated.
- The hub being asleep produces a visible "hub unreachable" state, never a delayed send.

## Non-goals

Syncing chat.db, the WhatsApp database, conversation history, or incoming messages. Syncing
WhatsApp sessions, Messages permissions, Full Disk Access, API keys, or Keychain secrets. Full
attachment replication. Cross-device concurrent editing. Executor selection or failover of any
kind. Offline queueing of approvals. Push notifications. Android, web-outside-the-tailnet,
cross-Apple-ID, or family sharing. Auto-send or remote approval of recurring automations.
Multi-user support.

## Dropped from the original spec, and why

Compare-and-set claims, the losing-Mac refetch rule, the durable attempt journal, the `sending`
no-takeover rule, the `ambiguous` state and its manual-inspection UX, and the 100,000-iteration
race harness, all unnecessary once one host executes. Executor selection UI, replaced by a
fixed per-transport rule. The native SwiftUI iPhone client, replaced by a served web surface.
CloudKit, its entitlement, its provisioning profile, its container, its quota and retention
questions, and the encrypted-record schema, replaced by direct device-to-device transport. The
policy gate blocking implementation, the data never leaves the user's own devices, so there is
nothing new to permit.

## Open items

- Confirm which Mac holds the linked WhatsApp session, and whether linking both is wanted.
- Decide whether the hub should send a to-self nudge when drafts are waiting.
- Decide whether spoke Macs should keep local hold-to-send for drafts they staged and own
  (attachment and reply drafts), or route everything through the hub queue view for consistency.
