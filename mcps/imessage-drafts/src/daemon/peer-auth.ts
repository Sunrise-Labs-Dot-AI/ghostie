// Peer authentication for the iMessage daemon's Unix-socket JSON-RPC server.
// Adapted from mcps/whatsapp-drafts/src/daemon/peer-auth.ts (only the dev
// env-var names + transport strings differ; the self-identity logic is
// identical).
//
// Threat model: ~/.messages-mcp/daemon.sock is reachable by ANY local
// process running as the user. Without peer-auth, any local process could
// `socat - UNIX-CONNECT:$HOME/.messages-mcp/daemon.sock` and read the user's
// entire message history through the daemon's chat.db access.
//
// Production check (runtime self-identity match):
//   1. At startup, cache THIS daemon's codesign Identifier + TeamIdentifier.
//   2. On every peer connect: get peer PID (LOCAL_PEERPID) → snapshot the
//      peer's process START TIME → resolve to binary path (proc_pidpath) →
//      codesign --verify + extract identity in ONE pass → re-snapshot the
//      start time → authorize iff Identifier+Team match AND the start time
//      didn't change (no PID reuse mid-auth).
//
// Why self-identity instead of an allowlist: the daemon and the MCP both
// ship inside Messages for AI.app, signed with `--identifier
// com.sunriselabs.messages-for-ai` and the same Developer Team. So "anyone
// matching me" is exactly the right allowlist — zero maintenance.
//
// Why Identifier+Team and not just Identifier: an attacker can adhoc-sign a
// binary with any Identifier; TeamIdentifier requires Apple's Developer ID
// chain, which they can't forge.
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
// Dev mode (MESSAGES_MCP_DEV=1): bypasses peer-auth, logs WARNING. A signed
// production daemon refuses to honor the override (refuseDevModeInProduction).
// Round 2 (issue #79): the production signal is derived from the REAL codesign
// result and DOMINATES — MESSAGES_MCP_ASSUME_PRODUCTION=0 can no longer relax a
// genuinely-signed binary into dev mode. The env var may only escalate an
// UNSIGNED binary to "production" (to exercise the refusal path in tests).

import type { Socket } from "node:net";
import { statSync } from "node:fs";

import { extractIdentity, verifyBinary, verifyAndExtractIdentity, type VerifiedIdentity } from "./codesign.ts";
import { getPeerPid, pidToPath, getPeerStartTime, socketFd } from "./peer-pid.ts";

// Read dynamically (not a module-const snapshot) so tests can flip
// MESSAGES_MCP_DEV without import-order gymnastics. In production the env is
// fixed at launch, so this is equivalent to the old snapshot.
function devModeRequested(): boolean {
  return process.env.MESSAGES_MCP_DEV === "1";
}

let selfIdentityCache: { identifier: string | null; teamIdentifier: string | null } | null = null;
const MAX_PEER_IDENTITY_CACHE_ENTRIES = 64;
let peerIdentityCache = new Map<string, VerifiedIdentity>();
let peerIdentityCacheHits = 0;
let peerIdentityCacheMisses = 0;

function selfIdentity(): { identifier: string | null; teamIdentifier: string | null } {
  if (selfIdentityCache != null) return selfIdentityCache;
  // process.execPath (not argv[0]): under `bun build --compile` argv[0] is
  // the literal "bun", but execPath is the running binary's absolute path.
  const ownPath = process.execPath;
  if (ownPath == null || ownPath === "") {
    selfIdentityCache = { identifier: null, teamIdentifier: null };
    return selfIdentityCache;
  }
  selfIdentityCache = extractIdentity(ownPath);
  return selfIdentityCache;
}

/** @internal test seam — reset the memoized self-identity. */
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
  return devModeRequested();
}

// The REAL codesign-derived signal: is the running binary a genuinely
// Developer-ID-signed production Mach-O? Computed from the binary itself, with
// NO env-var input — so it cannot be relaxed by an attacker-writable env. A
// test seam lets the test suite exercise the unsigned (dev) path without a real
// production signature; it is the ONLY way to fake this, and it defaults off.
let signedForProductionOverride: boolean | null = null;
/** @internal test seam — force the real-signature signal (unsigned-binary path). */
export function _setSignedForProductionForTesting(v: boolean | null): void {
  signedForProductionOverride = v;
}

function isGenuinelySignedForProduction(): boolean {
  if (signedForProductionOverride != null) return signedForProductionOverride;

  const ownPath = process.execPath;
  if (ownPath == null || ownPath === "") return false;

  // A dev binary runs under the `bun`/`node`/`deno` interpreter (execPath is
  // the interpreter, not a signed app Mach-O) — never "production".
  const basename = ownPath.split("/").pop() ?? "";
  if (basename === "bun" || basename === "node" || basename === "deno") return false;

  try {
    const v = verifyBinary(ownPath);
    return v.valid && v.requirement != null;
  } catch {
    return false;
  }
}

// Issue #79 (round 2): the production signal must be dominated by the REAL
// codesign result, NOT by MESSAGES_MCP_ASSUME_PRODUCTION. Previously
// `ASSUME_PRODUCTION=0` short-circuited to `false` even for a genuinely-signed
// daemon, letting an attacker pair it with MESSAGES_MCP_DEV=1 to disable
// peer-auth on a signed binary. Now:
//   - If the binary is GENUINELY signed for production, it is treated as
//     production REGARDLESS of ASSUME_PRODUCTION — the env cannot relax a real
//     signature.
//   - ASSUME_PRODUCTION=1 may only ESCALATE: force production for an unsigned
//     binary (used to test the refusal path).
//   - ASSUME_PRODUCTION=0 may only RELAX an UNSIGNED binary (the dev default),
//     never a signed one.
function isDaemonSignedForProduction(): boolean {
  // Real signature wins outright — no env can talk it out of production.
  if (isGenuinelySignedForProduction()) return true;

  // Unsigned binary: the env var may escalate to production (test the refusal),
  // or explicitly relax (the dev default). Anything else → not production.
  if (process.env.MESSAGES_MCP_ASSUME_PRODUCTION === "1") return true;
  return false;
}

/**
 * Refuses dev mode in a signed production binary. Returns {allow:true} if
 * startup should proceed; {allow:false, reason} if the daemon must exit.
 */
export function refuseDevModeInProduction(): { allow: boolean; reason?: string } {
  if (!devModeRequested()) return { allow: true };
  if (isDaemonSignedForProduction()) {
    return {
      allow: false,
      reason: "MESSAGES_MCP_DEV is set but daemon binary is signed for production. Refusing to start.",
    };
  }
  return { allow: true };
}

/**
 * Verify an incoming Unix-socket connection's peer. Dev mode short-circuits
 * to authorized=true with a WARNING.
 */
export async function authenticatePeer(sock: Socket): Promise<PeerAuthResult> {
  // A genuinely-signed production daemon never honors dev mode, even if
  // MESSAGES_MCP_DEV=1 is set: the bypass is only for unsigned dev binaries.
  // refuseDevModeInProduction() already exits the daemon at startup in that
  // case; this is belt-and-suspenders so a stray code path can't reach the
  // bypass on a signed binary.
  if (devModeRequested() && !isDaemonSignedForProduction()) {
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
