const OPEN = "<untrusted_content>";
const CLOSE = "</untrusted_content>";

// Prompt-injection mitigation for text that originated outside the agent:
// message bodies, contact/profile/group names, quoted previews, priority
// reasons, and similar labels. The storage layer stays raw so the menu bar can
// render normal text; MCP responses wrap at the boundary where an LLM will see
// the data.
//
// The load-bearing rule is total angle-bracket neutralization before wrapping.
// That prevents inner text from closing the outer <untrusted_content> tag,
// forging a nested opening tag, or smuggling tag-like scaffolding with
// zero-width characters.

// Kept as an exported list for documentation / test reference. Correctness
// comes from the total angle-bracket escape in sanitizeUntrusted, not from
// matching specific tag names.
export const SANITIZE_TOKENS: ReadonlyArray<RegExp> = [
  /<\/untrusted_content>/gi,
  /<\/tool_use>/gi,
  /<\/function_calls>/gi,
  /<\/tool_result>/gi,
];

export function sanitizeUntrusted(body: string): string {
  return body
    .replace(/[​-‍⁠﻿]/g, "")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

export function wrapUntrusted(body: string | null): string | null {
  if (body == null) return null;
  return `${OPEN}\n${sanitizeUntrusted(body)}\n${CLOSE}`;
}

export function wrapBodyInPlace<T extends { body: string | null }>(item: T): T {
  return { ...item, body: wrapUntrusted(item.body) };
}

export const DEFAULT_BODY_CAP_BYTES = 2048;

export function truncateToBytes(
  body: string,
  cap: number = DEFAULT_BODY_CAP_BYTES,
): { body: string; truncated: boolean } {
  const buf = Buffer.from(body, "utf8");
  if (buf.byteLength <= cap) return { body, truncated: false };
  let lo = 0;
  let hi = cap;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    const slice = buf.subarray(0, mid);
    const decoded = new TextDecoder("utf-8", { fatal: false }).decode(slice);
    if (!decoded.endsWith("�")) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return { body: buf.subarray(0, lo).toString("utf8"), truncated: true };
}
