import { existsSync, readFileSync, statSync, lstatSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

// Contacts sidecar — written by the Swift menu bar app via
// `CNContactStore`, read by this MCP binary. This is the primary source
// of truth for contact-name resolution because:
//
//   1. CNContactStore sees data Messages.app sees, including iCloud
//      contacts that are CloudKit-only and don't always write to the
//      local AddressBook SQLite files.
//
//   2. NSContacts permission has a proper native consent dialog
//      (CNContactStore.requestAccess), unlike Full Disk Access which
//      requires the user to manually drag the binary into a System
//      Settings pane.
//
//   3. Decoupling means a rebuilt MCP binary doesn't lose contact
//      resolution along with its TCC state — the menu bar app's
//      NSContacts grant survives independently.
//
// The MCP binary still has a direct-SQLite fallback (see load() in
// chatdb/contacts.ts) for users who haven't installed the menu bar app.

// Cached on first access. The TS side does NOT poll — Claude Desktop
// spawns a fresh MCP child often enough that the cache invalidates
// naturally. If we ever need live-refresh behavior, do an mtime check
// here at a 60-second interval rather than re-reading on every call.
function defaultSidecarPath(): string {
  return join(homedir(), ".messages-mcp", "contacts-cache.json");
}

// On-disk schema. Bumping `version` is a breaking change requiring a
// matching update in the Swift exporter — keep the constant in sync
// with `kContactsCacheSchemaVersion` over there.
export const CONTACTS_CACHE_SCHEMA_VERSION = 1;

// Valid permission_status values. The Swift exporter writes "granted",
// "denied", "restricted", "not_determined" (see ContactsExporter.swift's
// statusString switch) — "unknown" is a legacy fallback we still accept
// to avoid breaking sidecars written by older menubar builds. Anything
// outside this set causes readContactsSidecar to reject the whole file.
const VALID_PERMISSION_STATUSES = new Set([
  "granted",
  "denied",
  "restricted",
  "not_determined",
  "unknown",
]);

export interface ContactsSidecar {
  version: number;
  generated_at: string;          // ISO-8601
  source: string;                // "menubar-cnContactStore", etc.
  permission_status: "granted" | "denied" | "restricted" | "not_determined" | "unknown";
  count: number;
  // Canonical handle → display name. Keys are already canonicalized
  // by the writer using the same rule as canonHandle in
  // chatdb/contacts.ts (last-10-digits for phones, lowercase for emails).
  handles: Record<string, string>;
}

export interface ContactsSidecarDiagnostic {
  path: string;
  exists: boolean;
  read_status: "ok" | "missing" | "stale_schema" | "parse_error" | "io_error" | "rejected";
  read_error?: string;
  mtime_iso?: string;
  age_seconds?: number;
  generated_at?: string;
  source?: string;
  permission_status?: string;
  count?: number;
}

// Reject sidecars where the keys / values look like an attacker stashed
// prompt-injection bait in a contact name. The Swift writer canonicalizes
// keys to last-10-digit phones or lowercase emails; values come from
// CNContact display names which are user-controlled but realistic names
// don't contain control characters or newlines.
//
// HANDLE_KEY_RE allows Unicode letters / numbers (\p{L}\p{N}) so emails
// with non-ASCII localparts (e.g. `héctor@example.com`) survive — the
// Swift writer's `.lowercased()` doesn't strip accents, so rejecting
// them would silently lock out users with international contacts.
// PR 11 review finding #6.
const HANDLE_KEY_RE = /^[\p{L}\p{N}@.+_-]{1,256}$/u;
const HANDLE_VALUE_BAD_CHARS_RE = /[\x00-\x1f\x7f]/u;

// Keys that match the regex but would surprise consumers iterating via
// `Object.keys` / `for..in` because they collide with JS object-shape
// machinery. JSON.parse in modern V8/Bun does NOT pollute the prototype
// chain via these names (they become own properties instead), but a
// returned object that has `__proto__: "<string>"` as an own property
// still breaks any consumer that does `handles.__proto__` expecting
// the prototype. The Swift writer canonicalizes phones to digit strings
// and emails to lowercased local@domain — neither produces these names
// legitimately. PR 11 review finding #5.
const BANNED_KEY_NAMES = new Set(["__proto__", "constructor", "prototype"]);

function validateHandleEntry(key: unknown, value: unknown): { ok: true } | { ok: false; reason: string } {
  if (typeof key !== "string") return { ok: false, reason: `handle key is not a string (${typeof key})` };
  if (BANNED_KEY_NAMES.has(key)) {
    return { ok: false, reason: `handle key uses reserved name: ${JSON.stringify(key)}` };
  }
  if (!HANDLE_KEY_RE.test(key)) {
    return { ok: false, reason: `handle key fails canonical-form check: ${JSON.stringify(key.slice(0, 40))}` };
  }
  if (typeof value !== "string") return { ok: false, reason: `handle value for key ${JSON.stringify(key)} is not a string` };
  if (value.length === 0 || value.length > 200) {
    return { ok: false, reason: `handle value for key ${JSON.stringify(key)} has invalid length ${value.length}` };
  }
  if (HANDLE_VALUE_BAD_CHARS_RE.test(value)) {
    return { ok: false, reason: `handle value for key ${JSON.stringify(key)} contains control chars / newline` };
  }
  return { ok: true };
}

// Returns null on success, or a reason string explaining why the sidecar
// should be ignored. Mirrors the symlink / ownership guards in
// src/storage/drafts.ts so a local-UID attacker can't redirect the
// sidecar to a file they wrote.
function lstatSafe(path: string): string | null {
  const parent = dirname(path);
  const getuid = (process as NodeJS.Process & { getuid?: () => number }).getuid;
  const myUid = typeof getuid === "function" ? getuid.call(process) : null;

  // Parent directory must exist as a real directory (not a symlink),
  // owned by the calling UID, and not group-/other-writable. The
  // file-level 0600 check is moot if any local user can `rename()` a
  // sidecar into the parent. PR 11 review finding #3.
  // lstatSync on a missing path throws — handle that explicitly so the
  // "no sidecar" case stays distinguishable from "rejected sidecar".
  try {
    const parentStat = lstatSync(parent);
    if (parentStat.isSymbolicLink()) {
      return `parent directory is a symlink: ${parent}`;
    }
    if (!parentStat.isDirectory()) {
      return `parent is not a directory: ${parent}`;
    }
    if (myUid !== null && parentStat.uid !== myUid) {
      return `parent directory ${parent} owned by uid ${parentStat.uid} but process runs as uid ${myUid}`;
    }
    // Reject if group OR other has write permission. We tolerate read
    // because $TMPDIR on macOS is 0755-via-symlink and the contacts
    // dir under it is sometimes provisioned that way — but write would
    // be the actual privilege boundary.
    const parentMode = parentStat.mode & 0o777;
    if (parentMode & 0o022) {
      return `parent directory ${parent} has world-/group-writable mode 0${parentMode.toString(8)}`;
    }
  } catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code === "ENOENT") return null; // no parent → no sidecar; caller falls back
    return `parent lstat failed: ${(e as Error).message}`;
  }

  // The sidecar file itself.
  let fileStat;
  try {
    fileStat = lstatSync(path);
  } catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code === "ENOENT") return null;
    return `sidecar lstat failed: ${(e as Error).message}`;
  }
  if (fileStat.isSymbolicLink()) {
    return `sidecar is a symlink: ${path}`;
  }
  if (!fileStat.isFile()) {
    return `sidecar is not a regular file: ${path}`;
  }
  // Mode broader than 0600 means another local user could replace contents
  // mid-read. The Swift writer setAttributes-es to 0600 on every write.
  const mode = fileStat.mode & 0o777;
  if (mode & 0o077) {
    return `sidecar has overly permissive mode 0${mode.toString(8)}; refusing (expected 0600)`;
  }
  // Ownership check — only run when process has a uid (not on Windows;
  // bun on macOS exposes getuid via the node:process shim).
  if (myUid !== null && fileStat.uid !== myUid) {
    return `sidecar owned by uid ${fileStat.uid} but process runs as uid ${myUid}`;
  }
  return null;
}

// One-shot read of the sidecar. Returns null when the file doesn't
// exist, is unreadable, or fails ANY of our trust checks (lstat /
// schema / per-entry validation). Callers (the loader in chatdb/
// contacts.ts) fall back to SQLite on null.
//
// Validation failures emit a stderr breadcrumb so the cause is
// debuggable via the MCP server log; a silent fallback would
// indistinguishably look like "no menubar app installed".
export function readContactsSidecar(): ContactsSidecar | null {
  const path = contactsCachePath();
  if (!existsSync(path)) return null;

  const refusal = lstatSafe(path);
  if (refusal) {
    process.stderr.write(`[contacts] sidecar rejected: ${refusal}\n`);
    return null;
  }

  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (e) {
    process.stderr.write(`[contacts] sidecar read failed: ${(e as Error).message}\n`);
    return null;
  }

  let parsed: Partial<ContactsSidecar>;
  try {
    parsed = JSON.parse(raw) as Partial<ContactsSidecar>;
  } catch {
    // Atomic-write race or bad JSON. No breadcrumb here — this case
    // fires routinely under contention and would spam the log.
    return null;
  }

  if (
    typeof parsed.version !== "number" ||
    typeof parsed.handles !== "object" ||
    parsed.handles == null ||
    Array.isArray(parsed.handles)
  ) {
    process.stderr.write(`[contacts] sidecar rejected: missing version or handles field\n`);
    return null;
  }
  if (parsed.version !== CONTACTS_CACHE_SCHEMA_VERSION) {
    // Stale schema is expected during upgrades; no breadcrumb.
    return null;
  }
  if (typeof parsed.permission_status !== "string" || !VALID_PERMISSION_STATUSES.has(parsed.permission_status)) {
    process.stderr.write(
      `[contacts] sidecar rejected: invalid permission_status ${JSON.stringify(parsed.permission_status)}\n`
    );
    return null;
  }

  // Per-entry validation. Reject the whole sidecar on any failure so
  // the user gets a single clean failure rather than a quietly-
  // partial dataset.
  for (const [k, v] of Object.entries(parsed.handles)) {
    const r = validateHandleEntry(k, v);
    if (!r.ok) {
      process.stderr.write(`[contacts] sidecar rejected: ${r.reason}\n`);
      return null;
    }
  }

  return {
    version: parsed.version,
    generated_at: parsed.generated_at ?? "",
    source: parsed.source ?? "unknown",
    permission_status: parsed.permission_status as ContactsSidecar["permission_status"],
    count: parsed.count ?? Object.keys(parsed.handles).length,
    handles: parsed.handles as Record<string, string>,
  };
}

// Diagnostic-friendly inspection without committing to a load. Used by
// the `health_check` tool to show "is the sidecar there?
// when was it written? how stale is it?"
export function getContactsSidecarDiagnostic(): ContactsSidecarDiagnostic {
  const path = contactsCachePath();
  if (!existsSync(path)) {
    return { path, exists: false, read_status: "missing" };
  }

  // Trust checks first — if these fail, the file exists but readContactsSidecar
  // will refuse it, so the diagnostic must report rejection rather than "ok".
  const refusal = lstatSafe(path);
  if (refusal) {
    return {
      path,
      exists: true,
      read_status: "rejected",
      read_error: refusal,
    };
  }

  let mtime: Date;
  try {
    mtime = statSync(path).mtime;
  } catch (e) {
    return {
      path,
      exists: true,
      read_status: "io_error",
      read_error: (e as Error).message,
    };
  }

  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (e) {
    return {
      path,
      exists: true,
      read_status: "io_error",
      read_error: (e as Error).message,
      mtime_iso: mtime.toISOString(),
      age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
    };
  }

  let parsed: Partial<ContactsSidecar>;
  try {
    parsed = JSON.parse(raw) as Partial<ContactsSidecar>;
  } catch (e) {
    return {
      path,
      exists: true,
      read_status: "parse_error",
      read_error: (e as Error).message,
      mtime_iso: mtime.toISOString(),
      age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
    };
  }

  if (
    typeof parsed.version !== "number" ||
    parsed.version !== CONTACTS_CACHE_SCHEMA_VERSION ||
    typeof parsed.handles !== "object" ||
    parsed.handles == null ||
    Array.isArray(parsed.handles)
  ) {
    return {
      path,
      exists: true,
      read_status: "stale_schema",
      read_error: `expected version ${CONTACTS_CACHE_SCHEMA_VERSION}, got ${parsed.version ?? "(missing)"}`,
      mtime_iso: mtime.toISOString(),
      age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
      generated_at: parsed.generated_at,
      source: parsed.source,
    };
  }

  // Schema-valid but content-suspicious → report rejected so the
  // health tool can surface WHY the sidecar isn't winning the load
  // race in chatdb/contacts.ts:load().
  if (typeof parsed.permission_status !== "string" || !VALID_PERMISSION_STATUSES.has(parsed.permission_status)) {
    return {
      path,
      exists: true,
      read_status: "rejected",
      read_error: `invalid permission_status: ${JSON.stringify(parsed.permission_status)}`,
      mtime_iso: mtime.toISOString(),
      age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
      generated_at: parsed.generated_at,
      source: parsed.source,
    };
  }
  for (const [k, v] of Object.entries(parsed.handles)) {
    const r = validateHandleEntry(k, v);
    if (!r.ok) {
      return {
        path,
        exists: true,
        read_status: "rejected",
        read_error: r.reason,
        mtime_iso: mtime.toISOString(),
        age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
        generated_at: parsed.generated_at,
        source: parsed.source,
        permission_status: parsed.permission_status,
      };
    }
  }

  return {
    path,
    exists: true,
    read_status: "ok",
    mtime_iso: mtime.toISOString(),
    age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
    generated_at: parsed.generated_at,
    source: parsed.source,
    permission_status: parsed.permission_status,
    count: parsed.count ?? Object.keys(parsed.handles).length,
  };
}

// Test seam. Override the sidecar path so tests can use a tmp dir.
let pathOverride: string | null = null;
export function _setSidecarPathForTesting(p: string | null): void {
  pathOverride = p;
}

// Resolved sidecar path — honors test override. Exposed for the
// diagnostic path printout.
export function contactsCachePath(): string {
  return pathOverride ?? defaultSidecarPath();
}
