import { DaemonRpcError, DaemonUnavailableError } from "../daemon/rpc-client.ts";

export function daemonBlockedMessage(): string {
  return (
    "blocked: WhatsApp daemon is down or not responding. Open Messages for AI and wait for " +
    "WhatsApp status to show connected/running, then retry. WhatsApp tools " +
    "are blocked while the daemon is unavailable."
  );
}

export function isDaemonBlockedError(e: unknown): boolean {
  if (e instanceof DaemonUnavailableError) return true;
  const message = (e as Error | undefined)?.message ?? "";
  return message.startsWith("Daemon RPC ") && message.includes(" timed out ");
}

export function mapDaemonDependentToolError(e: unknown): string {
  if (isDaemonBlockedError(e)) return daemonBlockedMessage();
  if (e instanceof DaemonRpcError) return `daemon error (${e.code}): ${e.message}`;
  return `unexpected error: ${(e as Error).message}`;
}
