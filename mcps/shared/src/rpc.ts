export type JsonRpcId = string | number | null;

export interface RpcRequest {
  jsonrpc: "2.0";
  id?: JsonRpcId;
  method: string;
  params?: unknown;
}

export interface RpcResponse {
  jsonrpc: "2.0";
  id: JsonRpcId;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export interface RpcServer {
  stop(): Promise<void>;
}

export function rpcOk(id: JsonRpcId, result: unknown): RpcResponse {
  return { jsonrpc: "2.0", id, result };
}

export function rpcErr(id: JsonRpcId, code: number, message: string, data?: unknown): RpcResponse {
  const error = data === undefined ? { code, message } : { code, message, data };
  return { jsonrpc: "2.0", id, error };
}

export function makeFrameReader(
  maxFrameBytes: number,
  onLine: (line: string) => void,
  onOverflow: () => void,
): { push(chunk: Buffer | Uint8Array | string): void } {
  const NL = 0x0a;
  let chunks: Buffer[] = [];
  let bufferedBytes = 0;
  let overflowed = false;

  function emitCompleteFrames(): void {
    if (chunks.length === 0) return;
    let buf = chunks.length === 1 ? chunks[0]! : Buffer.concat(chunks, bufferedBytes);
    let nl: number;
    let consumedAny = false;
    while ((nl = buf.indexOf(NL)) >= 0) {
      const lineBuf = buf.subarray(0, nl);
      buf = buf.subarray(nl + 1);
      consumedAny = true;
      const line = lineBuf.toString("utf8");
      if (line.trim().length === 0) continue;
      onLine(line);
    }
    if (consumedAny) {
      chunks = buf.byteLength > 0 ? [Buffer.from(buf)] : [];
      bufferedBytes = buf.byteLength;
    }
  }

  return {
    push(chunk: Buffer | Uint8Array | string) {
      if (overflowed) return;
      const b = Buffer.isBuffer(chunk)
        ? chunk
        : typeof chunk === "string"
          ? Buffer.from(chunk, "utf8")
          : Buffer.from(chunk);
      if (bufferedBytes + b.byteLength > maxFrameBytes) {
        overflowed = true;
        chunks = [];
        bufferedBytes = 0;
        onOverflow();
        return;
      }
      chunks.push(b);
      bufferedBytes += b.byteLength;
      emitCompleteFrames();
    },
  };
}
