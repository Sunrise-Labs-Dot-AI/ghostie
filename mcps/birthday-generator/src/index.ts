// birthday-generator CLI / entry. Surfaces upcoming birthdays from the macOS
// Contacts sidecar (merged with the hand-maintained birthdays.json), stages a
// happy-birthday draft, and persists pin/mute curation. No LLM. Spawned by the
// Messages for AI menu-bar app (which holds Full Disk Access via launcher
// attribution); also usable as a CLI by the birthday-reminder Claude skill.
//
// The list leads with the user's curation (pinned = "On your list") then date.
// The on-device chat.db signals (text/call volume, wished-before) are a cheap
// BINARY STARTING POINT (`suggested`) + a net-new-people signal — NOT a "who
// matters" verdict. Claude/Codex does the real prioritization over the threads.
// Signals are cached on a long TTL (signalsCache.ts) so the list doesn't rescan
// on every open; --refresh-signals forces a recompute (the UI Refresh button).
//
// Modes:
//   --list   (default)  → JSON of upcoming birthdays + signals to stdout/--out
//   --gaps              → high-affinity contacts with no birthday (the net-new signal)
//   --seed              → everyone in regular contact (the LLM list-builder's input)
//   --import --in FILE  → bulk-upsert a finalized list (JSON array) into birthdays.json
//   --stage             → write a draft via the shared draft store
//   --pin/--unpin/--mute/--unmute → upsert curation into birthdays.json

import { homedir } from "node:os";
import { join } from "node:path";
import { readFileSync, writeFileSync, existsSync, lstatSync, renameSync, unlinkSync, mkdirSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { stageDraft } from "../../imessage-drafts/src/storage/drafts.ts";
import { canonHandle } from "../../imessage-drafts/src/chatdb/canon.ts";
import {
  readCache,
  readHand,
  readContactsNameMap,
  mergeContacts,
  upsertCuration,
  importCuration,
  defaultCachePath,
  defaultHandPath,
  defaultContactsCachePath,
  type MergedContact,
  type CurationUpdate,
} from "./store.ts";
import { enrichDates, civilToday, parseTodayArg, isoCivilDate } from "./dates.ts";
import { computeSignals, type SignalCandidate, type ContactSignals, type SignalsResult } from "./signals.ts";
import {
  loadFreshSignals,
  writeSignalsCache,
  defaultSignalsCachePath,
} from "./signalsCache.ts";
import { suggest, suggestedMessage } from "./suggest.ts";
import { defaultCallDbPath } from "./callhistory.ts";
import { topGaps } from "./gaps.ts";
import { buildSeed } from "./seed.ts";
import { buildKeepTabsCadence, buildKeepTabsRecommendations, buildKeepTabsStatus } from "./keeptabs.ts";

type Mode =
  | "list"
  | "gaps"
  | "seed"
  | "keep-tabs-recommend"
  | "keep-tabs-status"
  | "keep-tabs-cadence"
  | "import"
  | "stage"
  | "pin"
  | "unpin"
  | "mute"
  | "unmute";

interface Args {
  mode: Mode;
  db: string;
  callDb: string;
  windowDays: number;
  topN: number;
  today: string | null;
  out: string | null;
  in: string | null;
  handle: string | null;
  name: string | null;
  message: string | null;
  birthday: string | null;
  scheduledAt: string | null;
  approved: boolean;
  source: string | null;
  cachePath: string;
  handPath: string;
  contactsCachePath: string;
  signalsCachePath: string;
  useCache: boolean;
  refreshSignals: boolean;
  limit: number;
  excludeCanon: string[]; // --keep-tabs-recommend: canon handles already watched
  canon: string[]; // --keep-tabs-status: the watched canon handles to report on
}

function fail(msg: string): never {
  process.stderr.write(msg + "\n");
  process.exit(2);
}

// Write a JSON payload to --out at 0600. The output (e.g. birthday-list.json,
// handed to Claude) carries contact names + birthdays + handles, so it's treated
// like the other ~/.messages-mcp sidecars (mirrors store.ts writeHandAtomic):
// refuse a symlink, then write to a temp file at 0600 and atomically rename over
// the target. tmp+rename guarantees 0600 even when a looser-perm file already
// sits at the path (writeFileSync's mode only applies on create) and closes the
// check→write symlink race. Synchronous so the file is fully on disk before the
// process exits.
function writeOut(path: string, json: string): void {
  if (existsSync(path) && lstatSync(path).isSymbolicLink()) {
    fail(`refusing to write --out through a symlink: ${path}`);
  }
  const dir = join(path, "..");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const tmp = `${path}.tmp-${randomUUID()}`;
  writeFileSync(tmp, json, { mode: 0o600 });
  try {
    renameSync(tmp, path);
  } catch (err) {
    try {
      unlinkSync(tmp);
    } catch {
      /* best-effort cleanup */
    }
    throw err;
  }
}

function parseArgs(argv: string[]): Args {
  const a: Args = {
    mode: "list",
    db: join(homedir(), "Library", "Messages", "chat.db"),
    callDb: defaultCallDbPath(),
    windowDays: 30,
    topN: 25,
    today: null,
    out: null,
    in: null,
    handle: null,
    name: null,
    message: null,
    birthday: null,
    scheduledAt: null,
    approved: false,
    source: null,
    cachePath: defaultCachePath(),
    handPath: defaultHandPath(),
    contactsCachePath: defaultContactsCachePath(),
    signalsCachePath: defaultSignalsCachePath(),
    useCache: true,
    refreshSignals: false,
    limit: 15,
    excludeCanon: [],
    canon: [],
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i] ?? "";
    switch (k) {
      case "--list": a.mode = "list"; break;
      case "--gaps": a.mode = "gaps"; break;
      case "--seed": a.mode = "seed"; break;
      case "--keep-tabs-recommend": a.mode = "keep-tabs-recommend"; break;
      case "--keep-tabs-status": a.mode = "keep-tabs-status"; break;
      case "--keep-tabs-cadence": a.mode = "keep-tabs-cadence"; break;
      case "--import": a.mode = "import"; break;
      case "--stage": a.mode = "stage"; break;
      case "--pin": a.mode = "pin"; break;
      case "--unpin": a.mode = "unpin"; break;
      case "--mute": a.mode = "mute"; break;
      case "--unmute": a.mode = "unmute"; break;
      case "--db": a.db = next(); break;
      case "--call-db": a.callDb = next(); break;
      case "--no-calls": a.callDb = ""; break;
      case "--window-days": a.windowDays = parseInt(next(), 10); break;
      case "--top-n": a.topN = parseInt(next(), 10); break;
      case "--today": a.today = next(); break;
      case "--out": a.out = next(); break;
      case "--in": a.in = next(); break;
      case "--handle": a.handle = next(); break;
      case "--name": a.name = next(); break;
      case "--message": a.message = next(); break;
      case "--birthday": a.birthday = next(); break;
      case "--scheduled-at": a.scheduledAt = next(); break;
      case "--approved": a.approved = true; break;
      case "--source": a.source = next(); break;
      case "--cache-path": a.cachePath = next(); break;
      case "--hand-path": a.handPath = next(); break;
      case "--contacts-cache-path": a.contactsCachePath = next(); break;
      case "--signals-cache-path": a.signalsCachePath = next(); break;
      case "--no-cache": a.useCache = false; break;
      case "--refresh-signals": a.refreshSignals = true; break;
      case "--limit": a.limit = parseInt(next(), 10); break;
      case "--exclude-canon":
        a.excludeCanon = next().split(",").map((s) => s.trim()).filter(Boolean);
        break;
      case "--canon":
        a.canon = next().split(",").map((s) => s.trim()).filter(Boolean);
        break;
      default:
        if (k && k.startsWith("--")) fail(`unknown flag: ${k}`);
    }
  }
  if (!Number.isFinite(a.windowDays) || a.windowDays < 0) fail(`--window-days must be >= 0`);
  if (!Number.isFinite(a.topN) || a.topN < 1) fail(`--top-n must be >= 1`);
  if (!Number.isFinite(a.limit) || a.limit < 1) fail(`--limit must be >= 1`);
  return a;
}

function findByHandle(contacts: MergedContact[], handle: string): MergedContact | undefined {
  const canon = canonHandle(handle);
  return contacts.find(
    (c) => c.handles.includes(canon) || (c.best_handle != null && canonHandle(c.best_handle) === canon),
  );
}

function runList(a: Args): void {
  const today = a.today ? parseTodayArg(a.today) : civilToday();
  const contacts = mergeContacts(readCache(a.cachePath), readHand(a.handPath));

  // Enrich + window-filter; collect signal candidates in parallel.
  interface Row {
    contact: MergedContact;
    dates: NonNullable<ReturnType<typeof enrichDates>>;
    key: string;
  }
  const rows: Row[] = [];
  const candidates: SignalCandidate[] = [];
  contacts.forEach((contact, i) => {
    const dates = enrichDates(contact.birthday, today);
    if (!dates) {
      process.stderr.write(`  warn: skipping ${contact.name}: bad birthday ${JSON.stringify(contact.birthday)}\n`);
      return;
    }
    if (dates.days_until > a.windowDays) return;
    const key = `c${i}`;
    rows.push({ contact, dates, key });
    // Reuse the month/day enrichDates already parsed — no second parseBirthday
    // (which would be an un-guarded throw site, review S3).
    candidates.push({ key, handles: contact.handles, month: dates.month, day: dates.day });
  });

  // `today` drives the date/anniversary math; recency wants the real wall clock
  // so "last texted" isn't measured from this morning's midnight (review S4).
  //
  // Signals cache (v2, TTL-based): computeSignals is the dominant cost (full
  // chat.db scan). The signals are now a cheap binary STARTING POINT, not live
  // state, so the cache is a stable baseline that refreshes only a few times a
  // year (STARTING_POINT_TTL_DAYS) or when the user taps Refresh. chat.db changing
  // does NOT invalidate — that's deliberate (don't "generate every time"). A miss
  // happens on: missing/expired cache, an uncovered candidate (e.g. a newly-added
  // contact), --no-cache, or --refresh-signals.
  const callDbPath = a.callDb || undefined;
  const nowMs = Date.now();
  let signals: SignalsResult;
  const cached: Map<string, ContactSignals> | null =
    a.useCache && !a.refreshSignals
      ? loadFreshSignals(candidates, { nowMs }, a.signalsCachePath)
      : null;
  if (cached) {
    signals = { byKey: cached, available: true };
  } else {
    signals = computeSignals(a.db, candidates, {
      topN: a.topN,
      nowMs,
      callDbPath,
    });
    // Only cache real (FDA-available) signals — never the zeroed baseline that
    // computeSignals returns when chat.db can't be opened, or it would stick.
    if (a.useCache && signals.available) {
      try {
        writeSignalsCache(candidates, signals.byKey, { nowMs }, a.signalsCachePath);
      } catch (e) {
        process.stderr.write(`  warn: signals-cache write failed (${String(e)})\n`);
      }
    }
  }

  const upcoming = rows.map(({ contact, dates, key }) => {
    const sig = signals.byKey.get(key)!;
    const textsALot = sig.text_rank != null && sig.text_rank <= a.topN;
    const callsALot = sig.call_rank != null && sig.call_rank <= a.topN;
    const { suggested, reasons } = suggest({
      relationship: contact.relationship,
      pinned: contact.pinned,
      muted: contact.muted,
      textsALot,
      callsALot,
      wishedBefore: sig.wished_before,
    });
    return {
      name: contact.name,
      birthday: contact.birthday,
      next_occurrence: dates.next_occurrence,
      days_until: dates.days_until,
      weekday: dates.weekday,
      age_turning: dates.age_turning,
      relationship: contact.relationship,
      notes: contact.notes,
      best_handle: contact.best_handle,
      handles: contact.handles,
      source: contact.source,
      pinned: contact.pinned,
      muted: contact.muted,
      out_count: sig.out_count,
      text_rank: sig.text_rank,
      call_count: sig.call_count,
      call_rank: sig.call_rank,
      // NOTE: last_texted_days / last_call_days are intentionally NOT emitted.
      // They're wall-clock-derived and the TTL cache can hold them up to
      // STARTING_POINT_TTL_DAYS stale; surfacing "texted 1d ago" when it's really
      // 80 days would mislead the Claude handoff. The UI no longer shows recency,
      // and Claude reads the real threads for recency itself.
      wished_before: sig.wished_before,
      wished_years: sig.wished_years,
      suggested,
      reasons,
      // Only prepare a draft opener for SUGGESTED people. The tool does NOT
      // draft for the non-suggested tail — they're surfaced read-only with an
      // opt-in ("Add to my list"); promoting one makes it suggested and gets an
      // opener on the next list. Empty string keeps the field non-optional.
      suggested_message: suggested ? suggestedMessage(contact.name, contact.relationship) : "",
    };
  });

  // Order for the v2 list (Option 1): dismissed (muted) sink to the bottom (the
  // user said no — they must not lead "Coming up", review S2); then the user's
  // curation (pinned = "On your list") floats to the top; then soonest; then name
  // for a stable tiebreak. `suggested` stays in the payload as a binary STARTING-
  // POINT marker the GUI groups on, but it deliberately NO LONGER drives the top
  // of the sort — volume is a bad proxy for birthday priority; Claude does the
  // real prioritization over the threads.
  upcoming.sort(
    (x, y) =>
      Number(x.muted) - Number(y.muted) ||
      Number(y.pinned) - Number(x.pinned) ||
      x.days_until - y.days_until ||
      x.name.localeCompare(y.name),
  );

  const payload = {
    today: isoCivilDate(today),
    window_days: a.windowDays,
    top_n: a.topN,
    signals_available: signals.available,
    count: upcoming.length,
    upcoming,
  };
  const json = JSON.stringify(payload, null, 2);
  if (a.out) writeOut(a.out, json);
  else process.stdout.write(json + "\n");
}

function runGaps(a: Args): void {
  // Exclude anyone who already has a birthday (Contacts or hand file), by all
  // of their canonical handles.
  const excludeCanon = new Set<string>();
  for (const c of mergeContacts(readCache(a.cachePath), readHand(a.handPath))) {
    for (const h of c.handles) excludeCanon.add(h);
  }
  const nameByCanon = readContactsNameMap(a.contactsCachePath);
  const gaps = topGaps(a.db, nameByCanon, excludeCanon, {
    topN: a.topN,
    limit: a.limit,
    callDbPath: a.callDb || undefined,
  });
  const payload = {
    contacts_available: nameByCanon.size > 0,
    count: gaps.length,
    gaps,
  };
  const json = JSON.stringify(payload, null, 2);
  if (a.out) writeOut(a.out, json);
  else process.stdout.write(json + "\n");
}

// "Seed" for the LLM-built list: everyone in regular contact (incl. no saved
// birthday), with birthdays inferred from past wish dates where possible. Handed
// to the birthday-reminder skill, which sources the rest + asks the user.
function runSeed(a: Args): void {
  const nameByCanon = readContactsNameMap(a.contactsCachePath);
  // Per-canon saved birthday (so the seed marks who already has one + skips
  // wish-inference for them) and the muted set (dismissed people stay OUT of the
  // seed — an explicit "leave me out of birthday flows" the seed must honor).
  const savedByCanon = new Map<string, string>();
  const mutedCanon = new Set<string>();
  for (const c of mergeContacts(readCache(a.cachePath), readHand(a.handPath))) {
    if (c.muted) for (const h of c.handles) mutedCanon.add(h);
    if (!c.birthday) continue;
    for (const h of c.handles) if (!savedByCanon.has(h)) savedByCanon.set(h, c.birthday);
  }
  const { available, contacts } = buildSeed(a.db, nameByCanon, savedByCanon, {
    nowMs: Date.now(),
    callDbPath: a.callDb || undefined,
    mutedCanon,
  });
  const payload = {
    contacts_available: nameByCanon.size > 0,
    signals_available: available,
    count: contacts.length,
    contacts,
  };
  const json = JSON.stringify(payload, null, 2);
  if (a.out) writeOut(a.out, json);
  else process.stdout.write(json + "\n");
}

// Keep Tabs recommendations: rank named, non-business contacts by combined
// text+call affinity and suggest a contact cadence for each. The menu-bar app
// passes the current watchlist via --exclude-canon so already-watched people
// aren't re-recommended. Metadata-only output (no bodies).
function runKeepTabsRecommend(a: Args): void {
  const nameByCanon = readContactsNameMap(a.contactsCachePath);
  const excludeCanon = new Set(a.excludeCanon.map(canonHandle));
  const { available, recommendations } = buildKeepTabsRecommendations(a.db, nameByCanon, {
    nowMs: Date.now(),
    callDbPath: a.callDb || undefined,
    excludeCanon,
    limit: a.limit,
  });
  const payload = {
    contacts_available: nameByCanon.size > 0,
    signals_available: available,
    count: recommendations.length,
    recommendations,
  };
  const json = JSON.stringify(payload, null, 2);
  if (a.out) writeOut(a.out, json);
  else process.stdout.write(json + "\n");
}

// Live last-contacted (text + call) for the watched canon handles passed via
// --canon. The menu-bar app uses this to decide who's gone quiet past their
// target cadence (and to auto-clear a keep-tabs priority once contact resumes).
function runKeepTabsStatus(a: Args): void {
  const { available, statuses } = buildKeepTabsStatus(a.db, a.canon, {
    nowMs: Date.now(),
    callDbPath: a.callDb || undefined,
  });
  const payload = {
    signals_available: available,
    count: statuses.length,
    statuses,
  };
  const json = JSON.stringify(payload, null, 2);
  if (a.out) writeOut(a.out, json);
  else process.stdout.write(json + "\n");
}

// Suggested cadence (median text+call gap) for the ARBITRARY canon handles passed
// via --canon. The menu-bar app uses this in the manual-add flow: when the user
// searches a contact by name, it defaults the frequency picker to the person's
// real rhythm even though they aren't in the affinity-ranked recommend list.
function runKeepTabsCadence(a: Args): void {
  const { available, cadences } = buildKeepTabsCadence(a.db, a.canon, {
    nowMs: Date.now(),
    callDbPath: a.callDb || undefined,
  });
  const payload = {
    signals_available: available,
    count: cadences.length,
    cadences,
  };
  const json = JSON.stringify(payload, null, 2);
  if (a.out) writeOut(a.out, json);
  else process.stdout.write(json + "\n");
}

// Bulk-import the LLM-built finalized birthday list (or the app's paste-import)
// into birthdays.json. Input is a JSON array (via --in FILE) of entries shaped
// like the hand file: { name?, contact_handle?, birthday, relationship?, notes?,
// pinned?, muted? }. Each entry needs a name OR a handle, and a valid birthday;
// invalid entries are SKIPPED (and reported) rather than aborting the whole
// import — a single bad row from a hand-edited paste shouldn't lose the rest.
// Imported entries default to pinned:true (they're the user's curated list);
// existing entries + unknown keys are preserved (importCuration does one atomic
// rewrite). The skill writes this file; the app's Import action will reuse it.
function runImport(a: Args): void {
  if (!a.in) fail(`--import requires --in <path> (a JSON array of birthday entries)`);
  let raw: string;
  try {
    raw = readFileSync(a.in, "utf8");
  } catch (e) {
    return fail(`--import: cannot read ${a.in} (${String(e)})`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    return fail(`--import: ${a.in} is not valid JSON (${String(e)})`);
  }
  if (!Array.isArray(parsed)) return fail(`--import: expected a JSON array at the top level of ${a.in}`);

  const today = civilToday();
  const updates: CurationUpdate[] = [];
  const skipped: { index: number; reason: string }[] = [];
  parsed.forEach((item, i) => {
    if (!item || typeof item !== "object") {
      skipped.push({ index: i, reason: "not an object" });
      return;
    }
    const o = item as Record<string, unknown>;
    const name = typeof o.name === "string" ? o.name.trim() : "";
    // Accept either `contact_handle` (the hand-file field) or `handle` (the seed
    // field) so the skill can pass the seed's best_handle straight through.
    const handleRaw = typeof o.contact_handle === "string" ? o.contact_handle
      : typeof o.handle === "string" ? o.handle
      : "";
    const handle = handleRaw.trim();
    const birthday = typeof o.birthday === "string" ? o.birthday.trim() : "";
    if (!name && !handle) {
      skipped.push({ index: i, reason: "missing both name and contact_handle" });
      return;
    }
    if (!birthday) {
      skipped.push({ index: i, reason: `missing birthday for ${name || handle}` });
      return;
    }
    // Same validation the GUI curation path uses — rejects structurally-bad and
    // impossible dates, accepts MM-DD / YYYY-MM-DD (incl. the leap-day 02-29).
    if (!enrichDates(birthday, today)) {
      skipped.push({ index: i, reason: `invalid birthday ${JSON.stringify(birthday)} for ${name || handle}` });
      return;
    }
    // The finalized list is "on your list" by default; an entry can opt out
    // explicitly (e.g. importing a mute as { pinned:false, muted:true }).
    const pinned = typeof o.pinned === "boolean" ? o.pinned : true;
    // Pinning un-dismisses, exactly like the GUI pin (runCuration): pinned +
    // muted is contradictory and a muted row is hidden, so a default-pin import
    // over a previously-dismissed person clears the mute. An explicit `muted`
    // still wins (so the mute-import case above keeps working).
    const muted = typeof o.muted === "boolean" ? o.muted : pinned ? false : undefined;
    updates.push({
      handle: handle || null,
      name: name || handle,
      birthday,
      relationship: typeof o.relationship === "string" ? o.relationship : null,
      notes: typeof o.notes === "string" ? o.notes : null,
      pinned,
      muted,
    });
  });

  const { created, updated } = updates.length
    ? importCuration(updates, a.handPath)
    : { created: 0, updated: 0 };
  process.stdout.write(
    JSON.stringify({ status: "ok", created, updated, skipped: skipped.length, skipped_detail: skipped }) + "\n",
  );
}

function runStage(a: Args): void {
  if (!a.handle) fail(`--stage requires --handle`);
  if (a.message == null || a.message.trim() === "") fail(`--stage requires a non-empty --message`);
  // Validate the scheduled instant loudly — a malformed value would otherwise
  // produce a draft whose schedule silently never fires (review NH-5).
  if (a.scheduledAt != null && Number.isNaN(Date.parse(a.scheduledAt))) {
    fail(`--scheduled-at must be an ISO-8601 datetime, got ${JSON.stringify(a.scheduledAt)}`);
  }
  const { draft, path } = stageDraft({
    to_handle: a.handle,
    to_handle_name: a.name,
    body: a.message,
    source: a.source ?? "Messages for AI / Birthdays",
    // Approve-now/send-later: when set, the menu-bar scheduler fires it then —
    // but ONLY if schedule_approved is also set (the GUI passes --approved; the
    // bare CLI does not, so a non-GUI scheduled draft is held, not auto-sent).
    scheduled_send_at: a.scheduledAt,
    schedule_approved: a.approved || undefined,
  });
  process.stdout.write(JSON.stringify({ status: "ok", draft_id: draft.id, path }) + "\n");
}

function runCuration(a: Args): void {
  // Curation works by handle when available, but a contact may legitimately
  // have no phone/email (name + birthday only) — pin/mute must still work for
  // them, matched by name (review S8). Require at least a handle OR a name.
  if (!a.handle && !a.name) fail(`--${a.mode} requires --handle or --name`);
  const contacts = mergeContacts(readCache(a.cachePath), readHand(a.handPath));
  const found =
    (a.handle ? findByHandle(contacts, a.handle) : undefined) ??
    (a.name ? contacts.find((c) => c.name === a.name) : undefined);
  const name = a.name ?? found?.name ?? a.handle;
  if (!name) fail(`--${a.mode}: could not resolve a name; pass --name`);
  const birthday = a.birthday ?? found?.birthday;
  if (!birthday) fail(`--${a.mode}: no birthday known for ${a.handle ?? a.name}; pass --birthday`);
  // Validate before persisting — a malformed/impossible birthday written here
  // would corrupt the hand file the Claude skill also reads (review S13).
  // enrichDates runs the full parse + nextOccurrence, so it rejects both
  // structurally-bad ("abc") and impossible ("13-99", "06-31") dates while
  // accepting the leap-day "02-29".
  if (!enrichDates(birthday, civilToday())) {
    fail(`--${a.mode}: invalid --birthday ${JSON.stringify(birthday)} (expected MM-DD or YYYY-MM-DD)`);
  }

  const pinned = a.mode === "pin" ? true : a.mode === "unpin" ? false : undefined;
  // Pinning ("Add to my list" / search-add / gap backfill) also clears a prior
  // dismiss: pinned + muted is contradictory, and the GUI hides muted rows in a
  // collapsed "Dismissed" section — so re-adding a previously-dismissed contact
  // would otherwise silently vanish instead of landing on the list.
  const muted =
    a.mode === "mute" ? true : a.mode === "unmute" ? false : a.mode === "pin" ? false : undefined;
  upsertCuration(
    {
      handle: a.handle ?? found?.best_handle ?? null,
      name,
      birthday,
      relationship: found?.relationship ?? null,
      notes: found?.notes ?? null,
      pinned,
      muted,
    },
    a.handPath,
  );
  process.stdout.write(JSON.stringify({ status: "ok", action: a.mode, handle: a.handle ?? null, name }) + "\n");
}

function main(): void {
  const a = parseArgs(process.argv.slice(2));
  switch (a.mode) {
    case "list": return runList(a);
    case "gaps": return runGaps(a);
    case "seed": return runSeed(a);
    case "keep-tabs-recommend": return runKeepTabsRecommend(a);
    case "keep-tabs-status": return runKeepTabsStatus(a);
    case "keep-tabs-cadence": return runKeepTabsCadence(a);
    case "import": return runImport(a);
    case "stage": return runStage(a);
    default: return runCuration(a);
  }
}

main();
