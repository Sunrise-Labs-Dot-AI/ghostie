/**
 * Application heartbeat for the Mac's relay connection. The relay pings at the WebSocket layer, but
 * the Mac has no way to see those, so after a silent path death (sleep, NAT reset, Wi-Fi change) it
 * would keep reporting Online until the operating system noticed hours later. Sending a small frame
 * on a schedule and expecting its echo bounds that to seconds.
 */
export interface HeartbeatOptions {
  /** Send one heartbeat frame carrying this sequence number. */
  send: (sequence: number) => void;
  /** The connection missed an echo; the caller should drop it and reconnect. */
  dead: () => void;
  intervalMs?: number;
  timeoutMs?: number;
}
export interface Heartbeat {
  start(): void;
  stop(): void;
  /** Feed every incoming frame's heartbeat field; returns true when it was an awaited echo. */
  echo(sequence: unknown): boolean;
}
export const HEARTBEAT_INTERVAL_MS = 15_000;
export const HEARTBEAT_TIMEOUT_MS = 10_000;

export function createHeartbeat(options: HeartbeatOptions): Heartbeat {
  const interval = options.intervalMs ?? HEARTBEAT_INTERVAL_MS;
  const timeout = options.timeoutMs ?? HEARTBEAT_TIMEOUT_MS;
  let sequence = 0;
  let awaiting: number | undefined;
  let ticker: ReturnType<typeof setInterval> | undefined;
  let deadline: ReturnType<typeof setTimeout> | undefined;
  let running = false;
  const stop = () => {
    running = false;
    if (ticker) clearInterval(ticker);
    if (deadline) clearTimeout(deadline);
    ticker = undefined; deadline = undefined; awaiting = undefined;
  };
  const tick = () => {
    if (!running || awaiting !== undefined) return; // still waiting on the previous echo; its deadline decides
    awaiting = ++sequence;
    deadline = setTimeout(() => { if (!running) return; stop(); options.dead(); }, timeout);
    try { options.send(awaiting); } catch { stop(); options.dead(); }
  };
  return {
    start() { if (running) return; running = true; ticker = setInterval(tick, interval); },
    stop,
    echo(value) {
      if (!running || awaiting === undefined || value !== awaiting) return false;
      if (deadline) clearTimeout(deadline);
      deadline = undefined; awaiting = undefined;
      return true;
    },
  };
}
