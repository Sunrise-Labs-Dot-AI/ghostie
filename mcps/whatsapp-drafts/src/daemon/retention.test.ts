import { describe, expect, test } from "bun:test";
import { runMessageRetentionSweep } from "./server.ts";

describe("message retention sweep", () => {
  test("uses message_retention_days to compute retention milliseconds", () => {
    let received = 0;
    const deleted = runMessageRetentionSweep(
      { message_retention_days: 90 },
      (retentionMs) => {
        received = retentionMs;
        return 12;
      },
    );

    expect(deleted).toBe(12);
    expect(received).toBe(90 * 24 * 60 * 60 * 1000);
  });
});
