# Review — WhatsApp revoke + re-authenticate (PR #18)

Branch `claude/whatsapp-reconnect-feature-dba7df`. Authoring lane Claude/Opus,
review lane Codex (second lane, per HOME-ADR-0005).

Two blocking review passes ran: one on the plan (before implementation), one
adversarial pass on the diff. Both returned BLOCK. All findings are resolved
below.

---

## Pass 1 — plan review (Codex). Verdict: BLOCK, 8 findings

Run: `task-mscqtrsh-0ujvkx`, Codex session `019fc5ee-8356-7033-ad6a-1a0fca287013`.

Three of these changed the design materially and are the reason this PR is
larger than "add a Disconnect button".

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | `unwrap()` resolves the Keychain key internally, so a locked/denied Keychain would be classified as unreadable ciphertext and invite the user to destroy a valid session | **Fixed** — `KeychainAccessError` vs `CiphertextAuthError`; key resolved outside the try in `crypto.ts`; only the latter triggers recovery |
| 2 | Only `readCreds()` was wrapped, but `auth_state` rows decrypt lazily in `keys.get`, outside any catch | **Fixed** — `assertSessionReadable()` preflights creds + every row before Baileys is constructed |
| 3 | "Preserves message history" was false: `messages.db` content uses the SAME wrap key, and `deleteSession()` deleted it | **Fixed** — `deleteSession()` no longer rotates the key; read path fails soft on rows already lost |
| 4 | `unlinkAndReset` never stopped the live socket and left the crypto key cached after deleting it | **Fixed** — serialized `performUnlinkAndReset`: quiesce → wipe → verify gate → start one socket; key no longer deleted, so the cache issue is gone |
| 5 | Local wipe could race a live WAL database | **Fixed** — `stopAndConfirmDead()` before any unlink; abort without restarting on failure |
| 6 | A second `SESSION_UNREADABLE` sentinel is not downgrade-safe | **Fixed** — reuse `LOGGED_OUT` with a `reason=` payload; old builds park on existence and ignore contents |
| 7 | Banner / repair card / pairing window only understood `logged_out`, and offered a no-op Restart | **Fixed** — one observable `recoveryState`; every entry point routes into the confirmed reset |
| 8 | Deferring the `hasKey()` fix makes the shipped repair recurrent | **Accepted, fixed in this PR** — tri-state probe |

---

## Pass 2 — adversarial review of the diff (Codex). Verdict: BLOCK, 5 findings

Run: `task-mscs5ouk-w5t7w6`, Codex session `019fc610-9be8-77f0-8f32-b46b9c7b3509`.
Re-checked pass 1: 6 FIXED, 2 PARTIAL (#4 reset concurrency, #8 UI routing / PID safety).

### B1 — a freshly minted key could still be orphaned by the ACL migration — FIXED

`getOrCreateMasterKey` created a fresh key with the correct `-T` ACL but never
marked the migration done, so the next start ran `migrateKeychainAcl()` against
it — and that deletes before it re-adds. A failure in that window destroys a
brand-new key and orphans the session just paired under it.

Fix: `markMigrationDone()` after a verified fresh create, and the migration now
restores the key if the re-add fails, failing closed rather than losing it.
Commit `c98c393`. Test: "a freshly minted key is marked migrated so it is never
re-written".

### B2 — reset did not actually guarantee one socket — FIXED

Two holes. `scheduleConnect()` kept no timer handle, so a backoff queued before
a reset fired after it and called `connect()` directly, bypassing `start()`'s
teardown. And a connect already awaiting `fetchLatestBaileysVersion()` had not
yet assigned `this.socket`, so `prepareForReset()` couldn't see it and it
installed itself afterwards. Either way: two sockets writing one auth store.

Fix: a `generation` counter plus a stored timer handle. `invalidateInFlight()`
cancels the timer and invalidates in-flight attempts; `connect()` re-checks its
generation after every await and abandons (tearing down its own socket) if
superseded. Commit `c98c393`. Tests: `reset-concurrency.test.ts`.

### B3 — reset could wedge forever — FIXED

`teardownSocket()` awaited Baileys' `end()`, which waits on a WebSocket `close`
event with no timeout of its own. A lost close event left the RPC handler
pending and — because the reset promise is shared for coalescing — every
subsequent reset would await the same stuck promise. One lost event would
permanently disable recovery.

Fix: teardown is bounded by `TEARDOWN_TIMEOUT_MS` (3s); listeners are detached
first, so an abandoned socket can no longer touch the store. Commit `c98c393`.
Tests: coalescing lock clears after both success and failure.

### B4 — local fallback could terminate an unrelated process — FIXED

With `process == nil`, the fallback trusted `daemon.pid` and `kill(pid, 0)`,
which proves only that *a* process exists. macOS recycles PIDs, so a stale file
could aim SIGTERM/SIGKILL at something unrelated.

Fix: `isLiveWhatsAppDaemon(_:)` verifies identity via `/bin/ps -o args=` before
any signal, and fails closed. Applied to `reapStaleDaemonIfNeeded()` too, which
had the same latent risk on the normal launch path. Commit `c98c393`. Tests
cover the standalone and launcher forms, and explicitly reject the sibling
iMessage daemon and the WhatsApp MCP client.

### B5 — a Keychain failure during timer reconnect was never retried — FIXED

`scheduleConnect()` logged non-session errors and stopped, leaving a live daemon
with no socket and nothing scheduled. On startup the same error rethrew into the
fatal exit path.

Fix: `reportConnectFailure()` classifies — park only on `SessionUnreadableError`;
`KeychainAccessError` and generic failures retry on their own backoff. Startup
routes through the same logic instead of exiting. Commit `c98c393`.

### Non-blocking

1. **Preflight cost unbenchmarked** — accepted. ~6,400 small AES-GCM opens per
   connect. B2's serialization removes the repeated-scan-in-a-storm case. Full
   suite (302 tests, incl. a 6,400-row fixture) runs in <1s; not optimising on
   speculation.
2. **`removeAllListeners()` is broader than necessary** — accepted as-is. It
   also drops Baileys' internal listeners, which is fine for a socket being
   discarded; the real race was B2.
3. **Stale `baileysState` after a successful reset** — **fixed**, `noteSessionReset()`
   clears it so the UI doesn't keep offering Reconnect for up to 5s post-repair.
4. **Weak tests** — **fixed** where it mattered. The "does NOT rotate" test was
   vacuous (`WHATSAPP_MCP_TEST_KEY` makes `deleteMasterKey()` a no-op, so it
   would have passed even if the call were reintroduced); replaced with one that
   drives the live Keychain seam and asserts `delete-generic-password` is never
   issued. Swift tests gained real PID-safety coverage.

---

## Verification after fixes

Re-run against the fixed tree, out of sandbox:

- `mcps/whatsapp-drafts`: `tsc --noEmit` clean; `bun test` → **302 pass, 0 fail**
- `menubar`: `swift build` clean; `swift test` → **779 pass, 2 skipped, 0 fail**

## Residual risk, accepted

Content already encrypted under a lost key stays unreadable — this PR makes the
failure recoverable, it does not resurrect data. Those rows now degrade to empty
instead of throwing. Quarantining or purging them is deliberately out of scope.

---

## Post-validation investigation: the unexplained session wipe

During live validation the production `session.db` was observed to lose all
6398 `auth_state` rows plus its creds row sometime between 2026-08-02 21:42 PDT
and 2026-08-03 10:36 PDT, replaced by a fresh empty session. Investigated
before merge at James's request.

### Ruled out, with evidence

| Candidate | How it was excluded |
|---|---|
| The bun test suite (current, 302 tests) | Ran with `HOME` pointed at a seeded canary home. Canary `auth_state`/`auth_creds` rows untouched afterwards. |
| The bun test suite as of the first checkpoint (`071dcb8`, 294 tests) — the version actually run inside the window | Same canary experiment against a detached worktree at that commit. Untouched. |
| The WhatsApp MCP (stdio client) | No import path, direct or transitive, from `src/index.ts` or `src/tools/*` to `storage/session.ts`. |
| Swift tests | Only reference `/tmp/.whatsapp-mcp/...`; the new `WhatsAppSessionResetTests` assert constants and never call `perform`. |
| An automatic reset in the menu bar | Both call sites (`SettingsView.runDisconnect`, `WhatsAppPairingView.runUnlinkAndReset`) sit behind destructive-role confirmation buttons. No auto-invocation exists. |
| The daemon itself | No daemon log entries at all between the final crash at `04:35:54Z` and the `17:36:19Z` startup. |
| The Codex review agents (both ran inside the window with shell access) | Job logs contain no `sqlite3`, no `bun test`, no `rm`, no `$HOME` redirects. Only `stat` loops over the session files, all exit 0. `deleteSession(`/`unlink` hits are prose in their review text. |

### What is established

- The snapshot genuinely contained 6398 + 1 rows: the daemon later read exactly
  `6399 of 6399` from it during the controlled park test.
- The `17:36` startup did **not** park — the only park message in the entire
  17k-line log is at line 17118, from the controlled test. So that daemon saw an
  already-clean database.
- The main `session.db` file is byte-identical to the pre-incident snapshot
  (same SHA-256), so the rows were removed via a WAL write, not a file replace.

### Disposition

**Unresolved.** No remaining in-repo candidate explains it, and the external
possibilities (another agent session, a sync/backup tool, another worktree) are
not distinguishable from available evidence. It did not affect the validation,
which ran against the preserved snapshot, and it is not reproducible.

Rather than leave a destructive operation unattributable, `deleteSession()` now
logs the resolved database path, the pre-wipe row counts, and the calling stack
frames. A recurrence becomes a log line naming the caller instead of a forensic
dead end.
