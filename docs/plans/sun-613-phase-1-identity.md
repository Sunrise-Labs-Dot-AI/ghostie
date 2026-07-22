# SUN-613 phase 1, implementation plan: device identity primitives

Loop: **full**. Touches credentials (private keys). Does not qualify as abbreviated.

Branch `claude/sun-613-phase-1-identity`, worktree `.claude/worktrees/sun-613-phase-1`, off
`origin/main` at 42e0430.

**This plan was rewritten after a second-lane review returned BLOCK on the first version**
(10 CRITICAL). The review is recorded in `runs/reviews/2026-07-22-sun-613-phase-1-plan.md`. The
headline outcome: the original phase 1 was incoherent, and pairing has moved to phase 2.

## What changed, and why

**Pairing is out of this phase.** The original plan forbade networking and simultaneously claimed
two Macs would prove identity to each other. There is no mechanism in that scope by which the M1
learns the M4's public key, so the stated production validation could not have been performed. The
phase is now what it actually was: identity primitives.

**The SAS design was unsafe and is deferred with it.** Six digits derived from two static public
keys, with no commitment step, is breakable by an attacker who controls the transport during
pairing: roughly 20 bits, and the attacker can grind candidate keys toward each side until the
displayed codes collide. It was also bound to nothing but the two keys, so a transport attacker
could alter `device_id`, `role`, or `relay_protocol` in the enrollment record while the displayed
code still matched. A correct ceremony needs commit-then-reveal over a full transcript with
proof-of-possession, which belongs in the phase that has a transport.

**`devices.json` as the trust root was a direct contradiction of this codebase's threat model.**
`ApprovalAuthenticator` exists because the repo treats same-user JSON writes as hostile; mode 0600
and `O_NOFOLLOW` give availability, not integrity. Making an owner-writable JSON file the peer
public-key trust root would have thrown that away: a local process could swap an enrolled peer's
key for its own and have the hub verify a forged approval against it. The trust store moves into
the Keychain, in phase 2.

**Two things I had factually wrong about macOS Keychain**, both fixed below: `kSecAttrAccessible`
is only honored on macOS when `kSecUseDataProtectionKeychain` is true (otherwise the item lands in
the legacy file-based keychain and `ThisDeviceOnly` is not applied), and an environment-variable
key override is a production key-injection backdoor rather than a test seam.

## What gets built now

**A. `RelayDeviceIdentity`.** Secure Enclave P-256 signing key. **This replaces the Ed25519 in
the Keychain the previous revision specified.** The change was forced by measurement, not taste:

  - The data-protection keychain, the only macOS keychain that honors `kSecAttrAccessible`, returns
    `errSecMissingEntitlement` (-34018) without a keychain-access-group entitlement, which needs a
    provisioning profile, which is the fleet-wide launch dependency this design exists to avoid.
  - The legacy file-based keychain accepts the write and then reports `synchronizable = nil` and
    `accessible = nil` on readback. The attributes are not recorded, so "never syncs, never leaves
    this Mac" could be asserted but never verified. An unverifiable guarantee is not one, and this
    key is a send-authority boundary.
  - Measured on this hardware: `SecureEnclave.isAvailable == true`, create/sign/verify works in an
    unsigned binary with no entitlement, and the 284-byte blob restores to an identical public key.

  The enclave key is non-extractable, so it also dissolves the finding about bundled MCP binaries
  sharing the menu bar's keychain access: there is no raw key for them to read. P-256 is
  additionally the curve WebCrypto supports most universally, so phase 3's phone client gets easier.

  Accepted cost: requires Apple silicon or T2. Both target Macs qualify. Hardware without an
  enclave refuses to enroll with a clear message rather than silently downgrading to an extractable
  key.

  Superseded detail from the previous revision:

  - `kSecUseDataProtectionKeychain: true` on **every** add, read, update, and delete. Without it
    the accessibility class is silently not applied on macOS.
  - `kSecAttrSynchronizable: false` explicitly on add and on every query. If this key reached the
    iCloud Keychain, an Apple ID compromise would grant send authority, which is the exact thing
    this design claims to prevent.
  - `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Signing is interactive, so
    there is no reason to keep the key readable while the screen is locked. Tighter than the
    `AfterFirstUnlock` the first draft chose.
  - **Collision check, refuse rather than delete.** Synchronizability is part of a generic
    password's composite primary key, so a synced item with the same service/account can coexist
    with a local one. Enrollment enumerates with `kSecAttrSynchronizableAny` and refuses with
    remediation text if a synced record exists. It never deletes it: deleting a synchronized item
    propagates that deletion to the user's other devices.
  - **Minting is explicit, never lazy.** `ensureKeyPair()` is called only from enrollment; read
    paths return nil when absent. This is what makes "flag off means no key material" true.
  - Fail-closed when the Keychain is unavailable.
  - **No environment-variable override.** Tests inject through a `RelayKeyStore` protocol; the
    production type is the only Keychain-backed implementation.

**B. Settings: deferred to phase 2.** The `"relay"` block would be written and never read until
phase 2 introduces the first consumer, and unread persisted state rots. The feature flag alone
gates everything that exists in phase 1. Scope call made during implementation, recorded here
rather than silently dropped.

**C. Feature flag.** `MFAFeatureFlag.deviceRelay = "device-relay"`, `builtinDefault = false`.

**D. `RelayProtocolVersion`.** `current = 1`, `minimumSupported = 1`, carried as a constant only.
The enrollment check that consumes it moves to phase 2 with the rest of pairing, and the plan no
longer claims it detects stale executors, because it does not: it is a self-report by the current
app and says nothing about an old MCP binary a stale Claude config is still launching. Rollout
safety rests on single-homing the draft file, which is what the merged spec already says.

## Deliberately NOT in this phase

Pairing, the SAS ceremony, `devices.json`, any network call, any listener, remote approval
verification, revocation.

## Sequencing changes this review forced

Recorded here and mirrored into `docs/plans/cross-device-draft-sync-spec.md`:

1. **Pairing moves to phase 2**, designed as commit-then-reveal over a canonical transcript
   (pairing id, both nonces, role-labeled device ids, public keys, protocol range) with
   proof-of-possession signatures from both sides, one-shot sessions, expiry, and mismatch abort.
2. **The peer trust store is Keychain-anchored**, not a plain JSON file.
3. **Persistent replay ledger and revocation move from phase 4 into phase 3**, the phase that first
   accepts a remote approval. A nonce with no durable ledger is not replay protection, and a
   120-second TTL bounds replay rather than preventing it.
4. **The approval envelope grows** to bind hub id, pairing id, key generation, executor id, and
   assignment revision, so an approval cannot be replayed to a different hub or against a
   different executor assignment.

## Known constraint, surfaced rather than solved

Ghostie deliberately signs every inner Mach-O with one codesign identifier
(`com.sunriselabs.messages-for-ai`), which is what makes daemon peer-auth work. A consequence is
that the bundled MCP binaries and daemons may share the menu bar's effective keychain access, so
storing a signing key there does not separate it from them. Splitting that would need a dedicated
keychain-access-group entitlement, which needs a provisioning profile, which is the class of change
this whole design exists to avoid.

This is **status quo, not a regression**: `ApprovalAuthenticator`'s HMAC secret already lives in the
same keychain under the same identity, so anything that could read the new signing key can already
forge an approval today. Filed as a follow-up rather than blocking phase 1, but it should be
understood before phase 3 treats a Keychain key as a strong authority boundary.

## Acceptance criteria

1. Every Keychain operation sets `kSecUseDataProtectionKeychain: true`, synchronizable false, and
   `WhenUnlockedThisDeviceOnly`.
2. A live round-trip test adds an item, reads it back with `kSecReturnAttributes`, and asserts the
   returned attributes (not the query dictionary) show synchronization off and the expected
   accessibility, then deletes it. This is a required gate on the macOS leg, not a skip.
3. Enrollment refuses, with remediation text, when a synchronized item with the same
   service/account already exists. It does not delete it.
4. No environment variable can substitute a private key. Tests inject via protocol.
5. With the flag off and relay disabled, no Keychain item is created. Proven by a test that runs
   the normal startup paths and asserts absence.
6. Settings round-trip: absent `relay` block reads as disabled; a written block reads back
   identically; existing settings files unaffected.
7. Full existing suite stays green: 732 Swift, 392 iMessage, 262 WhatsApp, 21 ghostie.

## Rollback

Additive only, clean squash revert, no data migration. A reverted install leaves an orphaned
Keychain item that nothing reads. No shipped behavior changes while the flag is off.

## Test plan

`RelayIdentityTests`: query attribute construction, live round-trip with returned attributes,
synced-collision refusal, explicit-mint discipline, protocol-injected key store.
`SettingsStoreTests`: additive `relay` block round-trip and absence default.

## Production validation

On the M4 with the flag enabled: mint the identity, then confirm via
`security find-generic-password -s com.sunriselabs.messages-for-ai.relay-device-key` that the item
exists, is local-only, and is in the data-protection keychain. Confirm a fresh profile with the flag
off leaves no item behind.
