// Baileys WebSocket lifecycle. Single source of truth for "are we connected
// to WhatsApp right now." Owns the socket; emits high-level events to the
// rest of the daemon (RPC server, message ingest).
//
// State machine:
//   connecting   ─► connected   ─► reconnecting ─► (back to connecting)
//                       │
//                       └─► logged_out (terminal; writes LOGGED_OUT sentinel)
//
// Reconnect backoff: 1s initial, 2x multiplier, 60s cap, ±10% jitter.
// loggedOut    → write sentinel, stop process. launchd will respawn but
//                the next startup checks the sentinel and exits 0 immediately
//                so the user has to clear it via the menu bar's Reconnect
//                flow.
// restartRequired → reconnect immediately, no backoff.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { EventEmitter } from "node:events";

import {
  type AnyMessageContent,
  type WAMessage,
  type WAMessageKey,
  type WASocket,
  Browsers,
  DisconnectReason,
  downloadMediaMessage,
  fetchLatestBaileysVersion,
  makeWASocket,
  proto,
} from "@whiskeysockets/baileys";

// Baileys re-throws @hapi/boom errors with this shape — typed structurally
// to avoid taking @hapi/boom as a direct dependency.
type BoomLike = Error & { output?: { statusCode?: number } };

import { PATHS } from "../paths.ts";
import {
  getMediaDescriptor,
  insertMessages,
  upsertReactionEvents,
  upsertThread,
  upsertContact,
  type IngestMessage,
  type IngestReaction,
  type MessageType,
  type QuotedReconstruction,
  type ReactionTargetKey,
} from "../storage/messages.ts";
import { useSqliteAuthState } from "../storage/session.ts";

export type ConnectionState = "connecting" | "connected" | "reconnecting" | "logged_out";

export interface ConnectionEvents {
  state: (s: ConnectionState) => void;
  qr: (qr: string) => void;
  paired: (info: { phone_number?: string }) => void;
}

const BACKOFF_INITIAL_MS = 1000;
const BACKOFF_MULTIPLIER = 2;
const BACKOFF_CAP_MS = 60_000;
const BACKOFF_JITTER = 0.1;

export class WhatsAppConnection extends EventEmitter {
  private socket: WASocket | null = null;
  private state: ConnectionState = "connecting";
  private currentQr: string | null = null;
  private meJid: string | null = null;
  private mePhone: string | null = null;
  private backoffMs: number = BACKOFF_INITIAL_MS;
  private stopped = false;

  override on<K extends keyof ConnectionEvents>(event: K, listener: ConnectionEvents[K]): this {
    return super.on(event, listener as never);
  }
  override emit<K extends keyof ConnectionEvents>(event: K, ...args: Parameters<ConnectionEvents[K]>): boolean {
    return super.emit(event, ...(args as unknown[]));
  }

  getState(): ConnectionState { return this.state; }
  getQr(): string | null { return this.currentQr; }
  getMe(): { jid: string | null; phone: string | null } {
    return { jid: this.meJid, phone: this.mePhone };
  }

  async start(): Promise<void> {
    this.stopped = false;
    await this.connect();
  }

  /**
   * Set state to `logged_out` without starting Baileys. Called from
   * `index.ts` main() when the LOGGED_OUT sentinel is present so the
   * menubar UI reflects the recovery state while the RPC server stays
   * up to handle `unlinkAndReset`.
   */
  markLoggedOut(): void {
    this.setState("logged_out");
  }

  private setState(s: ConnectionState): void {
    if (s === this.state) return;
    this.state = s;
    this.emit("state", s);
  }

  private async connect(): Promise<void> {
    this.setState(this.socket == null ? "connecting" : "reconnecting");

    const { state: authState, saveCreds } = await useSqliteAuthState();
    const { version } = await fetchLatestBaileysVersion().catch(() => ({ version: [2, 3000, 0] as [number, number, number] }));

    const sock = makeWASocket({
      version,
      auth: authState,
      // Shows up in WhatsApp → Linked Devices as "Messages for AI on
      // Mac OS". Matches the user-visible brand of the .app bundle so
      // the user can identify it at a glance vs other WhatsApp Web
      // sessions they might have linked.
      browser: Browsers.macOS("Messages for AI"),
      printQRInTerminal: false,
      syncFullHistory: false,  // initial history-sync handled via messaging-history.set
      generateHighQualityLinkPreview: false,
    });

    sock.ev.on("creds.update", () => { void saveCreds(); });

    sock.ev.on("connection.update", (update) => {
      const { connection, lastDisconnect, qr } = update;
      if (qr != null && qr !== this.currentQr) {
        this.currentQr = qr;
        this.emit("qr", qr);
      }
      if (connection === "open") {
        this.currentQr = null;
        this.backoffMs = BACKOFF_INITIAL_MS;
        this.setState("connected");
        const meId = sock.user?.id ?? null;
        // Baileys appends ":N@s.whatsapp.net" device suffix (e.g.
        // "12025550001:42@s.whatsapp.net") — for sendMessage targeting
        // we want the bare user JID without the device part.
        this.meJid = meId != null ? meId.replace(/:\d+@/, "@") : null;
        this.mePhone = this.meJid != null ? jidToPhone(this.meJid) : null;
        this.emit("paired", { phone_number: this.mePhone ?? undefined });
      } else if (connection === "close") {
        this.handleClose(lastDisconnect?.error as Error | undefined);
      }
    });

    sock.ev.on("messages.upsert", ({ messages, type }) => {
      // type is "notify" (live), "append" (history), "prepend" (history), or "replace"
      const source = type === "notify" ? "live" : "history-sync";
      const batch = messages.flatMap((msg) => {
        const ingest = toIngestMessage(msg, source);
        return ingest == null ? [] : [ingest];
      });
      const reactions = messages.flatMap((msg) => {
        const reaction = toIngestReaction(msg, source);
        return reaction == null ? [] : [reaction];
      });
      try {
        insertMessages(batch);
        upsertReactionEvents(reactions);
      } catch (e) {
        process.stderr.write(`WhatsApp live ingest failed: ${(e as Error).message}\n`);
      }
    });

    (sock.ev as any).on("messages.reaction", (updates: unknown[]) => {
      const reactions = (Array.isArray(updates) ? updates : [])
        .flatMap((update) => {
          const reaction = toIngestReactionUpdate(update, "live");
          return reaction == null ? [] : [reaction];
        });
      try {
        upsertReactionEvents(reactions);
      } catch (e) {
        process.stderr.write(`WhatsApp reaction ingest failed: ${(e as Error).message}\n`);
      }
    });

    sock.ev.on("messaging-history.set", ({ chats, contacts, messages }) => {
      void (async () => {
        let touched = 0;
        for (const c of chats) {
          // Baileys 7.x widened Chat.id from `string` to `string | null |
          // undefined` — intermediate history-sync states can ship null
          // ids. Skip those rather than poisoning the threads table with
          // an empty primary key.
          if (c.id == null) continue;
          upsertThread({
            thread_jid: c.id,
            display_name: c.name ?? null,
            is_group: c.id.endsWith("@g.us"),
            last_message_ts: typeof c.conversationTimestamp === "number"
              ? c.conversationTimestamp * 1000
              : 0,
          });
          touched += 1;
          if (touched % 500 === 0) await yieldToEventLoop();
        }
        for (const contact of contacts) {
          upsertContact({
            jid: contact.id,
            display_name: contact.name ?? null,
            push_name: contact.notify ?? null,
          });
          touched += 1;
          if (touched % 500 === 0) await yieldToEventLoop();
        }
        let batch: IngestMessage[] = [];
        let reactionBatch: IngestReaction[] = [];
        for (const msg of messages) {
          const ingest = toIngestMessage(msg, "history-sync");
          if (ingest != null) batch.push(ingest);
          const reaction = toIngestReaction(msg, "history-sync");
          if (reaction != null) reactionBatch.push(reaction);
          if (batch.length >= 500) {
            insertMessages(batch);
            batch = [];
            await yieldToEventLoop();
          }
          if (reactionBatch.length >= 500) {
            upsertReactionEvents(reactionBatch);
            reactionBatch = [];
            await yieldToEventLoop();
          }
        }
        insertMessages(batch);
        upsertReactionEvents(reactionBatch);
      })().catch((err) => {
        process.stderr.write(`WhatsApp history ingest failed: ${(err as Error).message}\n`);
      });
    });

    sock.ev.on("chats.upsert", (chats) => {
      for (const c of chats) {
        // See messaging-history.set: Baileys 7.x can pass null id.
        if (c.id == null) continue;
        upsertThread({
          thread_jid: c.id,
          display_name: c.name ?? null,
          is_group: c.id.endsWith("@g.us"),
          last_message_ts: typeof c.conversationTimestamp === "number"
            ? c.conversationTimestamp * 1000
            : Date.now(),
        });
      }
    });

    sock.ev.on("contacts.upsert", (contacts) => {
      for (const contact of contacts) {
        upsertContact({
          jid: contact.id,
          display_name: contact.name ?? null,
          push_name: contact.notify ?? null,
        });
      }
    });

    this.socket = sock;
  }

  private handleClose(err: Error | undefined): void {
    const statusCode = (err as BoomLike | undefined)?.output?.statusCode;
    this.socket = null;

    if (statusCode === DisconnectReason.loggedOut) {
      this.setState("logged_out");
      writeFileSync(PATHS.loggedOutSentinel, `${new Date().toISOString()}\n`, { mode: 0o600 });
      process.stderr.write("Baileys reports loggedOut — wrote LOGGED_OUT sentinel, exiting\n");
      process.exit(0);
    }

    if (this.stopped) return;

    if (statusCode === DisconnectReason.restartRequired) {
      // Server told us to restart, no backoff needed.
      this.setState("reconnecting");
      setImmediate(() => { void this.connect(); });
      return;
    }

    // Any other close → exponential backoff with jitter.
    const jitter = 1 + (Math.random() * 2 - 1) * BACKOFF_JITTER;
    const delay = Math.min(BACKOFF_CAP_MS, this.backoffMs) * jitter;
    this.backoffMs = Math.min(BACKOFF_CAP_MS, this.backoffMs * BACKOFF_MULTIPLIER);
    this.setState("reconnecting");
    setTimeout(() => { void this.connect(); }, delay);
  }

  /** Graceful shutdown for SIGTERM handling. */
  async stop(): Promise<void> {
    this.stopped = true;
    if (this.socket != null) {
      try { await this.socket.end(new Error("daemon shutting down")); } catch { /* ignore */ }
      this.socket = null;
    }
  }

  /** Send a message via Baileys. Used by daemon's sendDraft handler.
   *  When `quoted` is provided the message is sent as a quoted reply
   *  (Baileys threads it via `quoted.key.id`). */
  async sendText(
    jid: string,
    body: string,
    quoted?: QuotedReconstruction | null,
  ): Promise<{ message_id: string }> {
    if (this.socket == null || this.state !== "connected") {
      throw new Error("Not connected to WhatsApp");
    }
    let opts: { quoted: WAMessage } | undefined;
    if (quoted != null) {
      // Self-quotes stored `participant` as the thread JID; substitute the
      // real self-JID so the quote attributes correctly. Incoming quotes
      // already carry the right sender.
      const fixed =
        quoted.key.fromMe && this.meJid != null
          ? { ...quoted, key: { ...quoted.key, participant: this.meJid } }
          : quoted;
      opts = { quoted: fixed as unknown as WAMessage };
    }
    const result = await this.socket.sendMessage(jid, { text: body }, opts);
    return { message_id: result?.key.id ?? "" };
  }

  /** Send a single local file as a WhatsApp media message. The bytes are read
   *  from disk here (the daemon is the FDA/launcher-attributed process) and the
   *  Baileys content type is chosen from the MIME: image / video / audio /
   *  document. An optional `caption` rides on image/video/document (audio has
   *  no caption — the caller sends the text separately). `quoted` threads it as
   *  a reply, same as sendText. */
  async sendMedia(
    jid: string,
    attachment: { path: string; filename: string; mime_type: string | null },
    caption: string | null,
    quoted?: QuotedReconstruction | null,
  ): Promise<{ message_id: string }> {
    if (this.socket == null || this.state !== "connected") {
      throw new Error("Not connected to WhatsApp");
    }
    const bytes = readFileSync(attachment.path);
    const mime = (attachment.mime_type ?? "").toLowerCase();
    const captionText = caption != null && caption.length > 0 ? caption : undefined;
    let content: AnyMessageContent;
    if (mime.startsWith("image/")) {
      content = { image: bytes, caption: captionText, mimetype: mime || undefined };
    } else if (mime.startsWith("video/")) {
      content = { video: bytes, caption: captionText, mimetype: mime || undefined };
    } else if (mime.startsWith("audio/")) {
      content = { audio: bytes, mimetype: mime || "audio/mp4", ptt: false };
    } else {
      content = {
        document: bytes,
        fileName: attachment.filename,
        mimetype: mime.length > 0 ? mime : "application/octet-stream",
        caption: captionText,
      };
    }
    let opts: { quoted: WAMessage } | undefined;
    if (quoted != null) {
      const fixed =
        quoted.key.fromMe && this.meJid != null
          ? { ...quoted, key: { ...quoted.key, participant: this.meJid } }
          : quoted;
      opts = { quoted: fixed as unknown as WAMessage };
    }
    const result = await this.socket.sendMessage(jid, content, opts);
    return { message_id: result?.key.id ?? "" };
  }

  async sendReaction(
    jid: string,
    emoji: string,
    targetKey: ReactionTargetKey,
  ): Promise<{ message_id: string }> {
    if (this.socket == null || this.state !== "connected") {
      throw new Error("Not connected to WhatsApp");
    }
    const fixedKey: WAMessageKey =
      targetKey.fromMe && this.meJid != null && jid.endsWith("@g.us")
        ? { ...targetKey, participant: this.meJid }
        : targetKey;
    const result = await this.socket.sendMessage(jid, {
      react: {
        text: emoji,
        key: fixedKey,
      },
    });
    return { message_id: result?.key.id ?? "" };
  }

  /** Download a message's media payload to disk on demand and return the local
   *  path. Idempotent: a file that's already present is returned without
   *  re-fetching. The bytes are decrypted by Baileys using the stored media
   *  descriptor; an expired CDN URL is re-requested through the live socket. */
  async downloadMedia(threadJid: string, messageId: string): Promise<{ path: string; mime: string | null }> {
    const stored = getMediaDescriptor(threadJid, messageId);
    if (stored == null) throw new Error("no downloadable media for this message");

    const ext = mediaExtension(stored.message_type, stored.mime);
    const safeId = messageId.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 128);
    const outPath = join(PATHS.mediaDir, `${safeId}.${ext}`);
    if (existsSync(outPath)) return { path: outPath, mime: stored.mime };

    if (this.socket == null || this.state !== "connected") {
      throw new Error("Not connected to WhatsApp");
    }
    const message = proto.Message.decode(stored.descriptor);
    const wamsg = {
      key: {
        id: messageId,
        remoteJid: threadJid,
        fromMe: stored.from_me,
        participant: stored.sender_jid,
      },
      message,
    } as unknown as WAMessage;

    const socket = this.socket;
    const ctx = {
      reuploadRequest: socket.updateMediaMessage.bind(socket),
      logger: NOOP_LOGGER,
    } as unknown as Parameters<typeof downloadMediaMessage>[3];
    const buffer = await downloadMediaMessage(wamsg, "buffer", {}, ctx);

    mkdirSync(PATHS.mediaDir, { recursive: true, mode: 0o700 });
    writeFileSync(outPath, buffer, { mode: 0o600 });
    return { path: outPath, mime: stored.mime };
  }
}

// Baileys' downloadMediaMessage wants a pino-shaped logger for the reupload
// path. We don't want WhatsApp internals on stderr, so feed it a silent stub.
const NOOP_LOGGER = {
  level: "silent",
  child() { return NOOP_LOGGER; },
  trace() {}, debug() {}, info() {}, warn() {}, error() {}, fatal() {},
};

// File extension for a downloaded payload, from the MIME subtype when present
// (image/jpeg → jpg) else a sane per-type default.
function mediaExtension(type: MessageType, mime: string | null): string {
  const sub = mime?.split("/")[1]?.split(";")[0]?.trim().toLowerCase();
  if (sub != null && sub.length > 0 && /^[a-z0-9.+-]+$/.test(sub)) {
    if (sub === "jpeg") return "jpg";
    if (sub === "quicktime") return "mov";
    if (sub === "mpeg" && type === "voice") return "mp3";
    if (sub.startsWith("ogg")) return "ogg";
    return sub.replace(/[^a-z0-9]/g, "");
  }
  switch (type) {
    case "image": return "jpg";
    case "video": return "mp4";
    case "voice": return "ogg";
    default: return "bin";
  }
}

function toIngestMessage(msg: WAMessage, source: "live" | "history-sync"): IngestMessage | null {
  const key: WAMessageKey = msg.key;
  if (key.remoteJid == null || key.id == null) return null;
  if (msg.message?.reactionMessage != null) return null;

  const ts = messageTimestampMs(msg);

  const { body, type, attachment_meta } = extractMessageContent(msg);

  return {
    message_id: key.id,
    thread_jid: key.remoteJid,
    sender_jid: key.participant ?? key.remoteJid,
    from_me: key.fromMe === true,
    ts,
    body,
    message_type: type,
    attachment_meta,
    media_descriptor: encodeMediaDescriptor(msg, type),
    reply_to_id: extractReplyToId(msg),
    source,
  };
}

// Media types whose payload can be downloaded on demand later. The proto bytes
// of the whole message node (which carry the media key + directPath) are
// persisted (encrypted) so downloadMedia can reconstruct a WAMessage and fetch
// the file when the user opens it.
const DOWNLOADABLE_TYPES: ReadonlySet<MessageType> = new Set(["image", "video", "voice", "document"]);

function encodeMediaDescriptor(msg: WAMessage, type: MessageType): Uint8Array | null {
  if (!DOWNLOADABLE_TYPES.has(type) || msg.message == null) return null;
  try {
    return proto.Message.encode(msg.message).finish();
  } catch {
    return null;
  }
}

function toIngestReaction(msg: WAMessage, source: "live" | "history-sync"): IngestReaction | null {
  const reaction = msg.message?.reactionMessage;
  const targetKey = reaction?.key;
  const targetMessageId = targetKey?.id ?? null;
  const threadJid = targetKey?.remoteJid ?? msg.key.remoteJid ?? null;
  if (threadJid == null || targetMessageId == null) return null;
  const fromMe = msg.key.fromMe === true;
  const reactorJid = fromMe ? "__me__" : (msg.key.participant ?? msg.key.remoteJid ?? "");
  const ts = timestampValueMs((reaction as { senderTimestampMs?: unknown } | undefined)?.senderTimestampMs, messageTimestampMs(msg));
  return {
    thread_jid: threadJid,
    target_message_id: targetMessageId,
    reactor_jid: reactorJid,
    from_me: fromMe,
    emoji: reaction?.text ?? "",
    ts,
    source,
  };
}

function toIngestReactionUpdate(update: unknown, source: "live" | "history-sync"): IngestReaction | null {
  const u = update as {
    key?: WAMessageKey;
    reaction?: {
      text?: string | null;
      key?: WAMessageKey | null;
      senderTimestampMs?: unknown;
    };
  };
  const reaction = u.reaction;
  const targetKey = reaction?.key;
  const targetMessageId = targetKey?.id ?? null;
  const threadJid = targetKey?.remoteJid ?? u.key?.remoteJid ?? null;
  if (threadJid == null || targetMessageId == null) return null;
  const fromMe = u.key?.fromMe === true;
  const reactorJid = fromMe ? "__me__" : (u.key?.participant ?? u.key?.remoteJid ?? "");
  return {
    thread_jid: threadJid,
    target_message_id: targetMessageId,
    reactor_jid: reactorJid,
    from_me: fromMe,
    emoji: reaction?.text ?? "",
    ts: timestampValueMs(reaction?.senderTimestampMs, Date.now()),
    source,
  };
}

function messageTimestampMs(msg: WAMessage): number {
  return timestampValueMs(msg.messageTimestamp, Date.now());
}

function timestampValueMs(value: unknown, fallback: number): number {
  const raw =
    typeof value === "number"
      ? value
      : (value as { low?: number } | undefined)?.low;
  if (typeof raw !== "number" || !Number.isFinite(raw)) return fallback;
  return raw < 10_000_000_000 ? raw * 1000 : raw;
}

function yieldToEventLoop(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

// A quoted reply's `contextInfo.stanzaId` hangs off whichever sub-message the
// reply itself is — a text reply on `extendedTextMessage`, a photo reply on
// `imageMessage`, etc. Check the common carriers so media replies surface a
// reply pointer too, not just text replies.
function extractReplyToId(msg: WAMessage): string | null {
  const m = msg.message;
  if (m == null) return null;
  const ctx =
    m.extendedTextMessage?.contextInfo ??
    m.imageMessage?.contextInfo ??
    m.videoMessage?.contextInfo ??
    m.documentMessage?.contextInfo ??
    m.audioMessage?.contextInfo ??
    null;
  return ctx?.stanzaId ?? null;
}

function extractMessageContent(msg: WAMessage): {
  body: string | null;
  type: MessageType;
  attachment_meta: { caption?: string; filename?: string; mime?: string } | null;
} {
  const m = msg.message;
  if (m == null) return { body: null, type: "system", attachment_meta: null };

  if (m.conversation != null) {
    return { body: m.conversation, type: "text", attachment_meta: null };
  }
  if (m.extendedTextMessage?.text != null) {
    return { body: m.extendedTextMessage.text, type: "text", attachment_meta: null };
  }
  if (m.imageMessage != null) {
    return {
      body: m.imageMessage.caption ?? null,
      type: "image",
      attachment_meta: {
        caption: m.imageMessage.caption ?? undefined,
        mime: m.imageMessage.mimetype ?? undefined,
      },
    };
  }
  if (m.videoMessage != null) {
    return {
      body: m.videoMessage.caption ?? null,
      type: "video",
      attachment_meta: {
        caption: m.videoMessage.caption ?? undefined,
        mime: m.videoMessage.mimetype ?? undefined,
      },
    };
  }
  if (m.audioMessage != null) {
    return {
      body: null,
      type: "voice",
      attachment_meta: {
        mime: m.audioMessage.mimetype ?? undefined,
      },
    };
  }
  if (m.documentMessage != null) {
    return {
      body: m.documentMessage.caption ?? null,
      type: "document",
      attachment_meta: {
        caption: m.documentMessage.caption ?? undefined,
        filename: m.documentMessage.fileName ?? undefined,
        mime: m.documentMessage.mimetype ?? undefined,
      },
    };
  }
  // Reactions, protocol messages, etc. — store as system with no body.
  return { body: null, type: "system", attachment_meta: null };
}

/** "12025550001@s.whatsapp.net" → "+12025550001". Returns input unchanged on parse fail. */
function jidToPhone(jid: string): string {
  const at = jid.indexOf("@");
  if (at < 0) return jid;
  const num = jid.slice(0, at).replace(/[^0-9]/g, "");
  if (num.length === 0) return jid;
  return `+${num}`;
}
