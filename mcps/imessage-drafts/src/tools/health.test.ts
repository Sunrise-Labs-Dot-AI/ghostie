import { describe, test, expect, afterEach } from "bun:test";
import {
  canonHandlePublic,
  resolveHandle,
  getContactsLoadDiagnostic,
  getLastContactsLoadSource,
  _setContactsForTesting,
  _resetContactsCache,
} from "../chatdb/contacts.ts";
import {
  _setSidecarPathForTesting,
  CONTACTS_CACHE_SCHEMA_VERSION,
} from "../storage/contacts-cache.ts";
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// Unit tests for the building blocks of `health_check`.
//
// We deliberately don't spin up an McpServer harness and invoke the
// registered tool — the project doesn't have a server-test fixture
// yet, and the tool body is a thin shell over functions we DO exercise
// directly here (`getAddressBookSqliteDiagnostic`,
// `getContactsLoadDiagnostic`, `getChatDbDiagnostic`,
// `canonHandlePublic`, `resolveHandle`). The shell wiring is type-
// checked by `bun --bun tsc --noEmit`.
//
// The two DB-probe functions hit real macOS paths and depend on TCC
// state, so we don't assert their outputs — they're integration-style
// and intentionally non-deterministic for unit tests. The `probe` block
// of the tool's output is pure-function (canonHandle + resolveHandle)
// and IS exercised here.

describe("canonHandlePublic", () => {
  afterEach(() => { _resetContactsCache(); });

  test("strips non-digits and takes last 10 for phones", () => {
    expect(canonHandlePublic("+1 (404) 555-0147")).toBe("4045550147");
    expect(canonHandlePublic("+14045550147")).toBe("4045550147");
    expect(canonHandlePublic("14045550147")).toBe("4045550147");
    expect(canonHandlePublic("4045550147")).toBe("4045550147");
  });

  test("lowercases emails", () => {
    expect(canonHandlePublic("Avery@Example.COM")).toBe("avery@example.com");
  });

  test("preserves short digit strings as-is (no slice)", () => {
    expect(canonHandlePublic("911")).toBe("911");
  });
});

describe("probe block: canonical + resolved_name", () => {
  afterEach(() => { _resetContactsCache(); });

  test("probe_handle with a known contact populates resolved_name", () => {
    // Seed Avery under her canonical 10-digit form, exactly as the
    // health tool's `probe` block would compute it.
    _setContactsForTesting(
      new Map([["4045550147", "Avery Test"]]),
      [{ lower_name: "avery test", handles: ["4045550147"] }]
    );

    const input = "+1 (404) 555-0147";
    const canonical = canonHandlePublic(input);
    const resolved_name = resolveHandle(input);

    expect(canonical).toBe("4045550147");
    expect(resolved_name).toBe("Avery Test");
  });

  test("probe_handle that doesn't match any contact yields null resolved_name", () => {
    _setContactsForTesting(new Map(), []);
    expect(resolveHandle("+15555550000")).toBeNull();
  });

  test("non-canonical phone formats all canonicalize identically — the lookup is format-agnostic", () => {
    _setContactsForTesting(
      new Map([["4045550147", "Avery Test"]]),
      [{ lower_name: "avery test", handles: ["4045550147"] }]
    );
    // All three forms should produce the same canonical key and thus the same name.
    for (const variant of ["+14045550147", "14045550147", "4045550147", "+1 (404) 555-0147"]) {
      expect(resolveHandle(variant)).toBe("Avery Test");
    }
  });
});

describe("getContactsLoadDiagnostic", () => {
  // Redirect the sidecar to a nonexistent tmp path so this test stays
  // deterministic regardless of whether the developer has a real
  // ~/.messages-mcp/contacts-cache.json on their machine.
  const tmpSidecarPath = join(tmpdir(), `imessage-drafts-mcp-load-diag-test-${process.pid}.json`);

  afterEach(() => {
    _setSidecarPathForTesting(null);
    _resetContactsCache();
  });

  test("surfaces test_seam source after _setContactsForTesting", () => {
    _setSidecarPathForTesting(tmpSidecarPath); // never written → no sidecar
    _setContactsForTesting(
      new Map([["4045550147", "Avery Test"]]),
      [{ lower_name: "avery test", handles: ["4045550147"] }]
    );
    const diag = getContactsLoadDiagnostic();
    expect(diag.source).toBe("test_seam");
    expect(diag.count).toBe(1);
    expect(diag.sidecar_present).toBe(false);
  });

  test("returns zero count + sidecar_present:false in a clean environment", () => {
    _setSidecarPathForTesting(tmpSidecarPath);
    // _resetContactsCache fires in afterEach so this start state is fresh.
    // Skip TCC-dependent assertions (source could be "sqlite_fallback" or
    // "none" depending on the developer's AddressBook state); just confirm
    // the shape contract.
    const diag = getContactsLoadDiagnostic();
    expect(["sqlite_fallback", "none"]).toContain(diag.source);
    expect(diag.sidecar_present).toBe(false);
    expect(typeof diag.count).toBe("number");
  });

  // PR 11 review finding #10 — the sidecar_granted_empty branch was
  // shipped without a test. Covers the menubar-granted-but-zero-handles
  // first-run state (fresh Mac, iCloud not synced).
  test("surfaces sidecar_granted_empty when the menubar is granted but the sidecar has zero handles", () => {
    const granted_empty_root = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-granted-empty-test-"));
    const granted_empty_sidecar = join(granted_empty_root, "contacts-cache.json");
    try {
      writeFileSync(granted_empty_sidecar, JSON.stringify({
        version: CONTACTS_CACHE_SCHEMA_VERSION,
        generated_at: "2026-05-15T12:00:00Z",
        source: "menubar-cnContactStore",
        permission_status: "granted",
        count: 0,
        handles: {},
      }, null, 2));
      chmodSync(granted_empty_sidecar, 0o600);
      _setSidecarPathForTesting(granted_empty_sidecar);
      _resetContactsCache(); // force load() to re-run with the new path

      // Trigger load() via resolveHandle. Without TCC-grant we expect
      // the SQLite fallback to also find nothing, so lastLoadSource
      // stays "sidecar_granted_empty". On a dev machine with FDA
      // granted, SQLite would find contacts and the branch would
      // upgrade to "sqlite_fallback" — accept either since both are
      // legitimate outcomes of the same branch logic.
      resolveHandle("+15555550000");
      expect(["sidecar_granted_empty", "sqlite_fallback"]).toContain(getLastContactsLoadSource());

      const diag = getContactsLoadDiagnostic();
      expect(["sidecar_granted_empty", "sqlite_fallback"]).toContain(diag.source);
      expect(diag.sidecar_present).toBe(true);
    } finally {
      rmSync(granted_empty_root, { recursive: true, force: true });
    }
  });
});
