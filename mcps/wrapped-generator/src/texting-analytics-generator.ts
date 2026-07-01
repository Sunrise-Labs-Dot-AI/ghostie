// Dedicated Texting Analytics CLI. It intentionally does not build Wrapped HTML:
// the Wrapped entrypoint stays on src/index.ts so the story generator contract
// is protected while this workbench can emit richer local dashboard blocks.

import { homedir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { decodeAttributedBody } from "../../imessage-drafts/src/chatdb/decode.ts";
import { appleToMs, exportChatDb, exportMessageBodies, kindFor, type EventKind, type MessageBody, type NormalizedExport } from "./chatdb-export.ts";
import { analyze } from "./analyze.ts";
import { emojiStats, NoUsableMessagesError } from "./emoji-stats.ts";
import { ageEstimate, NoAgeFeaturesError, type AgeRubric } from "./age-estimate.ts";
import { resolveNames } from "./resolve-names.ts";
import {
  addPreviousComparison,
  attachTextingAnalyticsBlocks,
  buildTextingAnalyticsReport,
  filterExportByThread,
  outboundCount,
} from "./analytics-report.ts";
import ageRubric from "../../../skills/texting-analytics/data/age_rubric.json" with { type: "json" };

const APPLE_EPOCH = 978307200;
const TWO_YEAR_DAYS = 730;

interface Args {
  db: string;
  windowDays: number;
  sinceMs: number | null;
  untilMs: number | null;
  noPeople: boolean;
  analyticsOut: string | null;
  jsonOnly: boolean;
  totalSent: number | null;
  threadFilter: string | null;
  comparePrevious: boolean;
}

interface FilteredBodyRow {
  date: number | bigint | null;
  is_from_me: number;
  item_type: number | null;
  assoc: number | null;
  att: number | null;
  text: string | null;
  ab: Uint8Array | null;
}

function msToAppleNs(ms: number): number {
  return Math.trunc((ms / 1000 - APPLE_EPOCH) * 1e9);
}

function parseArgs(argv: string[]): Args {
  const args: Args = {
    db: join(homedir(), "Library", "Messages", "chat.db"),
    windowDays: 365,
    sinceMs: null,
    untilMs: null,
    noPeople: false,
    analyticsOut: null,
    jsonOnly: false,
    totalSent: null,
    threadFilter: null,
    comparePrevious: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    const next = () => argv[++i] ?? "";
    switch (key) {
      case "--db": args.db = next(); break;
      case "--window-days": args.windowDays = parseInt(next(), 10); break;
      case "--all-time": args.windowDays = 0; break;
      case "--since-ms": args.sinceMs = parseInt(next(), 10); break;
      case "--until-ms": args.untilMs = parseInt(next(), 10); break;
      case "--no-people": args.noPeople = true; break;
      case "--analytics-out": args.analyticsOut = next(); break;
      case "--json-only": args.jsonOnly = true; break;
      case "--total-sent": args.totalSent = parseInt(next(), 10); break;
      case "--thread-filter": args.threadFilter = next().trim(); break;
      case "--compare-previous": args.comparePrevious = true; break;
      default:
        if (key && key.startsWith("--")) {
          process.stderr.write(`unknown flag: ${key}\n`);
          process.exit(2);
        }
    }
  }
  if ((args.sinceMs != null && !Number.isFinite(args.sinceMs)) || (args.untilMs != null && !Number.isFinite(args.untilMs))) {
    process.stderr.write("invalid custom range: --since-ms and --until-ms must be unix millisecond timestamps\n");
    process.exit(2);
  }
  if (args.sinceMs != null && args.untilMs != null && args.sinceMs > args.untilMs) {
    process.stderr.write("invalid custom range: --since-ms must be before --until-ms\n");
    process.exit(2);
  }
  return args;
}

function applyEmojiAndStyle(analysis: any, args: Args, filtered: ReturnType<typeof filterExportByThread>) {
  const hasCustomRange = args.sinceMs != null || args.untilMs != null;
  const allTime = args.windowDays <= 0 && !hasCustomRange;
  const bodyArgs = {
    dbPath: args.db,
    allTime,
    sinceDays: allTime || hasCustomRange ? undefined : args.windowDays,
    sinceMs: args.sinceMs ?? undefined,
    untilMs: args.untilMs ?? undefined,
  };
  const bodies = filtered.query
    ? exportMessageBodiesForThreads(bodyArgs, filtered.matchedThreadIds)
    : exportMessageBodies(bodyArgs);
  const em = emojiStats(bodies, { outboundOnly: true });
  analysis.emoji = em.emoji;
  analysis.style = em.style;
}

function exportMessageBodiesForThreads(
  args: { dbPath: string; allTime: boolean; sinceDays?: number; sinceMs?: number; untilMs?: number },
  matchedThreadIds: Set<string>,
): MessageBody[] {
  const chatGuids = [...matchedThreadIds]
    .map((id) => id.startsWith("imessage:") ? id.slice("imessage:".length) : id)
    .filter((id) => id.length > 0);
  if (chatGuids.length === 0) return [];

  const nowMs = Date.now();
  const effectiveUntilMs = args.untilMs ?? nowMs;
  const sinceMs = args.sinceMs ?? (
    args.allTime
      ? 0
      : nowMs - Math.min(args.sinceDays ?? TWO_YEAR_DAYS, TWO_YEAR_DAYS) * 86400 * 1000
  );
  const sinceNs = msToAppleNs(sinceMs);
  const untilNs = msToAppleNs(effectiveUntilMs);
  const placeholders = chatGuids.map(() => "?").join(",");

  const db = new Database(args.dbPath, { readonly: true });
  db.exec("PRAGMA query_only = ON;");
  try {
    const rows = db
      .query<FilteredBodyRow, Array<number | string>>(
        `SELECT m.date AS date, m.is_from_me AS is_from_me, m.item_type AS item_type,
                m.associated_message_type AS assoc, m.cache_has_attachments AS att,
                m.text AS text, m.attributedBody AS ab
           FROM message m
           JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
           JOIN chat c ON c.ROWID = cmj.chat_id
          WHERE m.date >= ? AND m.date <= ?
            AND c.guid IN (${placeholders})`,
      )
      .all(sinceNs, untilNs, ...chatGuids);

    return rows.map((row) => {
      const body = row.text ?? decodeAttributedBody(row.ab);
      const textLen = body ? [...body].length : null;
      return {
        text: body,
        from_me: row.is_from_me === 1,
        kind: kindFor(row.assoc, row.item_type, row.att, textLen, row.ab != null) as EventKind,
        assoc: row.assoc,
        ts_ms: appleToMs(row.date),
      };
    });
  } finally {
    db.close();
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  let exp: NormalizedExport;
  try {
    exp = exportChatDb({ dbPath: args.db, allTime: true });
  } catch (err) {
    process.stderr.write(JSON.stringify({ error: "chatdb_open_failed", detail: String(err) }) + "\n");
    process.exit(3);
  }

  const filtered = filterExportByThread(exp, args.threadFilter);
  const analysis: any = analyze([filtered.exp], {
    windowDays: args.windowDays,
    sinceMs: args.sinceMs ?? undefined,
    untilMs: args.untilMs ?? undefined,
  });
  attachTextingAnalyticsBlocks(analysis, filtered.exp);

  const sinceMs = analysis.filters.since_ts_ms || 0;
  const untilMs = analysis.filters.until_ts_ms || Date.now();
  if (filtered.query) {
    analysis.filters.thread_filter_query = filtered.query;
    analysis.filters.thread_filter_matched_threads = filtered.matchedThreadIds.size;
  }
  const totalSent = args.totalSent ?? outboundCount(filtered.exp, sinceMs, untilMs);

  if (args.comparePrevious && sinceMs > 0 && untilMs > sinceMs) {
    const span = untilMs - sinceMs;
    const previousUntil = sinceMs - 1;
    const previousSince = Math.max(0, sinceMs - span);
    const previous: any = analyze([filtered.exp], {
      windowDays: args.windowDays,
      sinceMs: previousSince,
      untilMs: previousUntil,
    });
    attachTextingAnalyticsBlocks(previous, filtered.exp);
    addPreviousComparison(
      analysis,
      totalSent || null,
      previous,
      outboundCount(filtered.exp, previousSince, previousUntil) || null,
    );
  }

  try {
    applyEmojiAndStyle(analysis, args, filtered);
  } catch (err) {
    if (!(err instanceof NoUsableMessagesError)) throw err;
  }

  if (analysis.style) {
    try {
      analysis.age = ageEstimate(analysis, ageRubric as AgeRubric, { totalSent });
    } catch (err) {
      if (!(err instanceof NoAgeFeaturesError)) throw err;
    }
  }

  try {
    resolveNames(analysis, args.db);
  } catch {
    /* contacts unavailable — leave handles/raw ids in place */
  }

  const report = buildTextingAnalyticsReport(analysis, {
    totalSent: totalSent || null,
    showPeople: !args.noPeople,
  });

  const json = JSON.stringify(report, null, 2);
  if (args.analyticsOut) {
    Bun.write(args.analyticsOut, json);
  } else {
    process.stdout.write(json);
  }

  if (args.jsonOnly) {
    process.stderr.write(JSON.stringify({
      status: "ok",
      analyticsOut: args.analyticsOut,
      window: args.windowDays,
      sinceMs,
      untilMs,
    }) + "\n");
  }
}

main();
