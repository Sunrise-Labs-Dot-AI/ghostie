// AES-256-GCM wrap/unwrap for session.db row values.
//
// Each row's BLOB is laid out as:
//   [12-byte nonce][16-byte auth tag][ciphertext]
// The nonce is random per row. GCM provides authenticated encryption —
// any tampering with the BLOB (including the nonce or tag) fails the
// auth check during unwrap.
//
// The master key comes from `getOrCreateMasterKey()` in keychain.ts.
// We cache it for the lifetime of the daemon process so we don't hit
// Keychain on every read/write.

import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

import { getOrCreateMasterKey } from "./keychain.ts";

const ALGO = "aes-256-gcm";
const NONCE_LEN = 12;
const TAG_LEN = 16;

let _key: Buffer | null = null;
function getKey(): Buffer {
  if (_key != null) return _key;
  _key = getOrCreateMasterKey();
  return _key;
}

/** Encrypt a UTF-8 string. Returns [nonce | tag | ciphertext] as a Buffer. */
export function wrap(plaintext: string): Buffer {
  const key = getKey();
  const nonce = randomBytes(NONCE_LEN);
  const cipher = createCipheriv(ALGO, key, nonce);
  const ct = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([nonce, tag, ct]);
}

/** Decrypt. Throws if the blob is malformed or the auth tag doesn't verify. */
export function unwrap(blob: Buffer): string {
  if (blob.byteLength < NONCE_LEN + TAG_LEN) {
    throw new Error(`Wrapped blob too short: ${blob.byteLength} bytes`);
  }
  const key = getKey();
  const nonce = blob.subarray(0, NONCE_LEN);
  const tag = blob.subarray(NONCE_LEN, NONCE_LEN + TAG_LEN);
  const ct = blob.subarray(NONCE_LEN + TAG_LEN);
  const decipher = createDecipheriv(ALGO, key, nonce);
  decipher.setAuthTag(tag);
  const pt = Buffer.concat([decipher.update(ct), decipher.final()]);
  return pt.toString("utf8");
}

/** Test seam — drop the cached key so the next call refetches from keychain. */
export function _resetKeyCache(): void {
  _key = null;
}
