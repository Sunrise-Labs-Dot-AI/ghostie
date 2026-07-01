// Tiny, dependency-free helpers for reasoning about Messages chat GUIDs.
//
// Lives on its own (not in chatdb/queries.ts) so the MCP side can import the
// addressability check WITHOUT dragging the chat.db query module — and its
// `bun:sqlite` dependency — into the MCP binary. The MCP has no Full Disk
// Access and never opens chat.db; only the daemon does. queries.ts re-exports
// these so the daemon's chat-resolution code has one import surface.

// True only when a chat GUID's service prefix is one AppleScript `chat id` can
// resolve: iMessage / SMS / RCS (case-insensitive). Deliberately STRICT — an
// unbound/aggregate guid ("any;-;+1555…") is NOT addressable; sending to that
// id fails with -1728 ("Can't get chat id"). Mirrors the Swift
// IMessageDirectChatResolver.isAddressableChatGUID.
export function isAddressableChatGUID(guid: string): boolean {
  const idx = guid.indexOf(";");
  const prefix = (idx === -1 ? guid : guid.slice(0, idx)).toUpperCase();
  return prefix === "IMESSAGE" || prefix === "SMS" || prefix === "RCS";
}

// Pull the service token out of a chat GUID prefix ("SMS;-;…" → "SMS"),
// preserving chat.db's original casing. Returns null when there's no prefix.
export function serviceFromChatGUID(guid: string): string | null {
  const idx = guid.indexOf(";");
  const prefix = idx === -1 ? guid : guid.slice(0, idx);
  return prefix.length > 0 ? prefix : null;
}
