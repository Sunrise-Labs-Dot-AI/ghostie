#!/usr/bin/env bun
// Local QR pairing helper. Connects to a running whatsapp-daemon via its
// Unix socket, subscribes to the "qr" and "state" channels, and renders
// each QR to the terminal until the daemon reports `state: "connected"`.
//
// This is the local-testing analog of the menu bar app's QR sheet
// (Phase 3). The menu bar app will use the same subscribe contract.
//
// Usage:
//   1. Start daemon in another terminal:
//        WHATSAPP_MCP_DEV=1 bun run dev:daemon
//   2. Run:
//        WHATSAPP_MCP_DEV=1 bun run scripts/pair.ts
//   3. Scan the QR with WhatsApp → Settings → Linked Devices on your phone.
//   4. Script auto-exits on "connected".
//
// WHATSAPP_MCP_DEV=1 is required because peer-auth refuses unsigned
// callers in production mode. (See src/daemon/peer-auth.ts.)

import { connect, type Socket } from "node:net";
import { existsSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import qrcode from "qrcode";

import { PATHS } from "../src/paths.ts";

const PNG_PATH = join(tmpdir(), "whatsapp-mcp-pair.png");

const CONNECT_TIMEOUT_MS = 3000;

interface Notification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

interface RpcResponse {
  jsonrpc: "2.0";
  id: number | string | null;
  result?: unknown;
  error?: { code: number; message: string };
}

async function main() {
  if (!existsSync(PATHS.daemonSock)) {
    console.error(`Daemon socket not found at ${PATHS.daemonSock}.`);
    console.error("Is the daemon running? Start it with: WHATSAPP_MCP_DEV=1 bun run dev:daemon");
    process.exit(1);
  }

  const sock = await new Promise<Socket>((resolve, reject) => {
    const s = connect(PATHS.daemonSock);
    const timer = setTimeout(() => {
      s.destroy();
      reject(new Error(`Timed out connecting to daemon at ${PATHS.daemonSock}`));
    }, CONNECT_TIMEOUT_MS);
    s.once("connect", () => { clearTimeout(timer); resolve(s); });
    s.once("error", (err) => { clearTimeout(timer); reject(err); });
  });

  let nextId = 1;
  const pending = new Map<number, (resp: RpcResponse) => void>();
  let buf = "";
  let printedAnyQr = false;

  sock.on("data", (chunk) => {
    buf += chunk.toString("utf8");
    let nl: number;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (line.length === 0) continue;
      let msg: RpcResponse | Notification;
      try { msg = JSON.parse(line); } catch { continue; }
      if ("id" in msg && msg.id != null) {
        const handler = pending.get(msg.id as number);
        if (handler != null) { handler(msg as RpcResponse); pending.delete(msg.id as number); }
        continue;
      }
      // Notification path
      const note = msg as Notification;
      if (note.method === "qr.update") {
        const { qr } = note.params as { qr: string };
        renderQr(qr);
        printedAnyQr = true;
      } else if (note.method === "state.update") {
        const { state } = note.params as { state: string };
        if (state === "connected") {
          if (printedAnyQr) {
            console.log("\n✅ Paired! Daemon is connected to WhatsApp.");
          } else {
            console.log("✅ Already paired — daemon is connected.");
          }
          sock.end();
          process.exit(0);
        } else {
          console.error(`[state] ${state}`);
        }
      }
    }
  });

  sock.on("error", (err) => {
    console.error(`Socket error: ${err.message}`);
    process.exit(2);
  });
  sock.on("close", () => {
    if (!printedAnyQr) {
      console.error("Daemon closed the connection before a QR was issued.");
      process.exit(3);
    }
  });

  const call = <T>(method: string, params?: unknown): Promise<T> => {
    const id = nextId++;
    return new Promise<T>((resolve, reject) => {
      pending.set(id, (resp) => {
        if (resp.error) reject(new Error(`${method}: [${resp.error.code}] ${resp.error.message}`));
        else resolve(resp.result as T);
      });
      sock.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  };

  // Check initial state first; if already connected we exit immediately.
  const status = await call<{ state: string }>("getConnectionStatus");
  if (status.state === "connected") {
    console.log("✅ Already paired — daemon is connected.");
    sock.end();
    return;
  }

  console.log("Subscribing to QR + connection-state channels...");
  await call("subscribe", { channel: "qr" });
  await call("subscribe", { channel: "state" });
  printScanInstructions();
}

function printScanInstructions() {
  const line = "═".repeat(64);
  console.log(`\n${line}`);
  console.log("  HOW TO SCAN — this is NOT a URL, do NOT use Camera/Chrome");
  console.log(line);
  console.log("  1. On your iPhone, open the WhatsApp app");
  console.log("  2. Tap Settings (gear icon, bottom right)");
  console.log("  3. Tap 'Linked Devices'");
  console.log("  4. Tap 'Link a Device' (Face ID auth)");
  console.log("  5. Point WhatsApp's camera at the QR code below");
  console.log(`${line}\n`);
  console.log("Waiting for daemon to push a QR...\n");
}

let firstQr = true;

function renderQr(qr: string) {
  // Terminal render (works on most setups but terminal QRs can be
  // distorted by font/spacing and small density).
  qrcode.toString(qr, { type: "terminal", small: true }, (err, str) => {
    if (err != null) {
      console.error(`qrcode error: ${err.message}`);
      return;
    }
    console.log("─".repeat(60));
    console.log(str);
    console.log("─".repeat(60));
  });

  // PNG render — high resolution, auto-opens in Preview on macOS the
  // first time. Subsequent QRs overwrite the same file so Preview just
  // refreshes the image rather than spawning new windows.
  qrcode.toFile(PNG_PATH, qr, { width: 600, margin: 2 }, (pngErr) => {
    if (pngErr != null) {
      console.error(`PNG render error: ${pngErr.message}`);
      return;
    }
    if (firstQr) {
      firstQr = false;
      try {
        Bun.spawn({ cmd: ["open", PNG_PATH], stdout: "ignore", stderr: "ignore" });
        console.log(`(opened ${PNG_PATH} in Preview — easier to scan than the terminal QR)`);
      } catch {
        console.log(`(saved high-res QR to ${PNG_PATH})`);
      }
    } else {
      // Subsequent QRs: just announce the file refreshed.
      console.log(`(refreshed ${PNG_PATH})`);
    }
  });
  console.log("scan within ~20s; daemon will push a fresh QR if this one expires");
}

main().catch((err) => {
  console.error(`Pair failed: ${(err as Error).message}`);
  process.exit(1);
});
