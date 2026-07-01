// Single source of truth for handle canonicalization.
//
// Canonicalize a phone or email for handle-lookup:
//   - phones: digits only, take the last 10 ("US-style" suffix matching that
//     ignores +1 vs. no-country). chat.db's handle.id for a phone uses E.164
//     (+14155551234) while AddressBook stores any user-entered formatting, so
//     matching by the last 10 digits is the common workaround.
//   - emails: lowercase.
//
// This rule was previously copy-pasted as `canonHandle` (contacts.ts) and
// `canonChatHandle` (queries.ts), plus a Swift mirror in ContactsExporter.swift.
// The TS copies are now unified here (see ROOT_CAUSE-contact-filter.md #1). The
// Swift copy (ContactsExporter.canonHandle) must stay in lockstep — its
// representative vectors are mirrored in canon.test.ts so the cross-language
// pair stays auditable. If you change this rule, change the Swift copy in the
// same PR.
export function canonHandle(s: string): string {
  if (s.includes("@")) return s.toLowerCase();
  const digits = s.replace(/[^\d]/g, "");
  return digits.length >= 10 ? digits.slice(-10) : digits;
}
