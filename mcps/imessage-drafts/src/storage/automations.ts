import { existsSync, lstatSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type AutomationCadence = "daily" | "weekly" | "biweekly" | "monthly" | "quarterly" | "yearly";
export type AutomationPlatform = "imessage" | "whatsapp";
export type AutomationApprovalStatus = "approved" | "pending";

export interface MessageAutomation {
  id: string;
  title: string;
  platform: AutomationPlatform;
  toHandle: string;
  toHandleName: string | null;
  body: string;
  cadence: AutomationCadence;
  nextRunAt: string;
  recurrenceInterval: number | null;
  weekdays: number[] | null;
  recurrenceAnchorAt: string | null;
  isEnabled: boolean;
  createdAt: string;
  updatedAt: string;
  approvalStatus: AutomationApprovalStatus | null;
  proposedBy: string | null;
  lastGeneratedAt: string | null;
  lastGeneratedDraftID: string | null;
  runHistory: Array<{
    id: string;
    draftID: string;
    generatedAt: string;
    dueAt: string;
  }> | null;
  failureNote: string | null;
}

let testFileOverride: string | null = null;

function automationsPath(): string {
  return testFileOverride ?? join(homedir(), ".messages-mcp", "automations.json");
}

export function _setAutomationsPathForTesting(path: string | null): void {
  testFileOverride = path;
}

export function automationsFile(): string {
  return automationsPath();
}

function ensureParentDir(): void {
  const file = automationsPath();
  const parent = dirname(file);
  try {
    if (lstatSync(parent).isSymbolicLink()) {
      throw new Error(`automations parent directory is a symlink, refusing to use: ${parent}`);
    }
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
  mkdirSync(parent, { recursive: true });
}

function normalizeAutomation(raw: Partial<MessageAutomation>): MessageAutomation | null {
  if (!raw.id || !raw.toHandle || raw.body == null || !raw.cadence || !raw.nextRunAt || !raw.createdAt || !raw.updatedAt) {
    return null;
  }
  const platform = raw.platform === "whatsapp" ? "whatsapp" : "imessage";
  return {
    id: raw.id,
    title: raw.title ?? "",
    platform,
    toHandle: raw.toHandle,
    toHandleName: raw.toHandleName ?? null,
    body: raw.body,
    cadence: raw.cadence,
    nextRunAt: raw.nextRunAt,
    recurrenceInterval: typeof raw.recurrenceInterval === "number" ? raw.recurrenceInterval : null,
    weekdays: Array.isArray(raw.weekdays) ? raw.weekdays.filter((day) => Number.isInteger(day) && day >= 1 && day <= 7) : null,
    recurrenceAnchorAt: raw.recurrenceAnchorAt ?? null,
    isEnabled: raw.isEnabled ?? false,
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
    approvalStatus: raw.approvalStatus ?? "approved",
    proposedBy: raw.proposedBy ?? null,
    lastGeneratedAt: raw.lastGeneratedAt ?? null,
    lastGeneratedDraftID: raw.lastGeneratedDraftID ?? null,
    runHistory: Array.isArray(raw.runHistory) ? raw.runHistory.filter((item) =>
      item != null &&
      typeof item.id === "string" &&
      typeof item.draftID === "string" &&
      typeof item.generatedAt === "string" &&
      typeof item.dueAt === "string"
    ) : null,
    failureNote: raw.failureNote ?? null,
  };
}

export function listAutomations(limit = 50): MessageAutomation[] {
  const file = automationsPath();
  if (!existsSync(file)) return [];
  if (lstatSync(file).isSymbolicLink()) {
    throw new Error(`automations file is a symlink, refusing to read: ${file}`);
  }
  const parsed = JSON.parse(readFileSync(file, "utf8")) as Partial<MessageAutomation>[];
  if (!Array.isArray(parsed)) throw new Error("automations file is not a JSON array");
  return parsed
    .map(normalizeAutomation)
    .filter((item): item is MessageAutomation => item != null)
    .sort((a, b) => {
      if (a.approvalStatus !== b.approvalStatus) return a.approvalStatus === "pending" ? -1 : 1;
      return Date.parse(a.nextRunAt) - Date.parse(b.nextRunAt);
    })
    .slice(0, limit);
}

function writeAutomations(items: MessageAutomation[]): void {
  ensureParentDir();
  const file = automationsPath();
  if (existsSync(file) && lstatSync(file).isSymbolicLink()) {
    throw new Error(`automations file is a symlink, refusing to write: ${file}`);
  }
  const tmp = `${file}.tmp-${randomUUID()}`;
  writeFileSync(tmp, JSON.stringify(items, null, 2), { mode: 0o600 });
  try {
    renameSync(tmp, file);
  } catch (err) {
    try { unlinkSync(tmp); } catch { /* best-effort */ }
    throw err;
  }
}

export interface ProposeAutomationArgs {
  title?: string | null;
  platform: AutomationPlatform;
  toHandle: string;
  toHandleName?: string | null;
  body: string;
  cadence: AutomationCadence;
  firstSendAt: string;
  proposedBy?: string | null;
}

export function proposeAutomation(args: ProposeAutomationArgs): MessageAutomation {
  if (Number.isNaN(Date.parse(args.firstSendAt))) {
    throw new Error(`first_send_at must be an ISO-8601 datetime, got ${JSON.stringify(args.firstSendAt)}`);
  }
  const existing = listAutomations(10_000);
  const now = new Date().toISOString();
  const automation: MessageAutomation = {
    id: randomUUID(),
    title: args.title?.trim() ?? "",
    platform: args.platform,
    toHandle: args.toHandle.trim(),
    toHandleName: args.toHandleName?.trim() || null,
    body: args.body.trim(),
    cadence: args.cadence,
    nextRunAt: new Date(args.firstSendAt).toISOString(),
    recurrenceInterval: args.cadence === "biweekly" ? 2 : 1,
    weekdays: (args.cadence === "weekly" || args.cadence === "biweekly")
      ? [new Date(args.firstSendAt).getUTCDay() + 1]
      : null,
    recurrenceAnchorAt: new Date(args.firstSendAt).toISOString(),
    isEnabled: false,
    createdAt: now,
    updatedAt: now,
    approvalStatus: "pending",
    proposedBy: args.proposedBy?.trim() || null,
    lastGeneratedAt: null,
    lastGeneratedDraftID: null,
    runHistory: null,
    failureNote: null,
  };
  if (!automation.toHandle) throw new Error("to_handle cannot be empty");
  if (!automation.body) throw new Error("body cannot be empty");
  existing.push(automation);
  writeAutomations(existing);
  return automation;
}

export function deletePendingAutomation(id: string): MessageAutomation | null {
  const existing = listAutomations(10_000);
  const target = existing.find((item) => item.id === id);
  if (!target) return null;
  if (target.approvalStatus !== "pending") {
    throw new Error("only pending automation proposals can be deleted from the MCP; use the app for approved automations");
  }
  writeAutomations(existing.filter((item) => item.id !== id));
  return target;
}

export function automationsMtimeMs(): number | null {
  const file = automationsPath();
  if (!existsSync(file)) return null;
  return statSync(file).mtimeMs;
}
