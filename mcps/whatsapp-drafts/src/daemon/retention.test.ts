import { describe, expect, test } from "bun:test";
import { runDraftRetentionSweep, runMessageRetentionSweep } from "./server.ts";

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

describe("draft retention sweep", () => {
  test("uses draft_ttl_days and returns orphan/sent cleanup counts", () => {
    let received = 0;
    const result = runDraftRetentionSweep(
      { draft_ttl_days: 7 },
      (ttlDays) => {
        received = ttlDays;
        return { deleted: 2, kept: 3, orphaned_attachments: 4 };
      },
    );

    expect(received).toBe(7);
    expect(result).toEqual({ deleted: 2, kept: 3, orphaned_attachments: 4 });
  });
});
