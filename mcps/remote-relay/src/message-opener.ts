import { z } from "zod";

const OPENER_URL = "https://ghostie.app/v1/links";
const OPENER_ORIGIN = "https://ghostie.app";
const MAX_BODY_SCALARS = 2_000;
const MAX_RESPONSE_BYTES = 8_192;
const MIN_TTL_MS = (7 * 24 - 1) * 60 * 60 * 1_000;
const MAX_TTL_MS = (7 * 24 + 1) * 60 * 60 * 1_000;

export const MESSAGE_LINK_TOOL_NAME = "ghostie_create_messages_link";

export const MESSAGE_LINK_TOOL = {
  name: MESSAGE_LINK_TOOL_NAME,
  title: "Create a tappable Messages link",
  description: "Create a short public HTTPS link that opens an iOS Messages compose screen with the recipient and body prefilled. Use this instead of returning a raw sms: URL to a mobile chat client. The link expires after seven days and is a bearer capability. This composes only and never sends a message.",
  inputSchema: {
    type: "object",
    properties: {
      phone: {
        type: "string",
        pattern: "^\\+[1-9]\\d{6,14}$",
        description: "Recipient in international format, for example +12155550123.",
      },
      body: {
        type: "string",
        minLength: 1,
        maxLength: MAX_BODY_SCALARS,
        pattern: "\\S",
        description: "Message body to prefill. Maximum 2,000 Unicode characters.",
      },
    },
    required: ["phone", "body"],
    additionalProperties: false,
  },
  outputSchema: {
    type: "object",
    properties: {
      url: { type: "string", format: "uri" },
      expires_at: { type: "string", format: "date-time" },
    },
    required: ["url", "expires_at"],
    additionalProperties: false,
  },
  annotations: {
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: true,
  },
} as const;

function wellFormedUnicode(value: string) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return false;
    }
  }
  return true;
}

export const messageLinkInputSchema = z.object({
  phone: z.string().regex(/^\+[1-9]\d{6,14}$/),
  body: z.string().superRefine((value, context) => {
    if (!value.trim() || !wellFormedUnicode(value) || Array.from(value).length > MAX_BODY_SCALARS) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: "Invalid message body" });
    }
  }),
}).strict();

export interface MessageLink {
  url: string;
  expires_at: string;
}

export interface MessageLinkCreator {
  create(input: unknown): Promise<MessageLink>;
}

type Fetcher = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export type MessageLinkErrorKind = "invalid_input" | "outcome_unknown" | "unavailable";

export class MessageLinkError extends Error {
  constructor(readonly kind: MessageLinkErrorKind, message: string) {
    super(message);
    this.name = "MessageLinkError";
  }
}

const invalidInput = () => new MessageLinkError(
  "invalid_input",
  "Use an international phone number such as +12155550123 and a non-empty message of at most 2,000 Unicode characters.",
);
const unavailable = () => new MessageLinkError(
  "unavailable",
  "The Messages link service could not create a link. Try again later.",
);
const outcomeUnknown = () => new MessageLinkError(
  "outcome_unknown",
  "The Messages link request may have completed, but no result was received. Do not retry automatically. Ask the user before creating another link.",
);

async function boundedText(response: Response, maximum: number, signal: AbortSignal) {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maximum) throw new Error("Response too large");
  if (!response.body) throw new Error("Missing response body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let rejectAbort: ((reason: unknown) => void) | undefined;
  const aborted = new Promise<never>((_, reject) => { rejectAbort = reject; });
  const onAbort = () => {
    void reader.cancel().catch(() => undefined);
    rejectAbort?.(new Error("Request timed out"));
  };
  signal.addEventListener("abort", onAbort, { once: true });
  try {
    if (signal.aborted) onAbort();
    while (true) {
      const { done, value } = await Promise.race([reader.read(), aborted]);
      if (done) break;
      total += value.byteLength;
      if (total > maximum) {
        await reader.cancel();
        throw new Error("Response too large");
      }
      chunks.push(value);
    }
  } finally {
    signal.removeEventListener("abort", onAbort);
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new Error("Invalid UTF-8 response");
  }
}

function parseLink(value: unknown, now: number): MessageLink {
  const parsed = z.object({ url: z.string(), expires_at: z.string() }).strict().safeParse(value);
  if (!parsed.success) throw unavailable();
  let url: URL;
  try {
    url = new URL(parsed.data.url);
  } catch {
    throw unavailable();
  }
  if (
    url.origin !== OPENER_ORIGIN ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !/^\/t\/[A-Za-z0-9_-]{16}$/.test(url.pathname)
  ) throw unavailable();
  const expires = Date.parse(parsed.data.expires_at);
  if (
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(parsed.data.expires_at) ||
    !Number.isFinite(expires) ||
    new Date(expires).toISOString() !== parsed.data.expires_at ||
    expires < now + MIN_TTL_MS ||
    expires > now + MAX_TTL_MS
  ) throw unavailable();
  return parsed.data;
}

export function createMessageLinkCreator({
  token,
  endpoint = OPENER_URL,
  fetcher = fetch,
  timeoutMs = 5_000,
  now = Date.now,
}: {
  token: string;
  endpoint?: string;
  fetcher?: Fetcher;
  timeoutMs?: number;
  now?: () => number;
}): MessageLinkCreator {
  return {
    async create(input: unknown) {
      const parsed = messageLinkInputSchema.safeParse(input);
      if (!parsed.success) throw invalidInput();
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        let response: Response;
        try {
          response = await fetcher(endpoint, {
            method: "POST",
            redirect: "error",
            signal: controller.signal,
            headers: {
              Authorization: `Bearer ${token}`,
              "Content-Type": "application/json",
              Accept: "application/json",
            },
            body: JSON.stringify(parsed.data),
          });
        } catch {
          throw outcomeUnknown();
        }
        const receivedAt = now();
        if (response.status !== 201) throw unavailable();
        try {
          const contentType = (response.headers.get("content-type")?.split(";", 1)[0] ?? "").trim().toLowerCase();
          if (contentType !== "application/json") throw new Error("Unexpected content type");
          const decoded = JSON.parse(await boundedText(response, MAX_RESPONSE_BYTES, controller.signal));
          return parseLink(decoded, receivedAt);
        } catch {
          throw outcomeUnknown();
        }
      } finally {
        clearTimeout(timer);
      }
    },
  };
}

export function addMessageLinkTool(response: unknown): unknown {
  if (!response || typeof response !== "object" || Array.isArray(response)) return response;
  const rpc = response as Record<string, unknown>;
  if (!rpc.result || typeof rpc.result !== "object" || Array.isArray(rpc.result)) return response;
  const result = rpc.result as Record<string, unknown>;
  if (!Array.isArray(result.tools)) return response;
  return {
    ...rpc,
    result: {
      ...result,
      tools: [...result.tools.filter(tool => !tool || typeof tool !== "object" || (tool as Record<string, unknown>).name !== MESSAGE_LINK_TOOL_NAME), MESSAGE_LINK_TOOL],
    },
  };
}

export const messageLinkInternals = {
  MAX_BODY_SCALARS,
  MAX_RESPONSE_BYTES,
  MAX_TTL_MS,
  MIN_TTL_MS,
  wellFormedUnicode,
};
