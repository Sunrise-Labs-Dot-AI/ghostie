import { describe, expect, test } from "bun:test";

import { DaemonRpcError, DaemonUnavailableError } from "../daemon/rpc-client.ts";
import {
  daemonBlockedMessage,
  isDaemonBlockedError,
  mapDaemonDependentToolError,
} from "./_daemon-errors.ts";

describe("daemon-dependent WhatsApp tool errors", () => {
  test("socket-unavailable errors are blocked, not generic failures", () => {
    const message = mapDaemonDependentToolError(new DaemonUnavailableError());

    expect(message).toBe(daemonBlockedMessage());
    expect(message.startsWith("blocked: WhatsApp daemon is down")).toBe(true);
  });

  test("request timeouts are treated as blocked daemon dependency failures", () => {
    const error = new Error("Daemon RPC getThreads timed out after 10000ms");

    expect(isDaemonBlockedError(error)).toBe(true);
    expect(mapDaemonDependentToolError(error)).toBe(daemonBlockedMessage());
  });

  test("daemon RPC errors remain daemon errors", () => {
    expect(mapDaemonDependentToolError(new DaemonRpcError(-32602, "bad params")))
      .toBe("daemon error (-32602): bad params");
  });

  test("ordinary errors remain unexpected", () => {
    expect(mapDaemonDependentToolError(new Error("boom"))).toBe("unexpected error: boom");
  });
});
