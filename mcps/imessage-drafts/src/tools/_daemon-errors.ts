import { DaemonRpcError, DaemonUnavailableError } from "../daemon/rpc-client.ts";

export function daemonBlockedMessage(): string {
  return (
    "blocked: iMessage daemon is down or not responding. Open Messages for AI and wait for " +
    "iMessage status to show running, then retry. Tools that read iMessage " +
    "history or stage iMessage drafts are blocked while the daemon is unavailable."
  );
}

export function isDaemonBlockedError(e: unknown): boolean {
  if (e instanceof DaemonUnavailableError) return true;
  const message = (e as Error | undefined)?.message ?? "";
  return message.startsWith("Daemon RPC ") && message.includes(" timed out ");
}

export function mapDaemonDependentToolError(e: unknown, fallbackPrefix: string): string {
  if (isDaemonBlockedError(e)) return daemonBlockedMessage();
  if (e instanceof DaemonRpcError) return `daemon error (${e.code}): ${e.message}`;
  return `${fallbackPrefix}: ${(e as Error).message}`;
}
