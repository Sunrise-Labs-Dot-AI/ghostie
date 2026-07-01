// wrapped-generator CLI / entry. Reads chat.db (read-only), runs the
// deterministic pipeline, and prints a self-contained Wrapped HTML to stdout
// (or --out). No LLM. Spawned by the Messages for AI menu-bar app (Tools >
// Generate Wrapped) and also callable by the texting-analytics Claude skill.
//
// The design assets (.jsx) + age rubric are EMBEDDED into the compiled binary
// here via `import ... with { type }` — a `bun build --compile` binary has no
// on-disk siblings, so this is how they travel.

import { homedir } from "node:os";
import { join } from "node:path";
import { exportChatDb, exportMessageBodies, type NormalizedExport } from "./chatdb-export.ts";
import { analyze } from "./analyze.ts";
import { emojiStats, NoUsableMessagesError } from "./emoji-stats.ts";
import { ageEstimate, NoAgeFeaturesError, type AgeRubric } from "./age-estimate.ts";
import { resolveNames } from "./resolve-names.ts";
import { buildAnalyticsReport, buildWrapped } from "./build-wrapped.ts";

// Bun embeds these into the --compile binary as raw strings via the `type:
// "text"` import attribute. tsc can't model ".jsx-as-text" (it tries to parse
// them as JSX modules), so the three .jsx imports are suppressed for the type
// checker only — they resolve and embed correctly at bun build/run time.
// @ts-ignore — text asset, not a JSX module
import iosFrame from "../../../skills/texting-analytics/wrapped/ios-frame.jsx" with { type: "text" };
// @ts-ignore — text asset, not a JSX module
import treatmentsJsx from "../../../skills/texting-analytics/wrapped/treatments.jsx" with { type: "text" };
// @ts-ignore — text asset, not a JSX module
import appJsx from "../../../skills/texting-analytics/wrapped/app.jsx" with { type: "text" };
import ageRubric from "../../../skills/texting-analytics/data/age_rubric.json" with { type: "json" };

const SUBSTANTIVE = new Set(["text", "media"]);

interface Args {
  db: string;
  // Window flags drive the --analytics-out / --json-only report path ONLY.
  // The Wrapped HTML always embeds BOTH the past-year and all-time metric
  // sets (the presentation UI carries the toggle), so there is no window
  // choice for the HTML anymore.
  windowDays: number;
  sinceMs: number | null;
  untilMs: number | null;
  noPeople: boolean;
  out: string | null;
  analyticsOut: string | null;
  jsonOnly: boolean;
  totalSent: number | null;
}

function parseArgs(argv: string[]): Args {
  const a: Args = {
    db: join(homedir(), "Library", "Messages", "chat.db"),
    windowDays: 365,
    sinceMs: null,
    untilMs: null,
    noPeople: false,
    out: null,
    analyticsOut: null,
    jsonOnly: false,
    totalSent: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i] ?? "";
    switch (k) {
      case "--db": a.db = next(); break;
      case "--window-days": a.windowDays = parseInt(next(), 10); break;
      case "--all-time": a.windowDays = 0; break;
      case "--since-ms": a.sinceMs = parseInt(next(), 10); break;
      case "--until-ms": a.untilMs = parseInt(next(), 10); break;
      case "--no-people": a.noPeople = true; break;
      case "--out": a.out = next(); break;
      case "--analytics-out": a.analyticsOut = next(); break;
      case "--json-only": a.jsonOnly = true; break;
      case "--total-sent": a.totalSent = parseInt(next(), 10); break;
      default:
        if (k && k.startsWith("--")) {
          process.stderr.write(`unknown flag: ${k}\n`);
          process.exit(2);
        }
    }
  }
  if ((a.sinceMs != null && !Number.isFinite(a.sinceMs)) || (a.untilMs != null && !Number.isFinite(a.untilMs))) {
    process.stderr.write(`invalid custom range: --since-ms and --until-ms must be unix millisecond timestamps\n`);
    process.exit(2);
  }
  if (a.sinceMs != null && a.untilMs != null && a.sinceMs > a.untilMs) {
    process.stderr.write(`invalid custom range: --since-ms must be before --until-ms\n`);
    process.exit(2);
  }
  return a;
}

/** Outbound substantive count within the analysis window — the Volume card. */
function outboundCount(exp: NormalizedExport, sinceMs: number, untilMs: number): number {
  let n = 0;
  for (const e of exp.events) {
    const ts = e.ts_ms ?? 0;
    if (e.from_me && SUBSTANTIVE.has(e.kind) && ts >= sinceMs && ts <= untilMs) n++;
  }
  return n;
}

interface WindowedAnalysis { analysis: any; totalSent: number }

/** Run the full deterministic metric stack for one window: analyze → emoji/
 * style pass → age estimate → contact-name resolution. */
function buildAnalysis(
  exp: NormalizedExport, dbPath: string,
  opts: { windowDays: number; sinceMs?: number | null; untilMs?: number | null; totalSentOverride?: number | null },
): WindowedAnalysis {
  const hasCustomRange = opts.sinceMs != null || opts.untilMs != null;
  const allTime = opts.windowDays <= 0 && !hasCustomRange;

  const analysis: any = analyze([exp], {
    windowDays: opts.windowDays,
    sinceMs: opts.sinceMs ?? undefined,
    untilMs: opts.untilMs ?? undefined,
  });
  const sinceMs = analysis.filters.since_ts_ms || 0;
  const untilMs = analysis.filters.until_ts_ms || Date.now();
  const totalSent = opts.totalSentOverride ?? outboundCount(exp, sinceMs, untilMs);

  // Emoji/style pass (content-reading, aggregates only).
  try {
    const bodies = exportMessageBodies({
      dbPath,
      allTime,
      sinceDays: allTime || hasCustomRange ? undefined : opts.windowDays,
      sinceMs: opts.sinceMs ?? undefined,
      untilMs: opts.untilMs ?? undefined,
    });
    const em = emojiStats(bodies, { outboundOnly: true });
    analysis.emoji = em.emoji;
    analysis.style = em.style;
  } catch (err) {
    if (!(err instanceof NoUsableMessagesError)) throw err;
    // no usable bodies → emoji/age cards simply omitted
  }

  // Age (optional — omitted if nothing fires or no style block).
  if (analysis.style) {
    try {
      analysis.age = ageEstimate(analysis, ageRubric as AgeRubric, { totalSent });
    } catch (err) {
      if (!(err instanceof NoAgeFeaturesError)) throw err;
    }
  }

  // Resolve contact names (1:1 handles + un-named group participants). Kept
  // out of the export so Gate-1 parity holds; runs here on the analysis.
  // Best-effort: if contacts are unavailable, names stay as handles.
  try {
    resolveNames(analysis, dbPath);
  } catch {
    /* contacts unavailable — leave handles/raw ids in place */
  }

  return { analysis, totalSent };
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  // One full-history export drives every window (analyze windows internally;
  // ball-in-court needs the full timeline).
  let exp: NormalizedExport;
  try {
    exp = exportChatDb({ dbPath: args.db, allTime: true });
  } catch (err) {
    process.stderr.write(JSON.stringify({ error: "chatdb_open_failed", detail: String(err) }) + "\n");
    process.exit(3);
  }

  // Analytics-report path: window flags apply here (the workbench asks for
  // 30d / 365d / all-time slices).
  if (args.analyticsOut || args.jsonOnly) {
    const flagged = buildAnalysis(exp, args.db, {
      windowDays: args.windowDays,
      sinceMs: args.sinceMs,
      untilMs: args.untilMs,
      totalSentOverride: args.totalSent,
    });
    if (args.analyticsOut) {
      const report = buildAnalyticsReport(flagged.analysis, {
        totalSent: flagged.totalSent || null,
        showPeople: !args.noPeople,
      });
      Bun.write(args.analyticsOut, JSON.stringify(report, null, 2));
    }
    if (args.jsonOnly) {
      process.stderr.write(JSON.stringify({
        status: "ok",
        analyticsOut: args.analyticsOut,
        window: args.windowDays,
        sinceMs: flagged.analysis.filters.since_ts_ms || 0,
        untilMs: flagged.analysis.filters.until_ts_ms || 0,
      }) + "\n");
      return;
    }
  }

  // Wrapped HTML: ALWAYS both windows — past year (default view) + all time —
  // in one self-contained file with the in-page toggle.
  const year = buildAnalysis(exp, args.db, { windowDays: 365, totalSentOverride: args.totalSent });
  const allTime = buildAnalysis(exp, args.db, { windowDays: 0 });

  const { html, data, allTimeData } = buildWrapped(
    year.analysis,
    { ios: iosFrame, treatments: treatmentsJsx, app: appJsx },
    {
      totalSent: year.totalSent || null,
      showPeople: !args.noPeople,
      allTimeAnalysis: allTime.analysis,
      allTimeTotalSent: allTime.totalSent || null,
    },
  );

  if (args.out) {
    Bun.write(args.out, html);
    process.stderr.write(JSON.stringify({
      status: "ok",
      out: args.out,
      cards: data.cards?.length,
      allTimeCards: allTimeData?.cards?.length ?? null,
      windows: ["past_year", "all_time"],
    }) + "\n");
  } else {
    process.stdout.write(html);
  }
}

main();
