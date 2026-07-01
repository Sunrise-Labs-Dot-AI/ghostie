import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readCallHistory } from "./callhistory.ts";

let dir: string;
let dbPath: string;
const CORE = 978_307_200; // Core Data epoch (2001-01-01 UTC, seconds)

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "bday-calls-"));
  dbPath = join(dir, "CallHistory.storedata");
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

function buildCallDb(rows: Array<{ addr: string | null; iso: string }>): void {
  const db = new Database(dbPath);
  db.exec(`CREATE TABLE ZCALLRECORD (Z_PK INTEGER PRIMARY KEY, ZADDRESS TEXT, ZDATE REAL);`);
  for (const r of rows) {
    db.run(`INSERT INTO ZCALLRECORD (ZADDRESS, ZDATE) VALUES (?, ?)`, [
      r.addr,
      Date.parse(r.iso) / 1000 - CORE,
    ]);
  }
  db.close();
}

describe("readCallHistory", () => {
  test("aggregates count + last per canonical handle, canonicalizing formatted numbers", () => {
    buildCallDb([
      { addr: "+1 (404) 555-0147", iso: "2026-01-01T10:00:00Z" },
      { addr: "+14045550147", iso: "2026-03-01T10:00:00Z" },
      { addr: "mom@example.com", iso: "2026-02-01T10:00:00Z" },
      { addr: null, iso: "2026-02-01T10:00:00Z" }, // ignored
    ]);
    const m = readCallHistory(dbPath);
    // Both phone formats canonicalize to the same 10-digit tail → merged.
    expect(m.get("4045550147")!.count).toBe(2);
    expect(m.get("4045550147")!.lastMs).toBe(Date.parse("2026-03-01T10:00:00Z"));
    expect(m.get("avery@example.com" /* not present */)).toBeUndefined();
    expect(m.get("mom@example.com")!.count).toBe(1);
  });

  test("missing DB → empty map (graceful)", () => {
    expect(readCallHistory(join(dir, "nope.storedata")).size).toBe(0);
  });

  test("DB without ZCALLRECORD → empty map (schema differs)", () => {
    const db = new Database(dbPath);
    db.exec(`CREATE TABLE SOMETHING_ELSE (x INTEGER);`);
    db.close();
    expect(readCallHistory(dbPath).size).toBe(0);
  });
});
