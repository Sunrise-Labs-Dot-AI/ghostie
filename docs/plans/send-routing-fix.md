# Plan — transport-aware send + failure visibility (the Jordan fix)

Status: **IN PROGRESS — paused 2026-06-22.** Scope C approved. Working branch
`fix/transport-aware-send` (based on `70ae625`, #187). Target base: `origin/main`.

## Progress / resume notes (paused 2026-06-22)

**Done (Swift, built + all 675 menubar tests green):**
- `IDSCapability.swift` — guarded IDS (`com.apple.madrid`) capability lookup; pure
  helpers unit-tested, dynamic call falls back to `.unknown` on any failure. (+ tests)
- `FeatureFlags.swift` — added `MFAFeatureFlag.transportAwareSend` (default OFF) +
  nonisolated `FeatureFlagStore.resolvedFromDisk(_:)` for the off-main-actor send path.
- `DraftSender.swift` — `nonIMessageFirstScript` (RCS→SMS→iMessage); `sendIMessageDirect`
  now, when flag ON + no addressable chat + IDS says not-iMessage, leads with RCS/SMS
  (iMessage kept last → strictly additive, no regression). Failure logging wired into
  `sendDirect` + `send(draft:)`. Non-blocking post-send delivery confirmation logs
  silent bounces. (+ `noChatSendStrategy` pure decision tested)
- `SendFailureLog.swift` — append-only JSONL at `~/.messages-mcp/logs/send-failures.log`
  (shared format with TS: ts, platform, handle, route, error, duration_ms, source).
- `IMessageDeliveryConfirmer.swift` — post-send chat.db read (real transport + bounce);
  fixture-backed tests.

**In flight:** TS `send_draft` mirror (task #6) delegated to a background agent
(`mcps/imessage-drafts`: 1:1 chat-id routing via a new daemon `resolveDirectChat` RPC +
shared-format failure log + bun tests). Result pending — check its handoff on resume.

**Not started / deferred:**
- Audit relabel residual: a successful auto-routed buddy-cascade send still logs
  "iMessage" (cosmetic). New routing paths already label correctly.
- `bun typecheck && bun test` for the TS side (task #7) — run after the agent lands.
- The actual RCS/SMS routing reroute is UNVERIFIED without a live send (constraint:
  no Messages automation). Validate by flipping the `transport-aware-send` override ON
  in the dev flags UI, then sending one real text to Jordan (+16505550159).

**Resume housekeeping:**
- Branch is behind `origin/main` (PR #179 mixed-media merged after branch point). Rebase
  `fix/transport-aware-send` onto latest `origin/main` before continuing / PRing, else
  the diff spuriously "deletes" the #179 files. (Working-tree changes themselves are clean.)
- Swift work is currently **uncommitted** in the worktree. First resume step: commit it.

---

(original plan below)

## Root cause (established this session)

- Ghostie's 1:1 send tries to send by `chat id` only for chat GUIDs that
  `IMessageDirectChatResolver.isAddressableChatGUID` accepts. It deliberately
  rejects **unbound `any;-;<handle>` 1:1 chats** (DraftSender.swift:199-211, comment
  at :203-204 — sending an unbound `any;-;…` chat hard-fails with `-1728`).
- Jordan Rivera (+16505550159) is **not on iMessage** (IDS verdict 2). His only
  thread is `any;-;+16505550159`, service RCS. So his send is judged unaddressable
  and falls through to `sendIMessageDirect` → the `script` buddy cascade
  (DraftSender.swift:348-377): iMessage service → RCS service → SMS service, each
  on *synchronous* AppleScript error.
- For a non-iMessage recipient that cascade is unreliable: macOS sometimes
  auto-routes the iMessage-service send to RCS and it delivers (his 4 audit-logged
  "iMessage" sends were really RCS), but when the iMessage `send` throws, the
  fallback depends on `first service whose service type is RCS` / `… SMS` resolving
  as scriptable service objects, which often fails (RCS rides Continuity through the
  iPhone and isn't reliably exposed; SMS needs Text Message Forwarding live). When
  neither resolves → hard ERROR, nothing queued.
- **No log records the failure.** Audit log = successful sends only; chat.db = queued
  messages only; menubar-events.jsonl doesn't track direct sends. So the failure is
  invisible, which is why it looked clean at first.

## Validated spike

`/tmp/ids-probe/ids_probe.m` — `IDSIDQueryController.refresh/currentIDStatusForDestinations:service:listenerID:queue:completionBlock:`,
service `com.apple.madrid`. Returns clean 1 (iMessage) / 2 (not-iMessage) verdicts
from an **unentitled CLI process** (no entitlement wall, cache warm). Across the 32
real Ghostie recipients it flagged exactly 4 as not-iMessage (+16505550159,
+12155550178, +14155550182, +15105550171) and confirmed +12155550192 as
iMessage-capable (its err25 was a transient blip, 11/12 delivered).

## The fix — three parts

### 1. Transport-aware 1:1 send (the actual routing fix)
- Add a native Swift IDS wrapper (`IDSCapability`): dlopen `/System/Library/PrivateFrameworks/IDS.framework`,
  call `refreshIDStatusForDestinations:` for `com.apple.madrid`, map URI→status.
  Guarded: `respondsToSelector` checks + 12s timeout + total fallback to current
  behavior if the framework/selector is absent (version-fragility safety).
- In `sendDirect` / `sendIMessageDirect`: when the recipient has an existing 1:1
  thread, send by a **concrete addressable chat id** (resolve `any;-;<handle>` to the
  service-specific chat, or bind it) instead of the buddy cascade. When there is no
  thread (cold contact), use the IDS verdict to **start the cascade at the correct
  service** (skip the iMessage attempt for known not-iMessage handles).
- TS `send_draft` path (drafts.ts/send.ts on origin/main): route 1:1 by resolved
  chat id via the daemon's chat.db access (the daemon already has `sendIMessageToGroup`
  = send by chat id, and chat-query infra in queries.ts). IDS-in-TS is out of process
  for Bun; first cut uses chat.db's recorded service as the transport signal, with an
  optional menu-bar→daemon IDS bridge as a fast-follow.

### 2. Failure observability
- Log every **failed** send attempt (handle, time, resolved route, errNum, script
  error) to a durable `send-failures.log` under `~/.messages-mcp/logs/`.
- Post-send delivery confirmation: after a send, the daemon polls chat.db for the new
  outbound row's `error`/`is_delivered` for a few seconds and surfaces real status
  (so a silent bounce becomes a visible, retryable failure).

### 3. Audit transport relabel
- Record the **real** transport in the audit log (read it back from chat.db, or from
  the resolved route) instead of always writing `service:"iMessage"`.

## Implementation steps
1. **Spike (read-only, ~30 min):** confirm how to address an `any;-;` 1:1 thread —
   does `send to chat id "any;-;<h>"` work, or must we resolve to a concrete
   `RCS;-;`/`iMessage;-;` chat id (or send service-directed buddy). Read-only AppleScript
   service-resolution probe + inspect chat GUID forms. No message sent.
2. `IDSCapability.swift` wrapper + unit shim; behind `Defaults` flag `transportAwareSend`.
3. Rework `sendDirect`/`sendIMessageDirect` to: resolve thread → chat-id send; else
   IDS-directed cascade. Keep the old path as the fallback branch.
4. Failure log + post-send confirmation (daemon side, shared substrate).
5. TS `send_draft`: chat-id routing for 1:1 via daemon resolution; failure surfacing.
6. Audit relabel.
7. Tests: Swift `swift test` (route resolver: `any;-;` addressable, IDS verdict →
   service mapping, fallback when IDS absent); TS `bun test` (send_draft 1:1 chat-id
   routing, failure result shape). Manual preview send to Jordan + 1 iMessage control.

## Rollback
- Everything behind the `transportAwareSend` flag (default on in dev, validate, then
  release). Flip off → exact current behavior. IDS wrapper fails closed to the existing
  cascade. No schema/state migration, so rollback is flag-flip + revert commit.

## Risks
- `any;-;` addressing unknown → resolved by step 1 spike before code.
- Private IDS API version-fragility → guarded wrapper + fallback; Developer-ID
  distribution (not MAS) makes private API acceptable.
- Live send path is the most sensitive code → flag-gated, fallback-on-error, daily-cap
  breaker stays, manual + unit test before release.
