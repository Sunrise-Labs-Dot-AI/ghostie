// Peer authentication for the Unix-socket JSON-RPC server.
//
// Threat model: ~/.whatsapp-mcp/daemon.sock is reachable by ANY local
// process running as the user (npm postinstall scripts, dev MCP servers,
// browser extensions). Without peer-auth, the 5s minimum-staged-age would
// be the entire send security model and `socat - UNIX-CONNECT:$HOME/...`
// from a malicious local process bypasses every guardrail.
//
// v0.3.0+ production check (runtime self-identity match):
//   1. At daemon startup, extract THIS daemon's codesign Identifier= +
//      TeamIdentifier= and cache them.
//   2. On every peer connect:
//      a. Get peer PID via SO_PEERCRED / LOCAL_PEERPID (FFI getsockopt)
//      b. Resolve PID → binary path via proc_pidpath (FFI libproc)
//      c. Run codesign --verify --strict --deep <path>
//      d. Extract peer's Identifier + TeamIdentifier
//      e. Authorize iff BOTH match the daemon's own
//
// Why self-identity instead of an allowlist:
// the daemon and menubar both ship inside Messages for AI.app, signed
// at build time with `--identifier com.sunriselabs.messages-for-ai`
// (same as the bundle's CFBundleIdentifier so one FDA grant covers
// every inner Mach-O). They inherit the team's signing certificate's
// TeamIdentifier. So "anyone matching me" is exactly the right
// allowlist — no maintenance burden, no risk of forgetting to update
// a baked-in PEER_ALLOWED_REQUIREMENTS string at release time, no
// rebuild-required when a future inner binary joins the bundle.
//
// Why Identifier+Team and not just Identifier:
// an attacker can adhoc-sign a binary with any Identifier they like.
// TeamIdentifier requires Apple's Developer ID signing chain, which
// they can't forge. Requiring both raises the bar from "name match" to
// "name match AND came from our Developer team".
//
// PID-reuse TOCTOU (issue #79): LOCAL_PEERPID returns a *PID*, not a handle to
// the connected process. Between reading the PID and running codesign, the
// peer can exit and its PID be recycled onto a legitimately-signed binary, so
// codesign would verify a DIFFERENT process than the one holding the socket.
// Two mitigations here:
//   (a) A SINGLE codesign pass (verifyAndExtractIdentity) instead of the old
//       verify-then-extract double-spawn — one fewer window, one fewer race.
//   (b) A process-start-time recheck: we capture the peer's kernel start time
//       (proc_pidinfo / pbi_start_tvsec) right after reading the PID and again
//       after the codesign pass; if it changed, the PID was recycled and we
//       reject. A recycled PID always gets a fresh start time, so a swap can't
//       slip through unnoticed.
// This is a MITIGATION, not the complete fix. The complete fix is to bind auth
// to the CONNECTION, not a PID: read the peer's audit token via
// getsockopt(LOCAL_PEERTOKEN) and validate the signing identity directly off
// that token (SecCodeCopyGuestWithAttributes + kSecGuestAttributeAudit), which
// is immune to PID reuse because the token names a specific process
// incarnation. That path needs Security.framework FFI from Bun and is tracked
// as a follow-up (issue #79).
//
// Dev mode (WHATSAPP_MCP_DEV=1): bypasses peer-auth, logs WARNING.
//   - Production safeguard: if THIS daemon's own binary is code-signed
//     AND WHATSAPP_MCP_DEV is set, refuse to start. Guarantees a signed
//     production binary never honors the dev override.

import type { Socket } from "node:net";
import { statSync } from "node:fs";

import { extractIdentity, verifyBinary, verifyAndExtractIdentity, type VerifiedIdentity } from "./codesign.ts";
import { getPeerPid, pidToPath, getPeerStartTime, socketFd } from "./peer-pid.ts";

// DEV_MODE is read at call time (not captured once at module load) so the
// safeguard logic is deterministic under test regardless of import order in a
// shared Bun process (#79). `isDevMode()` and the auth/safeguard paths both go
// through devModeActive().
function devModeActive(): boolean {
  return process.env.WHATSAPP_MCP_DEV === "1";
}

/**
 * The daemon's own (Identifier, TeamIdentifier) tuple, derived at
 * startup from `process.argv[0]`. Memoized on first read.
 *
 * Both nulls in development (adhoc signature has no team), which is OK
 * because dev mode short-circuits peer-auth anyway.
 */
let selfIdentityCache: { identifier: string | null; teamIdentifier: string | null } | null = null;
const MAX_PEER_IDENTITY_CACHE_ENTRIES = 64;
let peerIdentityCache = new Map<string, VerifiedIdentity>();
let peerIdentityCacheHits = 0;
let peerIdentityCacheMisses = 0;

function selfIdentity(): { identifier: string | null; teamIdentifier: string | null } {
  if (selfIdentityCache != null) return selfIdentityCache;
  // process.execPath, not process.argv[0]: under `bun build --compile`,
  // argv[0] is the runtime name (literal "bun"), not the executable path.
  // execPath is the absolute path of the running binary, which codesign
  // can actually inspect.
  const ownPath = process.execPath;
  if (ownPath == null || ownPath === "") {
    selfIdentityCache = { identifier: null, teamIdentifier: null };
    return selfIdentityCache;
  }
  selfIdentityCache = extractIdentity(ownPath);
  return selfIdentityCache;
}

/**
 * @internal — test seam. Resets the memoized self-identity so tests
 * can drive {selfIdentity} from a fixture path.
 */
export function _resetSelfIdentityCacheForTesting(): void {
  selfIdentityCache = null;
}

function peerIdentityCacheKey(path: string): string | null {
  try {
    const st = statSync(path);
    return [path, st.dev, st.ino, st.size, st.mtimeMs, st.ctimeMs].join(":");
  } catch {
    return null;
  }
}

function rememberPeerIdentity(key: string, v: VerifiedIdentity): void {
  if (peerIdentityCache.has(key)) peerIdentityCache.delete(key);
  peerIdentityCache.set(key, v);
  while (peerIdentityCache.size > MAX_PEER_IDENTITY_CACHE_ENTRIES) {
    const oldest = peerIdentityCache.keys().next().value;
    if (oldest == null) break;
    peerIdentityCache.delete(oldest);
  }
}

function verifyAndExtractPeerIdentity(path: string): VerifiedIdentity {
  const key = peerIdentityCacheKey(path);
  if (key != null) {
    const cached = peerIdentityCache.get(key);
    if (cached != null) {
      peerIdentityCacheHits += 1;
      return cached;
    }
  }

  peerIdentityCacheMisses += 1;
  const v = verifyAndExtractIdentity(path);
  if (key != null) rememberPeerIdentity(key, v);
  return v;
}

/** @internal test seam — reset the peer-identity verdict cache. */
export function _resetPeerIdentityCacheForTesting(): void {
  peerIdentityCache = new Map();
  peerIdentityCacheHits = 0;
  peerIdentityCacheMisses = 0;
}

/** @internal test seam — exercise peer identity caching without a socket. */
export function _verifyPeerIdentityForTesting(path: string): VerifiedIdentity {
  return verifyAndExtractPeerIdentity(path);
}

/** @internal test seam — observe cache behavior without shelling out in assertions. */
export function _peerIdentityCacheStatsForTesting(): { size: number; hits: number; misses: number } {
  return {
    size: peerIdentityCache.size,
    hits: peerIdentityCacheHits,
    misses: peerIdentityCacheMisses,
  };
}

export interface PeerAuthResult {
  authorized: boolean;
  reason?: string;
  identity?: string;
}

export function isDevMode(): boolean {
  return devModeActive();
}

/**
 * Returns true iff we're running as a compiled, production-signed daemon
 * binary (not under `bun run` / `node` interpretation).
 *
 * Detection:
 *   1. argv[0]'s basename must NOT be "bun"/"node" — those are
 *      interpreter mode where argv[0] is the runtime, not us.
 *   2. The binary must have a designated requirement under codesign.
 *      Ad-hoc signatures (the default for `bun build --compile` output)
 *      don't get one, so they read as non-production.
 */
// Test seam (issue #79): inject the REAL signedness result so tests can drive
// the safeguard logic without an actual signed binary. Production never sets
// this — it falls through to the live codesign probe. `true` models a genuinely
// production-signed binary; `false` models a genuinely UNSIGNED one.
let _realSignednessOverride: boolean | null = null;

/** @internal test seam. null restores the live codesign probe. */
export function _setRealSignednessForTesting(signed: boolean | null): void {
  _realSignednessOverride = signed;
}

/**
 * The LIVE, env-independent determination of whether THIS daemon binary is
 * genuinely code-signed for production. This is the source of truth that the
 * env override (issue #79) must NOT be able to weaken.
 */
function isBinaryGenuinelySigned(): boolean {
  if (_realSignednessOverride != null) return _realSignednessOverride;

  // process.execPath is the absolute path to the running binary; under
  // `bun build --compile` process.argv[0] is just "bun" (the runtime name)
  // and would fail the codesign lookup.
  const ownPath = process.execPath;
  if (ownPath == null || ownPath === "") return false;

  // Skip interpreter-mode invocations (running under `bun src/daemon/index.ts`
  // rather than as a compiled binary).
  const basename = ownPath.split("/").pop() ?? "";
  if (basename === "bun" || basename === "node" || basename === "deno") return false;

  try {
    const v = verifyBinary(ownPath);
    // Ad-hoc / dev-only signatures don't have a designated requirement.
    return v.valid && v.requirement != null;
  } catch {
    return false;
  }
}

/**
 * Returns true iff the daemon must be treated as production (and therefore
 * refuse dev mode).
 *
 * Issue #79 (round 2): the env override `WHATSAPP_MCP_ASSUME_PRODUCTION` could
 * previously force this to FALSE even for a genuinely-signed binary — letting an
 * attacker who can set the env disable peer-auth on a real production daemon by
 * exporting `WHATSAPP_MCP_ASSUME_PRODUCTION=0` (or relying on its absence) plus
 * `WHATSAPP_MCP_DEV=1`. Fix: the REAL codesign result wins. A genuinely-signed
 * binary is ALWAYS production regardless of the env. The override may only
 * RELAX — and only for a genuinely UNSIGNED binary, which is the dev/test case:
 *   - genuinely signed        → true   (env cannot flip this off)
 *   - unsigned + ASSUME="1"   → true   (test asserts the safeguard fires)
 *   - unsigned + ASSUME="0"   → false  (explicit dev opt-out, unsigned only)
 *   - unsigned + (unset)      → false  (normal dev/interpreter run)
 */
function isDaemonSignedForProduction(): boolean {
  // The REAL signedness is authoritative and cannot be overridden DOWN.
  if (isBinaryGenuinelySigned()) return true;

  // Unsigned binary: the env override may relax (or assert) production. This is
  // the ONLY path the override is honored on — a signed binary already returned
  // true above.
  if (process.env.WHATSAPP_MCP_ASSUME_PRODUCTION === "1") return true;
  return false;
}

/**
 * Refuses dev mode in a signed production binary.
 *
 * Returns {allow:true} if startup should proceed; {allow:false, reason}
 * if the daemon must exit. The exit happens at the caller (daemon/index.ts)
 * so this stays a pure predicate for testing.
 */
export function refuseDevModeInProduction(): { allow: boolean; reason?: string } {
  if (!devModeActive()) return { allow: true };
  if (isDaemonSignedForProduction()) {
    return {
      allow: false,
      reason: "WHATSAPP_MCP_DEV is set but daemon binary is signed for production. Refusing to start.",
    };
  }
  return { allow: true };
}

/**
 * Verify an incoming Unix-socket connection's peer.
 *
 * Dev mode: returns authorized=true and logs a WARNING.
 * Prod mode:
 *   - get peer PID via getsockopt (LOCAL_PEERPID)
 *   - snapshot the peer's process START TIME (proc_pidinfo)
 *   - resolve PID → binary path via proc_pidpath
 *   - codesign --verify + extract identity in ONE pass
 *   - peer's (Identifier, TeamIdentifier) must equal the daemon's own
 *   - re-snapshot the start time; reject if it changed (PID reused mid-auth)
 *   - any failure → authorized=false with explicit reason
 */
export async function authenticatePeer(sock: Socket): Promise<PeerAuthResult> {
  if (devModeActive()) {
    process.stderr.write("WARNING: dev mode active — peer-auth bypassed\n");
    return { authorized: true, identity: "dev-mode" };
  }

  const fd = socketFd(sock);
  if (fd == null) {
    return {
      authorized: false,
      reason: "could not obtain peer socket fd (Bun internals may have changed; report to maintainers)",
    };
  }
  const pid = getPeerPid(fd);
  if (pid == null) {
    return { authorized: false, reason: "getsockopt(LOCAL_PEERPID) failed" };
  }

  // Snapshot the peer's start time BEFORE we resolve/verify the binary, so we
  // can detect a PID recycled during the (slow, shellout-bearing) codesign
  // pass. A failure to read it is fatal in production — we can't prove the PID
  // is the one we'll re-check, so we refuse rather than fall back to a weaker
  // check. (issue #79)
  const startBefore = getPeerStartTime(pid);
  if (startBefore == null) {
    return { authorized: false, reason: `proc_pidinfo(${pid}) start-time read failed` };
  }

  const path = pidToPath(pid);
  if (path == null) {
    return { authorized: false, reason: `proc_pidpath(${pid}) failed` };
  }

  const mine = selfIdentity();
  if (mine.identifier == null || mine.teamIdentifier == null) {
    return {
      authorized: false,
      reason: "daemon's own identity is missing (Identifier or TeamIdentifier). The daemon must be Developer-ID signed in production.",
    };
  }

  // Cached codesign verdict: the peer binary's path+file metadata is stable
  // across repeated short-lived RPC sockets from the same MCP process, so we
  // pay the codesign shellouts once and reuse the result until the executable
  // changes on disk. The PID start-time recheck below still runs every connect.
  const v = verifyAndExtractPeerIdentity(path);
  if (!v.valid) {
    return {
      authorized: false,
      reason: `peer ${pid} at ${path}: codesign --verify failed: ${v.error ?? "no detail"}`,
    };
  }
  if (v.identifier !== mine.identifier) {
    return {
      authorized: false,
      reason: `peer Identifier mismatch: got '${v.identifier ?? "<none>"}', expected '${mine.identifier}'`,
    };
  }
  if (v.teamIdentifier !== mine.teamIdentifier) {
    return {
      authorized: false,
      reason: `peer TeamIdentifier mismatch: got '${v.teamIdentifier ?? "<none>"}', expected '${mine.teamIdentifier}'`,
    };
  }

  // Re-read the start time AFTER the codesign pass. If the PID was recycled
  // mid-auth (peer exited, kernel handed its PID to a different, legitimately-
  // signed process that the codesign check then "passed"), the start time will
  // differ and we reject. This closes the TOCTOU window between
  // LOCAL_PEERPID/proc_pidpath and codesign as far as a PID-based check can.
  const startAfter = getPeerStartTime(pid);
  if (startAfter == null) {
    return { authorized: false, reason: `proc_pidinfo(${pid}) start-time recheck failed (peer may have exited mid-auth)` };
  }
  if (startAfter !== startBefore) {
    return {
      authorized: false,
      reason: `peer ${pid} start time changed during auth (${startBefore} → ${startAfter}); PID was recycled mid-authentication — rejecting`,
    };
  }

  return {
    authorized: true,
    identity: `pid:${pid} start:${startAfter} id:${mine.identifier} team:${mine.teamIdentifier}`,
  };
}
