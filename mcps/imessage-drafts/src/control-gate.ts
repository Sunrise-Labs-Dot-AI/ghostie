// Cloud kill switch / forced-upgrade gate for the iMessage MCP send path.
//
// Issue #76: with `require_approval` off, `send_draft` fires AppleScript
// (src/imessage/send.ts) with no awareness of the operator's remote control
// channel. The menu bar app fetches a signed `control.json` from the cloud,
// VERIFIES its Ed25519 signature, and atomically writes the raw verified bytes
// (+ detached sig) under ~/.messages-mcp/. This module re-verifies those bytes
// independently inside the MCP process and refuses a send while a kill is
// active or the MCP is below the min supported version. The MCP never trusts
// the network itself — it only honors a manifest whose signature it can verify
// against the SAME embedded public key the app's Sparkle updater uses
// (SUPublicEDKey). An unsigned or tampered manifest is ignored entirely.
//
// Rollback resistance: an attacker who can write the user's home dir could
// drop an OLD (validly-signed) manifest to lift a kill that a newer manifest
// activated. We persist a sticky high-water mark (newest accepted issued_at +
// the kill_scope / min_version it carried) to ~/.messages-mcp/.control-imsg-
// state.json.
//
// Fail-SAFE UNION model (the effective block is the UNION of present + sticky,
// so the sticky may only ever keep us MORE blocked, never less):
//   - A present, validly-signed manifest that declares a KILL ALWAYS contributes
//     its block, even if its issued_at is older than the sticky mark. So a forged
//     or pre-seeded sticky (e.g. kill_scope:"none" with a huge issued_at) can
//     never SUPPRESS a real signed kill — the worst a forged sticky can do is
//     assert a false kill (a self-DoS), not lift a real one.
//   - A sticky kill PERSISTS and contributes its OWN block unless a present "none"
//     that is newer-or-equal explicitly lifts it. So an OLD, narrow-scope kill
//     replayed against this gate cannot DOWNGRADE a broader sticky kill (the
//     sticky's broader scope still blocks), and an old/low min_version cannot
//     LOWER the forced-upgrade floor (the floor is the MORE-restrictive of the
//     two). A legit lift (present "none" newer-or-equal to the sticky) still works.
// Inherent limit (documented, not solved): an attacker who can write BOTH the
// signed manifest (with an older validly-signed "none") AND the sticky file can
// still lift a kill locally. That is the same class as null-routing the update
// host in /etc/hosts — the kill switch is best-effort against honest failure and
// worms, not a determined local attacker with write access to ~/.messages-mcp.
//
// Fail behavior:
//   - no manifest file AND no sticky state → ALLOW (clean / fresh client).
//   - reads/verify throw but a sticky KILL exists → STAY BLOCKED (fail closed
//     toward the last known kill).
//   - reads/verify throw and no sticky kill → ALLOW.
//   - unsigned / signature-invalid manifest → IGNORED (never honored).

import { createPublicKey, verify } from "node:crypto";
import { existsSync, readFileSync, writeFileSync, statSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Embedded Ed25519 public key — the SAME 32-byte key as the app's Sparkle
// SUPublicEDKey. The menu bar app signs control.json with the matching private
// key (held only by the operator), so the MCP can verify the manifest offline.
const DEFAULT_PUBKEY_B64 = "AIBthhXpByRlrje9eWEBE0lE4w1/PwVJDFs6VGLqOHQ=";

// Test seam: override the embedded public key so tests can sign manifests with
// a throwaway keypair (we don't ship the real private key into the repo). NEVER
// set in production.
let pubkeyOverrideB64: string | null = null;
/** @internal test seam — override the embedded ed25519 pubkey (base64 raw). */
export function _setControlPubkeyForTesting(b64: string | null): void {
  pubkeyOverrideB64 = b64;
}

function activePubkeyB64(): string {
  return pubkeyOverrideB64 ?? DEFAULT_PUBKEY_B64;
}

// Home dir resolution mirrors src/daemon/paths.ts (MESSAGES_MCP_HOME override
// so tests don't touch the real ~/.messages-mcp).
function controlHome(): string {
  return process.env.MESSAGES_MCP_HOME ?? join(homedir(), ".messages-mcp");
}

function manifestPath(): string {
  return join(controlHome(), "control-manifest.json");
}
function sigPath(): string {
  return join(controlHome(), "control-manifest.json.sig");
}
function stickyPath(): string {
  return join(controlHome(), ".control-imsg-state.json");
}

export type KillScope = "none" | "all" | "send" | "whatsapp" | "imessage";

interface ControlManifest {
  schema: number;
  min_supported_version?: string;
  kill?: { scope?: KillScope; reason?: string };
  banner?: unknown;
  issued_at?: string;
}

interface StickyState {
  issued_at_ms: number;
  kill_scope: KillScope;
  min_version: string | null;
}

// Typed error so the send-tool can map a block to a clean refusal.
export class ControlBlockedError extends Error {
  constructor(public readonly blockReason: string) {
    super(blockReason);
    this.name = "ControlBlockedError";
  }
}

// Verify a detached Ed25519 signature over the EXACT manifest bytes using the
// embedded public key. Returns false (never throws) on any verification or
// key-construction failure — an unverifiable manifest must be treated as
// untrusted, not honored.
function verifyManifestSignature(manifestBytes: Buffer, sigB64: string): boolean {
  try {
    const raw = Buffer.from(activePubkeyB64(), "base64");
    if (raw.length !== 32) return false;
    // Wrap the raw 32-byte ed25519 key into SPKI DER (RFC 8410 prefix).
    const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]);
    const key = createPublicKey({ key: spki, format: "der", type: "spki" });
    return verify(null, manifestBytes, key, Buffer.from(sigB64.trim(), "base64"));
  } catch {
    return false;
  }
}

// Numeric semver compare: returns negative if a < b, 0 if equal, positive if
// a > b. Tolerant of pre-release/build suffixes (compares the numeric core
// only). Non-numeric components are treated as 0.
function compareSemver(a: string, b: string): number {
  const core = (s: string) => s.trim().replace(/^v/, "").split(/[-+]/)[0] ?? "";
  const pa = core(a).split(".").map((x) => Number.parseInt(x, 10) || 0);
  const pb = core(b).split(".").map((x) => Number.parseInt(x, 10) || 0);
  for (let i = 0; i < 3; i++) {
    const da = pa[i] ?? 0;
    const db = pb[i] ?? 0;
    if (da !== db) return da - db;
  }
  return 0;
}

// Best-effort read of this MCP's own version from package.json. Returns null
// when unreadable (in which case the min-version gate is skipped — we won't
// block on a comparison we can't make).
function currentMcpVersion(): string | null {
  try {
    // package.json sits at the package root; this file is src/control-gate.ts.
    const pkgPath = join(import.meta.dir, "..", "package.json");
    const parsed = JSON.parse(readFileSync(pkgPath, "utf8")) as { version?: unknown };
    return typeof parsed.version === "string" ? parsed.version : null;
  } catch {
    return null;
  }
}

function readSticky(): StickyState | null {
  try {
    const parsed = JSON.parse(readFileSync(stickyPath(), "utf8")) as Partial<StickyState>;
    if (typeof parsed.issued_at_ms !== "number" || !Number.isFinite(parsed.issued_at_ms)) return null;
    const scope = parsed.kill_scope;
    const validScope: KillScope =
      scope === "all" || scope === "send" || scope === "whatsapp" || scope === "imessage" || scope === "none"
        ? scope
        : "none";
    return {
      issued_at_ms: parsed.issued_at_ms,
      kill_scope: validScope,
      min_version: typeof parsed.min_version === "string" ? parsed.min_version : null,
    };
  } catch {
    return null;
  }
}

function writeSticky(state: StickyState): void {
  try {
    const dir = controlHome();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileSync(stickyPath(), JSON.stringify(state), { mode: 0o600 });
  } catch {
    // Best-effort: a failed sticky write degrades rollback resistance but must
    // not crash the send path. The effective state for THIS call already
    // reflects the freshly-accepted manifest.
  }
}

export interface EffectiveControlState {
  kill_scope: KillScope;
  min_version: string | null;
  reason: string | null;
  source: "manifest" | "sticky" | "none";
}

type Platform = "imessage" | "whatsapp";

// Does this kill scope block a send on `platform`? "all" and "send" block BOTH
// platforms; "imessage"/"whatsapp" block their own; "none" blocks nothing.
function killBlocks(scope: KillScope, platform: Platform): boolean {
  if (scope === "all" || scope === "send") return true;
  return scope === platform;
}

// The more-restrictive (greater) of two semver floors. null means "no floor";
// any concrete floor outranks null.
function maxFloor(a: string | null, b: string | null): string | null {
  if (a == null) return b;
  if (b == null) return a;
  return compareSemver(a, b) >= 0 ? a : b;
}

// Combine two kill scopes into a single representative scope for display/tests.
// Preserves a single non-"none" scope as-is; equal scopes return that scope;
// "all" if either is "all" OR the two are different single-platform scopes;
// "send" if "send" combines with a single platform.
function combineScopes(a: KillScope, b: KillScope): KillScope {
  if (a === b) return a;
  if (a === "none") return b;
  if (b === "none") return a;
  if (a === "all" || b === "all") return "all";
  // Neither is "none"/"all" and they differ. Cases: send+single, or two
  // different single platforms.
  const single = (s: KillScope) => s === "imessage" || s === "whatsapp";
  if (a === "send" || b === "send") {
    // "send" combined with a single platform → "send" (send already covers both).
    return "send";
  }
  // Two different single-platform scopes (imessage + whatsapp) → "all".
  if (single(a) && single(b)) return "all";
  return "all";
}

// Verified+parsed present manifest, or null when absent/sig-invalid/unparseable/
// undated. `presentMs` is a finite issued_at epoch-ms.
interface PresentManifest {
  scope: KillScope;
  minVersion: string | null;
  reason: string | null;
  presentMs: number;
}

// Read + verify the on-disk manifest. Returns null when absent, signature-
// invalid, unparseable, or carrying an unparseable/undated issued_at.
function readPresent(): PresentManifest | null {
  let manifestBytes: Buffer | null = null;
  let sigB64: string | null = null;
  try {
    if (existsSync(manifestPath()) && existsSync(sigPath())) {
      manifestBytes = readFileSync(manifestPath());
      sigB64 = readFileSync(sigPath(), "utf8");
    }
  } catch {
    return null;
  }
  if (manifestBytes == null || sigB64 == null) return null;
  if (!verifyManifestSignature(manifestBytes, sigB64)) return null;

  let manifest: ControlManifest | null = null;
  try {
    manifest = JSON.parse(manifestBytes.toString("utf8")) as ControlManifest;
  } catch {
    return null;
  }
  const presentMs = manifest.issued_at != null ? Date.parse(manifest.issued_at) : NaN;
  if (!Number.isFinite(presentMs)) return null;

  return {
    scope: manifest.kill?.scope ?? "none",
    minVersion: typeof manifest.min_supported_version === "string" ? manifest.min_supported_version : null,
    reason: manifest.kill?.reason ?? null,
    presentMs,
  };
}

// The reconciled effective state under the fail-safe UNION model. `present` and
// `sticky` are both read once; `present` is ratcheted into the sticky mark when
// it is newer-or-equal (or there is no sticky yet).
interface Reconciled {
  present: PresentManifest | null;
  sticky: StickyState | null;
  presentLifts: boolean;
}

// Read present + sticky, ratchet the high-water mark, and compute presentLifts.
// Ratchet: if present != null AND (sticky == null OR presentMs >= sticky.issued_at_ms),
// write the sticky to mirror the present manifest. presentLifts holds when a
// present "none" is newer-or-equal to the sticky (so it explicitly clears it).
function reconcile(): Reconciled {
  const present = readPresent();
  const sticky = readSticky();

  if (present != null && (sticky == null || present.presentMs >= sticky.issued_at_ms)) {
    writeSticky({
      issued_at_ms: present.presentMs,
      kill_scope: present.scope,
      min_version: present.minVersion,
    });
  }

  const presentLifts =
    present != null &&
    present.scope === "none" &&
    (sticky == null || present.presentMs >= sticky.issued_at_ms);

  return { present, sticky, presentLifts };
}

// Is a send on `platform` blocked under the UNION model? A present kill always
// contributes its block; a sticky kill contributes its block unless a present
// "none" (newer-or-equal) lifts it.
function blockedOn(r: Reconciled, platform: Platform): boolean {
  const presentBlocks = r.present != null && killBlocks(r.present.scope, platform);
  const stickyBlocks =
    r.sticky != null && killBlocks(r.sticky.kill_scope, platform) && !r.presentLifts;
  return presentBlocks || stickyBlocks;
}

// The forced-upgrade floor under the UNION model: the MORE-restrictive of the
// present floor and the sticky floor (the sticky floor is dropped only when a
// present "none" lifts it).
function effectiveFloor(r: Reconciled): string | null {
  let floor: string | null = null;
  if (r.present != null && r.present.minVersion != null) floor = r.present.minVersion;
  if (r.sticky != null && r.sticky.min_version != null && !r.presentLifts) {
    floor = maxFloor(floor, r.sticky.min_version);
  }
  return floor;
}

// Resolve the effective control state for display/tests. The kill_scope is a
// single representative scope: combineScopes(present.scope if present, the
// sticky kill_scope if a sticky exists AND a present "none" hasn't lifted it).
// min_version is the effective floor.
export function effectiveControlState(): EffectiveControlState {
  const r = reconcile();

  const presentScope: KillScope = r.present != null ? r.present.scope : "none";
  const stickyScope: KillScope =
    r.sticky != null && !r.presentLifts ? r.sticky.kill_scope : "none";
  const kill_scope = combineScopes(presentScope, stickyScope);
  const min_version = effectiveFloor(r);

  let source: EffectiveControlState["source"];
  if (r.present == null && r.sticky == null) source = "none";
  else if (r.present != null && (presentScope !== "none" || r.presentLifts)) source = "manifest";
  else if (stickyScope !== "none" || min_version != null) source = "sticky";
  else source = r.present != null ? "manifest" : "none";

  let reason: string | null = null;
  if (kill_scope !== "none") {
    const presentKillBlocks = r.present != null && r.present.scope !== "none";
    reason = presentKillBlocks ? r.present!.reason : "kill active (sticky high-water mark)";
  }

  return { kill_scope, min_version, reason, source };
}

// Does this kill scope block an iMessage send? (Retained for the read-error
// fallback path.)
function killBlocksIMessage(scope: KillScope): boolean {
  return killBlocks(scope, "imessage");
}

/**
 * Throw ControlBlockedError if the effective control state forbids an iMessage
 * send: an active kill (present OR sticky high-water mark) whose scope covers
 * iMessage, OR a min_supported_version floor the running MCP is below. Allows
 * the send (returns) otherwise.
 *
 * UNION model: a present valid KILL always contributes its block, so a forged
 * or older sticky can never SUPPRESS a real signed kill. A sticky kill persists
 * unless a present "none" newer-or-equal lifts it, so an old narrow-scope kill
 * replay can't DOWNGRADE a broader sticky kill and an old/low min_version can't
 * LOWER the floor.
 *
 * Fail-closed toward a known kill: if resolving the state itself throws but a
 * sticky kill exists, we re-derive from sticky and stay blocked; if no sticky
 * kill exists we allow (a fresh client with no remote state must not be wedged
 * by a transient read error).
 */
export function assertSendAllowed(platform: "imessage"): void {
  let r: Reconciled;
  try {
    r = reconcile();
  } catch {
    // Resolution itself failed — fall back to the sticky high-water mark so a
    // last-known kill keeps blocking, but a clean client still sends.
    const sticky = readSticky();
    if (sticky != null && killBlocksIMessage(sticky.kill_scope)) {
      throw new ControlBlockedError(
        `send blocked: a remote kill switch is active (scope '${sticky.kill_scope}') and the control state could not be re-read; failing closed.`
      );
    }
    return;
  }

  if (blockedOn(r, "imessage")) {
    // Prefer a present kill's operator-supplied reason; else note the sticky mark.
    const presentKillBlocks = r.present != null && killBlocks(r.present.scope, "imessage");
    const why = presentKillBlocks
      ? (r.present!.reason ? ` Reason: ${r.present!.reason}.` : "")
      : ` Reason: kill active (sticky high-water mark).`;
    const scope = presentKillBlocks ? r.present!.scope : (r.sticky?.kill_scope ?? "all");
    throw new ControlBlockedError(
      `send blocked: a remote kill switch is active (scope '${scope}').${why} ` +
      `This is set by the operator to halt sends; it cannot be overridden locally.`
    );
  }

  const floor = effectiveFloor(r);
  if (floor != null) {
    const cur = currentMcpVersion();
    // Skip the gate entirely if we can't read our own version — never block on
    // an incomparable value.
    if (cur != null && compareSemver(cur, floor) < 0) {
      throw new ControlBlockedError(
        `send blocked: this build (v${cur}) is below the minimum supported version (v${floor}) ` +
        `required by the operator. Update Messages for AI to continue sending.`
      );
    }
  }

  // platform is reserved for a future per-platform split; iMessage today.
  void platform;
}
