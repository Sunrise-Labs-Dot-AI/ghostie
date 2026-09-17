import { MESSAGE_LINK_TOOL_NAME } from "./message-opener.ts";

export const SUPPORTED_SCOPES = ["messages:read", "messages:draft", "messages:link"] as const;
export type Scope = (typeof SUPPORTED_SCOPES)[number];
export const OAUTH_SCOPE: string = SUPPORTED_SCOPES.join(" ");
/** Standard OAuth request for a refresh token. Accepted for compatibility; refresh tokens are issued regardless. */
export const OFFLINE_ACCESS = "offline_access";

const isScope = (value: string): value is Scope => (SUPPORTED_SCOPES as readonly string[]).includes(value);

/**
 * Canonical granted scope for a requested scope string. An absent request grants everything
 * inside `within`. Unknown scopes, an empty grant, or anything outside `within` throws.
 */
export function grantScope(requested: string | undefined, within: string = OAUTH_SCOPE): string {
  const allowed = new Set(within.split(" ").filter(isScope));
  if (requested === undefined) return SUPPORTED_SCOPES.filter(scope => allowed.has(scope)).join(" ");
  const parts = new Set(requested.split(/\s+/).filter(Boolean));
  const granted = new Set<Scope>();
  for (const part of parts) {
    if (part === OFFLINE_ACCESS) continue;
    if (!isScope(part) || !allowed.has(part)) throw new Error("invalid_scope");
    granted.add(part);
  }
  if (granted.size === 0) throw new Error("invalid_scope");
  return SUPPORTED_SCOPES.filter(scope => granted.has(scope)).join(" ");
}

export function scopeAllows(scope: string, name: Scope): boolean {
  return scope.split(" ").includes(name);
}

/** The scope a remote tool call needs. Everything not otherwise listed is a read. */
export function requiredScope(tool: string): Scope {
  if (tool === "stage_message_draft") return "messages:draft";
  if (tool === MESSAGE_LINK_TOOL_NAME) return "messages:link";
  return "messages:read";
}

/** Drop tools the token cannot call from a tools/list result. */
export function filterToolList(response: unknown, scope: string): unknown {
  if (!response || typeof response !== "object" || Array.isArray(response)) return response;
  const rpc = response as Record<string, unknown>;
  if (!rpc.result || typeof rpc.result !== "object" || Array.isArray(rpc.result)) return response;
  const result = rpc.result as Record<string, unknown>;
  if (!Array.isArray(result.tools)) return response;
  const tools = result.tools.filter(tool => tool && typeof tool === "object" && typeof (tool as Record<string, unknown>).name === "string"
    && scopeAllows(scope, requiredScope((tool as Record<string, unknown>).name as string)));
  return { ...rpc, result: { ...result, tools } };
}

const DESCRIPTIONS: Record<Scope, string> = {
  "messages:read": "read messages",
  "messages:draft": "stage drafts for your review",
  "messages:link": "create public Messages compose links",
};

/** Plain-language consent phrase, in canonical scope order. */
export function describeScope(scope: string): string {
  const parts = SUPPORTED_SCOPES.filter(name => scopeAllows(scope, name)).map(name => DESCRIPTIONS[name]);
  if (parts.length <= 1) return parts[0] ?? "";
  if (parts.length === 2) return `${parts[0]} and ${parts[1]}`;
  return `${parts.slice(0, -1).join(", ")}, and ${parts[parts.length - 1]}`;
}
