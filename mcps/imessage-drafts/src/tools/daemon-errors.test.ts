import { describe, expect, test } from "bun:test";

import { DaemonRpcError, DaemonUnavailableError } from "../daemon/rpc-client.ts";
import {
  daemonBlockedMessage,
  isDaemonBlockedError,
  mapDaemonDependentToolError,
} from "./_daemon-errors.ts";

describe("daemon-dependent iMessage tool errors", () => {
  test("socket-unavailable errors are blocked, not generic failures", () => {
    const message = mapDaemonDependentToolError(new DaemonUnavailableError(), "list_threads failed");

    expect(message).toBe(daemonBlockedMessage());
    expect(message.startsWith("blocked: iMessage daemon is down")).toBe(true);
  });

  test("request timeouts are treated as blocked daemon dependency failures", () => {
    const error = new Error("Daemon RPC listThreads timed out after 10000ms");

    expect(isDaemonBlockedError(error)).toBe(true);
    expect(mapDaemonDependentToolError(error, "list_threads failed")).toBe(daemonBlockedMessage());
  });

  test("daemon RPC errors remain daemon errors", () => {
    expect(mapDaemonDependentToolError(new DaemonRpcError(-32602, "bad params"), "get_thread failed"))
      .toBe("daemon error (-32602): bad params");
  });

  test("ordinary errors keep the tool prefix", () => {
    expect(mapDaemonDependentToolError(new Error("boom"), "search_messages failed"))
      .toBe("search_messages failed: boom");
  });
});
