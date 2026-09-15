import { z } from "zod";

// This boundary is checked on the Mac, even when a relay is compromised.
const platform = z.enum(["imessage", "whatsapp"]);
const all = z.enum(["imessage", "whatsapp", "all"]);
const limit = z.number().int().min(1).max(100).optional();
const scope = { platform: all.optional(), since: z.string().datetime().optional(), contact_filter: z.string().min(2).max(200).optional(), limit };
export const remoteSchemas = {
  list_message_threads: z.object({ ...scope, before: z.string().datetime().optional() }).strict(),
  get_message_thread: z.object({ thread_ref: z.string().min(1).max(300), limit, before: z.string().datetime().optional() }).strict(),
  search_message_history: z.object({ ...scope, query: z.string().min(2).max(500) }).strict(),
  stage_message_draft: z.object({ platform, to_handle: z.string().min(1).max(300), body: z.string().min(1).max(20_000), in_reply_to_thread_ref: z.string().min(1).max(300).optional() }).strict(),
  list_message_drafts: z.object({ platform: all.optional(), limit }).strict(),
  get_message_draft: z.object({ draft_ref: z.string().min(1).max(300) }).strict(),
} as const;

export function validateRemoteCall(name: string, args: unknown): Record<string, unknown> {
  if (!Object.hasOwn(remoteSchemas, name)) throw new Error("Tool not available remotely");
  return remoteSchemas[name as keyof typeof remoteSchemas].parse(args);
}

export const REDACTED = "[Authentication content hidden]";
const AUTH_CONTEXT = /(?:\b(?:otp|2fa|mfa|pin|passcode|password|verification|authentication|authorization|security code|login code|sign[ -]?in code|one[ -]?time|recovery code|backup code)\b|\bcode\s+(?:is|for|to|expires)\b|\b(?:do not|don't|never)\s+share\b|验证码|驗證碼|認証コード|인증\s*번호|c[oó]digo|code de (?:connexion|v[eé]rification)|best[aä]tigungscode|sicherheitscode)/iu;
const AUTH_URL = /https?:\/\/[^\s<>]*(?:token|verify|verification|magic|reset|signin|sign-in|login|auth|otp|code=)[^\s<>]*/iu;
const CODE_CONTEXT = /\bcode\b.{0,40}[A-Z\p{N}]{4}|[\p{N}].{0,40}\b(?:log[ -]?in|sign[ -]?in|code)\b/iu;
const BARE_CODE = /^(?:<untrusted_content>\s*)?(?:[\p{N}][\s-]*){4,10}(?:\s*<\/untrusted_content>)?$/u;

export function authenticationContent(text: string): boolean {
  const normalized = text.normalize("NFKC").replace(/[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]/g, "");
  return AUTH_CONTEXT.test(normalized) || AUTH_URL.test(normalized) || CODE_CONTEXT.test(normalized) || BARE_CODE.test(normalized.trim());
}

const PRIVATE_FIELDS = new Set(["path", "filename", "attachments", "media", "body_sha256", "body_hash", "context_diagnostic"]);
function authenticationRecord(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  return Object.entries(value).some(([key, item]) =>
    ["body", "last_message_preview", "caption"].includes(key) && typeof item === "string" && authenticationContent(item));
}
/** Sanitize before serialization, including JSON nested inside MCP text envelopes. */
export function sanitizeRemote(value: unknown): unknown {
  if (typeof value === "string") {
    // MCP text content commonly contains a second JSON document.
    if (/^\s*[\[{]/.test(value)) {
      try { return JSON.stringify(sanitizeRemote(JSON.parse(value))); } catch { /* ordinary text */ }
    }
    return authenticationContent(value) ? REDACTED : value;
  }
  // Omit matching message/search records entirely: replacing only their body
  // would reveal which candidate code matched through search-result presence.
  if (Array.isArray(value)) return value.filter(item => !authenticationRecord(item)).map(sanitizeRemote);
  if (value !== null && typeof value === "object") {
    if ("type" in value && value.type === "text" && "text" in value && typeof value.text === "string") {
      return { type: "text", text: sanitizeRemote(value.text) };
    }
    const entries = Object.entries(value);
    // Hide all text in a record when a sibling supplies authentication context.
    const sensitive = entries.some(([, item]) => typeof item === "string" && authenticationContent(item));
    return Object.fromEntries(entries.filter(([key]) => !PRIVATE_FIELDS.has(key)).map(([key, item]) => [
      key, key === "error" ? "Local transport unavailable" : sensitive && (typeof item === "string" || typeof item === "number") ? REDACTED : sanitizeRemote(item),
    ]));
  }
  return value;
}
