import { describe, expect, test } from "bun:test";
import { canonicalDraftPayloadBytes, draftPayloadDigest } from "../../shared/src/draft-payload.ts";

describe("canonical draft payload v1", () => {
  const vector = {
    id: "draft-🌅-42",
    platform: "whatsapp" as const,
    to_handle: "12025550123@s.whatsapp.net",
    body: "Photo 👻 | café",
    quoted_message_id: "quote-π",
    scheduled_send_at: "2026-07-16T18:30:00Z",
    attachments: [{
      asset_id: "asset-α",
      path: "/tmp/.whatsapp-mcp/draft-attachments/draft-🌅-42/photo one.jpg",
      filename: "photo one.jpg",
      mime_type: "image/jpeg",
      byte_count: 12345,
      sha256: "a".repeat(64),
    }, {
      asset_id: "asset-2",
      path: "/tmp/.whatsapp-mcp/draft-attachments/draft-🌅-42/résumé.pdf",
      filename: "",
      mime_type: "application/pdf",
      byte_count: -1,
      sha256: "b".repeat(64),
    }],
  };

  test("pins the cross-language encoding and SHA-256 vector", () => {
    expect(canonicalDraftPayloadBytes(vector).toString("utf8")).toBe(
      "24:ghostie-draft-payload-v1|13:draft-🌅-42|8:whatsapp|26:12025550123@s.whatsapp.net|18:Photo 👻 | café|8:quote-π|20:2026-07-16T18:30:00Z|1:2|8:asset-α|64:/tmp/.whatsapp-mcp/draft-attachments/draft-🌅-42/photo one.jpg|13:photo one.jpg|10:image/jpeg|5:12345|64:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|7:asset-2|63:/tmp/.whatsapp-mcp/draft-attachments/draft-🌅-42/résumé.pdf|0:|15:application/pdf|2:-1|64:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );
    expect(draftPayloadDigest(vector)).toBe("9c4c23978c28f9cbcf0310ff3711aec1ef6fb3925eca797f556d06121922207f");
  });

  test("changes for every approval-bound payload field", () => {
    const base = draftPayloadDigest(vector);
    expect(draftPayloadDigest({ ...vector, body: `${vector.body}!` })).not.toBe(base);
    expect(draftPayloadDigest({ ...vector, to_handle: "12025550999@s.whatsapp.net" })).not.toBe(base);
    expect(draftPayloadDigest({ ...vector, attachments: [{ ...vector.attachments[0]!, sha256: "f".repeat(64) }] })).not.toBe(base);
  });
});
