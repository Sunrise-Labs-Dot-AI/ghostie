#!/usr/bin/env bun
//
// Standalone contact-resolution diagnostic. Run directly from your
// macOS Terminal — it inherits Terminal's FDA grant, which is usually
// already configured (whereas the MCP child process's FDA is a separate
// TCC entry that's easy to overlook).
//
// Usage:
//   bun scripts/diagnose-contacts.ts
//   bun scripts/diagnose-contacts.ts "+1 (404) 555-0147"
//
// First form: reports which AddressBook databases were found, which
// opened successfully, how many contacts each contributed, and the
// total. Second form: additionally probes the supplied phone or email,
// showing the canonical lookup key and whether it resolves to a name.
//
// If `contacts_loaded` is 0 here but you can see contacts in Contacts.app,
// the issue is FDA on your Terminal, not the MCP binary. If the per-DB
// breakdown shows multiple .abcddb files but Avery's still missing,
// her record may be in a cloud-only source (CloudKit-backed iCloud
// contacts that don't write back to the local SQLite).
//
import {
  getAddressBookDiagnostic,
  resolveHandle,
  canonHandlePublic,
} from "../src/chatdb/contacts.ts";
import { getChatDbDiagnostic } from "../src/chatdb/open.ts";
import { homedir } from "node:os";

const probe = process.argv[2];

console.log("=== imessage-drafts-mcp contacts diagnostic ===\n");

const ab = getAddressBookDiagnostic();
const home = homedir();
const shorten = (p: string) => p.startsWith(home) ? "~" + p.slice(home.length) : p;

console.log(`AddressBook DBs found:    ${ab.db_paths.length}`);
console.log(`Primary DB open status:   ${ab.open_status}`);
if (ab.open_error) console.log(`Primary DB error:         ${ab.open_error}`);
console.log(`Total contacts loaded:    ${ab.contacts_loaded}`);

if (ab.per_db.length > 0) {
  console.log("\nPer-DB breakdown:");
  for (const r of ab.per_db) {
    const status = r.open_status === "ok"
      ? `${r.records} records, ${r.emails} emails, ${r.phones} phones → +${r.contacts_contributed} new handle keys`
      : `[${r.open_status}] ${r.open_error ?? ""}`;
    console.log(`  ${shorten(r.path)}`);
    console.log(`    ${status}`);
  }
}

const chat = getChatDbDiagnostic();
console.log(`\nchat.db open status:      ${chat.open_status}`);
if (chat.open_error) console.log(`chat.db error:            ${chat.open_error}`);

const fdaLikelyMissing = ab.open_status === "permission_denied" || chat.open_status === "permission_denied";
console.log(`\nFDA likely missing?       ${fdaLikelyMissing ? "YES" : "no"}`);

if (probe) {
  console.log(`\n=== probe: ${JSON.stringify(probe)} ===`);
  const canonical = canonHandlePublic(probe);
  const resolved = resolveHandle(probe);
  console.log(`Canonical lookup key:     ${JSON.stringify(canonical)}`);
  console.log(`Resolved name:            ${resolved === null ? "null (no match)" : JSON.stringify(resolved)}`);

  if (resolved === null && ab.contacts_loaded > 0) {
    // Look for near-misses to help narrow down "is it a digit-count
    // problem or is she just not in any of these DBs?"
    console.log(`\nSearching loaded handles for partial matches...`);
    const partial = canonical.slice(-7);
    let nearMatches = 0;
    // Note: we can't directly enumerate handleToName from here without
    // exposing another seam. Just report the probe and let the user
    // decide whether to dig deeper.
    console.log(`(For deeper inspection, search Contacts.app for "${partial.slice(0, 3)}".`);
  }
}

if (fdaLikelyMissing) {
  console.log(`\n⚠  Your Terminal likely doesn't have Full Disk Access.`);
  console.log(`   System Settings → Privacy & Security → Full Disk Access → add Terminal.`);
  console.log(`   Then re-run this script.`);
}

if (ab.contacts_loaded === 0 && !fdaLikelyMissing) {
  console.log(`\n⚠  No contacts loaded, but no permission error either.`);
  console.log(`   The AddressBook DB opened but returned no rows. Possible causes:`);
  console.log(`   - Schema changed in a recent macOS update (ZABCDRECORD/etc. renamed)`);
  console.log(`   - Your contacts are entirely in CloudKit and don't write to the local DB`);
  console.log(`   - The DB we opened is a stale/empty source`);
}
