# Root cause: `contact_filter` did not match AddressBook-resolved names

## Symptom (observed 2026-06-02)

Contact "Thomas Fixture" is saved with handle `+12025550148` (thread_id 1971).

- `list_threads(contact_filter="Thomas")` returned `{threads: []}`.
- `list_threads(contact_filter="Fixture")` returned `{threads: []}`.
- `search_messages(query="botco", since="2026-05-15")` found the thread AND
  resolved `sender.name` to "Thomas Fixture" correctly.

So the body-search path resolved the contact name fine, while the
`contact_filter` path (on `list_threads`, and the same on `search_messages`)
matched nothing by resolved name. An agent searching by name concluded "no
thread / bare number" when the thread plainly existed: a correctness bug that
produced a wrong assertion to the user.

## Root cause

Contact resolution keeps two in-memory structures in
`src/chatdb/contacts.ts`:

- `handleToName: Map<canonHandle, name>` — forward lookup. Used by
  `resolveHandle` / `resolveMany` to put a name on a message's sender. This is
  the path `search_messages` / `get_thread` use to display `sender.name`.
- `nameIndex: { lower_name, handles }[]` — reverse lookup. Used by
  `findHandlesByContactName`, which is what widens `contact_filter` so a name
  substring matches a thread whose raw handle is a bare phone number.

`load()` has two sources:

1. **Contacts sidecar** (written by the menu bar app via `CNContactStore`) —
   the *default and preferred* source once the app is installed. It is also
   the active source on this machine (`health_check` → `contacts_source:
   "sidecar"`, 2134 contacts).
2. **AddressBook SQLite fallback** — used only when the sidecar is missing /
   denied / empty.

The bug: the **sidecar branch populated `handleToName` but never built
`nameIndex`**, then `return`ed early. Only the SQLite fallback
(`loadOneDb`) built `nameIndex`. So on any normal install:

- `resolveHandle("+12025550148")` → "Thomas Fixture" ✅ (reads `handleToName`)
- `findHandlesByContactName("Thomas")` → `[]` ❌ (`nameIndex` empty)

With `findHandlesByContactName` returning `[]`,
`chatHandleRowIdsForContactName` returned no handle ROWIDs, so the
`contact_filter` SQL fell back to matching only the raw `handle.id` substring
and the chat `display_name`. "Thomas" / "Fixture" is in neither (the handle is
`+12025550148`; a 1:1 chat has a null `display_name`), so the result was empty.

The two name-resolution paths were inconsistent precisely because one read a
structure the sidecar populated and the other read a structure it didn't.

## Fix

`src/chatdb/contacts.ts`: the sidecar branch of `load()` now also builds the
reverse index, via a small shared helper `indexHandlesByName(pairs)`. The
sidecar only carries `(canonHandle -> name)` pairs (no per-record grouping),
so the helper groups by the display-name string: every handle sharing a name
becomes one `nameIndex` entry. `findHandlesByContactName` does a substring
match against `lower_name`, so grouping by the full name still matches first
name OR last name. Both the sidecar branch and the SQLite fallback now
populate `nameIndex` consistently.

This is a forward-lookup-vs-reverse-lookup reconciliation: nothing about the
SQL or the canonicalization changed, only that the reverse index is now built
under the sidecar path the daemon actually uses in production.

## Why the existing test did not catch it

`queries.test.ts` already had a "Fairfax fix" test for `contact_filter`, but it
seeds contacts via `_setContactsForTesting(handleToName, nameIndex)`, which
injects **both** structures directly and marks the loader `loaded = true`,
bypassing `load()` entirely. That seam made a green test coexist with a broken
production `load()` path, because the test never ran the sidecar branch.

The new regression tests (`queries.test.ts`, describe block
"contact_filter through the real sidecar load") deliberately avoid that seam:
they write a real granted sidecar to a tmp path via `_setSidecarPathForTesting`,
`_resetContactsCache()`, and force a real `load()`. Coverage:

- `contact_filter` by **first name** (`list_threads`).
- `contact_filter` by **last name** (`list_threads` and `search_messages`).
- contact **saved with a name but messaged by a bare number** (the fixture
  thread is keyed by `+12025550148`, name "Thomas Fixture", no chat
  `display_name`).
- a negative guard (a name not in contacts must still not match) so the fix
  can't regress into a blanket pass.

Verified the tests fail with the fix reverted (the 4 name-driven cases fail,
the negative guard still passes) and pass with it applied. Full suite: 162
pass, typecheck clean.

## Light robustness pass: other gaps worth noting (not fixed here)

1. **Canonicalization rule is duplicated three times.** `canonHandle`
   (`contacts.ts`), `canonChatHandle` (`queries.ts`), and the Swift sidecar
   writer each implement "last-10-digits for phones, lowercase for emails"
   independently. They agree today, but a future edit to one silently breaks
   name↔handle matching with no test guarding the equivalence. Candidate:
   unify the TS copies and add a cross-check test against representative
   inputs.

   **RESOLVED (birthday-tool PR):** the two TS copies are now a single
   `src/chatdb/canon.ts` (`contacts.ts` imports it; `queries.ts` imports it
   aliased as `canonChatHandle`), with `canon.test.ts` asserting a vector of
   representative inputs. The Swift mirror (`ContactsExporter.canonHandle`)
   stays separate (cross-language), but its expected outputs are the same
   vectors documented in `canon.test.ts`.

2. **Name matching is diacritic- and locale-sensitive.**
   `findHandlesByContactName` does `lower_name.includes(filter.toLowerCase())`.
   `String.toLowerCase()` does not strip accents, so contact "José" will not
   match `contact_filter="jose"`. Candidate: NFD-normalize and strip combining
   marks on both sides before comparing.

   **RESOLVED (birthday-tool PR):** a shared `foldName()` (NFD-decompose +
   strip combining marks + lowercase) is now applied on BOTH the build side
   (`indexHandlesByName` + the SQLite `nameIndex` push) and the query side
   (`findHandlesByContactName`), so `contact_filter="jose"` matches "José".
   Regression test: "contact_filter is diacritic-insensitive" in `queries.test.ts`.

3. **No invariant test tying the two structures together.** The deeper lesson
   is that any new contacts source must populate BOTH `handleToName` and
   `nameIndex`. A targeted invariant ("every named handle in `handleToName` is
   reachable via `findHandlesByContactName` on its own name") would catch a
   future source that forgets the reverse index, regardless of which branch
   added it.

   **RESOLVED (birthday-tool PR):** added the invariant test ("every named
   handle is reachable via findHandlesByContactName on its own name") in
   `queries.test.ts`, exercising the real sidecar `load()` path (not the
   `_setContactsForTesting` seam that masked the original bug).
