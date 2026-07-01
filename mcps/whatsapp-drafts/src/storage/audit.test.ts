import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const tmp = mkdtempSync(join(tmpdir(), "whatsapp-mcp-audit-"));
process.env.WHATSAPP_MCP_HOME = tmp;

const { reserveSend, recentSends, getAuditDb, _resetForTesting, SEND_ERR } = await import("./audit.ts");
const { DEFAULT_SETTINGS } = await import("../settings.ts");

afterAll(() => {
  _resetForTesting();
  rmSync(tmp, { recursive: true, force: true });
});

beforeEach(() => {
  const db = getAuditDb();
  db.exec("DELETE FROM sends");
});

const args = (id: string, now: number) => ({
  draft_id: id,
  to_handle: "12025550001@s.whatsapp.net",
  body_sha256: "deadbeef".repeat(8),
  settings: DEFAULT_SETTINGS,
  now,
});

describe("audit.reserveSend", () => {
  test("first send always succeeds; commit('ok') updates status", () => {
    const r = reserveSend(args("d1", 1_700_000_000_000));
    expect(r.ok).toBe(true);
    if (r.ok) r.commit("ok");
    const rows = recentSends();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.status).toBe("ok");
    expect(rows[0]!.draft_id).toBe("d1");
  });

  test("inter-send guard blocks rapid second send", () => {
    const t0 = 1_700_000_000_000;
    const a = reserveSend(args("d1", t0));
    expect(a.ok).toBe(true);
    if (a.ok) a.commit("ok");

    const b = reserveSend(args("d2", t0 + 500)); // 500ms < default 2000ms
    expect(b.ok).toBe(false);
    if (!b.ok) expect(b.error).toBe(SEND_ERR.INTER_SEND_TOO_FAST);
  });

  test("inter-send guard allows send after min delay", () => {
    const t0 = 1_700_000_000_000;
    const a = reserveSend(args("d1", t0));
    if (a.ok) a.commit("ok");

    const b = reserveSend(args("d2", t0 + 2500));
    expect(b.ok).toBe(true);
  });

  test("burst guard caps at max_burst_in_60s", () => {
    // Default max_burst_in_60s = 5. Insert 5 in a row spaced > min_inter_send_ms apart.
    const t0 = 1_700_000_000_000;
    for (let i = 0; i < 5; i++) {
      const r = reserveSend(args(`d${i}`, t0 + i * 3000));
      expect(r.ok).toBe(true);
      if (r.ok) r.commit("ok");
    }
    // 6th send within the 60s window should fail.
    const r6 = reserveSend(args("d6", t0 + 5 * 3000 + 3000));
    expect(r6.ok).toBe(false);
    if (!r6.ok) expect(r6.error).toBe(SEND_ERR.BURST_LIMIT_HIT);
  });

  test("daily-cap guard at 50 sends", () => {
    const t0 = 1_700_000_000_000;
    // Use a settings override with relaxed inter-send + burst limits.
    const lax = {
      ...DEFAULT_SETTINGS,
      min_inter_send_ms: 0,
      max_burst_in_60s: 10_000,
      daily_cap: 50,
    };
    for (let i = 0; i < 50; i++) {
      const r = reserveSend({ ...args(`d${i}`, t0 + i), settings: lax });
      expect(r.ok).toBe(true);
      if (r.ok) r.commit("ok");
    }
    const r = reserveSend({ ...args("d50", t0 + 51), settings: lax });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toBe(SEND_ERR.DAILY_CAP_HIT);
  });

  test("failed-send rows still consume cap (retry-storm defense)", () => {
    const t0 = 1_700_000_000_000;
    const lax = { ...DEFAULT_SETTINGS, min_inter_send_ms: 0, max_burst_in_60s: 10_000, daily_cap: 2 };
    const a = reserveSend({ ...args("d1", t0), settings: lax });
    if (a.ok) a.commit("send_failed");
    const b = reserveSend({ ...args("d2", t0 + 1), settings: lax });
    if (b.ok) b.commit("send_failed");
    // Both rows count toward cap → 3rd refused.
    const c = reserveSend({ ...args("d3", t0 + 2), settings: lax });
    expect(c.ok).toBe(false);
    if (!c.ok) expect(c.error).toBe(SEND_ERR.DAILY_CAP_HIT);
  });

  test("daily-cap rolls over at UTC midnight", () => {
    const t0 = new Date("2026-05-15T22:00:00Z").getTime();
    const t1 = new Date("2026-05-16T01:00:00Z").getTime(); // next UTC day
    const lax = { ...DEFAULT_SETTINGS, min_inter_send_ms: 0, max_burst_in_60s: 10_000, daily_cap: 1 };

    const a = reserveSend({ ...args("d1", t0), settings: lax });
    expect(a.ok).toBe(true);
    if (a.ok) a.commit("ok");

    const b = reserveSend({ ...args("d2", t0 + 1000), settings: lax });
    expect(b.ok).toBe(false); // still same UTC day

    const c = reserveSend({ ...args("d3", t1), settings: lax });
    expect(c.ok).toBe(true); // new UTC day, cap reset
  });
});
