import { createHash } from "node:crypto";
export interface CanonicalDraftAttachment {
  asset_id: string;
  path: string;
  filename: string;
  mime_type: string | null;
  byte_count: number;
  sha256: string;
}

export interface CanonicalDraftPayload {
  id: string;
  platform: "imessage" | "whatsapp";
  to_handle: string;
  body: string;
  quoted_message_id?: string | null;
  scheduled_send_at?: string | null;
  attachments: readonly CanonicalDraftAttachment[];
}

/**
 * Canonical v1 wire encoding shared with Swift. Each ordered component becomes
 * `<UTF8-byte-count>:<value>` and components are joined by literal `|` before
 * SHA-256. The byte count makes embedded colons/pipes unambiguous.
 */
export function canonicalDraftPayloadBytes(draft: CanonicalDraftPayload): Buffer {
  const components = [
    "ghostie-draft-payload-v1",
    draft.id,
    draft.platform,
    draft.to_handle,
    draft.body,
    draft.quoted_message_id ?? "",
    draft.scheduled_send_at ?? "",
    String(draft.attachments.length),
  ];
  for (const attachment of draft.attachments) {
    components.push(
      attachment.asset_id,
      attachment.path,
      attachment.filename,
      attachment.mime_type ?? "",
      String(attachment.byte_count),
      attachment.sha256,
    );
  }
  return Buffer.from(
    components.map((component) => `${Buffer.byteLength(component, "utf8")}:${component}`).join("|"),
    "utf8",
  );
}

export function draftPayloadDigest(draft: CanonicalDraftPayload): string {
  return createHash("sha256").update(canonicalDraftPayloadBytes(draft)).digest("hex");
}
