// Cloud kill switch / forced-upgrade gate for the MCP send path (issue #76).
//
// The menu bar app fetches a signed `control.json` from messagesfor.ai every
// 15 minutes, verifies its Ed25519 signature against the bundle's
// SUPublicEDKey, and — once verified — writes the RAW manifest bytes + the
// detached signature atomically to the SHARED ~/.messages-mcp dir:
//   - control-manifest.json      = raw verified control.json bytes
//   - control-manifest.json.sig  = base64 detached Ed25519 sig over those bytes
//
// The MCP's send path (send_whatsapp_draft) consults this gate BEFORE
// approving/sending. The Swift SendGate already blocks the menu-bar
// hold-to-fire path; this closes the OTHER send path — the MCP tool calling
// the daemon directly when require_approval is off (or any caller who reaches
// the tool). We RE-VERIFY the signature here rather than trusting the file:
// the file is same-UID-writable, so an attacker (or injected agent) could drop
// a forged manifest that LIFTS a kill. By checking the Ed25519 signature
// against the embedded public key, only the holder of the private key can
// author an honored manifest. Fail-closed: an unsigned/invalid/tampered file
// is never honored; a verified KILL is sticky and survives a later rollback or
// a read error.
//
// Fail-SAFE UNION model: the effective block is the UNION of the present
// manifest and the sticky high-water mark. A present valid KILL ALWAYS
// contributes its block (so a forged/older sticky can never SUPPRESS a real
// signed kill). A sticky kill PERSISTS and contributes its OWN block unless a
// present "none" newer-or-equal explicitly lifts it — so an OLD narrow-scope
// kill replayed here can't DOWNGRADE a broader sticky kill, and an old/low
// min_version can't LOWER the forced-upgrade floor (the floor is the
// MORE-restrictive of present + sticky). A legit lift (present "none"
// newer-or-equal to the sticky) still works.
//
// IMPORTANT: the manifest lives under ~/.messages-mcp (the SHARED dir), NOT
// ~/.whatsapp-mcp. One manifest covers both transports; the menu bar writes it
// once. The sticky-state sidecar (.control-wa-state.json) is WhatsApp-specific
// (anti-rollback anchor for THIS gate) and also lives in the shared dir so the
// path is stable regardless of WHATSAPP_MCP_HOME overrides.

import { createPublicKey, verify, type KeyObject } from "node:crypto";
import { existsSync, readFileSync, writeFileSync, mkdirSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";

// The app's SUPublicEDKey (same Ed25519 key Sparkle uses for update signing).
// base64 of the raw 32-byte Ed25519 public key.
const PUBLIC_KEY_B64 = "AIBthhXpByRlrje9eWEBE0lE4w1/PwVJDFs6VGLqOHQ=";

// DER SPKI prefix for an Ed25519 public key: SEQUENCE { AlgorithmIdentifier {
// 1.3.101.112 }, BIT STRING (raw 32-byte key) }. Concatenated with the raw key
// it yields a parseable SPKI DER that node:crypto accepts. (Verified working.)
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

type KillScope = "none" | "all" | "send" | "whatsapp" | "imessage";

interface ControlManifest {
  schema: number;
  min_supported_version?: string | null;
  kill?: { scope: KillScope; reason?: string | null } | null;
  banner?: unknown;
  issued_at: string;
}

/** Sticky anti-rollback state persisted across MCP invocations. */
interface StickyState {
  issued_at_ms: number;
  kill_scope: KillScope;
  min_version: string | null;
}

/** Thrown when a send is refused by the control gate. Mapped to a clear send
 *  refusal by the tool layer (do NOT send). */
export class ControlBlockedError extends Error {
  constructor(public readonly reason: string) {
    super(reason);
    this.name = "ControlBlockedError";
  }
}

// Test seam: redirect the shared ~/.messages-mcp dir without touching $HOME.
// Production never sets this.
let testDirOverride: string | null = null;

/** @internal test seam. Pass null to restore the real shared dir. */
export function _setControlDirForTesting(dir: string | null): void {
  testDirOverride = dir;
}

function sharedDir(): string {
  return testDirOverride ?? join(homedir(), ".messages-mcp");
}

function manifestPath(): string {
  return join(sharedDir(), "control-manifest.json");
}
function sigPath(): string {
  return join(sharedDir(), "control-manifest.json.sig");
}
function stickyPath(): string {
  return join(sharedDir(), ".control-wa-state.json");
}

// Test seam: lets tests substitute a keypair whose PRIVATE half they hold so
// they can mint valid signatures. Production never sets this — it stays the
// hardcoded SUPublicEDKey. A `null` raw key restores production.
let testPublicKeyRaw: Buffer | null = null;

/** @internal test seam. Override the verifying public key with a raw 32-byte
 *  Ed25519 key (so tests can sign with the matching private key). Pass null to
 *  restore the production SUPublicEDKey. */
export function _setPublicKeyForTesting(rawKey: Buffer | null): void {
  testPublicKeyRaw = rawKey;
  _pubKey = null; // force re-derive on next use
}

let _pubKey: KeyObject | null = null;
function publicKey(): KeyObject {
  if (_pubKey != null) return _pubKey;
  const raw = testPublicKeyRaw ?? Buffer.from(PUBLIC_KEY_B64, "base64");
  const spki = Buffer.concat([SPKI_PREFIX, raw]);
  _pubKey = createPublicKey({ key: spki, format: "der", type: "spki" });
  return _pubKey;
}

/** Verify a detached base64 signature over the exact manifest bytes. */
function verifyManifest(manifestBytes: Buffer, sigB64: string): boolean {
  const trimmed = sigB64.trim();
  if (trimmed.length === 0) return false;
  let sig: Buffer;
  try {
    sig = Buffer.from(trimmed, "base64");
  } catch {
    return false;
  }
  if (sig.byteLength !== 64) return false; // Ed25519 sigs are 64 bytes.
  try {
    return verify(null, manifestBytes, publicKey(), sig);
  } catch {
    return false;
  }
}

/** Parse an ISO-8601 issued_at to epoch ms. NaN on unparseable. */
function issuedAtMs(iso: string): number {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : NaN;
}

function readSticky(): StickyState | null {
  const p = stickyPath();
  if (!existsSync(p)) return null;
  try {
    const parsed = JSON.parse(readFileSync(p, "utf8")) as Partial<StickyState>;
    if (typeof parsed.issued_at_ms !== "number" || !Number.isFinite(parsed.issued_at_ms)) {
      return null;
    }
    const scope = parsed.kill_scope;
    const validScopes: KillScope[] = ["none", "all", "send", "whatsapp", "imessage"];
    return {
      issued_at_ms: parsed.issued_at_ms,
      kill_scope: validScopes.includes(scope as KillScope) ? (scope as KillScope) : "none",
      min_version: typeof parsed.min_version === "string" ? parsed.min_version : null,
    };
  } catch {
    return null;
  }
}

function writeSticky(s: StickyState): void {
  const p = stickyPath();
  try {
    mkdirSync(dirname(p), { recursive: true, mode: 0o700 });
    const tmp = `${p}.tmp-${process.pid}`;
    writeFileSync(tmp, JSON.stringify(s), { mode: 0o600 });
    // Atomic replace so a concurrent read never sees a partial write.
    renameSync(tmp, p);
  } catch {
    // Best-effort: enforcement still proceeds off the in-memory value this call
    // computed. A failure to persist only weakens NEXT call's rollback anchor.
  }
}

type Platform = "whatsapp" | "imessage";

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
  return versionLess(a, b) ? b : a;
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
  const mPath = manifestPath();
  const sPath = sigPath();
  if (!existsSync(mPath) || !existsSync(sPath)) return null;

  let manifestBytes: Buffer;
  let sigB64: string;
  try {
    manifestBytes = readFileSync(mPath);
    sigB64 = readFileSync(sPath, "utf8");
  } catch {
    return null;
  }
  if (!verifyManifest(manifestBytes, sigB64)) return null;

  let manifest: ControlManifest;
  try {
    manifest = JSON.parse(manifestBytes.toString("utf8")) as ControlManifest;
  } catch {
    return null;
  }
  const presentMs = issuedAtMs(manifest.issued_at);
  if (Number.isNaN(presentMs)) return null;

  return {
    scope: manifest.kill?.scope ?? "none",
    minVersion:
      typeof manifest.min_supported_version === "string" && manifest.min_supported_version.length > 0
        ? manifest.min_supported_version
        : null,
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

/** Read THIS MCP's version from package.json. Best-effort: null if unreadable
 *  (a missing/garbled package.json must NOT brick sends — version-floor
 *  enforcement is simply skipped). */
function currentMcpVersion(): string | null {
  // package.json sits two levels up from src/ (src/control-gate.ts →
  // ../../package.json). import.meta.dir is the dir of THIS file.
  const candidates = [
    join(import.meta.dir, "..", "package.json"),
  ];
  for (const p of candidates) {
    try {
      if (!existsSync(p)) continue;
      const pkg = JSON.parse(readFileSync(p, "utf8")) as { version?: unknown };
      if (typeof pkg.version === "string" && pkg.version.length > 0) return pkg.version;
    } catch {
      // try next / give up
    }
  }
  return null;
}

/**
 * Numeric semver compare of dotted-numeric versions. Non-numeric / missing
 * components are treated as 0 (so "0.6" and "0.6.0" compare equal). Returns
 * true when `a < b`.
 */
function versionLess(a: string, b: string): boolean {
  const pa = a.split(".").map((s) => parseInt(s.replace(/[^0-9]/g, ""), 10) || 0);
  const pb = b.split(".").map((s) => parseInt(s.replace(/[^0-9]/g, ""), 10) || 0);
  const n = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x < y) return true;
    if (x > y) return false;
  }
  return false;
}

/**
 * Assert that a send for `platform` is allowed by the cloud control gate.
 * Throws ControlBlockedError(reason) when blocked; returns normally when allowed.
 *
 * Blocks when EITHER (UNION model):
 *   - a present OR sticky kill blocks `platform` (a present kill always
 *     contributes its block; a sticky kill persists unless a present "none"
 *     newer-or-equal lifts it), OR
 *   - the effective min_supported_version floor (the more-restrictive of present
 *     + sticky) is above the current MCP version (best-effort; skipped if the
 *     MCP version is unreadable).
 *
 * `platform` is "whatsapp" for this MCP. The check intentionally honors `all`
 * and `send` too so a fleet-wide kill blocks WhatsApp sends as well.
 *
 * UNION rationale: a present valid KILL always contributes its block, so a
 * forged or older sticky can never SUPPRESS a real signed kill. A sticky kill
 * persists unless a present "none" newer-or-equal lifts it, so an old
 * narrow-scope kill replay can't DOWNGRADE a broader sticky kill, and an old/low
 * min_version can't LOWER the floor.
 */
export function assertSendAllowed(platform: "whatsapp" | "imessage"): void {
  const r = reconcile();

  if (blockedOn(r, platform)) {
    const presentKillBlocks = r.present != null && killBlocks(r.present.scope, platform);
    const scope = presentKillBlocks ? r.present!.scope : (r.sticky?.kill_scope ?? "all");
    const reason = presentKillBlocks
      ? (r.present!.reason ?? null)
      : "kill active (sticky high-water mark)";
    const why = reason && reason.length > 0 ? `: ${reason}` : "";
    throw new ControlBlockedError(
      `send blocked by remote kill switch (scope=${scope})${why}`,
    );
  }

  const floor = effectiveFloor(r);
  if (floor != null) {
    const mine = currentMcpVersion();
    // Skip the floor when we can't read our own version (fail-open on that
    // axis only — the kill switch above still applies).
    if (mine != null && versionLess(mine, floor)) {
      throw new ControlBlockedError(
        `send blocked: this version (${mine}) is below the minimum supported version ` +
        `(${floor}). Update Messages for AI to keep sending.`,
      );
    }
  }
}
