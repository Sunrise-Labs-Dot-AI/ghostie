# Ghostie cross-device draft sync, working spec

Linear: SUN-613. Supersedes the CloudKit design in the original issue description.
Adversarial review that produced this rewrite: [SUN-613-cross-device-sync.review.md](SUN-613-cross-device-sync.review.md).
Status: ready to implement. Personal-scale feature, off by default, contained behind a flag.

## Problem

Ghostie keeps draft state per installation. James runs it on an M1 and an M4, so a draft
staged or resolved on one Mac is invisible on the other, and there is no way to review or
approve a draft from an iPhone.

## Shape of the solution

> **Scope note (2026-07-22):** this section and the two that follow it (executor gate, rollout
> safety) were written for a design where a phone could authorise a Mac to send. James has since
> chosen **read-only visibility**: every device sees one unified queue, and sending stays at the
> Mac that staged the draft. Read the "SCOPE: read-only visibility" section further down as the
> authoritative statement of what is being built. The material here is kept because its
> reasoning (why not CloudKit, why the tailnet, the phase-0 executor gate) still holds, but where
> it describes cross-Mac execution, remote approval, or single-homed hand-off, read-only supersedes
> it.

One always-on **hub** Mac (the M4) serves the unified view. Every other device is a **spoke** that
can see the queue but never sends; each Mac executes only its own locally-staged drafts. Spokes
reach the hub directly over Tailscale. The iPhone surface is a web page the hub serves; there is no
iOS app.

Under read-only the system is single-executor by the simplest possible rule: the Mac that staged a
draft is the Mac that sends it. The original CloudKit design allowed either Mac to execute and
therefore needed a distributed mutual-exclusion protocol (compare-and-set claims, a durable attempt
journal, an `ambiguous` state, no-automatic-failover rules, and a 100,000-iteration race harness);
none of it is needed once execution never leaves the origin.

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

> **Mostly moot under read-only.** These requirements existed to make cross-Mac EXECUTION safe.
> Read-only never transfers execution, so most dissolve: there is no assignment revision (nothing is
> reassigned), no locked hand-off (nothing is handed off), and the mixed-version hazard largely goes
> because no draft is ever stamped for a foreign machine, so an old executor only ever sees and sends
> its own drafts normally. Requirement 4 (executor changes invalidate approvals) is retained in code
> from phase 0 and is harmless. Kept here for the record and in case remote approval is revived.

From the adversarial review of PR #12
(`runs/reviews/2026-07-22-sun-613-phase-0-executor-gate.md`).

1. **Rollout safety in a mixed-version fleet.** Written out in its own section below, because
   working it through changed what phase 2 builds.
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

### Rollout safety in a mixed-version fleet

> **Largely dissolved under read-only.** The hazard below is a cross-Mac EXECUTION hazard: an old
> build sending or un-routing a draft that a newer build routed to a different machine. Read-only
> routes nothing, so a published snapshot is just a read-only copy an old build ignores, and the
> real draft an old build executes is its own local one, exactly as today. The single-homing
> mechanism is therefore not needed for correctness. The reasoning is kept because it is the thing
> to re-read first if remote approval is ever revived.

**The hazard (applies only to the deferred remote-approval scope).** A Ghostie build that predates
the executor gate does not know `relay_executor`.
That produces two failure modes, and the second is worse than the first:

  a. It **sends** a draft stamped for another Mac, because it has no gate.
  b. Its `normalizeDraft` projects field-by-field, so it **erases** the stamp on its next write
     (`markDraftSent`, `updateScheduling`). The draft is then permanently unrouted, silently, and
     every machine will send it from then on.

**Why a capability handshake alone does not solve it.** The obvious fix is to have each device
advertise a protocol version and refuse to stamp until all of them are new enough. That fails on
the thing it most needs to catch: an executor that predates the announcement never announces. You
cannot enumerate the old processes by asking them. It is absence of evidence, and the fleet has
four executor processes per Mac (menubar, iMessage MCP, WhatsApp MCP, WhatsApp daemon), any of
which a stale Claude config could still be launching from an old path.

**Primary mechanism, therefore: single-home the draft file.** Ownership is expressed by *which
machine's drafts directory holds the file*, not by a field inside it. A draft exists in exactly one
`~/.messages-mcp/drafts/` at a time, and that machine is the executor. Hand-off is a **locked move**
(take the per-draft `SendLock` on both ends, write the destination, then remove the source and
leave a relay-cache entry behind for display), never a copy.

Spokes render the queue from a relay cache at `~/.messages-mcp/relay/`, which no MCP scans and no
executor reads. Old code cannot act on a file it never sees.

That covers the cases as follows:

| Case | Old executor on that machine | Covered by |
|---|---|---|
| Draft staged on the hub, executed on the hub | sees it, sends it, correctly | ownership is already right; stamp erasure is harmless |
| Draft relayed to a spoke for review | never appears in the spoke's drafts dir | single-homing |
| Draft staged on a spoke, executed on the hub | the window between staging and the move | the handshake, below |

**The residual case, and the narrowed handshake.** Only one case still needs a version check: a
draft staged by a spoke's own MCP, which therefore lands in that spoke's drafts directory before
the relay can move it. Until the move completes, an old executor on that spoke can send it.

So the handshake survives, but small and specific: each device publishes a `relay_protocol` integer
in its pairing record during the phase-1 ceremony, and the hub refuses to **accept a spoke into
relay mode at all** unless the spoke advertises a version that supports the gate. This is a check
about the *device we are enrolling*, made at enrollment time, which is exactly the moment the
information is available and trustworthy. It is not an attempt to poll for processes that cannot
answer.

Belt and braces for the same window: the relay moves a newly staged spoke draft under the per-draft
send lock, so the move cannot interleave with an in-flight send on that spoke.

**Accepted tradeoff.** After hand-off, the spoke's own Claude session loses `get_draft` visibility
of a draft it staged: the file is gone from the directory its MCP reads, so the tool returns "not
found". That is a real regression for the agent on the spoke, and it is the price of the property
that old code cannot act on a file it cannot see. If it proves annoying, the fix is to teach the
`ghostie` facade MCP to read the relay cache for read-only tools, which does not weaken the
invariant because the facade exposes no send. Do not fix it by leaving the file in place.

**Consequence for phase 1.** Device records must carry `relay_protocol` from the start, because
enrollment is where it is checked. This is the one piece of the rollout work that lands in phase 1
rather than phase 2.

### Scope of the invariant

The invariant is **staged-draft execution**, not "every send." `DraftSender.sendDirect` and
`sendDirectAttachment` are the inline composer, a human typing on that Mac, with no draft and no
stamp, and are deliberately out of scope. State it that way in any user-facing copy, because
"a spoke never sends" is false as written.

---

## SCOPE: read-only visibility (decided 2026-07-22)

**James chose read-only cross-device visibility over remote approval.** Every device sees one
unified draft queue; sending stays at the Mac that staged the draft. Nothing a phone or a spoke
sends over the wire can cause a message to go out.

This decision followed three consecutive BLOCK reviews, all on the same surface: the cryptographic
authority that would let a phone authorise a Mac to send. The queue and the transport were never
the hard part; proving remote send-authority was. Read-only deletes that surface entirely rather
than continuing to harden it.

**What this removes, and it is most of the design:** signed remote approvals, the replay ledger,
the 120-second TTL, revocation-of-send-authority, the SAS pairing ceremony as an authority
bootstrap, the assignment-revision protocol, and the single-homed locked hand-off. Under read-only
the origin Mac is always the executor of its own drafts, so ownership never transfers, so none of
the machinery that made transfer safe needs to exist. The phase-0 executor gate stays as a backstop
but is never actively used to route, because no draft is ever stamped for a foreign machine.

**What survives from the earlier design:** the CloudKit rejection and its reasoning, the tailnet as
transport, the feature flag, and the phase-0 executor gate.

---

## How read-only works

**Publish, do not hand off.** Each device writes a read-only snapshot of its own draft queue to a
relay cache at `~/.messages-mcp/relay/published/`. Snapshots are copies for display: the real draft
file never moves, so the origin Mac keeps executing it exactly as today and no old executor is ever
confused by a relocated or re-stamped file. This is a strictly weaker operation than the hand-off
the previous revision specified, and it is weaker on purpose.

**Content that crosses the wire.** A snapshot carries what the reviewer needs to see: recipient
label, body, thread context, staged time, and lifecycle state. It deliberately omits trusted
attachment file paths and any local execution detail. Draft bodies are message content, so this is
the point at which the product does transmit bodies between the user's own devices. The transport
is Tailscale, which is WireGuard, so bodies are encrypted in transit by the tailnet itself; the app
adds reader authentication on top so a non-paired device on the same tailnet cannot read the queue.

**The hub serves the unified view.** The always-on Mac (the M4) binds an HTTPS listener on the
Tailscale interface only, never `0.0.0.0`, off unless the flag and setting are both on. It merges
every device's published snapshots into one queue and serves it to authenticated readers, including
the phone's web page. It is a read surface: it exposes no endpoint that mutates a draft or triggers
a send.

**Reader authentication, not send authority.** A device proves it is paired before it may read.
Because the worst case of a compromised reader credential is disclosure of your own draft queue to
another device you control, not an unwanted send, this is a materially lower bar than the blocked
design carried. The exact credential (a paired-device keypair used for challenge-response, versus a
simpler paired token) is an implementation choice settled in the phase-1 plan and its review, not
here. Whatever it is, it grants read, never send.

## The iPhone surface

A responsive page the hub serves, added to the Home Screen. It renders the unified queue: who,
what, thread context, which Mac will send it, and how fresh the view is. It has **no** hold-to-send
and **no** approve control, because approval is not a thing the phone does in this scope. Where it
helps, it offers a "this is waiting on the M4" affordance so you know to walk over, not a way to act
from the phone.

Honest weakness to keep in view if this ever grows into remote approval: a browser-stored key is
weaker than the Secure Enclave, and Safari evicts site data after seven days of non-use unless the
page is installed to the Home Screen. Both are fine for read-only at n=1.

## Containment

- New `MFAFeatureFlag` case `deviceRelay`, `builtinDefault = false`.
- Additive `"relay"` block in `~/.messages-mcp/settings.json` (absence on read means disabled),
  introduced by the first phase that actually reads it.
- No entitlement change. No provisioning profile. No CloudKit container. No Xcode project. No App
  Store or TestFlight pipeline. No change to `SUFeedURL`, the bundle id, the codesign identifier,
  or the state directories.
- With the flag off the listener never binds, no keys or tokens are generated, nothing is published,
  and shipped behavior for every other user is byte-identical to today.
- `CONTRIBUTING.md:21` claims Ghostie "never stores or transmits message bodies." That was already
  inaccurate (draft JSON persists plaintext `body` and `context_messages` on disk), and read-only
  sync does transmit bodies between the user's own devices, so the sentence must be corrected to the
  accurate promise: no message content reaches any Sunrise Labs server, and content stays within the
  user's own paired devices. This is now a required change, not just a cleanup, and it is tracked by
  the spawned task on `CONTRIBUTING.md`.

---

## Delivery plan

| Phase | Scope | Effort |
|---|---|---|
| 0 | `relay_executor` executor gate, `WRONG_EXECUTOR`. **Merged, PR #12.** Stays as a backstop. | 0.5 day |
| 1 | `deviceRelay` feature flag, paired-device READ credential, settings block. Re-scoped from the blocked send-authority identity (PR #15 superseded). | ~1 day |
| 2 | Hub read listener on the tailnet, each device publishes read-only snapshots on the existing `DraftStore` watch, unified merged queue, reader authentication. | ~1 day |
| 3 | iPhone web page rendering the unified queue: who / what / which Mac sends it / freshness. No approve control. | ~0.75 day |

Roughly 2.75 focused days remaining after phase 0. Phase 4 (revocation, replay ledger, red-team of
the approval path) is gone with the approval path. Phase 0 is merged and already fixed a real
duplicate-send hole between the two Macs, so the safety win is banked regardless.

## Acceptance criteria

- A draft staged on the M1 appears in the unified queue on the M4 and the iPhone.
- The real draft file never leaves its origin Mac's `~/.messages-mcp/drafts/`; only a read-only
  snapshot is published. The origin Mac's `get_draft` still returns it.
- The hub exposes no endpoint that mutates a draft or triggers a send. Confirmed by an inventory of
  the served routes.
- A device that is not paired cannot read the queue over the tailnet.
- Every existing send path is unchanged: each Mac still executes only its own locally-staged drafts,
  through the same guards as today.
- With the flag off, no listener binds, no reader credential is generated, and nothing is published.
- The hub being asleep produces a visible "queue unavailable" state; it never affects sending, which
  is entirely local.
- No trusted attachment file path or local execution detail appears in a published snapshot.

## Non-goals (read-only scope)

Remote approval or remote send of any kind. Signed approvals, replay ledgers, revocation of send
authority, the SAS authority ceremony, and cross-Mac execution hand-off, all removed with the
approval surface. Also, as before: syncing chat.db, the WhatsApp database, conversation history, or
incoming messages; syncing WhatsApp sessions, permissions, FDA, API keys, or Keychain secrets; full
attachment replication; concurrent cross-device editing; push notifications; Android, web outside
the tailnet, cross-Apple-ID, or family sharing; multi-user support.

Remote approval is not rejected forever, only deferred. Read-only is a strict prefix of it: if it is
wanted later, this work is the foundation and nothing here is wasted. That later step is where the
Secure Enclave identity, the committed pairing ceremony, and the replay ledger from the blocked
design come back, designed properly rather than under sunk-cost pressure.

## Dropped from the original spec, and why

The CloudKit design and everything under it (entitlement, provisioning profile, container, quota,
retention, encrypted-record schema, compare-and-set claims, attempt journal, `ambiguous` state, the
100k race harness) went when the executor was fixed to one host and the transport became the
tailnet. The send-authority machinery (signed approvals, replay ledger, revocation, SAS authority
ceremony, single-homed hand-off, assignment revision) went when the scope became read-only. What is
left is deliberately small: publish snapshots, serve a read view, authenticate the reader.

## Open items

- The exact reader credential (challenge-response keypair vs. paired token), settled in the phase-1
  plan and its review.
- Whether the hub should send a to-self iMessage nudge when drafts are waiting (uses the existing
  local send path, so it stays within scope).
- Decide whether spoke Macs should keep local hold-to-send for drafts they staged and own
  (attachment and reply drafts), or route everything through the hub queue view for consistency.
