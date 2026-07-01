import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { callDaemon } from "../daemon/rpc-client.ts";
import { registerWithWitness } from "../witness.ts";
import { SearchInput, SearchShape, isoToMs } from "../schema.ts";
import { errorResult, jsonResult } from "./_result.ts";
import { wrapBodyInPlace, wrapUntrusted } from "./_untrusted.ts";
import { mapDaemonDependentToolError } from "./_daemon-errors.ts";

interface ReplyTo {
  message_id: string;
  body: string | null;
  from_me: boolean;
  sender_name: string | null;
}

interface DaemonReaction {
  emoji: string;
  sender_jid: string | null;
  sender_name: string | null;
  from_me: boolean;
  ts: number;
}

interface DaemonMessage {
  message_id: string;
  thread_jid: string;
  sender_jid: string;
  /** Resolved sender name from contacts table; null for from_me or
   *  unresolvable senders. */
  sender_name: string | null;
  from_me: boolean;
  ts: number;
  body: string | null;
  body_sha256: string | null;
  message_type: string;
  attachment_meta: { caption?: string; filename?: string; mime?: string } | null;
  reply_to_id: string | null;
  reply_to: ReplyTo | null;
  reactions?: DaemonReaction[];
}

// Wrap every attacker-controlled field in <untrusted_content>: the message
// body, the quoted reply_to.body, AND both sender_name fields. sender_name is
// the contact's WhatsApp profile name (peer-controlled) and does NOT pass
// through the storage-side sanitizeIncomingBody, so the wrap here is the
// boundary defense against a contact whose profile name is an injection
// payload. Mirrors tools/threads.ts and tools/drafts.ts.
function wrapMessage(m: DaemonMessage): DaemonMessage {
  const wrapped: DaemonMessage = {
    ...wrapBodyInPlace(m),
    sender_name: wrapUntrusted(m.sender_name),
    reactions: m.reactions?.map((reaction) => ({
      ...reaction,
      emoji: wrapUntrusted(reaction.emoji) ?? "",
      sender_name: wrapUntrusted(reaction.sender_name),
    })),
  };
  if (wrapped.reply_to == null) return wrapped;
  return {
    ...wrapped,
    reply_to: {
      ...wrapped.reply_to,
      body: wrapUntrusted(wrapped.reply_to.body),
      sender_name: wrapUntrusted(wrapped.reply_to.sender_name),
    },
  };
}

export function registerSearchTool(server: McpServer) {
  registerWithWitness(
    server,
    "search_whatsapps",
    {
      description:
        "Case-insensitive substring search over cached WhatsApp message bodies. " +
        "Query must be ≥2 chars. Either `since` or `contact_filter` is required.",
      inputSchema: SearchShape,
    },
    async (rawArgs) => {
      const parsed = SearchInput.safeParse(rawArgs);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
      const args = parsed.data;
      try {
        const { messages } = await callDaemon<{ messages: DaemonMessage[] }>("searchMessages", {
          query: args.query,
          since: isoToMs(args.since),
          contact_filter: args.contact_filter,
          limit: args.limit,
        });
        return jsonResult({ ok: true, messages: messages.map(wrapMessage) });
      } catch (e) {
        return errorResult(mapDaemonDependentToolError(e));
      }
    },
  );
}
