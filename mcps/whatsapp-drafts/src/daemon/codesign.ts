// Shellout wrappers around macOS `codesign` for verifying binaries and
// extracting their designated requirement.
//
// Used in two places:
//   1. peer-auth.ts asks: "is the daemon's OWN binary signed for
//      production?" — drives refuseDevModeInProduction()
//   2. peer-auth.ts asks: "is THIS peer's binary signed and does its
//      designated requirement match our allowlist?"
//
// macOS `codesign` is preinstalled. Output formats:
//   - `codesign --verify --strict --deep <path>` → exit 0 if signed and
//     valid, non-zero with a message on stderr otherwise.
//   - `codesign -d --requirements - <path>` → prints
//     `designated => <requirement text>` (or `(none)` if no DR).

const CODESIGN = "/usr/bin/codesign";

interface SpawnResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

function spawn(args: string[]): SpawnResult {
  const p = Bun.spawnSync({
    cmd: [CODESIGN, ...args],
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: p.exitCode ?? -1,
    stdout: new TextDecoder().decode(p.stdout ?? new Uint8Array()),
    stderr: new TextDecoder().decode(p.stderr ?? new Uint8Array()),
  };
}

export interface VerifyResult {
  /** True iff codesign --verify exits 0. */
  valid: boolean;
  /** Designated requirement string (the `=>` payload), if extractable. */
  requirement: string | null;
  /** Stderr message if invalid; null on success. */
  error: string | null;
}

/**
 * Run `codesign --verify --strict --deep` AND extract the designated
 * requirement. Returns a structured result; never throws on signature
 * failure (returns valid:false instead). Throws only on infrastructure
 * failure (codesign not on disk).
 */
export function verifyBinary(path: string): VerifyResult {
  // Step 1: signature verification.
  const verify = spawn(["--verify", "--strict", "--deep", path]);
  if (verify.exitCode !== 0) {
    return {
      valid: false,
      requirement: null,
      error: verify.stderr.trim() || `codesign --verify exited ${verify.exitCode}`,
    };
  }

  // Step 2: extract designated requirement. stdout is empty on success;
  // the requirement text lands on stderr in the form
  //   `designated => identifier "x" and anchor apple generic and ...`
  // — but with `--requirements -` flag the requirement is printed to
  // stdout. The exit code distinguishes "no requirement" (still 0) from
  // codesign infra error (non-zero).
  const dr = spawn(["-d", "--requirements", "-", path]);
  if (dr.exitCode !== 0) {
    return {
      valid: true,
      requirement: null,
      error: null,
    };
  }
  const requirement = parseRequirement(dr.stdout + dr.stderr);
  return { valid: true, requirement, error: null };
}

function parseRequirement(out: string): string | null {
  // codesign emits a line like:
  //   designated => identifier "com.foo" and anchor apple generic and ...
  // OR
  //   designated => (none)
  const m = out.match(/designated\s*=>\s*(.+)/);
  if (m == null) return null;
  const text = m[1]!.trim();
  if (text === "(none)") return null;
  return text;
}

/**
 * Verify and check the requirement matches an allowlist.
 *
 * The allowlist is exact-string-match on the requirement. Wildcards
 * are intentionally NOT supported (defense against bypass via lenient
 * matching).
 *
 * NOTE: as of v0.3.0 the daemon's peer-auth uses the runtime
 * self-identity check below (matchesSelfIdentity) instead of a baked-in
 * allowlist — the daemon and menubar ship inside the same .app bundle
 * with shared Identifier+TeamIdentifier, so the allowlist becomes
 * trivially derivable. This function is retained as scaffolding for
 * future allowlist-based peer-auth needs.
 */
export function verifyAgainstAllowlist(path: string, allowedRequirements: ReadonlyArray<string>): {
  ok: boolean;
  reason: string;
} {
  const v = verifyBinary(path);
  if (!v.valid) {
    return { ok: false, reason: `codesign --verify failed: ${v.error ?? "no detail"}` };
  }
  if (v.requirement == null) {
    return { ok: false, reason: "binary is signed but has no designated requirement" };
  }
  if (!allowedRequirements.includes(v.requirement)) {
    return { ok: false, reason: `requirement not in allowlist: ${v.requirement}` };
  }
  return { ok: true, reason: "matched allowlist" };
}

export interface BinaryIdentity {
  /** Codesign `Identifier=` line — TCC's grant-key string. */
  identifier: string | null;
  /** Codesign `TeamIdentifier=` line. Null for adhoc-signed binaries. */
  teamIdentifier: string | null;
}

export interface VerifiedIdentity {
  valid: boolean;
  error: string | null;
  identifier: string | null;
  teamIdentifier: string | null;
}

/**
 * Verify a binary AND extract its (Identifier, TeamIdentifier) in a SINGLE
 * pass, minimizing the number of `codesign` shellouts.
 *
 * Issue #79: peer-auth previously ran `codesign --verify` and then a SEPARATE
 * `codesign -dv` for the identity — two process spawns against a PID whose
 * backing image could be swapped between (or after) the calls. Folding the
 * identity extraction into the verify path removes one spawn and shrinks the
 * TOCTOU window. We still can't make `codesign` operate on a *connection*
 * rather than a *path* (that needs audit-token pinning; see peer-auth.ts), so
 * the caller pairs this with a process-start-time recheck.
 *
 * Returns valid:false (never throws) on a signature failure; throws only on
 * infra failure inside `spawn`.
 */
export function verifyAndExtractIdentity(path: string): VerifiedIdentity {
  const verify = spawn(["--verify", "--strict", "--deep", path]);
  if (verify.exitCode !== 0) {
    return {
      valid: false,
      error: verify.stderr.trim() || `codesign --verify exited ${verify.exitCode}`,
      identifier: null,
      teamIdentifier: null,
    };
  }
  // Single identity probe (was a second codesign invocation in peer-auth).
  const id = extractIdentity(path);
  return {
    valid: true,
    error: null,
    identifier: id.identifier,
    teamIdentifier: id.teamIdentifier,
  };
}

/**
 * Extract (Identifier, TeamIdentifier) from a binary's signature via
 * `codesign -dv --verbose=2`. Returns null fields when the binary
 * isn't signed or the line is missing.
 *
 * The two fields are used together: the daemon authorizes a peer iff
 * BOTH match its own. Identifier alone could theoretically be spoofed
 * by an attacker signing an adhoc binary with the same identifier;
 * pairing it with TeamIdentifier (which the attacker can't forge
 * without Apple's signing chain) closes that hole.
 */
export function extractIdentity(path: string): BinaryIdentity {
  // -dv --verbose=2 prints Identifier= and TeamIdentifier= to stderr.
  const r = spawn(["-dv", "--verbose=2", path]);
  if (r.exitCode !== 0) {
    return { identifier: null, teamIdentifier: null };
  }
  const text = r.stdout + r.stderr;
  const idMatch = text.match(/^Identifier=(.+)$/m);
  const teamMatch = text.match(/^TeamIdentifier=(.+)$/m);
  return {
    identifier: idMatch ? idMatch[1]!.trim() : null,
    // TeamIdentifier=not set ⇒ adhoc. Normalize to null.
    teamIdentifier:
      teamMatch && teamMatch[1]!.trim() !== "not set"
        ? teamMatch[1]!.trim()
        : null,
  };
}
