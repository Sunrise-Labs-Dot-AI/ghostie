import { Socket } from "node:net";

import { makeFrameReader, type RpcResponse } from "./rpc.ts";

export class DaemonUnavailableError extends Error {
  constructor(
    message: string = "daemon unavailable",
    /** False only when the client knows no request bytes reached the daemon. */
    public requestMayHaveBeenSent: boolean = false,
  ) {
    super(message);
    this.name = "DaemonUnavailableError";
  }
}

export class DaemonRpcError extends Error {
  constructor(public code: number, message: string) {
    super(message);
  }
}

export interface DaemonCallerOptions {
  socketPath: () => string;
  unavailableMessage: string;
  connectTimeoutMs?: number;
  requestTimeoutMs?: number;
  maxResponseFrameBytes?: number;
}

export function createDaemonCaller(options: DaemonCallerOptions) {
  const connectTimeoutMs = options.connectTimeoutMs ?? 2000;
  const requestTimeoutMs = options.requestTimeoutMs ?? 10_000;
  const maxResponseFrameBytes = options.maxResponseFrameBytes ?? 10_000_000;

  function connectWithTimeout(): Promise<Socket> {
    return new Promise((resolve, reject) => {
      const sock = new Socket();
      const unavailable = () => new DaemonUnavailableError(options.unavailableMessage);
      const timer = setTimeout(() => {
        sock.destroy();
        reject(unavailable());
      }, connectTimeoutMs);
      sock.once("connect", () => { clearTimeout(timer); resolve(sock); });
      sock.once("error", () => { clearTimeout(timer); reject(unavailable()); });
      sock.connect(options.socketPath());
    });
  }

  return async function callDaemon<T>(method: string, params?: unknown): Promise<T> {
    const sock = await connectWithTimeout();
    const id = Math.floor(Math.random() * 1e9);
    const req = { jsonrpc: "2.0" as const, id, method, params };

    return new Promise<T>((resolve, reject) => {
      let settled = false;
      // Declare timer before done to avoid a forward-reference in the closure.
      let timer: ReturnType<typeof setTimeout> | undefined;
      const done = (fn: () => void) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        fn();
      };

      timer = setTimeout(() => done(() => {
        sock.destroy();
        reject(new Error(`Daemon RPC ${method} timed out after ${requestTimeoutMs}ms`));
      }), requestTimeoutMs);

      const reader = makeFrameReader(
        maxResponseFrameBytes,
        (line) => {
          let resp: RpcResponse;
          try { resp = JSON.parse(line) as RpcResponse; } catch { return; }
          if (resp.id == null) {
            if (resp.error != null) {
              // id:null + error = peer-auth rejection. Fail immediately rather than
              // waiting for the request timeout. Log the detail locally for
              // diagnostics but don't propagate paths/PIDs/identities to the caller.
              process.stderr.write(`[daemon-client] peer-auth rejection during ${method}: ${resp.error.message}\n`);
              done(() => {
                sock.destroy();
                reject(new DaemonUnavailableError("daemon rejected connection (peer-auth failed)", false));
              });
            }
            // id:null without error is a notification or protocol frame — ignore.
            return;
          }
          if (resp.id !== id) return;
          done(() => {
            sock.end();
            if (resp.error != null) {
              reject(new DaemonRpcError(resp.error.code, resp.error.message));
            } else {
              resolve(resp.result as T);
            }
          });
        },
        () => done(() => {
          sock.destroy();
          reject(new Error(`Daemon RPC ${method} response exceeded ${maxResponseFrameBytes} bytes`));
        }),
      );
      sock.on("data", (chunk: Buffer) => reader.push(chunk));
      sock.on("error", () => done(() => {
        sock.destroy();
        reject(new DaemonUnavailableError(
          `daemon connection failed after request handoff during ${method}`,
          true,
        ));
      }));
      sock.on("close", () => done(() => reject(new DaemonUnavailableError(
        `daemon closed connection unexpectedly during ${method}`,
        true,
      ))));
      sock.write(JSON.stringify(req) + "\n");
    });
  };
}
