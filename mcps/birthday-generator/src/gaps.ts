// "Gaps": people you clearly care about (high text/call affinity) who have NO
// birthday on file. Surfacing is deterministic; the actual birthday is filled by
// a Claude handoff (read the thread, propose a date + confidence) that you
// confirm — never silently guessed.

import { Database } from "bun:sqlite";
import { canonHandle } from "../../imessage-drafts/src/chatdb/canon.ts";
import { readCallHistory, type CallAgg } from "./callhistory.ts";
import { scanOneToOne, scanPerChat } from "./signals.ts";

export interface GapContact {
  name: string;
  best_handle: string | null; // dispatchable (chat.db E.164 / call address)
  out_count: number;
  call_count: number;
  reasons: string[];
}

export interface GapsOpts {
  topN: number; // rank threshold for "a lot" reasons
  limit: number; // max gaps to return
  callDbPath?: string;
}

interface Affinity { canon: string; original: string | null; out: number; calls: number }

// Rank named contacts (from contacts-cache) by combined text+call affinity,
// excluding anyone who already has a birthday (excludeCanon). A contact must be
// in the name map (so we can label them) and have some affinity.
export function topGaps(
  dbPath: string,
  nameByCanon: Map<string, string>,
  excludeCanon: Set<string>,
  opts: GapsOpts,
): GapContact[] {
  const byCanon = new Map<string, Affinity>();
  const bump = (canon: string, original: string | null) => {
    const a = byCanon.get(canon) ?? { canon, original: null, out: 0, calls: 0 };
    if (original && !a.original) a.original = original;
    byCanon.set(canon, a);
    return a;
  };

  // Text affinity (best-effort; degrade if chat.db is unreadable).
  try {
    const db = new Database(dbPath, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
    try {
      const oneToOne = scanOneToOne(db);
      for (const row of scanPerChat(db)) {
        const o = oneToOne.get(row.chat_id);
        if (!o) continue;
        bump(o.canon, o.original).out += Number(row.out_cnt ?? 0);
      }
    } finally {
      db.close();
    }
  } catch {
    /* no chat.db → call-only gaps still surface */
  }

  // Call affinity.
  const perCall: Map<string, CallAgg> = opts.callDbPath ? readCallHistory(opts.callDbPath) : new Map();
  for (const [canon, agg] of perCall) bump(canon, agg.original).calls += agg.count;

  // Rank thresholds for the reason labels.
  const textTop = topSet([...byCanon.values()].filter((a) => a.out > 0).sort((x, y) => y.out - x.out), opts.topN);
  const callTop = topSet([...byCanon.values()].filter((a) => a.calls > 0).sort((x, y) => y.calls - x.calls), opts.topN);

  const gaps: GapContact[] = [];
  for (const a of byCanon.values()) {
    if (excludeCanon.has(a.canon)) continue; // already has a birthday
    const name = nameByCanon.get(a.canon);
    if (!name) continue; // unnamed handle — can't present it usefully
    if (a.out === 0 && a.calls === 0) continue;
    const reasons: string[] = [];
    if (textTop.has(a.canon)) reasons.push("You text them a lot");
    if (callTop.has(a.canon)) reasons.push("You call them a lot");
    if (reasons.length === 0) continue; // only surface genuine high-affinity gaps
    gaps.push({ name, best_handle: a.original, out_count: a.out, call_count: a.calls, reasons });
  }

  // Combined affinity, calls weighted a bit higher (a call is a stronger signal).
  gaps.sort((x, y) => y.call_count * 3 + y.out_count - (x.call_count * 3 + x.out_count));
  return gaps.slice(0, opts.limit);
}

function topSet(sorted: Affinity[], n: number): Set<string> {
  return new Set(sorted.slice(0, n).map((a) => a.canon));
}
