import { describe, test, expect } from "bun:test";
import { z } from "zod";
import {
  ListThreadsShape,
  GetThreadShape,
  SearchShape,
  StageDraftShape,
  ProposeMessageAutomationShape,
  GetTextingVoiceShape,
  requireSinceOrContactFilter,
} from "./schema.ts";

const ListThreads = z.object(ListThreadsShape);
const GetThread = z.object(GetThreadShape);
const Search = z.object(SearchShape);
const StageDraft = z.object(StageDraftShape);
const ProposeMessageAutomation = z.object(ProposeMessageAutomationShape);
const GetTextingVoice = z.object(GetTextingVoiceShape);

describe("ListThreadsShape", () => {
  test("accepts a valid since within 2 years", () => {
    const r = ListThreads.safeParse({ since: new Date().toISOString(), limit: 25 });
    expect(r.success).toBe(true);
  });

  test("rejects since older than 2 years", () => {
    const r = ListThreads.safeParse({ since: "2020-01-01T00:00:00Z" });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues.some((i) => i.message.includes("2 years"))).toBe(true);
    }
  });

  test("rejects contact_filter shorter than 2 chars", () => {
    const r = ListThreads.safeParse({ contact_filter: "x" });
    expect(r.success).toBe(false);
  });

  test("accepts before parameter", () => {
    const r = ListThreads.safeParse({ before: "2026-05-01T00:00:00Z", since: new Date().toISOString() });
    expect(r.success).toBe(true);
  });

  test("limit clamped to [1, 100]", () => {
    expect(ListThreads.safeParse({ limit: 0, since: new Date().toISOString() }).success).toBe(false);
    expect(ListThreads.safeParse({ limit: 101, since: new Date().toISOString() }).success).toBe(false);
    expect(ListThreads.safeParse({ limit: 100, since: new Date().toISOString() }).success).toBe(true);
  });
});

describe("requireSinceOrContactFilter", () => {
  test("rejects when both are missing", () => {
    expect(requireSinceOrContactFilter({})).not.toBeNull();
  });

  test("accepts when since is present", () => {
    expect(requireSinceOrContactFilter({ since: "2026-05-01T00:00:00Z" })).toBeNull();
  });

  test("accepts when contact_filter is present", () => {
    expect(requireSinceOrContactFilter({ contact_filter: "Fairfax" })).toBeNull();
  });

  test("accepts when both are present", () => {
    expect(requireSinceOrContactFilter({ since: "2026-05-01T00:00:00Z", contact_filter: "Fairfax" })).toBeNull();
  });
});

describe("SearchShape", () => {
  test("rejects query under 2 chars", () => {
    const r = Search.safeParse({ query: "a", since: new Date().toISOString() });
    expect(r.success).toBe(false);
  });

  test("accepts query of exactly 2 chars", () => {
    const r = Search.safeParse({ query: "ok", since: new Date().toISOString() });
    expect(r.success).toBe(true);
  });
});

describe("GetThreadShape", () => {
  test("requires positive thread_id", () => {
    expect(GetThread.safeParse({ thread_id: 0 }).success).toBe(false);
    expect(GetThread.safeParse({ thread_id: -1 }).success).toBe(false);
    expect(GetThread.safeParse({ thread_id: 1 }).success).toBe(true);
  });

  test("limit max 200", () => {
    expect(GetThread.safeParse({ thread_id: 1, limit: 201 }).success).toBe(false);
    expect(GetThread.safeParse({ thread_id: 1, limit: 200 }).success).toBe(true);
  });
});

describe("StageDraftShape", () => {
  test("accepts an email handle", () => {
    expect(StageDraft.safeParse({ to_handle: "friend@example.com", body: "hi" }).success).toBe(true);
  });

  test("accepts a phone handle", () => {
    expect(StageDraft.safeParse({ to_handle: "+14155551234", body: "hi" }).success).toBe(true);
  });

  test("rejects nonsense handles", () => {
    expect(StageDraft.safeParse({ to_handle: "not an address", body: "hi" }).success).toBe(false);
  });

  test("accepts empty body at the schema level (attachment-only is valid; the tool enforces body-or-attachment)", () => {
    expect(StageDraft.safeParse({ to_handle: "+14155551234", body: "" }).success).toBe(true);
  });

  test("accepts a draft with attachments", () => {
    const r = StageDraft.safeParse({
      to_handle: "+14155551234",
      body: "",
      attachments: [{ path: "/tmp/photo.jpg", mime_type: "image/jpeg" }],
    });
    expect(r.success).toBe(true);
  });

  test("rejects more than 10 attachments", () => {
    const attachments = Array.from({ length: 11 }, (_, i) => ({ path: `/tmp/f${i}.jpg` }));
    expect(StageDraft.safeParse({ to_handle: "+14155551234", body: "hi", attachments }).success).toBe(false);
  });

  test("rejects body over 20 KB", () => {
    expect(StageDraft.safeParse({ to_handle: "+14155551234", body: "x".repeat(20_001) }).success).toBe(false);
  });
});

describe("ProposeMessageAutomationShape", () => {
  test("accepts a weekly iMessage automation proposal", () => {
    const r = ProposeMessageAutomation.safeParse({
      to_handle: "+14155551234",
      body: "Hope your Friday is good",
      cadence: "weekly",
      first_send_at: "2026-06-05T17:00:00Z",
    });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.platform).toBe("imessage");
  });

  test("accepts a WhatsApp JID", () => {
    const r = ProposeMessageAutomation.safeParse({
      platform: "whatsapp",
      to_handle: "14155551234@s.whatsapp.net",
      body: "hi",
      cadence: "monthly",
      first_send_at: "2026-06-05T17:00:00Z",
    });
    expect(r.success).toBe(true);
  });

  test("rejects invalid cadence and invalid date", () => {
    expect(ProposeMessageAutomation.safeParse({
      to_handle: "+14155551234",
      body: "hi",
      cadence: "hourly",
      first_send_at: "2026-06-05T17:00:00Z",
    }).success).toBe(false);
    expect(ProposeMessageAutomation.safeParse({
      to_handle: "+14155551234",
      body: "hi",
      cadence: "weekly",
      first_send_at: "friday-ish",
    }).success).toBe(false);
  });
});

describe("GetTextingVoiceShape", () => {
  test("defaults to the base profile", () => {
    const r = GetTextingVoice.parse({});
    expect(r.profile).toBe("base");
  });

  test("rejects path-like profile ids", () => {
    expect(GetTextingVoice.safeParse({ profile: "../base" }).success).toBe(false);
    expect(GetTextingVoice.safeParse({ profile: "base/other" }).success).toBe(false);
  });
});
