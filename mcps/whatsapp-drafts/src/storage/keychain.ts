// Get-or-create the AES-256-GCM master key for session.db wrapping.
//
// Stored in macOS Keychain as a generic-password item. The first time
// the daemon runs against a fresh Keychain, it generates a random 256-bit
// key and stores it; subsequent runs retrieve it.
//
// The item is created with an explicit `-T` access-control list scoped to
// the running daemon binary (its absolute executable path). Without a `-T`,
// the item carried an EMPTY ACL, which macOS treats as "prompt for any app"
// — but once the user clicks "Always Allow" for ANY same-user process, that
// process is added to the ACL and can read the key forever (#82: account-
// hijack path). Binding `-T <daemon-path>` whitelists ONLY the daemon: the
// daemon reads without a prompt, and any other same-user process is denied
// (or, at most, can prompt the user — it can't silently read).
//
// PRODUCTION NOTE: the `-T` path must match the SIGNED daemon binary's path.
// In a packaged build that's the executable inside the .app bundle, not the
// dev `bun`/compiled path. macOS keys the ACL entry to the binary at this
// path; if the signed binary lives elsewhere, re-create the item from the
// signed binary so the ACL points at it. `process.execPath` is correct for
// the compiled standalone daemon (the Mach-O the menu bar app launches).
//
// `security` is invoked by ABSOLUTE PATH (/usr/bin/security), never via
// PATH, so a poisoned launch environment can't substitute a fake `security`
// to intercept the wrap key.
//
// Failure modes (all fail-closed):
//   - `security` CLI missing at /usr/bin/security      → throw
//   - Keychain locked / user denied access             → throw
//   - Stored key isn't a 32-byte base64 string         → throw
//
// On any throw, the daemon must refuse to start. The session would be
// unreadable without the key.

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const SERVICE = "ai.sunriselabs.whatsapp-mcp";
const ACCOUNT = "session-wrap-key";

/** Absolute path to the system `security` CLI. Invoked by absolute path
 *  (never via PATH) so a poisoned launch env can't shim a fake binary in
 *  to intercept the wrap key (#82). */
const SECURITY_BIN = "/usr/bin/security";

/** Absolute path of the running daemon executable, used for the Keychain
 *  `-T` ACL so only this binary can read the wrap key without a prompt.
 *  `process.execPath` resolves to the compiled standalone daemon Mach-O the
 *  menu bar app launches. See PRODUCTION NOTE above. */
function daemonBinaryPath(): string {
  return process.execPath;
}

/** Generate 32 random bytes via Node's crypto module. */
function generateKey(): Buffer {
  const { randomBytes } = require("node:crypto") as typeof import("node:crypto");
  return randomBytes(32);
}

interface SpawnSyncResult {
  exitCode: number;
  stdout: Uint8Array;
  stderr: Uint8Array;
}

/** Default runner: invoke /usr/bin/security by absolute path (#82). */
function spawnSecurity(args: string[], stdin?: string): SpawnSyncResult {
  const proc = Bun.spawnSync({
    cmd: [SECURITY_BIN, ...args],
    stdin: stdin != null ? new TextEncoder().encode(stdin) : "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: proc.exitCode ?? -1,
    stdout: proc.stdout ?? new Uint8Array(),
    stderr: proc.stderr ?? new Uint8Array(),
  };
}

// Test seam: lets tests capture the exact argv passed to `security` (and the
// absolute SECURITY_BIN / -T ACL wiring) without mutating a real Keychain.
// Production never sets this — it stays the real spawn against /usr/bin/security.
type SecurityRunner = (bin: string, args: string[], stdin?: string) => SpawnSyncResult;
let _securityRunner: SecurityRunner | null = null;

/** @internal test seam. Pass null to restore the real runner. */
export function _setSecurityRunnerForTesting(runner: SecurityRunner | null): void {
  _securityRunner = runner;
}

function runSecurity(args: string[], stdin?: string): SpawnSyncResult {
  if (_securityRunner != null) return _securityRunner(SECURITY_BIN, args, stdin);
  return spawnSecurity(args, stdin);
}

// ── One-time ACL migration (#82) ────────────────────────────────────────────
//
// An item CREATED BEFORE the `-T` fix carries the old permissive (empty) ACL.
// `getOrCreateMasterKey` short-circuits on `hasKey()` and returns the stored
// key WITHOUT ever calling `writeKey`, so a legacy item is never rewritten and
// keeps its account-hijack-prone ACL forever. We can't read an item's ACL via
// the `security` CLI, so we track "this item has been re-written with `-T`"
// with a one-time marker file under the daemon home. On first run after this
// fix lands, if the item exists AND the marker is absent, we delete+re-add the
// SAME key bytes WITH the `-T` ACL (via writeKey), then verify the round-trip.
// Fail-closed: if the re-add or verification fails, we throw rather than leave
// a permissive item silently in place.

/** Absolute path of the one-time ACL-migration marker. Under the daemon home
 *  (WHATSAPP_MCP_HOME-aware) so a fresh install / different test home re-runs.
 *  Overridable for tests via the seam below. */
function migrationMarkerPath(): string {
  if (_migrationMarkerOverride != null) return _migrationMarkerOverride;
  const home = process.env.WHATSAPP_MCP_HOME ?? join(homedir(), ".whatsapp-mcp");
  return join(home, ".keychain-acl-migrated-v1");
}

let _migrationMarkerOverride: string | null = null;

/** @internal test seam — point the migration marker at a tmp path (or null to
 *  restore the real WHATSAPP_MCP_HOME-derived path). */
export function _setMigrationMarkerPathForTesting(path: string | null): void {
  _migrationMarkerOverride = path;
}

function migrationDone(): boolean {
  try {
    return existsSync(migrationMarkerPath());
  } catch {
    return false;
  }
}

function markMigrationDone(): void {
  const p = migrationMarkerPath();
  try {
    mkdirSync(join(p, ".."), { recursive: true, mode: 0o700 });
  } catch { /* dir may already exist */ }
  // Best-effort marker write. If it fails, the migration simply re-runs next
  // start — idempotent (writeKey re-applies the same key + `-T`), so a missing
  // marker only costs an extra delete+add, it never weakens the ACL.
  try {
    writeFileSync(p, `migrated ${new Date().toISOString()}\n`, { mode: 0o600 });
  } catch { /* non-fatal */ }
}

/**
 * One-time ACL migration for a pre-`-T` keychain item (#82). Idempotent and
 * fail-closed. Returns true if a migration was performed, false if it was a
 * no-op (already migrated / no item / test-key seam).
 *
 * Steps when an item exists and the marker is absent:
 *   1. Read the stored key bytes (throws if missing/malformed → fail-closed).
 *   2. writeKey(key): deletes the old item, re-adds it WITH the `-T` ACL.
 *   3. Read back and confirm the key round-trips; throw on mismatch.
 *   4. Write the marker so subsequent starts skip the migration.
 */
export function migrateKeychainAcl(): boolean {
  // Test-key seam short-circuits the Keychain entirely (see getOrCreateMasterKey).
  const testKey = process.env.WHATSAPP_MCP_TEST_KEY;
  if (testKey != null && testKey.length > 0) return false;

  if (migrationDone()) return false;
  if (!hasKey()) return false; // nothing to migrate (fresh install)

  // Read the existing key (fail-closed: a malformed/denied item throws here).
  const existing = readKey();
  // Re-add WITH the -T ACL (writeKey deletes then re-adds with -T + absolute path).
  writeKey(existing);
  // Verify the round-trip so we never declare success on a silently-failed re-add.
  const verify = readKey();
  if (!verify.equals(existing)) {
    throw new Error("Keychain ACL migration round-trip mismatch — refusing to start");
  }
  markMigrationDone();
  return true;
}

/** True if a key is already stored. */
function hasKey(): boolean {
  const r = runSecurity(["find-generic-password", "-s", SERVICE, "-a", ACCOUNT]);
  return r.exitCode === 0;
}

/** Read the stored key, decoding from base64. Throws if missing/malformed. */
function readKey(): Buffer {
  // `-w` flag prints just the secret payload to stdout.
  const r = runSecurity(["find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"]);
  if (r.exitCode !== 0) {
    const err = new TextDecoder().decode(r.stderr).trim();
    throw new Error(`Keychain read failed (${r.exitCode}): ${err || "user denied or item missing"}`);
  }
  const b64 = new TextDecoder().decode(r.stdout).trim();
  let raw: Buffer;
  try {
    raw = Buffer.from(b64, "base64");
  } catch {
    throw new Error("Keychain item is not valid base64");
  }
  if (raw.byteLength !== 32) {
    throw new Error(`Keychain key has wrong length: expected 32 bytes, got ${raw.byteLength}`);
  }
  return raw;
}

/**
 * Write a key, binding an explicit `-T` ACL to the running daemon binary so
 * only that executable can read it without a prompt (#82).
 *
 * `add-generic-password -U` (update-in-place) does NOT change an existing
 * item's ACL — so a pre-existing no-`-T` item would keep its permissive
 * empty ACL. To guarantee the ACL is (re)applied, when an item already
 * exists we delete it first, then add fresh with `-T`. The wrap key itself
 * is unchanged across this delete+add (we pass the same bytes), so the
 * session stays decryptable; the only effect is the tightened ACL.
 *
 * Passing exactly one `-T <path>` whitelists ONLY that binary; no other app
 * is on the trusted-application list.
 */
function writeKey(key: Buffer): void {
  const b64 = key.toString("base64");
  // Drop any pre-existing item so the fresh add applies the -T ACL. Exit 44
  // = "item not found", which is the expected/fine case on first run.
  const del = runSecurity(["delete-generic-password", "-s", SERVICE, "-a", ACCOUNT]);
  if (del.exitCode !== 0 && del.exitCode !== 44) {
    const err = new TextDecoder().decode(del.stderr).trim();
    throw new Error(`Keychain pre-write delete failed (${del.exitCode}): ${err || "unknown error"}`);
  }
  // -s: service; -a: account; -w: password value;
  // -T <path>: trusted application (this daemon binary) — the ACL.
  const r = runSecurity([
    "add-generic-password",
    "-s", SERVICE,
    "-a", ACCOUNT,
    "-w", b64,
    "-T", daemonBinaryPath(),
  ]);
  if (r.exitCode !== 0) {
    const err = new TextDecoder().decode(r.stderr).trim();
    throw new Error(`Keychain write failed (${r.exitCode}): ${err || "unknown error"}`);
  }
}

/**
 * Get-or-create the master key. Idempotent across daemon restarts.
 *
 * Test seam: set WHATSAPP_MCP_TEST_KEY=<base64 32 bytes> to skip the
 * Keychain entirely. Tests run in environments where `security` may not
 * be available (CI Linux) and we don't want to hit a real Keychain.
 */
export function getOrCreateMasterKey(): Buffer {
  const testKey = process.env.WHATSAPP_MCP_TEST_KEY;
  if (testKey != null && testKey.length > 0) {
    const buf = Buffer.from(testKey, "base64");
    if (buf.byteLength !== 32) {
      throw new Error(`WHATSAPP_MCP_TEST_KEY must decode to 32 bytes, got ${buf.byteLength}`);
    }
    return buf;
  }

  if (hasKey()) {
    // One-time ACL migration (#82): a pre-`-T` item is rewritten WITH the
    // scoped ACL before we return it. Fail-closed (throws) if it can't
    // complete, rather than silently serving a permissive item.
    migrateKeychainAcl();
    return readKey();
  }
  const fresh = generateKey();
  writeKey(fresh);
  // Read back to confirm round-trip and surface any silent failures early.
  const verify = readKey();
  if (!verify.equals(fresh)) {
    throw new Error("Keychain round-trip mismatch — refusing to start");
  }
  return fresh;
}

/** Delete the master key. Called from the `unlinkAndReset` recovery path
 *  alongside `deleteSession()` so a re-pair generates fresh ciphertext. */
export function deleteMasterKey(): void {
  if (process.env.WHATSAPP_MCP_TEST_KEY != null) return;
  const r = runSecurity(["delete-generic-password", "-s", SERVICE, "-a", ACCOUNT]);
  // Exit 44 = item not found, which is fine.
  if (r.exitCode !== 0 && r.exitCode !== 44) {
    const err = new TextDecoder().decode(r.stderr).trim();
    throw new Error(`Keychain delete failed (${r.exitCode}): ${err}`);
  }
}
