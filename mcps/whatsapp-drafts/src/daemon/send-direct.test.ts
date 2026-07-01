import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { generateKeyPairSync, randomBytes, sign, type KeyObject } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const tmp = mkdtempSync(join(tmpdir(), "whatsapp-mcp-direct-"));
process.env.WHATSAPP_MCP_HOME = tmp;
process.env.WHATSAPP_MCP_TEST_KEY = randomBytes(32).toString("base64");

const { handleSendDirectMessage, handleSendDirectReaction, mapReservationError } = await import("./server.ts");
const { getAuditDb, recentSends, _resetForTesting } = await import("../storage/audit.ts");
const { getMessagesDb, insertMessage, _resetForTesting: _resetMessagesForTesting } = await import("../storage/messages.ts");
const {
  _setControlDirForTesting,
  _setPublicKeyForTesting,
} = await import("../control-gate.ts");

let signingKey: KeyObject;
const controlDir = join(tmp, "control");

function rawPublicFrom(pub: KeyObject): Buffer {
  return pub.export({ format: "der", type: "spki" }).subarray(-32);
}

function writeManifest(manifest: unknown): void {
  mkdirSync(controlDir, { recursive: true });
  const bytes = Buffer.from(JSON.stringify(manifest), "utf8");
  const sig = sign(null, bytes, signingKey);
  writeFileSync(join(controlDir, "control-manifest.json"), bytes);
  writeFileSync(join(controlDir, "control-manifest.json.sig"), sig.toString("base64"));
}

afterAll(() => {
  _resetForTesting();
  _resetMessagesForTesting();
  _setControlDirForTesting(null);
  _setPublicKeyForTesting(null);
  rmSync(tmp, { recursive: true, force: true });
});

beforeEach(() => {
  getAuditDb().exec("DELETE FROM sends");
  const messagesDb = getMessagesDb();
  messagesDb.exec("DELETE FROM message_reactions");
  messagesDb.exec("DELETE FROM messages");
  messagesDb.exec("DELETE FROM threads");
  messagesDb.exec("DELETE FROM contacts");
  rmSync(controlDir, { recursive: true, force: true });
  const kp = generateKeyPairSync("ed25519");
  signingKey = kp.privateKey;
  _setPublicKeyForTesting(rawPublicFrom(kp.publicKey));
  _setControlDirForTesting(controlDir);
});

describe("sendDirectMessage", () => {
  test("sends through the connection and records metadata-only audit", async () => {
    const calls: Array<{ jid: string; body: string }> = [];
    const connection = {
      sendText: async (jid: string, body: string) => {
        calls.push({ jid, body });
        return { message_id: "msg-1" };
      },
    };

    const originalRandom = Math.random;
    Math.random = () => 0;
    try {
      const response = await handleSendDirectMessage(
        "req-1",
        "12025550001@s.whatsapp.net",
        "hello directly",
        "first_party_inline_composer",
        connection as never,
      );

      expect(response.error).toBeUndefined();
      expect(response.result).toMatchObject({
        ok: true,
        message_id: "msg-1",
      });
      expect((response.result as { draft_id: string }).draft_id.startsWith("direct-")).toBe(true);
      expect(calls).toEqual([{ jid: "12025550001@s.whatsapp.net", body: "hello directly" }]);

      const rows = recentSends();
      expect(rows).toHaveLength(1);
      expect(rows[0]!.draft_id.startsWith("direct-")).toBe(true);
      expect(rows[0]!.to_handle).toBe("12025550001@s.whatsapp.net");
      expect(rows[0]!.body_sha256).toHaveLength(64);
      expect(rows[0]!.body_sha256).not.toContain("hello");
      expect(rows[0]!.status).toBe("ok");
    } finally {
      Math.random = originalRandom;
    }
  });

  test("rate limits before calling the connection", async () => {
    let sendCount = 0;
    const connection = {
      sendText: async () => {
        sendCount += 1;
        return { message_id: `msg-${sendCount}` };
      },
    };

    const originalRandom = Math.random;
    Math.random = () => 0;
    try {
      const first = await handleSendDirectMessage(
        "req-1",
        "12025550001@s.whatsapp.net",
        "first",
        "first_party_inline_composer",
        connection as never,
      );
      const second = await handleSendDirectMessage(
        "req-2",
        "12025550001@s.whatsapp.net",
        "second",
        "first_party_inline_composer",
        connection as never,
      );

      expect(first.error).toBeUndefined();
      expect(second.error?.code).toBe(-32022);
      expect(sendCount).toBe(1);
    } finally {
      Math.random = originalRandom;
    }
  });

  test("requires the first-party inline composer source", async () => {
    let sendCount = 0;
    const connection = {
      sendText: async () => {
        sendCount += 1;
        return { message_id: "msg-1" };
      },
    };

    const response = await handleSendDirectMessage(
      "req-1",
      "12025550001@s.whatsapp.net",
      "hello directly",
      "mcp_or_unknown",
      connection as never,
    );

    expect(response.error?.code).toBe(-32602);
    expect(response.error?.message).toContain("first_party_inline_composer");
    expect(sendCount).toBe(0);
    expect(recentSends()).toHaveLength(0);
  });

  test("sends a direct reaction through the connection using cached target key", async () => {
    insertMessage({
      message_id: "target-1",
      thread_jid: "group@g.us",
      sender_jid: "12025550009@s.whatsapp.net",
      from_me: false,
      ts: 1,
      body: "hello group",
      message_type: "text",
      source: "live",
    });
    const calls: Array<{ jid: string; emoji: string; key: unknown }> = [];
    const connection = {
      sendReaction: async (jid: string, emoji: string, key: unknown) => {
        calls.push({ jid, emoji, key });
        return { message_id: "reaction-send-1" };
      },
    };

    const originalRandom = Math.random;
    Math.random = () => 0;
    try {
      const response = await handleSendDirectReaction(
        "req-reaction",
        "group@g.us",
        "target-1",
        "🔥",
        "first_party_message_tab",
        connection as never,
      );

      expect(response.error).toBeUndefined();
      expect(response.result).toMatchObject({
        ok: true,
        message_id: "reaction-send-1",
        reacted_to_message_id: "target-1",
      });
      expect(calls).toEqual([{
        jid: "group@g.us",
        emoji: "🔥",
        key: {
          remoteJid: "group@g.us",
          id: "target-1",
          fromMe: false,
          participant: "12025550009@s.whatsapp.net",
        },
      }]);
      expect(recentSends()[0]!.draft_id.startsWith("direct-reaction-")).toBe(true);
      expect(recentSends()[0]!.body_sha256).toHaveLength(64);
    } finally {
      Math.random = originalRandom;
    }
  });

  test("direct reaction requires Messages-tab source and cached target", async () => {
    let sendCount = 0;
    const connection = {
      sendReaction: async () => {
        sendCount += 1;
        return { message_id: "reaction-send-1" };
      },
    };

    const badSource = await handleSendDirectReaction(
      "req-bad-source",
      "group@g.us",
      "target-1",
      "🔥",
      "mcp_or_unknown",
      connection as never,
    );
    const missingTarget = await handleSendDirectReaction(
      "req-missing",
      "group@g.us",
      "target-1",
      "🔥",
      "first_party_message_tab",
      connection as never,
    );

    expect(badSource.error?.code).toBe(-32602);
    expect(missingTarget.error?.code).toBe(-32029);
    expect(sendCount).toBe(0);
  });

  test("remote kill switch blocks direct sends before reservation or connection send", async () => {
    let sendCount = 0;
    const connection = {
      sendText: async () => {
        sendCount += 1;
        return { message_id: "msg-1" };
      },
    };
    writeManifest({
      schema: 1,
      kill: { scope: "whatsapp", reason: "maintenance" },
      issued_at: new Date().toISOString(),
    });

    const response = await handleSendDirectMessage(
      "req-1",
      "12025550001@s.whatsapp.net",
      "hello directly",
      "first_party_inline_composer",
      connection as never,
    );

    expect(response.error?.code).toBe(-32028);
    expect(response.error?.message).toContain("maintenance");
    expect(sendCount).toBe(0);
    expect(recentSends()).toHaveLength(0);
  });

  test("unknown reservation errors return a safe send failure", () => {
    const response = mapReservationError("req-1", {
      ok: false,
      error: "FUTURE_SEND_ERROR",
      detail: "unexpected future limiter",
    } as never);

    expect(response.error?.code).toBe(-32025);
    expect(response.error?.message).toBe("send reservation failed");
  });

  test("MCP tools do not expose the direct send RPC", () => {
    const tools = readFileSync(join(import.meta.dir, "..", "tools", "drafts.ts"), "utf8");

    expect(tools).not.toContain("sendDirectMessage");
    expect(tools).not.toContain("sendReaction");
    expect(tools).not.toContain("send_direct");
  });
});
