// Phase A — contact-name resolution. Runs AFTER analyze (kept OUT of the
// export so the export stays byte-identical to the Python adapter — Gate 1).
// Mirrors what the texting-analytics skill did as a separate merge step:
//   - 1:1 thread names are the counterparty HANDLE (phone/email) → resolve to
//     a contact name via the daemon's AddressBook/sidecar resolver.
//   - Un-named group labels are a raw chat identifier ("chat123…") → resolve to
//     a participant first-name list ("Erin, Pete"). Named groups pass through.
//
// The resolver loads contacts from the menu-bar app's sidecar
// (~/.messages-mcp/contacts-cache.json) or AddressBook directly — the binary
// holds Full Disk Access via launcher attribution when the app spawns it.

import { Database } from "bun:sqlite";
import { resolveHandle, resolveMany } from "../../imessage-drafts/src/chatdb/contacts.ts";

function looksLikeHandle(s: string): boolean {
  if (!s) return false;
  if (s.includes("@")) return true; // email
  return /^\+?[\d\s().-]+$/.test(s); // phone-ish
}

function looksLikeRawChatId(s: string): boolean {
  return /^chat\d+$/.test(s);
}

function firstName(name: string | null): string | null {
  if (!name) return null;
  const parts = name.trim().split(/\s+/);
  return parts[0] || null;
}

/** chat_identifier → "Erin, Pete" participant label, for un-named groups. */
function groupParticipantLabels(dbPath: string): Map<string, string> {
  const db = new Database(dbPath, { readonly: true });
  db.exec("PRAGMA query_only = ON;");
  try {
    // chat_identifier → participant handle ids (groups only: style 43)
    const handlesByChat = new Map<string, string[]>();
    for (const r of db
      .query<{ chat_identifier: string; handle_id: string }, []>(
        `SELECT c.chat_identifier AS chat_identifier, h.id AS handle_id
           FROM chat c
           JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
           JOIN handle h ON h.ROWID = chj.handle_id
          WHERE c.style = 43`,
      )
      .all()) {
      if (!r.chat_identifier || !r.handle_id) continue;
      let arr = handlesByChat.get(r.chat_identifier);
      if (!arr) { arr = []; handlesByChat.set(r.chat_identifier, arr); }
      arr.push(r.handle_id);
    }

    const labels = new Map<string, string>();
    for (const [cid, handles] of handlesByChat) {
      const resolved = resolveMany(handles);
      const names = new Set<string>();
      for (const h of handles) {
        const fn = firstName(resolved.get(h) ?? null);
        if (fn) names.add(fn);
      }
      if (names.size === 0) continue; // leave as raw chat id
      const sorted = [...names].sort();
      labels.set(cid, sorted.length <= 3 ? sorted.join(", ") : sorted.slice(0, 3).join(", ") + ` + ${sorted.length - 3}`);
    }
    return labels;
  } finally {
    db.close();
  }
}

/** Mutates `analysis` in place: resolves 1:1 handles + un-named group labels. */
export function resolveNames(analysis: any, dbPath: string): void {
  const fix1to1 = (name: string): string => (looksLikeHandle(name) ? resolveHandle(name) ?? name : name);

  for (const list of [analysis.top_people, analysis.top_people_l30, analysis.top_people_by_chars]) {
    for (const p of list ?? []) p.name = fix1to1(p.name);
  }
  const tl = analysis.talk_listen;
  if (tl) {
    for (const p of tl.per_thread ?? []) p.name = fix1to1(p.name);
    for (const k of Object.keys(tl.highlights ?? {})) {
      if (tl.highlights[k]) tl.highlights[k].name = fix1to1(tl.highlights[k].name);
    }
  }

  // Groups: resolve raw chat-id labels via participants.
  const grp = analysis.group_contribution;
  if (grp) {
    const anyRaw =
      (grp.worst_offender && looksLikeRawChatId(grp.worst_offender.thread_label)) ||
      (grp.per_thread ?? []).some((t: any) => looksLikeRawChatId(t.thread_label));
    if (anyRaw) {
      const labels = groupParticipantLabels(dbPath);
      const fixGroup = (lbl: string): string => (looksLikeRawChatId(lbl) ? labels.get(lbl) ?? lbl : lbl);
      if (grp.worst_offender) grp.worst_offender.thread_label = fixGroup(grp.worst_offender.thread_label);
      for (const t of grp.per_thread ?? []) t.thread_label = fixGroup(t.thread_label);
    }
  }
}
