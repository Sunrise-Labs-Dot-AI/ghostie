// Minimal NSKeyedArchiver typedstream decoder for `message.attributedBody`.
//
// On macOS Big Sur+ the `message.text` column is sometimes NULL and the real
// body lives in `attributedBody`, an NSAttributedString serialized via Apple's
// typedstream format. The full format is complex (class hierarchies, object
// graph, multiple runs), but the body string is recoverable with a small,
// well-known heuristic: locate the "NSString" class marker, then read the
// next length-prefixed UTF-8 payload. This handles the overwhelmingly common
// case of a single-run plaintext body. Messages with embedded objects (file
// transfers, tapbacks) will fall back to whatever non-null `text` column
// content the caller can find — or to `null` if neither is available.

const NSSTRING_MARKER = Buffer.from("NSString", "utf8");

// Strip leading/trailing C0 control characters (NUL, SOH, …) that can leak in
// from imperfect typedstream parsing, while preserving legit whitespace
// (tab/newline/CR) and all internal text. Belt-and-suspenders on top of the
// correct length decoding below.
function stripBoundaryControls(s: string): string {
  return s
    .replace(/^[\x00-\x08\x0B\x0C\x0E-\x1F]+/, "")
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]+$/, "");
}

export function decodeAttributedBody(blob: Buffer | Uint8Array | null): string | null {
  if (!blob || blob.length === 0) return null;
  const buf = Buffer.isBuffer(blob) ? blob : Buffer.from(blob);

  const markerIdx = buf.indexOf(NSSTRING_MARKER);
  if (markerIdx < 0) return null;

  // After the class name, the encoder writes class metadata bytes, then a
  // length-prefixed UTF-8 string. Scan forward for the first plausible length
  // marker (a byte 0x01 followed by 0x2B `+`, the typedstream signature for
  // "NSString instance, UTF-8, length follows").
  let cursor = markerIdx + NSSTRING_MARKER.length;
  while (cursor < buf.length - 1) {
    if (buf[cursor] === 0x01 && buf[cursor + 1] === 0x2b) {
      cursor += 2;
      break;
    }
    cursor++;
  }
  if (cursor >= buf.length) return null;

  // typedstream variable-length integer (LITTLE-endian):
  //   < 0x80 → the byte itself is the length
  //   0x81   → uint16 LE follows (2 bytes)
  //   0x82   → uint32 LE follows (4 bytes)
  //
  // The previous version read 0x81 as a SINGLE byte and 0x82/0x83 as
  // big-endian. That silently mis-parsed every message ≥128 chars: it took
  // the low length byte as the length and the high byte as the first
  // character — producing a leading control-char artifact (e.g. "\x01…" for
  // a 256–511-char body) AND truncating to the low byte's value. That is the
  // bug behind get_thread / search_messages cutting off mid-message.
  let len: number;
  const first = buf[cursor++];
  if (first === undefined) return null;
  if (first < 0x80) {
    len = first;
  } else if (first === 0x81) {
    if (cursor + 2 > buf.length) return null;
    len = buf.readUInt16LE(cursor);
    cursor += 2;
  } else if (first === 0x82) {
    if (cursor + 4 > buf.length) return null;
    len = buf.readUInt32LE(cursor);
    cursor += 4;
  } else {
    return null;
  }

  if (len <= 0 || cursor + len > buf.length) return null;
  const decoded = stripBoundaryControls(buf.toString("utf8", cursor, cursor + len));
  return decoded.length > 0 ? decoded : null;
}

export function bestMessageBody(textCol: string | null, attributedBody: Uint8Array | null): string | null {
  if (textCol && textCol.length > 0) return textCol;
  return decodeAttributedBody(attributedBody);
}

const MAX_BODY_BYTES = 8 * 1024;

export function truncateBody(body: string | null): string | null {
  if (body == null) return null;
  const bytes = Buffer.byteLength(body, "utf8");
  if (bytes <= MAX_BODY_BYTES) return body;
  // Truncate by characters until under the byte budget. Keeps UTF-8 valid.
  let lo = 0;
  let hi = body.length;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (Buffer.byteLength(body.slice(0, mid), "utf8") <= MAX_BODY_BYTES - 64) lo = mid;
    else hi = mid - 1;
  }
  const omitted = body.length - lo;
  return `${body.slice(0, lo)}... [truncated, ${omitted} chars omitted]`;
}

// True when `body` exceeds the on-wire byte budget (truncateBody would clip
// it). Callers surface this as `body_truncated` so an agent knows the returned
// body is intentionally shortened vs. the complete message.
export function isOverBudget(body: string | null): boolean {
  return body != null && Buffer.byteLength(body, "utf8") > MAX_BODY_BYTES;
}
