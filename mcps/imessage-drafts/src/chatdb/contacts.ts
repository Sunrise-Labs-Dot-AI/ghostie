// Resolve a chat.db handle.id (phone like "+14155551234" or email) to a human
// display name from the macOS Contacts database. We avoid AppleScript (slow,
// requires automation entitlement) and read the local AddressBook SQLite
// directly. It's the same TCC-protected zone as chat.db, so any process that
// has Full Disk Access for chat.db also has it for AddressBook.
//
// All contacts are bulk-loaded into memory on first use — for a typical Mac
// AddressBook (~500–5000 records) this is <100ms and avoids the leading-%
// LIKE on `ZABCDPHONENUMBER` that made per-handle resolution slow at scale.

import { Database } from "bun:sqlite";
import { homedir } from "node:os";
import { readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { readContactsSidecar } from "../storage/contacts-cache.ts";
import { canonHandle } from "./canon.ts";

let loaded = false;
let handleToName = new Map<string, string>(); // canonicalized handle -> name
let nameIndex: { lower_name: string; handles: string[] }[] = []; // for substring search

// Return EVERY AddressBook database we can find. On a multi-account Mac
// (iCloud Contacts + Google + Exchange + local "On My Mac"), each source
// stores its contacts in a separate Sources/{uuid}/AddressBook-v22.abcddb
// file. The previous version of this function returned only the first
// match, which routinely missed iCloud contacts on machines where the
// local source happened to be enumerated first.
//
// We also include the top-level AddressBook-v22.abcddb when present — it
// historically held the consolidated DB before macOS split into per-source
// files, and some users still have a populated copy there.
//
// IMPORTANT: the Sources-scan try/catch is intentionally separate from the
// outer guard. readdirSync(sourcesRoot) raises EPERM when TCC hasn't yet
// granted access to that specific sub-path (even when FDA is granted for
// the top-level AddressBook dir). Catching the inner error lets us fall
// through to the top-level path rather than short-circuiting to [].
function findAddressBookDbs(): string[] {
  const out: string[] = [];
  try {
    const sourcesRoot = join(homedir(), "Library", "Application Support", "AddressBook", "Sources");
    if (existsSync(sourcesRoot)) {
      try {
        for (const source of readdirSync(sourcesRoot)) {
          const candidate = join(sourcesRoot, source, "AddressBook-v22.abcddb");
          if (existsSync(candidate)) out.push(candidate);
        }
      } catch {
        // Sources scan failed (EPERM or similar) — fall through to top-level path.
      }
    }
    const top = join(homedir(), "Library", "Application Support", "AddressBook", "AddressBook-v22.abcddb");
    if (existsSync(top)) out.push(top);
  } catch {
    // Outer fs surface failed entirely — return whatever we collected so far.
  }
  return out;
}

// Single-path accessor kept for backward compat with callers that just
// want a "primary" DB to display in a diagnostic. Returns the first DB
// from `findAddressBookDbs()` or null when there are none.
function findAddressBookDb(): string | null {
  return findAddressBookDbs()[0] ?? null;
}

interface RecordRow {
  Z_PK: number;
  ZFIRSTNAME: string | null;
  ZLASTNAME: string | null;
  ZORGANIZATION: string | null;
}

interface EmailRow { ZOWNER: number; ZADDRESS: string | null }
interface PhoneRow { ZOWNER: number; ZFULLNUMBER: string | null }

function nameFromRow(row: RecordRow | undefined): string | null {
  if (!row) return null;
  const first = (row.ZFIRSTNAME ?? "").trim();
  const last = (row.ZLASTNAME ?? "").trim();
  const org = (row.ZORGANIZATION ?? "").trim();
  const name = [first, last].filter(Boolean).join(" ").trim();
  return name || org || null;
}

// Append the reverse name -> handles entries (used by findHandlesByContactName)
// for a source that only carries (canonical handle -> name) pairs, like the
// sidecar. Unlike the SQLite path, the sidecar has no per-record grouping, so
// we group by the display name string: every handle that shares a name becomes
// one nameIndex entry. findHandlesByContactName does a substring match against
// lower_name, so grouping by full name still matches first OR last name.
//
// This is the fix for the contact_filter-by-name bug: load()'s sidecar branch
// (the default path once the menu bar app is installed) returns early, so
// before this ran there, nameIndex stayed empty and contact_filter matched
// nothing by name even though resolveHandle resolved the SAME name from
// handleToName. The two name-resolution paths were inconsistent; now both the
// sidecar branch and the SQLite fallback populate nameIndex.
// Fold a contact name for diacritic- and case-insensitive substring matching.
// String.toLowerCase() does NOT strip accents, so a contact saved "José" would
// never match contact_filter="jose" (ROOT_CAUSE-contact-filter.md #2). NFD-
// decompose then drop combining marks so the stored name and the filter compare
// on the same base letters. Build-side (indexHandlesByName + the SQLite path)
// and query-side (findHandlesByContactName) MUST use this same fold or name
// matching silently breaks.
function foldName(s: string): string {
  return s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
}

function indexHandlesByName(pairs: Iterable<readonly [string, string]>): void {
  const byName = new Map<string, string[]>();
  for (const [canon, name] of pairs) {
    if (!name) continue;
    const lower = foldName(name);
    const arr = byName.get(lower) ?? [];
    arr.push(canon);
    byName.set(lower, arr);
  }
  for (const [lower_name, handles] of byName) {
    nameIndex.push({ lower_name, handles });
  }
}

// Per-DB load report, surfaced to `getAddressBookDiagnostic` so the
// menu bar / health_check tool can show "loaded 3 DBs — local + iCloud
// + Google — 412 contacts total" rather than a flat number.
interface PerDbReport {
  path: string;
  open_status: DbOpenStatus;
  open_error?: string;
  records: number;
  emails: number;
  phones: number;
  contacts_contributed: number; // new handle keys added by THIS DB
}

let lastLoadReport: PerDbReport[] = [];

function loadOneDb(path: string): PerDbReport {
  let db: Database;
  try {
    db = new Database(path, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch (err) {
    const { status, message } = classifyDbError(err);
    return {
      path,
      open_status: status,
      open_error: message,
      records: 0,
      emails: 0,
      phones: 0,
      contacts_contributed: 0,
    };
  }

  let records: RecordRow[];
  let emails: EmailRow[];
  let phones: PhoneRow[];
  try {
    records = db.query<RecordRow, []>("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD").all();
    emails = db.query<EmailRow, []>("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS").all();
    phones = db.query<PhoneRow, []>("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER").all();
  } catch (err) {
    try { db.close(); } catch { /* ignore */ }
    const { status, message } = classifyDbError(err);
    return {
      path,
      open_status: status,
      open_error: message,
      records: 0,
      emails: 0,
      phones: 0,
      contacts_contributed: 0,
    };
  }
  try { db.close(); } catch { /* ignore */ }

  const recordsByPk = new Map<number, RecordRow>();
  for (const r of records) recordsByPk.set(r.Z_PK, r);

  // Group handles per record so we can build the name->handles index in one pass.
  const handlesPerRecord = new Map<number, string[]>();
  function pushHandle(owner: number, handle: string) {
    if (!handle) return;
    const arr = handlesPerRecord.get(owner) ?? [];
    arr.push(handle);
    handlesPerRecord.set(owner, arr);
  }

  const sizeBefore = handleToName.size;
  for (const e of emails) {
    if (!e.ZADDRESS || e.ZOWNER == null) continue;
    const name = nameFromRow(recordsByPk.get(e.ZOWNER));
    if (name) handleToName.set(canonHandle(e.ZADDRESS), name);
    pushHandle(e.ZOWNER, e.ZADDRESS.toLowerCase());
  }
  for (const p of phones) {
    if (!p.ZFULLNUMBER || p.ZOWNER == null) continue;
    const name = nameFromRow(recordsByPk.get(p.ZOWNER));
    if (name) handleToName.set(canonHandle(p.ZFULLNUMBER), name);
    // Store the canonical phone tail as the lookup-form handle. We don't keep
    // the raw E.164 — chat.db will give us E.164, and we canonicalize at
    // lookup time.
    pushHandle(p.ZOWNER, canonHandle(p.ZFULLNUMBER));
  }

  for (const [pk, handles] of handlesPerRecord) {
    const name = nameFromRow(recordsByPk.get(pk));
    if (!name) continue;
    nameIndex.push({ lower_name: foldName(name), handles });
  }

  return {
    path,
    open_status: "ok",
    records: records.length,
    emails: emails.length,
    phones: phones.length,
    contacts_contributed: handleToName.size - sizeBefore,
  };
}

// Tracks which source actually populated the in-memory map on the most
// recent load(). Surfaced via getContactsLoadDiagnostic so the health
// tool can show "sidecar" vs "sidecar_granted_empty" vs "sqlite_fallback"
// vs "none". The "sidecar_granted_empty" value distinguishes the case
// where the menubar app has Contacts permission but the user has zero
// contacts (fresh Mac, iCloud not synced) — without it, that case looks
// indistinguishable from "menubar denied permission" or "no menubar app".
export type ContactsLoadSource =
  | "sidecar"
  | "sidecar_granted_empty"
  | "sqlite_fallback"
  | "none"
  | "test_seam";

let lastLoadSource: ContactsLoadSource = "none";

// SQLite bulk-load, factored out so the diagnostic can run a pure-SQLite
// scan without touching the sidecar code path. Mutates the global
// handleToName + nameIndex + lastLoadReport because loadOneDb already
// does — this is the same scan production load() runs, just isolated
// so we can call it without first consulting the sidecar.
function runSqliteBulkLoad(): void {
  const paths = findAddressBookDbs();
  const reports: PerDbReport[] = [];
  for (const path of paths) {
    reports.push(loadOneDb(path));
  }
  lastLoadReport = reports;

  // Stderr breadcrumb so the user can see what happened by tailing
  // ~/Library/Logs/Claude/mcp-server-imessage-drafts-mcp.log. Stays out of
  // stdout (which is reserved for JSON-RPC).
  if (reports.length > 0) {
    const summary = reports
      .map((r) => `${r.open_status === "ok" ? "ok" : `[${r.open_status}]`} ${r.path.replace(homedir(), "~")} (+${r.contacts_contributed})`)
      .join("; ");
    process.stderr.write(`[contacts] sqlite bulk-load: ${reports.length} db(s); ${handleToName.size} total contacts. ${summary}\n`);
  } else {
    process.stderr.write(`[contacts] sqlite bulk-load: no AddressBook databases found\n`);
  }
}

function load(): void {
  if (loaded) return;
  loaded = true; // mark loaded even on failure to avoid retry storms

  // Primary path: contacts sidecar written by the Swift menu bar app
  // via CNContactStore. This is preferred because:
  //   - It sees CloudKit-only iCloud contacts that don't appear in
  //     the local AddressBook SQLite files.
  //   - It runs under NSContacts permission (native consent dialog),
  //     not FDA — so the menu bar can be granted access without the
  //     manual drag-into-System-Settings dance.
  //   - It survives MCP-binary rebuilds, which can lose their FDA
  //     grant if the codesign identifier shifts.
  const sidecar = readContactsSidecar();
  if (sidecar && sidecar.permission_status === "granted" && Object.keys(sidecar.handles).length > 0) {
    for (const [canon, name] of Object.entries(sidecar.handles)) {
      handleToName.set(canon, name);
    }
    // Build the reverse name -> handles index too, so contact_filter by name
    // works under the sidecar path (not just the SQLite fallback). Without
    // this, findHandlesByContactName returned [] and list_threads /
    // search_messages contact_filter matched nothing by resolved name.
    indexHandlesByName(Object.entries(sidecar.handles));
    lastLoadSource = "sidecar";
    lastLoadReport = []; // sqlite path didn't run
    process.stderr.write(
      `[contacts] loaded from sidecar: ${handleToName.size} contacts ` +
      `(written ${sidecar.generated_at} by ${sidecar.source})\n`
    );
    return;
  }

  // Granted-but-empty: distinct from "denied" or "missing sidecar". The
  // menubar has permission but the user genuinely has zero contacts.
  // Without this branch the failure mode silently looks identical to
  // "FDA missing" — and a SQLite scan won't find anything either, so
  // we still fall through but record the cause first.
  if (sidecar && sidecar.permission_status === "granted" && Object.keys(sidecar.handles).length === 0) {
    lastLoadSource = "sidecar_granted_empty";
    process.stderr.write(
      `[contacts] sidecar present and granted but contains zero handles; ` +
      `falling back to SQLite (this typically means no contacts have synced from iCloud yet)\n`
    );
    runSqliteBulkLoad();
    // If SQLite also returned nothing, lastLoadSource stays "sidecar_granted_empty".
    // If SQLite found contacts (rare in this branch), upgrade to sqlite_fallback so
    // the diagnostic doesn't lie about where the data came from.
    if (handleToName.size > 0) lastLoadSource = "sqlite_fallback";
    return;
  }

  // Fallback: bulk-load from AddressBook SQLite. Used when the sidecar
  // is missing (menu bar app not installed), unreadable (denied /
  // restricted / rejected), or schema-mismatched. Requires Full Disk
  // Access on this binary; will report empty maps without it.
  if (sidecar) {
    process.stderr.write(
      `[contacts] sidecar present but unusable (status=${sidecar.permission_status}, ` +
      `count=${Object.keys(sidecar.handles).length}); falling back to SQLite\n`
    );
  } else {
    process.stderr.write(
      `[contacts] no sidecar at ~/.messages-mcp/contacts-cache.json; ` +
      `falling back to SQLite (install the menu bar app and grant Contacts permission to skip the FDA dependency)\n`
    );
  }

  runSqliteBulkLoad();
  lastLoadSource = handleToName.size > 0 ? "sqlite_fallback" : "none";
}

export function getLastContactsLoadSource(): ContactsLoadSource {
  return lastLoadSource;
}

// Expose the last bulk-load report so the diagnostic tool can show
// per-DB stats (which DBs were found, which opened, contacts each
// contributed). Empty array before the first load() call.
export function getLastContactsLoadReport(): readonly PerDbReport[] {
  return lastLoadReport;
}

export function resolveHandle(handleId: string): string | null {
  load();
  return handleToName.get(canonHandle(handleId)) ?? null;
}

export function resolveMany(handleIds: readonly string[]): Map<string, string | null> {
  load();
  const out = new Map<string, string | null>();
  for (const h of handleIds) out.set(h, handleToName.get(canonHandle(h)) ?? null);
  return out;
}

// Given a substring like "Fairfax", return the canonicalized handle strings
// (canonical phone tails + lowercased emails) belonging to contacts whose
// name contains that substring. Callers use this list to widen a chat.db
// query that would otherwise only match against the raw handle string.
export function findHandlesByContactName(filter: string): string[] {
  load();
  if (!filter) return [];
  const lower = foldName(filter);
  const out = new Set<string>();
  for (const entry of nameIndex) {
    if (entry.lower_name.includes(lower)) {
      for (const h of entry.handles) out.add(h);
    }
  }
  return [...out];
}

// For tests / forced cache invalidation.
export function _resetContactsCache(): void {
  loaded = false;
  handleToName = new Map();
  nameIndex = [];
  lastLoadReport = [];
  lastLoadSource = "none";
}

// Snapshot of which source served the last contact resolution and how
// many handles ended up in memory. Surfaced by the health tool as a
// separate field from the SQLite diagnostic so an agent can read
// "contacts_load.source === 'sidecar'" without confusing it for FDA
// state. `sidecar_present` distinguishes "no sidecar at all" from
// "sidecar exists but didn't win" without re-running the load.
export interface ContactsLoadDiagnostic {
  source: ContactsLoadSource;
  count: number;
  sidecar_present: boolean;
}

export function getContactsLoadDiagnostic(): ContactsLoadDiagnostic {
  // Trigger a load if one hasn't happened yet — otherwise source would
  // be "none" simply because nobody's called resolveHandle, which is
  // misleading.
  load();
  // Reading the sidecar without populating the map: safe because
  // readContactsSidecar is pure (it never mutates state in this file).
  // If the sidecar was rejected by trust checks, this returns null —
  // which is the correct semantics: "no usable sidecar present".
  const sidecar_present = readContactsSidecar() !== null;
  return {
    source: lastLoadSource,
    count: handleToName.size,
    sidecar_present,
  };
}

// Test seam: inject contacts data directly, bypassing the AddressBook
// SQLite read. Marks the loader as "already loaded" so subsequent calls
// don't try to read AddressBook over the injected state.
export function _setContactsForTesting(
  handles: ReadonlyMap<string, string>,
  names: { lower_name: string; handles: string[] }[]
): void {
  loaded = true;
  handleToName = new Map(handles);
  nameIndex = names.map((e) => ({ lower_name: e.lower_name, handles: [...e.handles] }));
  lastLoadSource = "test_seam";
}

// Public accessor for the canonicalization rule, exposed so the
// `health_check` diagnostic tool can show callers exactly
// what their handle string canonicalizes to. The rule itself stays
// private — this just publishes the result for inspection.
export function canonHandlePublic(s: string): string {
  return canonHandle(s);
}

export type DbOpenStatus = "ok" | "permission_denied" | "not_found" | "error";

export interface AddressBookDiagnostic {
  // Primary DB path for backward compat. First entry of `db_paths`.
  db_path: string | null;
  db_path_exists: boolean;
  // Every AddressBook DB the loader found. Multi-account Macs typically
  // have several Sources/{uuid}/AddressBook-v22.abcddb files (one per
  // CardDAV source: iCloud, Google, Exchange, "On My Mac") plus the
  // top-level path.
  db_paths: string[];
  // Open status for the PRIMARY DB. Aggregate state for callers that
  // just want a single yes/no; `per_db` has the breakdown.
  open_status: DbOpenStatus;
  open_error?: string;
  contacts_loaded: number;
  per_db: ReadonlyArray<{
    path: string;
    open_status: DbOpenStatus;
    open_error?: string;
    records: number;
    emails: number;
    phones: number;
    contacts_contributed: number;
  }>;
}

// Classify a thrown error from `new Database(path, { readonly: true })`
// or a filesystem read. macOS surfaces FDA denial as EACCES on the file
// open; bun:sqlite tends to surface the same as a SQLite open failure
// with "permission denied" / "unable to open" in the message. ENOENT
// only appears if the file genuinely isn't there.
function classifyDbError(err: unknown): { status: DbOpenStatus; message: string } {
  const e = err as NodeJS.ErrnoException & { message?: string };
  const code = e?.code ?? "";
  const msg = (e?.message ?? String(err)).toLowerCase();
  if (
    code === "EACCES" ||
    code === "EPERM" ||
    e?.errno === -13 ||
    // bun:sqlite (and the system libsqlite TCC authorizer hook on macOS)
    // surface FDA denial as the literal "authorization denied" error
    // message — verified empirically running this loader without FDA.
    // We also catch the older / generic SQLite phrasings here.
    msg.includes("authorization denied") ||
    msg.includes("permission denied") ||
    msg.includes("operation not permitted") ||
    msg.includes("unable to open")
  ) {
    return { status: "permission_denied", message: e?.message ?? String(err) };
  }
  if (code === "ENOENT" || msg.includes("no such file")) {
    return { status: "not_found", message: e?.message ?? String(err) };
  }
  return { status: "error", message: e?.message ?? String(err) };
}

// Run the AddressBook SQLite bulk-load and report per-DB stats.
// Resets the cache first so the result reflects current TCC state
// (FDA could have been granted between server start and now), then
// runs the SQLite scan DIRECTLY — bypassing the sidecar code path
// entirely. This is what makes `contacts_loaded` meaningfully report
// the SQLite layer's state rather than whichever layer happened to
// win in a regular `load()` call.
//
// The shape distinguishes "primary DB status" (back-compat for callers
// that just want a one-line yes/no) from `per_db` (the breakdown for
// multi-account Macs where iCloud + local + Google all live in
// separate files).
//
// IMPORTANT: after this runs, lastLoadSource will be "sqlite_fallback"
// or "none" — NOT "sidecar". Callers that want to know which layer
// served the *production* data should call getContactsLoadDiagnostic()
// instead, which preserves the layer-of-record. The health tool calls
// both: this for FDA state, the other for "which layer served the data".
export function getAddressBookSqliteDiagnostic(): AddressBookDiagnostic {
  const db_paths = findAddressBookDbs();
  const primary = db_paths[0] ?? null;

  if (db_paths.length === 0) {
    return {
      db_path: null,
      db_path_exists: false,
      db_paths: [],
      open_status: "not_found",
      open_error: "findAddressBookDbs returned [] (no Sources/* match and top-level path missing or unreadable)",
      contacts_loaded: 0,
      per_db: [],
    };
  }

  // Force a fresh SQLite scan. Skip readContactsSidecar — we want to
  // report THIS layer's state, not the sidecar's. The function
  // encapsulates its own cache cleanup: we snapshot the SQLite-only
  // result, then `_resetContactsCache()` BEFORE returning so the very
  // next `resolveHandle` call goes through the normal layered load().
  // This invariant is enforced inside the function rather than left
  // as a caller-must-remember contract — PR 11 review finding #2.
  _resetContactsCache();
  loaded = true; // prevent a parallel load() from also running
  runSqliteBulkLoad();
  const sqliteCount = handleToName.size;
  const sqliteOpenStatus = lastLoadReport.find((r) => r.path === primary)?.open_status ?? "error";
  const sqliteOpenError = lastLoadReport.find((r) => r.path === primary)?.open_error;
  const sqlitePerDb = [...lastLoadReport]; // snapshot before reset

  // Restore the cache to a fresh state so production resolveHandle
  // calls go through the normal sidecar-first path on next access.
  // Critical: callers that previously relied on this function leaving
  // the cache in SQLite-only state will now see normal behavior. The
  // only intended caller (health tool) didn't need that anyway.
  _resetContactsCache();

  return {
    db_path: primary,
    db_path_exists: primary != null && existsSync(primary),
    db_paths,
    open_status: sqliteOpenStatus,
    open_error: sqliteOpenError,
    contacts_loaded: sqliteCount,
    per_db: sqlitePerDb,
  };
}
