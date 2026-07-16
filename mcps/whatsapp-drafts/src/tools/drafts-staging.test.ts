import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const tmp = mkdtempSync(join(tmpdir(), "whatsapp-stage-media-"));
process.env.WHATSAPP_MCP_HOME = tmp;

const { DaemonUnavailableError } = await import("../daemon/rpc-client.ts");
const { stageWhatsAppDraft } = await import("./drafts.ts");

function snapshots(): string[] {
  const root = join(tmp, "draft-attachments");
  return existsSync(root) ? readdirSync(root) : [];
}

beforeEach(() => {
  rmSync(join(tmp, "draft-attachments"), { recursive: true, force: true });
});

afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

describe("stageWhatsAppDraft media ownership", () => {
  test("cleans a snapshot when connection failed before request handoff", async () => {
    const source = join(tmp, "offline.jpg");
    writeFileSync(source, Buffer.from([0xff, 0xd8, 0xff, 0x11]));

    await expect(stageWhatsAppDraft(
      { to_handle: "12025550001@s.whatsapp.net", body: "photo", attachments: [{ path: source }] },
      async <T>() => { throw new DaemonUnavailableError("offline", false); },
    )).rejects.toBeInstanceOf(DaemonUnavailableError);

    expect(snapshots()).toEqual([]);
  });

  test("retains an ambiguous post-write snapshot for the daemon orphan sweep", async () => {
    const source = join(tmp, "ambiguous.jpg");
    writeFileSync(source, Buffer.from([0xff, 0xd8, 0xff, 0x22]));

    await expect(stageWhatsAppDraft(
      { to_handle: "12025550001@s.whatsapp.net", body: "photo", attachments: [{ path: source }] },
      async <T>() => { throw new DaemonUnavailableError("closed after write", true); },
    )).rejects.toBeInstanceOf(DaemonUnavailableError);

    expect(snapshots()).toHaveLength(1);
  });
});
