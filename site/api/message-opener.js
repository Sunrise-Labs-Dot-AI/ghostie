const crypto = require("node:crypto");
const blobSdk = require("@vercel/blob");

const PUBLIC_ORIGIN = "https://ghostie.app";
const PREFIX = "message-openers/";
const LINK_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_BODY_CHARS = 2_000;
const MAX_REQUEST_BYTES = 8_192;
const ID_PATTERN = /^[A-Za-z0-9_-]{16}$/;
const PHONE_PATTERN = /^\+[1-9]\d{6,14}$/;

class RequestError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function firstQueryValue(value) {
  return Array.isArray(value) ? value[0] : value;
}

function headerValue(req, name) {
  const headers = req.headers || {};
  const direct = headers[name] ?? headers[name.toLowerCase()];
  if (Array.isArray(direct)) return direct[0];
  if (typeof direct === "string") return direct;
  if (typeof req.get === "function") return req.get(name);
  return undefined;
}

function bearerToken(req) {
  const authorization = headerValue(req, "authorization") || "";
  return authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
}

function safeTokenEqual(actual, expected) {
  if (typeof actual !== "string" || typeof expected !== "string" || !expected) return false;
  const actualBytes = Buffer.from(actual);
  const expectedBytes = Buffer.from(expected);
  if (actualBytes.length !== expectedBytes.length) return false;
  return crypto.timingSafeEqual(actualBytes, expectedBytes);
}

function hasWellFormedUnicode(value) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return false;
    }
  }
  return true;
}

function validateDraft(input) {
  const phone = input?.phone;
  const body = input?.body;
  if (typeof phone !== "string" || !PHONE_PATTERN.test(phone)) {
    throw new RequestError(400, "phone must be in international format, such as +12155550123");
  }
  if (
    typeof body !== "string" ||
    body.trim().length === 0 ||
    !hasWellFormedUnicode(body) ||
    Array.from(body).length > MAX_BODY_CHARS
  ) {
    throw new RequestError(400, `body must be 1 to ${MAX_BODY_CHARS} well-formed Unicode characters`);
  }
  return { phone, body };
}

function bodyByteLength(body) {
  if (Buffer.isBuffer(body)) return body.length;
  if (typeof body === "string") return Buffer.byteLength(body);
  return Buffer.byteLength(JSON.stringify(body ?? null));
}

async function readJsonBody(req) {
  const contentType = (headerValue(req, "content-type") || "").split(";", 1)[0].trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new RequestError(415, "Content-Type must be application/json");
  }

  const declaredLength = Number(headerValue(req, "content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BYTES) {
    throw new RequestError(413, "Request body is too large");
  }

  if (req.body !== undefined) {
    if (bodyByteLength(req.body) > MAX_REQUEST_BYTES) {
      throw new RequestError(413, "Request body is too large");
    }
    if (typeof req.body === "object" && !Buffer.isBuffer(req.body)) return req.body;
    try {
      return JSON.parse(Buffer.isBuffer(req.body) ? req.body.toString("utf8") : req.body);
    } catch {
      throw new RequestError(400, "Request body must be valid JSON");
    }
  }

  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    const bytes = Buffer.from(chunk);
    total += bytes.length;
    if (total > MAX_REQUEST_BYTES) throw new RequestError(413, "Request body is too large");
    chunks.push(bytes);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new RequestError(400, "Request body must be valid JSON");
  }
}

function decodeEncryptionKey(value) {
  if (typeof value !== "string" || !value) return null;
  try {
    const key = Buffer.from(value, "base64url");
    return key.length === 32 ? key : null;
  } catch {
    return null;
  }
}

function encryptPayload(payload, id, key, randomBytes = crypto.randomBytes) {
  const iv = randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.from(`message-opener:v1:${id}`));
  const ciphertext = Buffer.concat([
    cipher.update(JSON.stringify(payload), "utf8"),
    cipher.final(),
  ]);
  return {
    v: 1,
    expiresAt: payload.expiresAt,
    iv: iv.toString("base64url"),
    tag: cipher.getAuthTag().toString("base64url"),
    ciphertext: ciphertext.toString("base64url"),
  };
}

function validEnvelope(value) {
  return Boolean(
    value &&
    value.v === 1 &&
    Number.isSafeInteger(value.expiresAt) &&
    typeof value.iv === "string" &&
    typeof value.tag === "string" &&
    typeof value.ciphertext === "string"
  );
}

function decryptPayload(envelope, id, key) {
  if (!validEnvelope(envelope)) return null;
  try {
    const decipher = crypto.createDecipheriv(
      "aes-256-gcm",
      key,
      Buffer.from(envelope.iv, "base64url")
    );
    decipher.setAAD(Buffer.from(`message-opener:v1:${id}`));
    decipher.setAuthTag(Buffer.from(envelope.tag, "base64url"));
    const plaintext = Buffer.concat([
      decipher.update(Buffer.from(envelope.ciphertext, "base64url")),
      decipher.final(),
    ]).toString("utf8");
    const payload = JSON.parse(plaintext);
    const draft = validateDraft(payload);
    if (payload.v !== 1 || !Number.isSafeInteger(payload.expiresAt)) return null;
    return { ...draft, v: 1, expiresAt: payload.expiresAt };
  } catch {
    return null;
  }
}

function openerPath(id) {
  return `${PREFIX}${id}.json`;
}

function createBlobStorage({ token, sdk = blobSdk }) {
  async function readResult(result) {
    if (!result || result.statusCode !== 200 || !result.stream) return null;
    return new Response(result.stream).text();
  }

  async function readItem(item) {
    const result = await sdk.get(item.url, { access: "public", useCache: false, token });
    return readResult(result);
  }

  return {
    async put(pathname, body) {
      return sdk.put(pathname, body, {
        access: "public",
        addRandomSuffix: false,
        allowOverwrite: false,
        cacheControlMaxAge: 60,
        contentType: "application/json",
        token,
      });
    },
    async get(pathname) {
      const result = await sdk.get(pathname, { access: "public", useCache: false, token });
      const body = await readResult(result);
      if (body === null) return null;
      return { body, target: result.blob.url, pathname: result.blob.pathname };
    },
    async list(cursor) {
      const result = await sdk.list({ prefix: PREFIX, limit: 100, cursor, token });
      return {
        items: result.blobs.map((blob) => ({ pathname: blob.pathname, url: blob.url })),
        cursor: result.hasMore ? result.cursor : undefined,
      };
    },
    read: readItem,
    async delete(target) {
      await sdk.del(target, { token });
    },
  };
}

function parseStoredEnvelope(raw) {
  try {
    const value = JSON.parse(raw);
    return validEnvelope(value) ? value : null;
  } catch {
    return null;
  }
}

function messageTargets(phone, body) {
  const encodedBody = encodeURIComponent(body);
  return [
    `sms://${phone}/?body=${encodedBody}`,
    `sms:${phone}&body=${encodedBody}`,
    `sms://${phone};?&body=${encodedBody}`,
  ];
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function scriptJson(value) {
  return JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll(">", "\\u003e")
    .replaceAll("&", "\\u0026")
    .replaceAll("\u2028", "\\u2028")
    .replaceAll("\u2029", "\\u2029");
}

function landingPage({ phone, body, expiresAt, nonce }) {
  const targets = messageTargets(phone, body);
  const primary = escapeHtml(targets[0]);
  const expiry = new Date(expiresAt).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  });
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="referrer" content="no-referrer">
  <meta http-equiv="refresh" content="0;url=${primary}">
  <title>Open in Messages</title>
  <style nonce="${nonce}">
    :root { color-scheme: light; font-family: ui-rounded, -apple-system, BlinkMacSystemFont, "SF Pro Rounded", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100svh; display: grid; place-items: center; padding: 24px; background: #f3fff9; color: #13261f; }
    main { width: min(100%, 420px); text-align: center; background: #fff; border: 2px solid #b9e8d4; border-radius: 28px; padding: 32px 24px; box-shadow: 0 18px 50px rgba(19, 67, 49, .13); }
    .ghost { font-size: 48px; line-height: 1; margin-bottom: 14px; }
    h1 { font-size: 28px; line-height: 1.1; margin: 0 0 12px; }
    p { font-size: 17px; line-height: 1.45; margin: 0 0 24px; color: #466359; }
    a { display: block; width: 100%; padding: 17px 18px; border-radius: 16px; background: #167c5a; color: #fff; font-size: 19px; font-weight: 750; text-decoration: none; }
    small { display: block; margin-top: 18px; color: #52675f; font-size: 13px; line-height: 1.4; }
    details { margin-top: 16px; color: #466359; font-size: 14px; }
    summary { cursor: pointer; padding: 6px; }
    .alternates { display: grid; gap: 10px; margin-top: 10px; }
    .alternates a { padding: 12px; border: 2px solid #167c5a; background: transparent; color: #126a4c; font-size: 16px; }
    a:focus-visible, summary:focus-visible { outline: 3px solid #13261f; outline-offset: 3px; }
  </style>
</head>
<body>
  <main>
    <div class="ghost" aria-hidden="true">👻</div>
    <h1>Opening Messages…</h1>
    <p>Compose a message to ${escapeHtml(phone)}. Nothing sends until you tap Send in Messages.</p>
    <a href="${primary}">Open in Messages</a>
    <small>If nothing happened, tap the button. This compose link expires ${escapeHtml(expiry)}.</small>
    <details>
      <summary>Having trouble?</summary>
      <div class="alternates">
        <a href="${escapeHtml(targets[1])}">Try alternate Messages link 2</a>
        <a href="${escapeHtml(targets[2])}">Try alternate Messages link 3</a>
      </div>
    </details>
  </main>
  <script nonce="${nonce}">
    (() => {
      const targets = ${scriptJson(targets)};
      let stopped = false;
      const stop = () => { stopped = true; };
      addEventListener("pagehide", stop, { once: true });
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "hidden") stop();
      });
      const open = (index) => {
        if (stopped || document.visibilityState !== "visible") return;
        if (index === 0) location.replace(targets[index]);
        else location.href = targets[index];
      };
      open(0);
      setTimeout(() => open(1), 700);
      setTimeout(() => open(2), 1400);
    })();
  </script>
</body>
</html>`;
}

function setNoStoreHeaders(res) {
  res.setHeader("Cache-Control", "private, no-store, max-age=0");
  res.setHeader("Pragma", "no-cache");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
}

function sendJson(res, status, value, head = false) {
  const body = JSON.stringify(value);
  setNoStoreHeaders(res);
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.end(head ? undefined : body);
}

function sendHtml(res, status, body, nonce, head = false) {
  setNoStoreHeaders(res);
  res.statusCode = status;
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader(
    "Content-Security-Policy",
    `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`
  );
  res.end(head ? undefined : body);
}

async function cleanupExpired(storage, now) {
  const expired = [];
  let failed = 0;
  let cursor;
  do {
    let page;
    try {
      page = await storage.list(cursor);
    } catch {
      failed += 1;
      break;
    }
    for (const item of page.items) {
      if (!item.pathname.startsWith(PREFIX) || !item.pathname.endsWith(".json")) continue;
      try {
        const envelope = parseStoredEnvelope(await storage.read(item));
        if (envelope && envelope.expiresAt <= now) expired.push(item.url || item.pathname);
      } catch {
        failed += 1;
      }
    }
    cursor = page.cursor;
  } while (cursor);

  let deleted = 0;
  for (const target of expired) {
    try {
      await storage.delete(target);
      deleted += 1;
    } catch {
      failed += 1;
    }
  }
  return { deleted, failed };
}

function createHandler({
  env = process.env,
  storage,
  now = () => Date.now(),
  randomBytes = crypto.randomBytes,
} = {}) {
  return async function handler(req, res) {
    const action = firstQueryValue(req.query?.action);
    const isHead = req.method === "HEAD";

    try {
      if (action === "create") {
        if (req.method !== "POST") {
          res.setHeader("Allow", "POST");
          return sendJson(res, 405, { error: "Method not allowed" });
        }
        if (!env.MESSAGE_OPENER_API_TOKEN || !env.BLOB_READ_WRITE_TOKEN) {
          return sendJson(res, 503, { error: "Service unavailable" });
        }
        if (!safeTokenEqual(bearerToken(req), env.MESSAGE_OPENER_API_TOKEN)) {
          return sendJson(res, 401, { error: "Unauthorized" });
        }
        const key = decodeEncryptionKey(env.MESSAGE_OPENER_ENCRYPTION_KEY);
        if (!key) return sendJson(res, 503, { error: "Service unavailable" });

        const draft = validateDraft(await readJsonBody(req));
        const createdAt = now();
        const expiresAt = createdAt + LINK_TTL_MS;
        const id = randomBytes(12).toString("base64url");
        const envelope = encryptPayload({ v: 1, ...draft, createdAt, expiresAt }, id, key, randomBytes);
        const activeStorage = storage || createBlobStorage({ token: env.BLOB_READ_WRITE_TOKEN });
        await activeStorage.put(openerPath(id), JSON.stringify(envelope));
        return sendJson(res, 201, {
          url: `${PUBLIC_ORIGIN}/t/${id}`,
          expires_at: new Date(expiresAt).toISOString(),
        });
      }

      if (action === "open") {
        if (req.method !== "GET" && !isHead) {
          res.setHeader("Allow", "GET, HEAD");
          return sendJson(res, 405, { error: "Method not allowed" });
        }
        const id = firstQueryValue(req.query?.id);
        if (typeof id !== "string" || !ID_PATTERN.test(id)) {
          return sendJson(res, 404, { error: "Link not found" }, isHead);
        }
        const key = decodeEncryptionKey(env.MESSAGE_OPENER_ENCRYPTION_KEY);
        if (!key || !env.BLOB_READ_WRITE_TOKEN) {
          return sendJson(res, 503, { error: "Service unavailable" }, isHead);
        }
        const activeStorage = storage || createBlobStorage({ token: env.BLOB_READ_WRITE_TOKEN });
        const stored = await activeStorage.get(openerPath(id));
        if (!stored) return sendJson(res, 404, { error: "Link not found" }, isHead);
        const envelope = parseStoredEnvelope(stored.body);
        const payload = envelope && decryptPayload(envelope, id, key);
        if (!payload) return sendJson(res, 404, { error: "Link not found" }, isHead);
        if (payload.expiresAt <= now()) {
          try {
            await activeStorage.delete(stored.target || stored.pathname);
          } catch {
            // The daily cleanup retries deletion. Expiry remains authoritative.
          }
          return sendJson(res, 410, { error: "Link expired" }, isHead);
        }

        const nonce = randomBytes(18).toString("base64url");
        return sendHtml(res, 200, landingPage({ ...payload, nonce }), nonce, isHead);
      }

      if (action === "cleanup") {
        if (req.method !== "GET") {
          res.setHeader("Allow", "GET");
          return sendJson(res, 405, { error: "Method not allowed" });
        }
        if (!env.CRON_SECRET || !env.BLOB_READ_WRITE_TOKEN) {
          return sendJson(res, 503, { error: "Service unavailable" });
        }
        if (!safeTokenEqual(bearerToken(req), env.CRON_SECRET)) {
          return sendJson(res, 401, { error: "Unauthorized" });
        }
        const activeStorage = storage || createBlobStorage({ token: env.BLOB_READ_WRITE_TOKEN });
        const result = await cleanupExpired(activeStorage, now());
        return sendJson(res, 200, result);
      }

      return sendJson(res, 404, { error: "Not found" }, isHead);
    } catch (error) {
      if (error instanceof RequestError) {
        return sendJson(res, error.status, { error: error.message }, isHead);
      }
      return sendJson(res, 503, { error: "Service unavailable" }, isHead);
    }
  };
}

module.exports = createHandler();
module.exports.createHandler = createHandler;
module.exports._internals = {
  ID_PATTERN,
  LINK_TTL_MS,
  MAX_BODY_CHARS,
  MAX_REQUEST_BYTES,
  PHONE_PATTERN,
  PREFIX,
  cleanupExpired,
  createBlobStorage,
  decodeEncryptionKey,
  decryptPayload,
  encryptPayload,
  hasWellFormedUnicode,
  landingPage,
  messageTargets,
  openerPath,
  parseStoredEnvelope,
  safeTokenEqual,
  validateDraft,
};
