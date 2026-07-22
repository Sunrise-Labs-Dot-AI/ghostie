// SUN-613 phase 0. The TypeScript half of the executor gate.
//
// This rule has to agree with `Draft.executorRefusal` in Swift byte-for-byte:
// the two live in different languages and different processes but decide the
// same question about the same file. A divergence here is a duplicate send.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  executorRefusal,
  isValidDeviceId,
  localDeviceId,
  resetDeviceIdCacheForTesting,
} from "../../shared/src/device-id.ts";

let root: string;
let previousHome: string | undefined;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ghostie-device-id-"));
  previousHome = process.env.MESSAGES_MCP_HOME;
  process.env.MESSAGES_MCP_HOME = root;
  resetDeviceIdCacheForTesting();
});

afterEach(() => {
  if (previousHome === undefined) delete process.env.MESSAGES_MCP_HOME;
  else process.env.MESSAGES_MCP_HOME = previousHome;
  resetDeviceIdCacheForTesting();
  rmSync(root, { recursive: true, force: true });
});

describe("executorRefusal", () => {
  test("an unstamped draft is allowed", () => {
    // Every draft that exists today. Phase 0 must be a no-op without the relay.
    expect(executorRefusal(null, "device-aaaaaaaa")).toBeNull();
    expect(executorRefusal(undefined, "device-aaaaaaaa")).toBeNull();
  });

  test("a present but malformed stamp is REFUSED, not treated as unstamped", () => {
    // Only absent / JSON null mean "unrouted". Guessing that corrupt routing
    // data means "anyone may send" is the fail-open direction, and it is what
    // the first version of this function did. (Second-lane review, finding 6.)
    expect(executorRefusal("", "device-aaaaaaaa")).toContain("WRONG_EXECUTOR");
    expect(executorRefusal("   ", "device-aaaaaaaa")).toContain("WRONG_EXECUTOR");
    expect(executorRefusal("has spaces", "device-aaaaaaaa")).toContain("WRONG_EXECUTOR");
    expect(executorRefusal("a".repeat(65), "device-aaaaaaaa")).toContain("WRONG_EXECUTOR");
  });

  test("whitespace padding around a valid stamp still matches", () => {
    expect(executorRefusal(" device-aaaaaaaa ", "device-aaaaaaaa")).toBeNull();
  });

  test("a matching stamp is allowed", () => {
    expect(executorRefusal("device-aaaaaaaa", "device-aaaaaaaa")).toBeNull();
  });

  test("a foreign stamp is refused with WRONG_EXECUTOR", () => {
    const refusal = executorRefusal("device-bbbbbbbb", "device-aaaaaaaa");
    expect(refusal).toContain("WRONG_EXECUTOR");
    expect(refusal).toContain("device-bbbbbbbb");
  });

  test("an unreadable local id fails CLOSED", () => {
    // The load-bearing case. "I can't prove I own this" must never resolve to
    // "so I'll send it".
    expect(executorRefusal("device-bbbbbbbb", null)).toContain("WRONG_EXECUTOR");
  });

  test("a malformed local id cannot match a malformed stamp", () => {
    expect(executorRefusal("../../etc/passwd", "../../etc/passwd")).toContain("WRONG_EXECUTOR");
  });

  test("a non-string stamp FAILS CLOSED", () => {
    // `"relay_executor": 42` previously coerced to "" and was allowed on both
    // MCP paths while Swift refused the same file — a divergence between the
    // two gates is a duplicate send. (Second-lane review, finding 6.)
    expect(executorRefusal(42, "device-aaaaaaaa")).toContain("WRONG_EXECUTOR");
    expect(executorRefusal({}, "device-aaaaaaaa")).toContain("WRONG_EXECUTOR");
    expect(executorRefusal(true, "device-aaaaaaaa")).toContain("WRONG_EXECUTOR");
    // ...but absent and explicit null remain the legacy unrouted shape.
    expect(executorRefusal(undefined, "device-aaaaaaaa")).toBeNull();
    expect(executorRefusal(null, "device-aaaaaaaa")).toBeNull();
  });
});

describe("isValidDeviceId", () => {
  test("accepts a uuid, rejects paths, spaces, and out-of-range lengths", () => {
    expect(isValidDeviceId("A1B2C3D4-0000-1111-2222-333344445555")).toBe(true);
    expect(isValidDeviceId("short")).toBe(false);
    expect(isValidDeviceId("../../etc/passwd")).toBe(false);
    expect(isValidDeviceId("device id with spaces")).toBe(false);
    expect(isValidDeviceId("a".repeat(65))).toBe(false);
    expect(isValidDeviceId(null)).toBe(false);
  });
});

describe("localDeviceId", () => {
  test("creates device.json once and returns a stable id", () => {
    const first = localDeviceId();
    expect(first).not.toBeNull();
    expect(isValidDeviceId(first)).toBe(true);

    // A second process (cache cleared) must read the SAME id, or the Swift and
    // TS gates would disagree about ownership after a relaunch.
    resetDeviceIdCacheForTesting();
    expect(localDeviceId()).toBe(first!);

    const onDisk = JSON.parse(readFileSync(join(root, "device.json"), "utf8")) as {
      device_id: string;
      schema_version: number;
    };
    expect(onDisk.device_id).toBe(first!);
    expect(onDisk.schema_version).toBe(1);
  });

  test("reads an id written by the Swift side", () => {
    // Cross-language contract: the menu bar may have created this file first.
    mkdirSync(root, { recursive: true });
    writeFileSync(
      join(root, "device.json"),
      JSON.stringify({ schema_version: 1, device_id: "A1B2C3D4-0000-1111-2222-333344445555", label: "M4" }),
      // 0600 matters: the reader rejects any device.json with group/other
      // access, because a world-writable identity file is not ours to trust.
      { mode: 0o600 },
    );
    resetDeviceIdCacheForTesting();
    expect(localDeviceId()).toBe("A1B2C3D4-0000-1111-2222-333344445555");
  });

  test("a corrupt device.json yields no id, so stamped drafts fail closed", () => {
    writeFileSync(join(root, "device.json"), "{ not json", { mode: 0o600 });
    resetDeviceIdCacheForTesting();
    expect(localDeviceId()).toBeNull();
    expect(executorRefusal("device-bbbbbbbb", localDeviceId())).toContain("WRONG_EXECUTOR");
  });

  test("an out-of-alphabet device_id is rejected rather than trusted", () => {
    writeFileSync(
      join(root, "device.json"),
      JSON.stringify({ schema_version: 1, device_id: "../../etc/passwd" }),
      { mode: 0o600 },
    );
    resetDeviceIdCacheForTesting();
    expect(localDeviceId()).toBeNull();
  });
});

describe("device.json hardening", () => {
  test("a group/other-readable device.json is rejected", () => {
    // Second-lane review, finding 7: the identity file decides which drafts
    // this Mac may send, so a permissive one is not ours to trust.
    writeFileSync(
      join(root, "device.json"),
      JSON.stringify({ schema_version: 1, device_id: "A1B2C3D4-0000-1111-2222-333344445555" }),
      { mode: 0o644 },
    );
    resetDeviceIdCacheForTesting();
    expect(localDeviceId()).toBeNull();
  });

  test("a symlinked device.json is not followed", () => {
    // The attack: point device.json at a file containing ANOTHER Mac's id, and
    // this Mac starts answering for that Mac's drafts while the real one also
    // sends. O_NOFOLLOW is what stops it.
    const target = join(root, "attacker.json");
    writeFileSync(
      target,
      JSON.stringify({ schema_version: 1, device_id: "BBBBBBBB-0000-1111-2222-333344445555" }),
      { mode: 0o600 },
    );
    symlinkSync(target, join(root, "device.json"));
    resetDeviceIdCacheForTesting();
    expect(localDeviceId()).toBeNull();
  });

  test("a wrong schema_version is rejected rather than guessed at", () => {
    writeFileSync(
      join(root, "device.json"),
      JSON.stringify({ schema_version: 99, device_id: "A1B2C3D4-0000-1111-2222-333344445555" }),
      { mode: 0o600 },
    );
    resetDeviceIdCacheForTesting();
    expect(localDeviceId()).toBeNull();
  });

  test("creation leaves no stray temp files behind", () => {
    // Finding 8: publish is write-temp -> fsync -> link, so a crash cannot leave
    // an empty final file. Confirm the happy path cleans up after itself.
    expect(localDeviceId()).not.toBeNull();
    const leftovers = readdirSync(root).filter((f) => f.startsWith(".device.json."));
    expect(leftovers).toEqual([]);
  });
});
